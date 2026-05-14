"""Tracing setup and cross-process trace-context propagation.

Two concerns live here, both factored from the Python side of the
Emacs ↔ Python bridge:

1. **Tracer factory** — ``setup_tracer`` configures an OTel
   ``TracerProvider`` that ships to Phoenix (or the console as a
   fallback) and returns a ``Tracer`` for the caller. Phoenix is
   auto-started on localhost:6006 if not already listening. This path
   is stateless from the caller's perspective — every subprocess that
   needs a tracer calls ``setup_tracer`` once.

2. **TraceContextStore** — the *handshake* that lets a W3C traceparent
   travel between Emacs and this process. Emacs writes
   ``<STATUS_DIR>/<session_id>.trace-context`` at span start; the
   subprocess reads it back to seed its span as a child. The store is
   a class because it owns the directory, caches nothing (file-system
   is the source of truth), and needs to be substitutable in tests.

``STATUS_DIR`` is exported as a module constant because other modules
(``workspace_bridge``) mix session files of various shapes in the same
directory; exposing the location once keeps them aligned.
"""

from __future__ import annotations

import os
import subprocess
import time
from typing import Optional

from opentelemetry import trace
from opentelemetry.context import Context
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.trace import NonRecordingSpan, SpanContext, TraceFlags

# --------------------------------------------------------------------
# Module constants
# --------------------------------------------------------------------

PHOENIX_ENDPOINT = os.environ.get(
    "CLAUDE_OTEL_ENDPOINT", "http://localhost:6006/v1/traces"
)

PHOENIX_HEALTH_URL = PHOENIX_ENDPOINT.rsplit("/v1/traces", 1)[0] + "/health"

STATUS_DIR = "/tmp/claude-agent-status"

# ======================================================================
# Phoenix auto-start
#
# Best-effort: if Phoenix is not listening, try to launch it via uv.
# Failures are swallowed — a missing local Phoenix is not an error
# condition, it just means traces go to the console exporter instead.
# ======================================================================


def _phoenix_is_running() -> bool:
    """Return True if Phoenix's ``/health`` endpoint answers within 2s."""
    try:
        import urllib.request

        req = urllib.request.Request(PHOENIX_HEALTH_URL, method="GET")
        with urllib.request.urlopen(req, timeout=2):
            return True
    except Exception:
        return False


def _ensure_phoenix() -> None:
    """Launch Phoenix via uv if it is not already running.

    Intentionally tolerant — missing ``uv``, missing ``python`` dir, or
    any other startup failure leaves Phoenix down and traces degrade to
    the console exporter without raising.
    """
    if _phoenix_is_running():
        return
    try:
        python_dir = os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", ""), "python")
        if not os.path.isdir(python_dir):
            return
        subprocess.Popen(
            [
                "uv",
                "run",
                "--extra",
                "phoenix",
                "python",
                "-m",
                "phoenix.server.main",
                "serve",
            ],
            cwd=python_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for _ in range(10):
            time.sleep(0.5)
            if _phoenix_is_running():
                return
    except Exception:
        pass  # best-effort


# ======================================================================
# Exporter + tracer factories
# ======================================================================


def create_exporter():
    """Return the best span exporter available.

    Prefers OTLP (binary protobuf over HTTP to Phoenix). Falls back to
    the console exporter when the OTLP package is missing — useful in
    stripped-down environments where printed traces are better than no
    traces.
    """
    try:
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
            OTLPSpanExporter,
        )

        return OTLPSpanExporter(endpoint=PHOENIX_ENDPOINT)
    except ImportError:
        from opentelemetry.sdk.trace.export import ConsoleSpanExporter

        return ConsoleSpanExporter()


