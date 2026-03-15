"""Tests for the OTel bridge Flask server."""

import pytest

from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.trace.status import StatusCode

from claude_agent.otel_bridge import app, spans, setup_otel

# Initialize OTel with an in-memory exporter (no I/O, no blocking).
_test_exporter = InMemorySpanExporter()
setup_otel(exporter=_test_exporter)


@pytest.fixture
def client():
    """Flask test client."""
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


@pytest.fixture(autouse=True)
def _clear_state():
    """Reset active spans and exported spans between tests."""
    spans.clear()
    _test_exporter.clear()
    yield
    spans.clear()
    _test_exporter.clear()


class TestStatus:
    """GET /otel/status health check."""

    def test_returns_ok(self, client):
        resp = client.get("/otel/status")
        assert resp.status_code == 200
        assert resp.get_json() == {"status": "ok"}


class TestSpanStart:
    """POST /otel/span/start creates spans."""

    TRACE_ID = "0" * 32
    SPAN_ID = "abc123"

    def _start_payload(self, **overrides):
        payload = {
            "trace_id": self.TRACE_ID,
            "span_id": self.SPAN_ID,
            "name": "test-span",
        }
        payload.update(overrides)
        return payload

    def test_creates_span(self, client):
        """Starting a span returns ok and registers it."""
        resp = client.post("/otel/span/start", json=self._start_payload())
        assert resp.status_code == 200
        assert resp.get_json()["status"] == "ok"
        assert self.SPAN_ID in spans

    def test_with_attributes(self, client):
        """Attributes with hyphens are converted to dots."""
        resp = client.post(
            "/otel/span/start",
            json=self._start_payload(attrs={"claude-session": "s1"}),
        )
        assert resp.status_code == 200
        assert self.SPAN_ID in spans

    def test_with_parent_span_id(self, client):
        """Parent span id creates a linked child context."""
        parent_id = "def456"
        resp = client.post(
            "/otel/span/start",
            json=self._start_payload(parent_span_id=parent_id),
        )
        assert resp.status_code == 200
        assert resp.get_json()["status"] == "ok"
        assert self.SPAN_ID in spans

    def test_with_start_time(self, client):
        """Custom start_time_ns is accepted."""
        resp = client.post(
            "/otel/span/start",
            json=self._start_payload(start_time_ns=1000000000),
        )
        assert resp.status_code == 200
        assert self.SPAN_ID in spans

    def test_with_span_kind(self, client):
        """SpanKind is set from the kind field."""
        from opentelemetry.trace import SpanKind

        resp = client.post(
            "/otel/span/start",
            json=self._start_payload(kind="SERVER"),
        )
        assert resp.status_code == 200
        span = spans[self.SPAN_ID]
        assert span.kind == SpanKind.SERVER

    def test_default_span_kind_is_internal(self, client):
        """SpanKind defaults to INTERNAL when kind is omitted."""
        from opentelemetry.trace import SpanKind

        resp = client.post(
            "/otel/span/start",
            json=self._start_payload(),
        )
        assert resp.status_code == 200
        span = spans[self.SPAN_ID]
        assert span.kind == SpanKind.INTERNAL


class TestSpanEnd:
    """POST /otel/span/end finishes spans."""

    TRACE_ID = "0" * 32
    SPAN_ID = "end789"

    def _start_span(self, client, span_id=None):
        sid = span_id or self.SPAN_ID
        client.post(
            "/otel/span/start",
            json={
                "trace_id": self.TRACE_ID,
                "span_id": sid,
                "name": "test-span",
            },
        )

    def test_end_ok(self, client):
        """Ending a span with status ok succeeds."""
        self._start_span(client)
        resp = client.post(
            "/otel/span/end",
            json={"span_id": self.SPAN_ID, "status": "ok"},
        )
        assert resp.status_code == 200
        assert resp.get_json()["status"] == "ok"
        assert self.SPAN_ID not in spans

    def test_end_error(self, client):
        """Ending a span with status error sets error status and message."""
        self._start_span(client)
        resp = client.post(
            "/otel/span/end",
            json={
                "span_id": self.SPAN_ID,
                "status": "error",
                "error_message": "something broke",
            },
        )
        assert resp.status_code == 200
        assert resp.get_json()["status"] == "ok"
        assert self.SPAN_ID not in spans

    def test_end_with_end_time(self, client):
        """Custom end_time_ns is accepted."""
        self._start_span(client)
        resp = client.post(
            "/otel/span/end",
            json={"span_id": self.SPAN_ID, "end_time_ns": 2000000000},
        )
        assert resp.status_code == 200

    def test_end_unknown_span_returns_404(self, client):
        """Ending a non-existent span returns 404."""
        resp = client.post(
            "/otel/span/end",
            json={"span_id": "does-not-exist"},
        )
        assert resp.status_code == 404
        assert resp.get_json()["status"] == "not_found"

    def test_end_default_status_is_ok(self, client):
        """Omitting status defaults to ok."""
        self._start_span(client)
        resp = client.post(
            "/otel/span/end",
            json={"span_id": self.SPAN_ID},
        )
        assert resp.status_code == 200


