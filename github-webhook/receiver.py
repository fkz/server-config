#!/usr/bin/env python3
"""GitHub webhook receiver that triggers a NixOS update on push to main.

The receiver runs as a small root-owned systemd service bound to
127.0.0.1:8081. nginx terminates TLS on 443 and reverse-proxies
``/webhook/`` here. Every request is authenticated with an HMAC-SHA256
signature using a shared secret that lives only on the host (never in the
Nix store). Only ``push`` events on the ``main`` branch start the fixed
``nixos-update.service`` unit via systemctl.

Fail-closed design:
  * A missing or malformed signature is rejected (no update).
  * An unverified signature is rejected (no update).
  * Any non-push event or a push to a non-``main`` branch is ignored.
  * Requests are size-bounded; oversized bodies are dropped.
  * Memory and capability are constrained by the systemd unit, not here.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import selectors
import socket
import struct
import subprocess
import sys
import time

SECRET_PATH = "/var/lib/hermes/.hermes/secrets/github-webhook-secret"
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8081
MAX_BODY_BYTES = 1_048_576  # 1 MiB; GitHub push payloads stay well below this
SYSTEMCTL = "/run/current-system/sw/bin/systemctl"
UPDATE_UNIT = "nixos-update.service"
TRIGGERED_BRANCH = "main"

# Gunicorn-less single-purpose server: one connection at a time is fine because
# GitHub retries failed deliveries; throughput is not a concern.
LISTEN_BACKLOG = 8
REQUEST_TIMEOUT = 10


def load_secret() -> bytes | None:
    try:
        with open(SECRET_PATH, "rb") as fh:
            return fh.read().strip()
    except OSError:
        return None


def constant_time_compare(a: bytes, b: bytes) -> bool:
    return hmac.compare_digest(a, b)


def read_http_request(connection: socket.socket) -> tuple[dict[str, str], bytes] | None:
    """Read one HTTP request and return (headers, body) or None on protocol error.

    Bodies are capped at MAX_BODY_BYTES. A ``Content-Length`` larger than the
    cap immediately fails closed rather than buffering.
    """
    connection.settimeout(REQUEST_TIMEOUT)
    buf = bytearray()
    # Read until we have the full header block.
    while b"\r\n\r\n" not in buf:
        chunk = connection.recv(4096)
        if not chunk:
            return None
        buf.extend(chunk)
        if len(buf) > 64 * 1024:  # absurd header size
            return None

    header_blob, _, body_start = bytes(buf).partition(b"\r\n\r\n")
    lines = header_blob.split(b"\r\n")
    request_line = lines[0].decode("latin-1", errors="replace")
    if not request_line.startswith("POST ") or " HTTP/" not in request_line:
        return None

    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line:
            continue
        name, sep, value = line.partition(b":")
        if not sep:
            return None
        headers[name.decode("latin-1", errors="replace").strip().lower()] = (
            value.decode("latin-1", errors="replace").strip()
        )

    try:
        length = int(headers.get("content-length", "0"))
    except ValueError:
        length = 0
    if length < 0 or length > MAX_BODY_BYTES:
        return None

    body = bytearray(body_start)
    while len(body) < length:
        chunk = connection.recv(min(4096, length - len(body)))
        if not chunk:
            return None
        body.extend(chunk)
        if len(body) > MAX_BODY_BYTES:
            return None

    return headers, bytes(body)


def send_response(connection: socket.socket, status: int, message: str) -> None:
    payload = message.encode("utf-8")
    response = (
        f"HTTP/1.1 {status} {message}\r\n"
        f"Content-Length: {len(payload)}\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("utf-8") + payload
    try:
        connection.sendall(response)
    except OSError:
        pass


def trigger_update() -> tuple[int, str]:
    """Start the fixed update unit without blocking on its completion."""
    try:
        result = subprocess.run(
            [SYSTEMCTL, "start", "--no-block", UPDATE_UNIT],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return 500, f"trigger failed: {error}"
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "systemctl failed").strip()
        return 500, detail[:200]
    return 202, "nixos-update queued"


def verify_signature(secret: bytes, signature_header: str | None, body: bytes) -> bool:
    if not signature_header:
        return False
    # Accept GitHub's "sha256=<hex>" scheme.
    if not signature_header.startswith("sha256="):
        return False
    provided = signature_header[len("sha256="):]
    try:
        provided_bytes = bytes.fromhex(provided)
    except ValueError:
        return False
    expected = hmac.new(secret, body, hashlib.sha256).digest()
    return constant_time_compare(expected, provided_bytes)


def should_trigger(headers: dict[str, str], body: bytes) -> tuple[bool, str]:
    """Decide whether a verified payload should start the update.

    Returns (trigger, reason). reason is informational for logging.
    """
    event = headers.get("x-github-event")
    if event != "push":
        return False, f"ignored event={event}"

    try:
        payload = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        return False, "invalid json"

    ref = payload.get("ref")
    if ref != f"refs/heads/{TRIGGERED_BRANCH}":
        return False, f"ignored ref={ref}"

    deleted = payload.get("deleted")
    if deleted:
        return False, "branch deleted"

    return True, f"push to {TRIGGERED_BRANCH}"


def handle_connection(connection: socket.socket, secret: bytes | None) -> None:
    try:
        parsed = read_http_request(connection)
        if parsed is None:
            send_response(connection, 400, "Bad Request")
            return
        headers, body = parsed

        if secret is None:
            send_response(connection, 500, "Receiver not configured")
            print("webhook secret missing; rejecting all requests", file=sys.stderr)
            return

        signature = headers.get("x-hub-signature-256")
        if not verify_signature(secret, signature, body):
            send_response(connection, 403, "Forbidden")
            print("rejected request with invalid signature", file=sys.stderr)
            return

        trigger, reason = should_trigger(headers, body)
        if not trigger:
            send_response(connection, 200, reason)
            print(f"webhook {reason}", file=sys.stderr)
            return

        status, message = trigger_update()
        send_response(connection, status, message)
        print(f"webhook triggered update: {message}", file=sys.stderr)
    except (OSError, UnicodeDecodeError, ValueError) as error:
        try:
            send_response(connection, 400, "Bad Request")
        except OSError:
            pass
        print(f"webhook error: {error}", file=sys.stderr)
    finally:
        try:
            connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        connection.close()


def main() -> int:
    secret = load_secret()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((LISTEN_HOST, LISTEN_PORT))
    listener.listen(LISTEN_BACKLOG)
    listener.settimeout(REQUEST_TIMEOUT)

    print(
        f"github-webhook-receiver listening on {LISTEN_HOST}:{LISTEN_PORT} "
        f"(secret={'loaded' if secret else 'MISSING'})",
        file=sys.stderr,
    )

    while True:
        try:
            connection, _addr = listener.accept()
        except socket.timeout:
            continue
        except OSError as error:
            print(f"accept error: {error}", file=sys.stderr)
            continue
        handle_connection(connection, secret)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