def setup_tracer(service_name: str = "emacs-agent") -> trace.Tracer:
    """Initialise OTel and return a ``Tracer`` for ``service_name``.

    Uses a ``SimpleSpanProcessor`` so every span exports on ``end()``
    without requiring the caller to flush. Auto-starts Phoenix first
    (best-effort) so a fresh Emacs boot has traces immediately.

    Side-effect: installs a global ``TracerProvider`` via
    ``trace.set_tracer_provider``. Calling twice is safe but the later
    provider wins.
    """
    _ensure_phoenix()
    resource = Resource.create(
        {
            "service.name": service_name,
            "openinference.project.name": "emacs-agent",
        }
    )
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(SimpleSpanProcessor(create_exporter()))
    trace.set_tracer_provider(provider)
    return trace.get_tracer(service_name)


# ======================================================================
# TraceContextStore — the Emacs ↔ Python traceparent handshake
#
# Design rationale: we file-based because the two sides are different
# processes with independent lifetimes and we want the store to survive
# either side restarting mid-session. A per-session-id file keyed on
# the terminal session holds the traceparent; a newest-file fallback
# handles the known mismatch where Emacs keys the file on a per-heading
# session id that doesn't match the terminal's.
# ======================================================================


class TraceContextStore:
    """Reads and writes W3C traceparent files under a status directory.

    The store owns its directory and the file naming convention so
    callers hand it a session id and stay agnostic of the on-disk
    shape. Tests substitute a store pointing at ``tmp_path``.
    """

    def __init__(self, status_dir: str = STATUS_DIR):
        self.status_dir = status_dir

    # ------------------------------------------------------------------
    # Read
    # ------------------------------------------------------------------

    def read(self, session_id: str) -> Optional[Context]:
        """Return an OTel context for SESSION_ID, or None if none exists.

        Tries the session-specific file first (fast path). Falls back
        to the newest ``.trace-context`` file in the directory so the
        bridge works even when Emacs keyed the file on a per-heading
        session id that doesn't match the terminal's.
        """
        ctx = self._parse_traceparent(
            os.path.join(self.status_dir, f"{session_id}.trace-context")
        )
        if ctx is not None:
            return ctx
        return self._parse_newest_traceparent()

    # ------------------------------------------------------------------
    # Write
    # ------------------------------------------------------------------

    def write(self, session_id: str, trace_id: str, span_id: str) -> None:
        """Persist a traceparent for SESSION_ID.

        Writes two files — the session-scoped one (preferred by
        ``read``) and the generic ``traceparent`` sidecar (used by
        other tools that just want "the last one")."""
        os.makedirs(self.status_dir, exist_ok=True)
        traceparent = f"00-{trace_id}-{span_id}-01"
        path = os.path.join(self.status_dir, f"{session_id}.trace-context")
        with open(path, "w") as f:
            f.write(traceparent)
        with open(os.path.join(self.status_dir, "traceparent"), "w") as f:
            f.write(traceparent)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _parse_traceparent(self, path: str) -> Optional[Context]:
        """Parse a W3C traceparent file and return the OTel context.

        Returns None for any failure (missing file, malformed payload,
        non-hex ids) — callers treat None as "no parent, start fresh"."""
        try:
            with open(path) as f:
                tp = f.read().strip()
            parts = tp.split("-")
            if len(parts) != 4:
                return None
            trace_id = int(parts[1], 16)
            span_id = int(parts[2], 16)
            parent_ctx = SpanContext(
                trace_id=trace_id,
                span_id=span_id,
                is_remote=True,
                trace_flags=TraceFlags(TraceFlags.SAMPLED),
            )
            return trace.set_span_in_context(NonRecordingSpan(parent_ctx))
        except (FileNotFoundError, ValueError, IndexError):
            return None

    def _parse_newest_traceparent(self) -> Optional[Context]:
        """Parse whichever ``.trace-context`` was written most recently."""
        try:
            candidates = []
            for f in os.listdir(self.status_dir):
                if f.endswith(".trace-context"):
                    path = os.path.join(self.status_dir, f)
                    candidates.append((os.path.getmtime(path), path))
            if candidates:
                candidates.sort(reverse=True)
                return self._parse_traceparent(candidates[0][1])
        except OSError:
            pass
        return None