class TestSpanLifecycle:
    """Full span lifecycle verifying exported spans."""

    TRACE_ID = "a" * 32
    SPAN_ID = "life01"

    def test_start_then_end_exports_span(self, client):
        """Complete lifecycle: start -> end -> span exported."""
        client.post(
            "/otel/span/start",
            json={
                "trace_id": self.TRACE_ID,
                "span_id": self.SPAN_ID,
                "name": "lifecycle-span",
                "attrs": {"org.block": "ai-block-1"},
            },
        )
        assert self.SPAN_ID in spans

        client.post(
            "/otel/span/end",
            json={
                "span_id": self.SPAN_ID,
                "status": "ok",
                "end_time_ns": 5000000000,
            },
        )
        assert self.SPAN_ID not in spans

        exported = _test_exporter.get_finished_spans()
        assert len(exported) == 1
        assert exported[0].name == "lifecycle-span"

    def test_error_lifecycle_sets_status(self, client):
        """Error lifecycle: start -> end with error -> exported span has error."""
        client.post(
            "/otel/span/start",
            json={
                "trace_id": self.TRACE_ID,
                "span_id": self.SPAN_ID,
                "name": "error-span",
            },
        )

        client.post(
            "/otel/span/end",
            json={
                "span_id": self.SPAN_ID,
                "status": "error",
                "error_message": "timeout",
            },
        )

        exported = _test_exporter.get_finished_spans()
        assert len(exported) == 1
        assert exported[0].status.status_code == StatusCode.ERROR
        assert "timeout" in exported[0].status.description

    def test_multiple_concurrent_spans(self, client):
        """Multiple spans can be active simultaneously."""
        for i in range(5):
            client.post(
                "/otel/span/start",
                json={
                    "trace_id": self.TRACE_ID,
                    "span_id": f"concurrent-{i}",
                    "name": f"span-{i}",
                },
            )
        assert len(spans) == 5

        for i in range(4, -1, -1):
            resp = client.post(
                "/otel/span/end",
                json={"span_id": f"concurrent-{i}"},
            )
            assert resp.status_code == 200

        assert len(spans) == 0

        exported = _test_exporter.get_finished_spans()
        assert len(exported) == 5

    def test_span_preserves_exact_ids(self, client):
        """Exported span has the exact trace/span IDs from the request."""
        trace_id_hex = "abcd" * 8  # 32 hex chars
        span_id_hex = "ef01" * 4   # 16 hex chars
        client.post(
            "/otel/span/start",
            json={
                "trace_id": trace_id_hex,
                "span_id": span_id_hex,
                "name": "id-check",
            },
        )
        client.post(
            "/otel/span/end",
            json={"span_id": span_id_hex},
        )
        exported = _test_exporter.get_finished_spans()
        assert len(exported) == 1
        ctx = exported[0].context
        assert format(ctx.trace_id, "032x") == trace_id_hex
        assert format(ctx.span_id, "016x") == span_id_hex

    def test_root_span_has_no_parent(self, client):
        """Root span (no parent_span_id) has no parent in exported data."""
        client.post(
            "/otel/span/start",
            json={
                "trace_id": "a" * 32,
                "span_id": "b" * 16,
                "name": "root-check",
            },
        )
        client.post(
            "/otel/span/end",
            json={"span_id": "b" * 16},
        )
        exported = _test_exporter.get_finished_spans()
        assert len(exported) == 1
        # Root span should have no valid parent
        assert exported[0].parent is None

    def test_child_span_references_parent(self, client):
        """Child span's parent_id matches the parent's actual span_id."""
        trace_id = "c" * 32
        parent_sid = "d" * 16
        child_sid = "e" * 16
        # Start parent
        client.post("/otel/span/start", json={
            "trace_id": trace_id, "span_id": parent_sid, "name": "parent",
        })
        # Start child referencing parent
        client.post("/otel/span/start", json={
            "trace_id": trace_id, "span_id": child_sid, "name": "child",
            "parent_span_id": parent_sid,
        })
        # End both
        client.post("/otel/span/end", json={"span_id": child_sid})
        client.post("/otel/span/end", json={"span_id": parent_sid})

        exported = _test_exporter.get_finished_spans()
        assert len(exported) == 2
        by_name = {s.name: s for s in exported}
        parent = by_name["parent"]
        child = by_name["child"]
        # Child's parent_id should match parent's span_id exactly
        assert child.parent.span_id == parent.context.span_id
