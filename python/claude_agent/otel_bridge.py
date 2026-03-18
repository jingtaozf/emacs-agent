"""OTel bridge -- Flask HTTP server that creates real OTel spans.

Started externally (make otel-server), Emacs connects via HTTP.
SimpleSpanProcessor auto-exports each span on end() -- no flush needed.

Uses a custom IdGenerator so that Emacs-assigned trace/span IDs are
preserved exactly in the exported spans.  This ensures parent-child
relationships match across processes and root spans appear correctly
in Phoenix (no phantom parent).
"""

import json
import os
import random
import threading

from flask import Flask, request, jsonify
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace.id_generator import IdGenerator
from opentelemetry.trace import SpanContext, TraceFlags, NonRecordingSpan, SpanKind
from opentelemetry.trace.status import Status, StatusCode

from claude_agent.otel_setup import create_exporter

app = Flask(__name__)

_SPAN_KIND_MAP = {
    "INTERNAL": SpanKind.INTERNAL,
    "SERVER": SpanKind.SERVER,
    "CLIENT": SpanKind.CLIENT,
    "PRODUCER": SpanKind.PRODUCER,
    "CONSUMER": SpanKind.CONSUMER,
}

# OpenInference span kinds for Phoenix UI display
_OI_KIND_ATTR = "openinference.span.kind"

# Default OTel kind -> OpenInference kind mapping
_OI_KIND_DEFAULTS = {
    "SERVER": "CHAIN",
    "CONSUMER": "CHAIN",
    "INTERNAL": "CHAIN",
    "CLIENT": "TOOL",
    "PRODUCER": "TOOL",
}


class _PresetIdGenerator(IdGenerator):
    """IdGenerator that returns preset IDs when available, random otherwise.

    Before calling tracer.start_span(), set the desired IDs via preset().
    The next generate_span_id() / generate_trace_id() call consumes them.
    """

    def __init__(self):
        self._local = threading.local()

    def preset(self, trace_id: int | None, span_id: int | None):
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


_id_gen = _PresetIdGenerator()

resource = Resource.create({
    "service.name": "emacs-agent",
    "openinference.project.name": "emacs-agent",
})
provider = TracerProvider(resource=resource, id_generator=_id_gen)
tracer = trace.get_tracer("emacs.agent", "0.1.0")

# Active spans: span_id (hex string) -> OTel Span object
spans: dict[str, trace.Span] = {}

_setup_done = False


def setup_otel(exporter=None):
    """Configure OTel provider with the given exporter.

    Call once at startup. Tests can pass a custom exporter (e.g.
    InMemorySpanExporter) to avoid I/O.  When called without arguments,
    uses create_exporter() which tries OTLP then falls back to console.
    """
    global _setup_done
    if _setup_done:
        return
    if exporter is None:
        exporter = create_exporter()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    trace.set_tracer_provider(provider)
    _setup_done = True


def _serialize_value(value):
    """Serialize a value to JSON string for span attributes."""
    if value is None:
        return "null"
    if isinstance(value, str):
        return value
    return json.dumps(value, default=str)


# -- Routes --


@app.route("/health", methods=["GET"])
@app.route("/otel/status", methods=["GET"])
def status():
    return jsonify({"status": "ok"})


@app.route("/otel/span/start", methods=["POST"])
def span_start():
    data = request.get_json()

    # Validate required keys
    for key in ("trace_id", "span_id", "name"):
        if key not in data:
            return jsonify({"status": "error", "message": f"missing required key: {key}"}), 400

    # Validate hex values
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
            return jsonify({"status": "error", "message": "invalid hex parent_span_id"}), 400

    name = data["name"]
    start_ns = data.get("start_time_ns")
    attrs = data.get("attrs") or {}

    # Preset IDs so the SDK uses our exact trace/span IDs
    _id_gen.preset(trace_id, span_id_int)

    if parent_span_id:
        parent_ctx = SpanContext(
            trace_id=trace_id,
            span_id=int(parent_span_id, 16),
            is_remote=False,
            trace_flags=TraceFlags(TraceFlags.SAMPLED),
        )
        ctx = trace.set_span_in_context(NonRecordingSpan(parent_ctx))
    else:
        # Root span: use a clean empty context so OTel creates a true root.
        # Do NOT use NonRecordingSpan(span_id=0) — span_id=0 is invalid in
        # OTel and causes the exporter to silently drop the span.
        from opentelemetry.context import Context
        ctx = Context()

    # Filter out meta-keys that control bridge behavior, not span attributes
    _META_KEYS = {"span-kind", "oi-kind", "input", "output"}
    kind_str = data.get("kind", "INTERNAL")
    span = tracer.start_span(
        name=name,
        context=ctx,
        kind=_SPAN_KIND_MAP.get(kind_str, SpanKind.INTERNAL),
        start_time=start_ns,
        attributes=(
            {k.replace("-", "."): v for k, v in attrs.items()
             if v is not None and k not in _META_KEYS}
            if attrs
            else None
        ),
    )

    # Set OpenInference span kind for Phoenix UI
    oi_kind = data.get("openinference_kind") or _OI_KIND_DEFAULTS.get(kind_str)
    if oi_kind:
        span.set_attribute(_OI_KIND_ATTR, oi_kind)

    # Set input.value for Phoenix display
    input_value = data.get("input")
    if input_value is not None:
        span.set_attribute("input.value", _serialize_value(input_value))
        span.set_attribute("input.mime_type", "application/json")

    spans[span_id_hex] = span
    return jsonify({"status": "ok"})


@app.route("/otel/span/end", methods=["POST"])
def span_end():
    data = request.get_json()
    if "span_id" not in data:
        return jsonify({"status": "error", "message": "missing required key: span_id"}), 400
    span_id_hex = data["span_id"]
    span = spans.pop(span_id_hex, None)
    if span is None:
        return jsonify({"status": "not_found"}), 404

    status_str = data.get("status", "ok")
    end_ns = data.get("end_time_ns")

    # Set output.value for Phoenix display
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


# -- Entry point --


def run_server():
    setup_otel()
    host = os.environ.get("CLAUDE_OTEL_HOST", "127.0.0.1")
    port = int(os.environ.get("CLAUDE_OTEL_PORT", "7331"))
    app.run(host=host, port=port, debug=False, use_reloader=False)


if __name__ == "__main__":
    run_server()
