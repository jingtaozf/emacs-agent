"""OTel relay server — Emacs POSTs span lifecycle; we create real spans.

The bridge runs as a small Flask server on ``CLAUDE_OTEL_PORT`` (default
7331). Emacs's tracing code does not link against the OTel SDK
directly; instead it sends structured JSON for each span start/end and
this process creates the matching ``trace.Span`` objects via a real
``TracerProvider``. A ``SimpleSpanProcessor`` auto-exports on span end
so no explicit flush is needed from either side.

The one subtle piece is the ``_PresetIdGenerator``: Emacs assigns its
own trace/span ids when it writes OTel events, and we want those exact
ids to appear in Phoenix so parent-child relationships match across
processes. The preset generator returns caller-supplied ids when
available and falls back to random ones otherwise. A new id pair is
presented immediately before each ``start_span`` call.

The server is modelled as a single ``OtelBridgeServer`` class — one
instance = one Flask app = one tracer. Flask routes are thin
delegations to methods on the instance. A module-level ``run_server``
convenience function exists only as the entry point bound by the
``otel-server`` console script in ``pyproject.toml``.
"""

from __future__ import annotations

import json
import os
import random
import threading

from flask import Flask, jsonify, request
from opentelemetry import trace
from opentelemetry.context import Context
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.id_generator import IdGenerator
from opentelemetry.trace import NonRecordingSpan, SpanContext, SpanKind, TraceFlags
from opentelemetry.trace.status import Status, StatusCode

from claude_agent.otel_setup import create_exporter

# OpenInference is Phoenix-specific metadata — see
# https://github.com/Arize-ai/openinference for the full enum. These
# defaults drive the Phoenix UI's colour coding and are overridable by
# the caller via ``openinference_kind`` in the start payload.
#
# Public module constant (no leading underscore) because workspace_bridge
# imports it for span tagging.  Single source of truth across modules.
OI_KIND_ATTR = "openinference.span.kind"

# ======================================================================
# Preset-id generator
# ======================================================================


class _PresetIdGenerator(IdGenerator):
    """IdGenerator that returns caller-supplied ids when available.

    ``preset`` stores a trace-id + span-id pair in thread-local state
    and the next ``generate_*_id`` call consumes them. When no preset
    is active we produce random ids, preserving the default SDK
    behaviour for the CLIENT-internal spans that aren't driven by
    Emacs.
    """

    def __init__(self):
        self._local = threading.local()

    def preset(self, trace_id: int | None, span_id: int | None) -> None:
        self._local.trace_id = trace_id
        self._local.span_id = span_id

    def generate_span_id(self) -> int:
        sid = getattr(self._local, "span_id", None)
        if sid is not None:
            self._local.span_id = None
            return sid
        return random.getrandbits(64)

    def generate_trace_id(self) -> int:
        tid = getattr(self._local, "trace_id", None)
        if tid is not None:
            self._local.trace_id = None
            return tid
        return random.getrandbits(128)


# ======================================================================
# Serialization helper
# ======================================================================


def _serialize_value(value):
    """Serialise an arbitrary JSON-ish value to a span-attribute string."""
    if value is None:
        return "null"
    if isinstance(value, str):
        return value
    return json.dumps(value, default=str)


# ======================================================================
# OtelBridgeServer
# ======================================================================


