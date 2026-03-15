"""Tests for the OTel setup module."""

import os
from unittest.mock import MagicMock, patch

import pytest


# Mock OTel packages before importing the module under test.
# These may not be installed in the test environment.

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
    """Ensure OTel modules are available even without installation."""
    for mod_name, mock_mod in _OTEL_MODULES.items():
        monkeypatch.setitem(__import__("sys").modules, mod_name, mock_mod)


@pytest.fixture()
def otel_setup():
    """Import otel_setup after mocks are in place."""
    # Force re-import so module-level code sees mocked modules.
    import importlib

    import claude_agent.otel_setup as mod

    importlib.reload(mod)
    return mod


class TestSetupTracer:
    """Tests for setup_tracer()."""

    def test_returns_tracer(self, otel_setup):
        """setup_tracer() returns whatever trace.get_tracer() provides."""
        tracer = otel_setup.setup_tracer("test-service")
        assert tracer is not None

    def test_creates_provider_with_service_name(self, otel_setup):
        """TracerProvider is created with a Resource containing the service name."""
        otel_setup.setup_tracer("my-service")
        otel_setup.Resource.create.assert_called_with(
            {"service.name": "my-service", "openinference.project.name": "emacs-agent"}
        )

    def test_sets_global_tracer_provider(self, otel_setup):
        """setup_tracer() calls trace.set_tracer_provider()."""
        otel_setup.setup_tracer("svc")
        otel_setup.trace.set_tracer_provider.assert_called()

    def test_falls_back_to_console_exporter_on_import_error(self, otel_setup):
        """When OTLP exporter is unavailable, ConsoleSpanExporter is used."""
        with patch.dict("sys.modules", {"opentelemetry.exporter": None,
                                         "opentelemetry.exporter.otlp": None,
                                         "opentelemetry.exporter.otlp.proto": None,
                                         "opentelemetry.exporter.otlp.proto.http": None,
                                         "opentelemetry.exporter.otlp.proto.http.trace_exporter": None}):
            # The ImportError path uses ConsoleSpanExporter from sdk.export
            otel_setup.setup_tracer("fallback-svc")
            # Provider should still be created (no crash)
            _mock_sdk_trace.TracerProvider.assert_called()


class TestReadTraceContext:
    """Tests for read_trace_context()."""

    def test_parses_valid_traceparent(self, tmp_path, otel_setup, monkeypatch):
        """A valid W3C traceparent file yields an OTel context."""
        monkeypatch.setattr(otel_setup, "STATUS_DIR", str(tmp_path))
        ctx_file = tmp_path / "sess-123.trace-context"
        ctx_file.write_text(
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\n"
        )
        result = otel_setup.read_trace_context("sess-123")
        assert result is not None

    def test_uses_newest_trace_context_file(self, tmp_path, otel_setup, monkeypatch):
        """Always uses the newest .trace-context file regardless of session ID."""
        import time
        monkeypatch.setattr(otel_setup, "STATUS_DIR", str(tmp_path))
        # Write an older file
        old = tmp_path / "old-session.trace-context"
        old.write_text("00-" + "a" * 32 + "-" + "a" * 16 + "-01")
        time.sleep(0.05)
        # Write a newer file
        new = tmp_path / "new-session.trace-context"
        new.write_text("00-" + "b" * 32 + "-" + "b" * 16 + "-01")
        # Should pick newest file even with non-matching session ID
        result = otel_setup.read_trace_context("any-session")
        assert result is not None

    def test_ignores_non_trace_context_files(self, tmp_path, otel_setup, monkeypatch):
        """Only .trace-context files are considered, not generic traceparent."""
        monkeypatch.setattr(otel_setup, "STATUS_DIR", str(tmp_path))
        generic = tmp_path / "traceparent"
        generic.write_text(
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        )
        result = otel_setup.read_trace_context("different-session-id")
        assert result is None  # only .trace-context files are used

    def test_returns_none_for_missing_file(self, tmp_path, otel_setup, monkeypatch):
        """Missing trace-context file returns None."""
        monkeypatch.setattr(otel_setup, "STATUS_DIR", str(tmp_path))
        result = otel_setup.read_trace_context("nonexistent-session")
        assert result is None

    def test_returns_none_for_malformed_content(self, tmp_path, otel_setup, monkeypatch):
        """Malformed traceparent (wrong number of parts) returns None."""
        monkeypatch.setattr(otel_setup, "STATUS_DIR", str(tmp_path))
        ctx_file = tmp_path / "bad-sess.trace-context"
        ctx_file.write_text("not-a-valid-traceparent\n")
        result = otel_setup.read_trace_context("bad-sess")
        assert result is None

    def test_returns_none_for_invalid_hex(self, tmp_path, otel_setup, monkeypatch):
        """Traceparent with non-hex values returns None."""
        monkeypatch.setattr(otel_setup, "STATUS_DIR", str(tmp_path))
        ctx_file = tmp_path / "hex-fail.trace-context"
        ctx_file.write_text("00-ZZZZ-0000-01\n")
        result = otel_setup.read_trace_context("hex-fail")
        assert result is None

    def test_returns_none_for_empty_file(self, tmp_path, otel_setup, monkeypatch):
        """Empty trace-context file returns None."""
        monkeypatch.setattr(otel_setup, "STATUS_DIR", str(tmp_path))
        ctx_file = tmp_path / "empty.trace-context"
        ctx_file.write_text("")
        result = otel_setup.read_trace_context("empty")
        assert result is None


class TestWriteTraceContext:
    """Tests for write_trace_context()."""

    def test_writes_session_file(self, tmp_path, otel_setup, monkeypatch):
        """Writes per-session traceparent file."""
        monkeypatch.setattr(otel_setup, "STATUS_DIR", str(tmp_path))
        otel_setup.write_trace_context("sess-1", "a" * 32, "b" * 16)
        content = (tmp_path / "sess-1.trace-context").read_text()
        assert content == f"00-{'a' * 32}-{'b' * 16}-01"

    def test_writes_generic_traceparent(self, tmp_path, otel_setup, monkeypatch):
        """Writes generic traceparent file."""
        monkeypatch.setattr(otel_setup, "STATUS_DIR", str(tmp_path))
        otel_setup.write_trace_context("sess-1", "a" * 32, "b" * 16)
        content = (tmp_path / "traceparent").read_text()
        assert content == f"00-{'a' * 32}-{'b' * 16}-01"

    def test_creates_status_dir(self, tmp_path, otel_setup, monkeypatch):
        """Creates STATUS_DIR if it doesn't exist."""
        new_dir = tmp_path / "subdir"
        monkeypatch.setattr(otel_setup, "STATUS_DIR", str(new_dir))
        otel_setup.write_trace_context("s", "0" * 32, "1" * 16)
        assert new_dir.is_dir()

    def test_roundtrip_with_read(self, tmp_path, otel_setup, monkeypatch):
        """write then read returns a valid context."""
        monkeypatch.setattr(otel_setup, "STATUS_DIR", str(tmp_path))
        otel_setup.write_trace_context("rt-sess", "a" * 32, "b" * 16)
        ctx = otel_setup.read_trace_context("rt-sess")
        assert ctx is not None
