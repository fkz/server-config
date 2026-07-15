from __future__ import annotations

import hashlib
import hmac
import importlib.util
import json
from pathlib import Path
from types import ModuleType

import pytest


RECEIVER_PATH = (
    Path(__file__).parents[1] / "github-webhook" / "receiver.py"
)


def load_receiver() -> ModuleType:
    spec = importlib.util.spec_from_file_location("github_webhook_receiver", RECEIVER_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SECRET = b"test-secret-value"
PUSH_MAIN_PAYLOAD = json.dumps(
    {"ref": "refs/heads/main", "deleted": False}
).encode("utf-8")
PUSH_OTHER_PAYLOAD = json.dumps(
    {"ref": "refs/heads/dev", "deleted": False}
).encode("utf-8")
PUSH_DELETE_PAYLOAD = json.dumps(
    {"ref": "refs/heads/main", "deleted": True}
).encode("utf-8")


def sign(secret: bytes, body: bytes) -> str:
    digest = hmac.new(secret, body, hashlib.sha256).digest()
    return "sha256=" + digest.hex()


class _FakeConnection:
    """Minimal socket stand-in for read_http_request tests."""

    def __init__(self, raw: bytes) -> None:
        self._buffer = raw
        self.sent: list[bytes] = []

    def settimeout(self, timeout: int) -> None:  # noqa: D401 (test helper)
        pass

    def recv(self, size: int) -> bytes:
        chunk = self._buffer[:size]
        self._buffer = self._buffer[size:]
        if not chunk:
            return b""  # EOF
        return chunk

    def sendall(self, data: bytes) -> None:
        self.sent.append(data)

    def shutdown(self, _direction: int) -> None:
        pass

    def close(self) -> None:
        pass


def http_request(body: bytes, *, headers: dict[str, str] | None = None) -> bytes:
    base = {
        "content-length": str(len(body)),
    }
    if headers:
        base.update(headers)
    header_lines = "\r\n".join(f"{k}: {v}" for k, v in base.items())
    return f"POST /webhook/ HTTP/1.1\r\n{header_lines}\r\n\r\n".encode("latin-1") + body


def test_receiver_file_does_not_leak_secret_path() -> None:
    text = RECEIVER_PATH.read_text()
    # The secret path is a constant; ensure the secret value itself is never
    # inlined anywhere in the module.
    assert "github-webhook-secret" in text
    assert "test-secret-value" not in text


def test_load_secret_uses_systemd_credentials_directory(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    receiver = load_receiver()
    credential = tmp_path / "github-webhook-secret"
    credential.write_bytes(SECRET + b"\n")
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(tmp_path))

    assert receiver.load_secret() == SECRET


def test_verify_signature_accepts_valid_sha256() -> None:
    receiver = load_receiver()
    body = PUSH_MAIN_PAYLOAD
    assert receiver.verify_signature(SECRET, sign(SECRET, body), body) is True


def test_verify_signature_rejects_wrong_secret() -> None:
    receiver = load_receiver()
    body = PUSH_MAIN_PAYLOAD
    bad = sign(b"wrong-secret", body)
    assert receiver.verify_signature(SECRET, bad, body) is False


def test_verify_signature_rejects_missing_header() -> None:
    receiver = load_receiver()
    assert receiver.verify_signature(SECRET, None, PUSH_MAIN_PAYLOAD) is False


def test_verify_signature_rejects_non_sha256_scheme() -> None:
    receiver = load_receiver()
    assert receiver.verify_signature(SECRET, "sha1=abc", PUSH_MAIN_PAYLOAD) is False


def test_verify_signature_rejects_malformed_hex() -> None:
    receiver = load_receiver()
    assert receiver.verify_signature(SECRET, "sha256=zzzz", PUSH_MAIN_PAYLOAD) is False


def test_should_trigger_push_to_main() -> None:
    receiver = load_receiver()
    trigger, reason = receiver.should_trigger(
        {"x-github-event": "push"}, PUSH_MAIN_PAYLOAD
    )
    assert trigger is True
    assert "main" in reason


def test_should_trigger_ignores_non_push_events() -> None:
    receiver = load_receiver()
    trigger, _reason = receiver.should_trigger(
        {"x-github-event": "ping"}, PUSH_MAIN_PAYLOAD
    )
    assert trigger is False


def test_should_trigger_ignores_other_branch() -> None:
    receiver = load_receiver()
    trigger, reason = receiver.should_trigger(
        {"x-github-event": "push"}, PUSH_OTHER_PAYLOAD
    )
    assert trigger is False
    assert "dev" in reason or "ignored" in reason


def test_should_trigger_ignores_branch_deletion() -> None:
    receiver = load_receiver()
    trigger, _reason = receiver.should_trigger(
        {"x-github-event": "push"}, PUSH_DELETE_PAYLOAD
    )
    assert trigger is False


def test_should_trigger_rejects_invalid_json() -> None:
    receiver = load_receiver()
    trigger, _reason = receiver.should_trigger(
        {"x-github-event": "push"}, b"not-json"
    )
    assert trigger is False


def test_read_http_request_parses_valid_body() -> None:
    receiver = load_receiver()
    body = PUSH_MAIN_PAYLOAD
    conn = _FakeConnection(http_request(body))
    parsed = receiver.read_http_request(conn)
    assert parsed is not None
    headers, received = parsed
    assert received == body
    assert headers["content-length"] == str(len(body))


def test_read_http_request_rejects_oversized_content_length() -> None:
    receiver = load_receiver()
    conn = _FakeConnection(
        "POST /webhook/ HTTP/1.1\r\ncontent-length: 999999999\r\n\r\n".encode()
    )
    assert receiver.read_http_request(conn) is None


def test_read_http_request_rejects_non_post_method() -> None:
    receiver = load_receiver()
    conn = _FakeConnection(
        "GET /webhook/ HTTP/1.1\r\ncontent-length: 0\r\n\r\n".encode()
    )
    assert receiver.read_http_request(conn) is None


def test_handle_connection_rejects_invalid_signature(monkeypatch: pytest.MonkeyPatch) -> None:
    receiver = load_receiver()
    body = PUSH_MAIN_PAYLOAD
    conn = _FakeConnection(
        http_request(body, headers={"x-hub-signature-256": sign(b"nope", body),
                                    "x-github-event": "push"})
    )
    receiver.handle_connection(conn, SECRET)
    assert b"403 Forbidden" in conn.sent[0]


def test_handle_connection_triggers_on_valid_signed_main_push(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    receiver = load_receiver()
    triggered: list[str] = []

    def fake_trigger() -> tuple[int, str]:
        triggered.append("start")
        return 202, "nixos-update queued"

    monkeypatch.setattr(receiver, "trigger_update", fake_trigger)

    body = PUSH_MAIN_PAYLOAD
    conn = _FakeConnection(
        http_request(body, headers={"x-hub-signature-256": sign(SECRET, body),
                                    "x-github-event": "push"})
    )
    receiver.handle_connection(conn, SECRET)
    assert triggered == ["start"]
    assert b"202" in conn.sent[0]


def test_handle_connection_ignores_other_branch_without_trigger(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    receiver = load_receiver()
    triggered: list[str] = []
    monkeypatch.setattr(
        receiver, "trigger_update",
        lambda: triggered.append("start") or (202, "ok"),
    )
    body = PUSH_OTHER_PAYLOAD
    conn = _FakeConnection(
        http_request(body, headers={"x-hub-signature-256": sign(SECRET, body),
                                    "x-github-event": "push"})
    )
    receiver.handle_connection(conn, SECRET)
    assert triggered == []
    assert b"200" in conn.sent[0]


def test_handle_connection_rejects_when_secret_missing() -> None:
    receiver = load_receiver()
    body = PUSH_MAIN_PAYLOAD
    conn = _FakeConnection(
        http_request(body, headers={"x-hub-signature-256": sign(SECRET, body),
                                    "x-github-event": "push"})
    )
    receiver.handle_connection(conn, None)
    assert b"500" in conn.sent[0]