class OtelBridgeServer:
    """Single-instance bridge server owning the tracer and active-span map.

    One instance = one Flask app = one OTel provider. Tests construct a
    fresh instance (usually with an ``InMemorySpanExporter``) rather
    than rely on module globals, so state is fully isolated between
    tests.
    """

    # ------------------------------------------------------------------
    # Class-level translation tables (override in subclasses for testing
    # alternate OTel/OpenInference kind mappings without touching globals)
    # ------------------------------------------------------------------

    SPAN_KIND_MAP: dict[str, SpanKind] = {
        "INTERNAL": SpanKind.INTERNAL,
        "SERVER": SpanKind.SERVER,
        "CLIENT": SpanKind.CLIENT,
        "PRODUCER": SpanKind.PRODUCER,
        "CONSUMER": SpanKind.CONSUMER,
    }
    """OTel SpanKind translation — string from start-span payload → SpanKind enum."""

    OI_KIND_DEFAULTS: dict[str, str] = {
        "SERVER": "CHAIN",
        "CONSUMER": "CHAIN",
        "INTERNAL": "CHAIN",
        "CLIENT": "TOOL",
        "PRODUCER": "TOOL",
    }
    """OpenInference (Phoenix) span-kind defaults keyed by the OTel kind name.
    Caller can override per-span via ``openinference_kind`` in the start payload."""

    META_ATTR_KEYS: frozenset[str] = frozenset(
        {"span-kind", "oi-kind", "input", "output"}
    )
    """Keys the bridge consumes for routing — never forwarded as span
    attributes because they're not part of the semantic schema."""

    def __init__(self, service_name: str = "emacs-agent"):
        self.id_gen = _PresetIdGenerator()
        self.resource = Resource.create(
            {
                "service.name": service_name,
                "openinference.project.name": "emacs-agent",
            }
        )
        self.provider = TracerProvider(resource=self.resource, id_generator=self.id_gen)
        # Pull the tracer from *our* provider so multiple server instances
        # (e.g. across tests) don't share spans via the SDK global.
        self.tracer = self.provider.get_tracer("emacs.agent", "0.1.0")
        self.spans: dict[str, trace.Span] = {}
        self._setup_done = False
        self.app = Flask(__name__)
        self._register_routes()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def setup(self, exporter=None) -> None:
        """Attach the span exporter exactly once.

        Tests typically pass an in-memory exporter to avoid I/O. A
        second call after the first no-ops so the caller doesn't need
        to remember which init path they're on.
        """
        if self._setup_done:
            return
        if exporter is None:
            exporter = create_exporter()
        self.provider.add_span_processor(SimpleSpanProcessor(exporter))
        trace.set_tracer_provider(self.provider)
        self._setup_done = True

    def run(self, host: str = "127.0.0.1", port: int = 7331) -> None:
        """Run the Flask app (blocking)."""
        self.setup()
        self.app.run(host=host, port=port, debug=False, use_reloader=False)

    # ------------------------------------------------------------------
    # Route registration
    # ------------------------------------------------------------------

    def _register_routes(self) -> None:
        self.app.add_url_rule(
            "/health",
            "health",
            lambda: jsonify({"status": "ok"}),
            methods=["GET"],
        )
        self.app.add_url_rule(
            "/otel/status",
            "otel_status",
            lambda: jsonify({"status": "ok"}),
            methods=["GET"],
        )
        self.app.add_url_rule(
            "/otel/span/start",
            "span_start",
            self._handle_span_start,
            methods=["POST"],
        )
        self.app.add_url_rule(
            "/otel/span/end",
            "span_end",
            self._handle_span_end,
            methods=["POST"],
        )

    # ------------------------------------------------------------------
    # Span handlers
    # ------------------------------------------------------------------

    def _handle_span_start(self):
        """POST /otel/span/start — create a new span with Emacs-supplied ids."""
        data = request.get_json()

        for key in ("trace_id", "span_id", "name"):
            if key not in data:
                return (
                    jsonify(
                        {"status": "error", "message": f"missing required key: {key}"}
                    ),
                    400,
                )

        try:
            trace_id = int(data["trace_id"], 16)
        except ValueError:
            return jsonify({"status": "error", "message": "invalid hex trace_id"}), 400

        span_id_hex = data["span_id"]
        try:
            span_id_int = int(span_id_hex, 16)
        except ValueError:
            span_id_int = None

        parent_span_id = data.get("parent_span_id")
        if parent_span_id:
            try:
                int(parent_span_id, 16)
            except ValueError:
                return (
                    jsonify(
                        {"status": "error", "message": "invalid hex parent_span_id"}
                    ),
                    400,
                )

        name = data["name"]
        start_ns = data.get("start_time_ns")
        attrs = data.get("attrs") or {}

        # Preset ids so the SDK uses Emacs-supplied trace/span ids verbatim.
        self.id_gen.preset(trace_id, span_id_int)

        ctx = self._build_span_context(trace_id, parent_span_id)

        kind_str = data.get("kind", "INTERNAL")
        filtered_attrs = (
            {
                k.replace("-", "."): v
                for k, v in attrs.items()
                if v is not None and k not in self.META_ATTR_KEYS
            }
            if attrs
            else None
        )
        span = self.tracer.start_span(
            name=name,
            context=ctx,
            kind=self.SPAN_KIND_MAP.get(kind_str, SpanKind.INTERNAL),
            start_time=start_ns,
            attributes=filtered_attrs,
        )

        oi_kind = data.get("openinference_kind") or self.OI_KIND_DEFAULTS.get(kind_str)
        if oi_kind:
            span.set_attribute(OI_KIND_ATTR, oi_kind)

        input_value = data.get("input")
        if input_value is not None:
            span.set_attribute("input.value", _serialize_value(input_value))
            span.set_attribute("input.mime_type", "application/json")

        self.spans[span_id_hex] = span
        return jsonify({"status": "ok"})

    def _handle_span_end(self):
        """POST /otel/span/end — finalise and export the named span."""
        data = request.get_json()
        if "span_id" not in data:
            return (
                jsonify(
                    {"status": "error", "message": "missing required key: span_id"}
                ),
                400,
            )
        span_id_hex = data["span_id"]
        span = self.spans.pop(span_id_hex, None)
        if span is None:
            return jsonify({"status": "not_found"}), 404

        status_str = data.get("status", "ok")
        end_ns = data.get("end_time_ns")

        output_value = data.get("output")
        if output_value is not None:
            span.set_attribute("output.value", _serialize_value(output_value))
            span.set_attribute("output.mime_type", "application/json")

        if status_str == "error":
            error_msg = data.get("error_message", "unknown error")
            span.set_status(Status(StatusCode.ERROR, error_msg))
            span.set_attribute("error.message", error_msg)
        else:
            span.set_status(Status(StatusCode.OK))

        span.end(end_time=end_ns)
        return jsonify({"status": "ok"})

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _build_span_context(self, trace_id: int, parent_span_id_hex: str | None):
        """Construct the OTel context for a new span.

        With a parent: seed a ``NonRecordingSpan`` so child-of semantics
        hold. Without a parent: a clean empty ``Context`` so the SDK
        treats the span as a true root (using ``NonRecordingSpan`` with
        ``span_id=0`` would silently drop the span in the exporter).
        """
        if parent_span_id_hex:
            parent_ctx = SpanContext(
                trace_id=trace_id,
                span_id=int(parent_span_id_hex, 16),
                is_remote=False,
                trace_flags=TraceFlags(TraceFlags.SAMPLED),
            )
            return trace.set_span_in_context(NonRecordingSpan(parent_ctx))
        return Context()


# ======================================================================
# Entry point
# ======================================================================


def run_server() -> None:
    """Start the default OtelBridgeServer on ``CLAUDE_OTEL_HOST:PORT``."""
    host = os.environ.get("CLAUDE_OTEL_HOST", "127.0.0.1")
    port = int(os.environ.get("CLAUDE_OTEL_PORT", "7331"))
    OtelBridgeServer().run(host=host, port=port)


if __name__ == "__main__":
    run_server()
