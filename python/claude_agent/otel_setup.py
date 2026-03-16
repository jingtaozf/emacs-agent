"""Shared OTel configuration for all Python components."""

import os
import subprocess
import time

from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.trace import NonRecordingSpan, SpanContext, TraceFlags

PHOENIX_ENDPOINT = os.environ.get(
    "CLAUDE_OTEL_ENDPOINT", "http://localhost:6006/v1/traces"
)
PHOENIX_HEALTH_URL = PHOENIX_ENDPOINT.rsplit("/v1/traces", 1)[0] + "/health"
STATUS_DIR = "/tmp/claude-agent-status"


def _phoenix_is_running() -> bool:
    """Check if Phoenix is reachable via a quick HTTP health check."""
    try:
        import urllib.request

        req = urllib.request.Request(PHOENIX_HEALTH_URL, method="GET")
        with urllib.request.urlopen(req, timeout=2):
            return True
    except Exception:
        return False


def _ensure_phoenix() -> None:
    """Start Phoenix if not running. Best-effort, never raises."""
    if _phoenix_is_running():
        return
    try:
        python_dir = os.path.join(
            os.environ.get("CLAUDE_PLUGIN_ROOT", ""), "python"
        )
        if not os.path.isdir(python_dir):
            return
        subprocess.Popen(
            ["uv", "run", "--extra", "phoenix",
             "python", "-m", "phoenix.server.main", "serve"],
            cwd=python_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # Wait briefly for Phoenix to start accepting connections
        for _ in range(10):
            time.sleep(0.5)
            if _phoenix_is_running():
                return
    except Exception:
        pass  # best-effort


def create_exporter():
    """Create the configured span exporter (OTLP if available, else console)."""
    try:
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
            OTLPSpanExporter,
        )

        return OTLPSpanExporter(endpoint=PHOENIX_ENDPOINT)
    except ImportError:
        from opentelemetry.sdk.trace.export import ConsoleSpanExporter

        return ConsoleSpanExporter()


def setup_tracer(service_name: str = "emacs-agent") -> trace.Tracer:
    """Initialize OTel with SimpleSpanProcessor (auto-exports on span end).

    Auto-starts Phoenix if it's not running (best-effort).
    """
    _ensure_phoenix()
    resource = Resource.create({
        "service.name": service_name,
        "openinference.project.name": "emacs-agent",
    })
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(SimpleSpanProcessor(create_exporter()))
    trace.set_tracer_provider(provider)
    return trace.get_tracer(service_name)


def _parse_traceparent(path: str):
    """Parse a W3C traceparent file, return OTel context or None."""
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


def read_trace_context(session_id: str):
    """Read W3C traceparent from file, return OTel context or None.

    Tries session-specific file first. Falls back to the most recently
    written .trace-context file, which handles the case where Emacs
    writes under a per-heading session ID that differs from the
    terminal's SDD_SESSION_ID.
    """
    # Direct match — fast path
    ctx = _parse_traceparent(
        os.path.join(STATUS_DIR, f"{session_id}.trace-context")
    )
    if ctx is not None:
        return ctx

    # Fallback: newest .trace-context file (handles session ID mismatch)
    try:
        candidates = []
        for f in os.listdir(STATUS_DIR):
            if f.endswith(".trace-context"):
                path = os.path.join(STATUS_DIR, f)
                candidates.append((os.path.getmtime(path), path))
        if candidates:
            candidates.sort(reverse=True)
            return _parse_traceparent(candidates[0][1])
    except OSError:
        pass
    return None


def write_trace_context(session_id: str, trace_id: str, span_id: str) -> None:
    """Write W3C traceparent file for cross-process propagation.

    Mirror of Emacs claude-agent-trace--write-context.
    Used by sdd_bridge when it is the root (no existing traceparent from Emacs).
    """
    os.makedirs(STATUS_DIR, exist_ok=True)
    traceparent = f"00-{trace_id}-{span_id}-01"
    path = os.path.join(STATUS_DIR, f"{session_id}.trace-context")
    with open(path, "w") as f:
        f.write(traceparent)
    with open(os.path.join(STATUS_DIR, "traceparent"), "w") as f:
        f.write(traceparent)
