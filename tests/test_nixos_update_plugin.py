from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType

import pytest


PLUGIN_PATH = Path(__file__).parents[1] / "plugins" / "nixos-update" / "__init__.py"


def load_plugin() -> ModuleType:
    spec = importlib.util.spec_from_file_location("nixos_update_plugin", PLUGIN_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RecordingContext:
    def __init__(self) -> None:
        self.tools: dict[str, dict[str, object]] = {}

    def register_tool(self, **kwargs: object) -> None:
        self.tools[str(kwargs["name"])] = kwargs


def test_register_exposes_parameterless_update_logs_tool() -> None:
    plugin = load_plugin()
    context = RecordingContext()

    plugin.register(context)

    registration = context.tools["nixos_update_logs"]
    schema = registration["schema"]
    assert isinstance(schema, dict)
    assert schema["parameters"] == {
        "type": "object",
        "properties": {},
        "additionalProperties": False,
    }


def test_update_logs_handler_returns_bounded_fixed_unit_logs(monkeypatch: pytest.MonkeyPatch) -> None:
    plugin = load_plugin()
    monkeypatch.setattr(plugin, "_request_update_logs_consent", lambda: "accept")
    monkeypatch.setattr(
        plugin,
        "_fetch_update_logs_via_broker",
        lambda: (
            "Jul 13 20:00:00 host systemd[1]: Started nixos-update.service",
            False,
            1,
        ),
    )

    result = json.loads(plugin._handle_nixos_update_logs({}))

    assert result == {
        "success": True,
        "unit": "nixos-update.service",
        "requested_lines": 200,
        "returned_lines": 1,
        "truncated": False,
        "logs": "Jul 13 20:00:00 host systemd[1]: Started nixos-update.service",
    }


def test_update_logs_handler_fails_closed_without_fresh_consent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    plugin = load_plugin()
    monkeypatch.setattr(plugin, "_request_update_logs_consent", lambda: "decline")
    monkeypatch.setattr(
        plugin,
        "_fetch_update_logs_via_broker",
        lambda: pytest.fail("broker must not be contacted after declined consent"),
    )

    result = json.loads(plugin._handle_nixos_update_logs({}))

    assert result == {
        "success": False,
        "status": "denied",
        "error": "the user did not approve this NixOS update log request",
    }


def test_update_logs_handler_rejects_all_parameters(monkeypatch: pytest.MonkeyPatch) -> None:
    plugin = load_plugin()
    called = False

    def unexpected_fetch() -> str:
        nonlocal called
        called = True
        return ""

    monkeypatch.setattr(plugin, "_fetch_update_logs_via_broker", unexpected_fetch)

    result = json.loads(plugin._handle_nixos_update_logs({"lines": 500}))

    assert result == {"success": False, "error": "this tool accepts no parameters"}
    assert called is False


def test_root_broker_uses_only_a_fixed_bounded_journal_query() -> None:
    nix = (Path(__file__).parents[1] / "hermes.nix").read_text()

    assert 'journalctl = os.path.join(systemd_package, "bin", "journalctl")' in nix
    for fixed_argument in (
        '"--unit=nixos-update.service"',
        '"--lines=200"',
        '"--no-pager"',
        '"--output=short-iso"',
    ):
        assert fixed_argument in nix
    assert 'if request == b"logs\\n":' in nix
    logs_branch = nix.split('if request == b"logs\\n":', 1)[1].split(
        'if request != b"start\\n":', 1
    )[0]
    assert "bounded_process_tail(" in logs_branch
    assert "capture_output=True" not in logs_branch
    assert "subprocess.Popen(" in nix
    assert "selector = None" in nix
    assert "except BaseException:" in nix
    assert "selectors.DefaultSelector()" in nix
    assert "tail = tail[-max_bytes:]" in nix
    assert 'f"ok truncated={int(truncated)} "' in logs_branch
    assert 'f"lines={line_count}\\n"' in logs_branch
    assert "connection.settimeout(5)" in nix
    assert 'MemoryMax = "128M";' in nix


def test_log_client_parses_explicit_truncation_metadata(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    plugin = load_plugin()

    class FakeSocket:
        def __init__(self, *_args: object) -> None:
            self.chunks = [b"ok truncated=1 lines=2\nolder\n", b"newest\n", b""]

        def __enter__(self) -> "FakeSocket":
            return self

        def __exit__(self, *_args: object) -> None:
            return None

        def settimeout(self, timeout: int) -> None:
            assert timeout == 45

        def connect(self, path: str) -> None:
            assert path == "/run/hermes-nixos-update-broker/socket"

        def sendall(self, request: bytes) -> None:
            assert request == b"logs\n"

        def shutdown(self, _direction: int) -> None:
            return None

        def recv(self, _size: int) -> bytes:
            return self.chunks.pop(0)

    monkeypatch.setattr(plugin.socket, "socket", FakeSocket)

    assert plugin._fetch_update_logs_via_broker() == (
        "older\nnewest\n",
        True,
        2,
    )


@pytest.mark.parametrize(
    "response",
    [
        b"ok 1 2\nmalformed\n",
        b"ok truncated=0 lines=1_0\nx\n",
        b"ok truncated=0 lines=+1\nx\n",
        b"ok truncated=0 lines=0\nx\n",
        b"ok truncated=0 lines=2\nx\n",
    ],
)
def test_log_client_rejects_malformed_or_mismatched_metadata(
    monkeypatch: pytest.MonkeyPatch,
    response: bytes,
) -> None:
    plugin = load_plugin()

    class FakeSocket:
        def __init__(self, *_args: object) -> None:
            self.chunks = [response, b""]

        def __enter__(self) -> "FakeSocket":
            return self

        def __exit__(self, *_args: object) -> None:
            return None

        def settimeout(self, _timeout: int) -> None:
            return None

        def connect(self, _path: str) -> None:
            return None

        def sendall(self, _request: bytes) -> None:
            return None

        def shutdown(self, _direction: int) -> None:
            return None

        def recv(self, _size: int) -> bytes:
            return self.chunks.pop(0)

    monkeypatch.setattr(plugin.socket, "socket", FakeSocket)

    with pytest.raises(RuntimeError):
        plugin._fetch_update_logs_via_broker()
