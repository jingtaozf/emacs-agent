"""Tests for the OTel setup module.

Covers both the stateless tracer factory (``setup_tracer``) and the
``TraceContextStore`` class that persists Emacs↔Python traceparents.
"""

from unittest.mock import MagicMock, patch

import pytest


# Mock OTel packages before importing the module under test — they may
# not be installed in the test environment.

_mock_trace = MagicMock()
_mock_sdk_trace = MagicMock()
_mock_sdk_export = MagicMock()
_mock_sdk_resources = MagicMock()

_OTEL_MODULES = {
    "opentelemetry": MagicMock(),
    "opentelemetry.trace": _mock_trace,
    "opentelemetry.sdk": MagicMock(),
    "opentelemetry.sdk.trace": _mock_sdk_trace,
    "opentelemetry.sdk.trace.export": _mock_sdk_export,
    "opentelemetry.sdk.resources": _mock_sdk_resources,
}


@pytest.fixture(autouse=True)
def _patch_otel_imports(monkeypatch):
    for mod_name, mock_mod in _OTEL_MODULES.items():
        monkeypatch.setitem(__import__("sys").modules, mod_name, mock_mod)


@pytest.fixture()
def otel_setup():
    """Reload the module so its module-level code sees the mocked OTel."""
    import importlib

    import claude_agent.otel_setup as mod

    importlib.reload(mod)
    return mod


class TestSetupTracer:
    """Tests for ``setup_tracer()`` — the stateless tracer factory."""

    def test_returns_tracer(self, otel_setup):
        tracer = otel_setup.setup_tracer("test-service")
        assert tracer is not None

    def test_creates_provider_with_service_name(self, otel_setup):
        otel_setup.setup_tracer("my-service")
        otel_setup.Resource.create.assert_called_with(
            {
                "service.name": "my-service",
                "openinference.project.name": "emacs-agent",
            }
        )

    def test_sets_global_tracer_provider(self, otel_setup):
        otel_setup.setup_tracer("svc")
        otel_setup.trace.set_tracer_provider.assert_called()

    def test_falls_back_to_console_exporter_on_import_error(self, otel_setup):
        with patch.dict(
            "sys.modules",
            {
                "opentelemetry.exporter": None,
                "opentelemetry.exporter.otlp": None,
                "opentelemetry.exporter.otlp.proto": None,
                "opentelemetry.exporter.otlp.proto.http": None,
                "opentelemetry.exporter.otlp.proto.http.trace_exporter": None,
            },
        ):
            otel_setup.setup_tracer("fallback-svc")
            _mock_sdk_trace.TracerProvider.assert_called()


class TestTraceContextStoreRead:
    """``TraceContextStore.read`` returns an OTel context, or None."""

    def _make_store(self, otel_setup, tmp_path):
        return otel_setup.TraceContextStore(status_dir=str(tmp_path))

    def test_parses_valid_traceparent(self, tmp_path, otel_setup):
        ctx_file = tmp_path / "sess-123.trace-context"
        ctx_file.write_text("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\n")
        store = self._make_store(otel_setup, tmp_path)
        assert store.read("sess-123") is not None

    def test_falls_back_to_newest_when_session_missing(self, tmp_path, otel_setup):
        import time

        old = tmp_path / "old-session.trace-context"
        old.write_text("00-" + "a" * 32 + "-" + "a" * 16 + "-01")
        time.sleep(0.05)
        new = tmp_path / "new-session.trace-context"
        new.write_text("00-" + "b" * 32 + "-" + "b" * 16 + "-01")
        store = self._make_store(otel_setup, tmp_path)
        assert store.read("missing-session") is not None

    def test_prefers_session_specific_over_newest(self, tmp_path, otel_setup):
        import time

        session = tmp_path / "my-sess.trace-context"
        session.write_text("00-" + "a" * 32 + "-" + "a" * 16 + "-01")
        time.sleep(0.05)
        other = tmp_path / "other-sess.trace-context"
        other.write_text("00-" + "b" * 32 + "-" + "b" * 16 + "-01")
        store = self._make_store(otel_setup, tmp_path)
        assert store.read("my-sess") is not None

    def test_ignores_non_trace_context_files(self, tmp_path, otel_setup):
        generic = tmp_path / "traceparent"
        generic.write_text("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
        store = self._make_store(otel_setup, tmp_path)
        assert store.read("different-session-id") is None

    def test_returns_none_for_missing_file(self, tmp_path, otel_setup):
        store = self._make_store(otel_setup, tmp_path)
        assert store.read("nonexistent-session") is None

    def test_returns_none_for_malformed_content(self, tmp_path, otel_setup):
        ctx_file = tmp_path / "bad-sess.trace-context"
        ctx_file.write_text("not-a-valid-traceparent\n")
        store = self._make_store(otel_setup, tmp_path)
        assert store.read("bad-sess") is None

    def test_returns_none_for_invalid_hex(self, tmp_path, otel_setup):
        ctx_file = tmp_path / "hex-fail.trace-context"
        ctx_file.write_text("00-ZZZZ-0000-01\n")
        store = self._make_store(otel_setup, tmp_path)
        assert store.read("hex-fail") is None

    def test_returns_none_for_empty_file(self, tmp_path, otel_setup):
        ctx_file = tmp_path / "empty.trace-context"
        ctx_file.write_text("")
        store = self._make_store(otel_setup, tmp_path)
        assert store.read("empty") is None


class TestTraceContextStoreWrite:
    """``TraceContextStore.write`` persists traceparents to disk."""

    def test_writes_session_file(self, tmp_path, otel_setup):
        store = otel_setup.TraceContextStore(status_dir=str(tmp_path))
        store.write("sess-1", "a" * 32, "b" * 16)
        content = (tmp_path / "sess-1.trace-context").read_text()
        assert content == f"00-{'a' * 32}-{'b' * 16}-01"

    def test_writes_generic_traceparent(self, tmp_path, otel_setup):
        store = otel_setup.TraceContextStore(status_dir=str(tmp_path))
        store.write("sess-1", "a" * 32, "b" * 16)
        content = (tmp_path / "traceparent").read_text()
        assert content == f"00-{'a' * 32}-{'b' * 16}-01"

    def test_creates_status_dir(self, tmp_path, otel_setup):
        new_dir = tmp_path / "subdir"
        store = otel_setup.TraceContextStore(status_dir=str(new_dir))
        store.write("s", "0" * 32, "1" * 16)
        assert new_dir.is_dir()

    def test_roundtrip_with_read(self, tmp_path, otel_setup):
        store = otel_setup.TraceContextStore(status_dir=str(tmp_path))
        store.write("rt-sess", "a" * 32, "b" * 16)
        assert store.read("rt-sess") is not None
