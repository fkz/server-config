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


def test_register_exposes_service_scoped_logs_tool() -> None:
    plugin = load_plugin()
    context = RecordingContext()

    plugin.register(context)

    registration = context.tools["systemd_service_logs"]
    schema = registration["schema"]
    assert isinstance(schema, dict)
    assert schema["parameters"] == {
        "type": "object",
        "properties": {
            "service": {
                "type": "string",
                "description": "Exact systemd service unit, for example sshd.service",
            }
        },
        "required": ["service"],
        "additionalProperties": False,
    }


def test_service_logs_handler_confirms_and_returns_requested_unit_logs(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    plugin = load_plugin()
    consented: list[str] = []
    fetched: list[str] = []
    monkeypatch.setattr(
        plugin,
        "_request_service_logs_consent",
        lambda service: consented.append(service) or "accept",
    )
    monkeypatch.setattr(
        plugin,
        "_fetch_service_logs_via_broker",
        lambda service: fetched.append(service)
        or ("Jul 13 host systemd[1]: Started sshd.service\n", False, 1),
    )

    result = json.loads(plugin._handle_systemd_service_logs({"service": "sshd.service"}))

    assert consented == ["sshd.service"]
    assert fetched == ["sshd.service"]
    assert result == {
        "success": True,
        "unit": "sshd.service",
        "requested_lines": 200,
        "returned_lines": 1,
        "truncated": False,
        "logs": "Jul 13 host systemd[1]: Started sshd.service\n",
    }


def test_service_logs_handler_fails_closed_without_fresh_consent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    plugin = load_plugin()
    monkeypatch.setattr(
        plugin, "_request_service_logs_consent", lambda _service: "decline"
    )
    monkeypatch.setattr(
        plugin,
        "_fetch_service_logs_via_broker",
        lambda _service: pytest.fail("broker must not be contacted after declined consent"),
    )

    result = json.loads(
        plugin._handle_systemd_service_logs({"service": "sshd.service"})
    )

    assert result == {
        "success": False,
        "status": "denied",
        "error": "the user did not approve logs for sshd.service",
    }


def test_service_logs_handler_rejects_invalid_units_before_consent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    plugin = load_plugin()
    monkeypatch.setattr(
        plugin,
        "_request_service_logs_consent",
        lambda _service: pytest.fail("invalid units must not reach consent"),
    )
    monkeypatch.setattr(
        plugin,
        "_fetch_service_logs_via_broker",
        lambda _service: pytest.fail("invalid units must not reach the broker"),
    )

    for params in (
        {},
        {"service": ""},
        {"service": "sshd"},
        {"service": "../sshd.service"},
        {"service": "sshd.service\nstart"},
        {"service": "sshd.socket"},
        {"service": "sshd.service", "lines": 500},
    ):
        result = json.loads(plugin._handle_systemd_service_logs(params))
        assert result["success"] is False
        assert "valid systemd .service unit" in result["error"]


def test_root_broker_validates_service_and_keeps_journal_options_fixed() -> None:
    nix = (Path(__file__).parents[1] / "hermes.nix").read_text()

    assert 'journalctl = os.path.join(systemd_package, "bin", "journalctl")' in nix
    for fixed_argument in (
        '"--lines=200"',
        '"--no-pager"',
        '"--output=short-iso"',
    ):
        assert fixed_argument in nix
    assert 'service_pattern.fullmatch(service)' in nix
    assert 'r"[A-Za-z0-9][A-Za-z0-9_.:@-]{0,246}\\.service\\Z"' in nix
    assert '[journalctl, f"--unit={service}"' in nix
    logs_branch = nix.split('if service is not None:', 1)[1].split(
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
    assert 'f"bytes={len(log_bytes)} "' in logs_branch
    assert 'f"lines={line_count}\\n"' in logs_branch
    assert "connection.settimeout(5)" in nix
    assert 'MemoryMax = "128M";' in nix


def test_root_broker_requires_canonical_main_pid_output() -> None:
    nix = (Path(__file__).parents[1] / "hermes.nix").read_text()

    assert "pid_value.isascii()" in nix
    assert "pid_value.isdecimal()" in nix
    assert 'result.stdout.endswith("\\n")' in nix
    assert 'result.stdout.count("\\n") != 1' in nix


def test_log_client_parses_explicit_truncation_metadata(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    plugin = load_plugin()

    class FakeSocket:
        def __init__(self, *_args: object) -> None:
            self.chunks = [
                b"ok truncated=1 bytes=13 lines=2\nolder\n",
                b"newest\n",
                b"",
            ]

        def __enter__(self) -> "FakeSocket":
            return self

        def __exit__(self, *_args: object) -> None:
            return None

        def settimeout(self, timeout: int) -> None:
            assert timeout == 45

        def connect(self, path: str) -> None:
            assert path == "/run/hermes-nixos-update-broker/socket"

        def sendall(self, request: bytes) -> None:
            assert request == b"logs sshd.service\n"

        def shutdown(self, _direction: int) -> None:
            return None

        def recv(self, _size: int) -> bytes:
            return self.chunks.pop(0)

    monkeypatch.setattr(plugin.socket, "socket", FakeSocket)

    assert plugin._fetch_service_logs_via_broker("sshd.service") == (
        "older\nnewest\n",
        True,
        2,
    )


def test_log_client_rejects_incomplete_payload_with_unchanged_line_count(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    plugin = load_plugin()
    response = b"ok truncated=0 bytes=20 lines=1\npartial-one-line"

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
        plugin._fetch_service_logs_via_broker("sshd.service")


@pytest.mark.parametrize(
    "response",
    [
        b"ok 1 2\nmalformed\n",
        b"ok truncated=0 bytes=1_0 lines=1\nx\n",
        b"ok truncated=0 bytes=+1 lines=1\nx\n",
        b"ok truncated=0 bytes=01 lines=1\nx\n",
        b"ok truncated=0 bytes=3 lines=1\nx\n",
        b"ok truncated=0 bytes=2 lines=1_0\nx\n",
        b"ok truncated=0 bytes=2 lines=+1\nx\n",
        b"ok truncated=0 bytes=2 lines=0\nx\n",
        b"ok truncated=0 bytes=2 lines=2\nx\n",
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
        plugin._fetch_service_logs_via_broker("sshd.service")
