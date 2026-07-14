"""Scoped tools for starting the NixOS update and reading its logs.

The update action always performs a synchronous, non-persisted human consent
request. Log access may instead be approved once or for the current Hermes
session, scoped to the exact validated service name. Permanent and YOLO
approvals are deliberately not honored. Only after consent does the handler ask
the root-owned broker to queue the fixed update unit or return its bounded
journal excerpt.

Log retrieval is read-only, accepts one strictly validated ``.service`` unit, and
is bounded to the latest 200 journal lines. The broker socket is not mounted into
the terminal container and accepts only the live main PID of the managed Hermes
gateway/dashboard services.
"""

from __future__ import annotations

import json
import re
import socket
from typing import Any

_TOOL_NAME = "nixos_update"
_LOGS_TOOL_NAME = "systemd_service_logs"
_UNIT = "nixos-update.service"
_BROKER_SOCKET = "/run/hermes-nixos-update-broker/socket"
_LOG_LINES = 200
_MAX_LOG_BYTES = 65_536
_SERVICE_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:@-]{0,246}\.service\Z")
_APPROVAL_MESSAGE = "Start the root-owned nixos-update.service"
_APPROVAL_DESCRIPTION = (
    "The service fetches and deploys the latest server configuration and may "
    "restart Hermes. This confirmation applies only to this invocation."
)

_SCHEMA = {
    "name": _TOOL_NAME,
    "description": (
        "Always request a fresh user confirmation, then queue the root-owned "
        "NixOS update service. The service may restart Hermes. This tool accepts "
        "no arguments and confirmations are never reused."
    ),
    "parameters": {
        "type": "object",
        "properties": {},
        "additionalProperties": False,
    },
}

_LOGS_SCHEMA = {
    "name": _LOGS_TOOL_NAME,
    "description": (
        "Request confirmation, then fetch the latest 200 journal lines for one "
        "exact systemd service unit. Approval may be reused only for that exact "
        "service in the current session; permanent approval is disabled. The "
        "output is bounded."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "service": {
                "type": "string",
                "description": "Exact systemd service unit, for example sshd.service",
            }
        },
        "required": ["service"],
        "additionalProperties": False,
    },
}


def _request_individual_consent() -> str:
    """Request non-persisted consent through Hermes' active user surface."""
    # Import lazily so plugin discovery stays cheap and testable. Unlike normal
    # command approval, elicitation consent does not consult YOLO or approval
    # allowlists and therefore runs for every handler invocation.
    from tools.approval import request_elicitation_consent

    return request_elicitation_consent(
        _APPROVAL_MESSAGE,
        _APPROVAL_DESCRIPTION,
        timeout_seconds=120,
        surface="nixos-update",
    )


def _request_service_logs_consent(service: str) -> str:
    """Request once-or-session consent for one exact service journal."""
    from tools import approval

    session_key = approval.get_current_session_key(default="")
    pattern_key = f"systemd_service_logs:{service}"

    # Check only the in-memory session set. ``is_approved`` also consults the
    # permanent command allowlist, which must never authorize journal access.
    if session_key:
        with approval._lock:
            session_approvals = approval._session_approved.get(session_key, set())
            if pattern_key in session_approvals:
                return "accept"

    message = f"Read the latest {service} journal entries"
    description = (
        f"Return at most the latest 200 lines (and 60,000 bytes) from {service}. "
        "Service journals can contain sensitive data. Session approval applies "
        "only to this exact service and is not persisted."
    )

    if approval._is_gateway_approval_context():
        with approval._lock:
            notify_cb = approval._gateway_notify_cbs.get(session_key)
        if notify_cb is None:
            return "decline"
        decision = approval._await_gateway_decision(
            session_key,
            notify_cb,
            {
                "command": message,
                "description": description,
                "pattern_key": pattern_key,
                "pattern_keys": [pattern_key],
                "allow_permanent": False,
            },
            surface="systemd-service-logs",
        )
        if decision.get("notify_failed"):
            return "decline"
        if not decision.get("resolved"):
            return "cancel"
        choice = decision.get("choice")
    else:
        try:
            from tools.terminal_tool import _get_approval_callback

            approval_callback = _get_approval_callback()
        except Exception:
            approval_callback = None
        choice = approval.prompt_dangerous_approval(
            message,
            description,
            timeout_seconds=120,
            allow_permanent=False,
            approval_callback=approval_callback,
        )

    if choice in {"session", "always"} and session_key:
        # Some generic approval clients can still submit ``always`` manually.
        # Downgrade it to process-memory session scope; never persist it.
        approval.approve_session(session_key, pattern_key)
        return "accept"
    if choice == "once":
        return "accept"
    return "decline"


