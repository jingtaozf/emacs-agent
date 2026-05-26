"""Tests for the OTel bridge Flask server.

Each test constructs a fresh ``OtelBridgeServer`` wired to an in-memory
span exporter so state is fully isolated between cases.
"""

import pytest

from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.trace.status import StatusCode

from code_agent.otel_bridge import OtelBridgeServer


@pytest.fixture
def server():
    """Fresh server + in-memory exporter per test."""
    srv = OtelBridgeServer()
    exporter = InMemorySpanExporter()
    srv.setup(exporter=exporter)
    srv._exporter = exporter  # test-only handle for assertions
    return srv


@pytest.fixture
def client(server):
    """Flask test client for the server's app."""
    server.app.config["TESTING"] = True
    with server.app.test_client() as c:
        yield c


class TestStatus:
    """GET /otel/status health check."""

    def test_returns_ok(self, client):
        resp = client.get("/otel/status")
        assert resp.status_code == 200
        assert resp.get_json() == {"status": "ok"}

    def test_health_also_returns_ok(self, client):
        resp = client.get("/health")
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

    def test_creates_span(self, client, server):
        resp = client.post("/otel/span/start", json=self._start_payload())
        assert resp.status_code == 200
        assert resp.get_json()["status"] == "ok"
        assert self.SPAN_ID in server.spans

    def test_with_attributes(self, client, server):
        resp = client.post(
            "/otel/span/start",
            json=self._start_payload(attrs={"claude-session": "s1"}),
        )
        assert resp.status_code == 200
        assert self.SPAN_ID in server.spans

    def test_with_parent_span_id(self, client, server):
        parent_id = "def456"
        resp = client.post(
            "/otel/span/start",
            json=self._start_payload(parent_span_id=parent_id),
        )
        assert resp.status_code == 200
        assert resp.get_json()["status"] == "ok"
        assert self.SPAN_ID in server.spans

    def test_with_start_time(self, client, server):
        resp = client.post(
            "/otel/span/start",
            json=self._start_payload(start_time_ns=1000000000),
        )
        assert resp.status_code == 200
        assert self.SPAN_ID in server.spans

    def test_with_span_kind(self, client, server):
        from opentelemetry.trace import SpanKind

        resp = client.post(
            "/otel/span/start",
            json=self._start_payload(kind="SERVER"),
        )
        assert resp.status_code == 200
        span = server.spans[self.SPAN_ID]
        assert span.kind == SpanKind.SERVER

    def test_missing_trace_id_returns_400(self, client):
        resp = client.post(
            "/otel/span/start",
            json={"span_id": "abc", "name": "test"},
        )
        assert resp.status_code == 400

    def test_missing_span_id_returns_400(self, client):
        resp = client.post(
            "/otel/span/start",
            json={"trace_id": "0" * 32, "name": "test"},
        )
        assert resp.status_code == 400

    def test_missing_name_returns_400(self, client):
        resp = client.post(
            "/otel/span/start",
            json={"trace_id": "0" * 32, "span_id": "abc"},
        )
        assert resp.status_code == 400

    def test_invalid_hex_trace_id_returns_400(self, client):
        resp = client.post(
            "/otel/span/start",
            json={"trace_id": "not-hex", "span_id": "abc", "name": "t"},
        )
        assert resp.status_code == 400

    def test_invalid_hex_parent_span_id_returns_400(self, client):
        resp = client.post(
            "/otel/span/start",
            json=self._start_payload(parent_span_id="not-hex"),
        )
        assert resp.status_code == 400

    def test_default_span_kind_is_internal(self, client, server):
        from opentelemetry.trace import SpanKind

        resp = client.post(
            "/otel/span/start",
            json=self._start_payload(),
        )
        assert resp.status_code == 200
        span = server.spans[self.SPAN_ID]
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

    def test_end_ok(self, client, server):
        self._start_span(client)
        resp = client.post(
            "/otel/span/end",
            json={"span_id": self.SPAN_ID, "status": "ok"},
        )
        assert resp.status_code == 200
        assert resp.get_json()["status"] == "ok"
        assert self.SPAN_ID not in server.spans

    def test_end_error(self, client, server):
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
        assert self.SPAN_ID not in server.spans

    def test_end_with_end_time(self, client):
        self._start_span(client)
        resp = client.post(
            "/otel/span/end",
            json={"span_id": self.SPAN_ID, "end_time_ns": 2000000000},
        )
        assert resp.status_code == 200

    def test_end_unknown_span_returns_404(self, client):
        resp = client.post(
            "/otel/span/end",
            json={"span_id": "does-not-exist"},
        )
        assert resp.status_code == 404
        assert resp.get_json()["status"] == "not_found"

    def test_end_default_status_is_ok(self, client):
        self._start_span(client)
        resp = client.post(
            "/otel/span/end",
            json={"span_id": self.SPAN_ID},
        )
        assert resp.status_code == 200

    def test_end_missing_span_id_returns_400(self, client):
        resp = client.post(
            "/otel/span/end",
            json={"status": "ok"},
        )
        assert resp.status_code == 400


class TestSpanLifecycle:
    """Full span lifecycle verifying exported spans."""

    TRACE_ID = "a" * 32
    SPAN_ID = "life01"

    def test_start_then_end_exports_span(self, client, server):
        client.post(
            "/otel/span/start",
            json={
                "trace_id": self.TRACE_ID,
                "span_id": self.SPAN_ID,
                "name": "lifecycle-span",
                "attrs": {"org.block": "ai-block-1"},
            },
        )
        assert self.SPAN_ID in server.spans

        client.post(
            "/otel/span/end",
            json={
                "span_id": self.SPAN_ID,
                "status": "ok",
                "end_time_ns": 5000000000,
            },
        )
        assert self.SPAN_ID not in server.spans

        exported = server._exporter.get_finished_spans()
        assert len(exported) == 1
        assert exported[0].name == "lifecycle-span"

    def test_error_lifecycle_sets_status(self, client, server):
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

        exported = server._exporter.get_finished_spans()
        assert len(exported) == 1
        assert exported[0].status.status_code == StatusCode.ERROR
        assert "timeout" in exported[0].status.description

    def test_multiple_concurrent_spans(self, client, server):
        for i in range(5):
            client.post(
                "/otel/span/start",
                json={
                    "trace_id": self.TRACE_ID,
                    "span_id": f"concurrent-{i}",
                    "name": f"span-{i}",
                },
            )
        assert len(server.spans) == 5

        for i in range(4, -1, -1):
            resp = client.post(
                "/otel/span/end",
                json={"span_id": f"concurrent-{i}"},
            )
            assert resp.status_code == 200

        assert len(server.spans) == 0
        exported = server._exporter.get_finished_spans()
        assert len(exported) == 5

    def test_span_preserves_exact_ids(self, client, server):
        trace_id_hex = "abcd" * 8
        span_id_hex = "ef01" * 4
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
        exported = server._exporter.get_finished_spans()
        assert len(exported) == 1
        ctx = exported[0].context
        assert format(ctx.trace_id, "032x") == trace_id_hex
        assert format(ctx.span_id, "016x") == span_id_hex

    def test_root_span_has_no_parent(self, client, server):
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
        exported = server._exporter.get_finished_spans()
        assert len(exported) == 1
        assert exported[0].parent is None

    def test_child_span_references_parent(self, client, server):
        trace_id = "c" * 32
        parent_sid = "d" * 16
        child_sid = "e" * 16
        client.post(
            "/otel/span/start",
            json={
                "trace_id": trace_id,
                "span_id": parent_sid,
                "name": "parent",
            },
        )
        client.post(
            "/otel/span/start",
            json={
                "trace_id": trace_id,
                "span_id": child_sid,
                "name": "child",
                "parent_span_id": parent_sid,
            },
        )
        client.post("/otel/span/end", json={"span_id": child_sid})
        client.post("/otel/span/end", json={"span_id": parent_sid})

        exported = server._exporter.get_finished_spans()
        assert len(exported) == 2
        by_name = {s.name: s for s in exported}
        parent = by_name["parent"]
        child = by_name["child"]
        assert child.parent.span_id == parent.context.span_id