def _queue_update_via_broker() -> None:
    """Ask the fixed host broker to queue the update; never execute a command."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(45)
        client.connect(_BROKER_SOCKET)
        client.sendall(b"start\n")
        client.shutdown(socket.SHUT_WR)
        response = client.recv(2_048).decode("utf-8", errors="replace").strip()

    if response != "ok":
        raise RuntimeError(response or "update broker returned an empty response")


def _fetch_service_logs_via_broker(service: str) -> tuple[str, bool, int]:
    """Fetch one service's bounded journal excerpt and truncation metadata."""
    response = bytearray()
    saw_eof = False
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        # The broker can spend up to 10 seconds authenticating both managed
        # service PIDs and 15 seconds collecting logs. Leave bounded headroom for
        # local socket setup and delivery without racing the server deadline.
        client.settimeout(45)
        client.connect(_BROKER_SOCKET)
        client.sendall(f"logs {service}\n".encode("ascii"))
        client.shutdown(socket.SHUT_WR)
        while len(response) < _MAX_LOG_BYTES:
            chunk = client.recv(min(8_192, _MAX_LOG_BYTES - len(response)))
            if not chunk:
                saw_eof = True
                break
            response.extend(chunk)

    if not saw_eof:
        raise RuntimeError("service log response exceeded the client limit")

    header_bytes, separator, log_bytes = bytes(response).partition(b"\n")
    if not separator:
        detail = response.decode("utf-8", errors="replace").strip()
        raise RuntimeError(detail or "update broker returned an empty response")

    try:
        header = header_bytes.decode("ascii")
        status, truncated_field, bytes_field, lines_field = header.split()
        if (
            status != "ok"
            or not truncated_field.startswith("truncated=")
            or not bytes_field.startswith("bytes=")
            or not lines_field.startswith("lines=")
        ):
            raise ValueError
        truncated_value = truncated_field.removeprefix("truncated=")
        bytes_value = bytes_field.removeprefix("bytes=")
        lines_value = lines_field.removeprefix("lines=")
        if truncated_value not in {"0", "1"}:
            raise ValueError
        for value in (bytes_value, lines_value):
            if (
                not value.isascii()
                or not value.isdecimal()
                or (len(value) > 1 and value.startswith("0"))
            ):
                raise ValueError
        payload_bytes = int(bytes_value)
        line_count = int(lines_value)
        if payload_bytes != len(log_bytes):
            raise ValueError
        logs = log_bytes.decode("utf-8", errors="replace")
        if line_count != len(logs.splitlines()):
            raise ValueError
    except (UnicodeDecodeError, ValueError):
        detail = response.decode("utf-8", errors="replace").strip()
        raise RuntimeError(detail or "update broker returned an invalid response") from None

    return logs, truncated_value == "1", line_count


def _handle_nixos_update(params: dict[str, Any], **kwargs: Any) -> str:
    """Confirm this invocation, then queue only the fixed root-owned update."""
    del kwargs
    if params:
        return json.dumps({"success": False, "error": "this tool accepts no parameters"})

    try:
        consent = _request_individual_consent()
    except Exception as exc:
        return json.dumps({"success": False, "error": f"approval failed closed: {exc}"})

    if consent != "accept":
        return json.dumps(
            {
                "success": False,
                "status": "denied" if consent == "decline" else "cancelled",
                "error": "the user did not approve this NixOS update invocation",
            }
        )

    try:
        _queue_update_via_broker()
    except (OSError, RuntimeError) as exc:
        return json.dumps({"success": False, "error": f"could not queue update: {exc}"})

    return json.dumps(
        {
            "success": True,
            "status": "queued",
            "unit": _UNIT,
            "message": (
                "nixos-update.service was queued as a root-owned systemd job. "
                "It continues independently and may restart Hermes while deploying."
            ),
        }
    )


def _handle_systemd_service_logs(params: dict[str, Any], **kwargs: Any) -> str:
    """Confirm this invocation, then return one service's bounded journal."""
    del kwargs
    service = params.get("service")
    if (
        set(params) != {"service"}
        or not isinstance(service, str)
        or _SERVICE_PATTERN.fullmatch(service) is None
    ):
        return json.dumps(
            {"success": False, "error": "provide exactly one valid systemd .service unit"}
        )

    try:
        consent = _request_service_logs_consent(service)
    except Exception as exc:
        return json.dumps({"success": False, "error": f"approval failed closed: {exc}"})

    if consent != "accept":
        return json.dumps(
            {
                "success": False,
                "status": "denied" if consent == "decline" else "cancelled",
                "error": f"the user did not approve logs for {service}",
            }
        )

    try:
        logs, truncated, returned_lines = _fetch_service_logs_via_broker(service)
    except (OSError, RuntimeError) as exc:
        return json.dumps({"success": False, "error": f"could not fetch logs: {exc}"})

    return json.dumps(
        {
            "success": True,
            "unit": service,
            "requested_lines": _LOG_LINES,
            "returned_lines": returned_lines,
            "truncated": truncated,
            "logs": logs,
        }
    )


def register(ctx: Any) -> None:
    ctx.register_tool(
        name=_TOOL_NAME,
        toolset="nixos_update",
        schema=_SCHEMA,
        handler=_handle_nixos_update,
        description=_SCHEMA["description"],
        emoji="❄️",
    )
    ctx.register_tool(
        name=_LOGS_TOOL_NAME,
        toolset="nixos_update",
        schema=_LOGS_SCHEMA,
        handler=_handle_systemd_service_logs,
        description=_LOGS_SCHEMA["description"],
        emoji="📜",
    )
