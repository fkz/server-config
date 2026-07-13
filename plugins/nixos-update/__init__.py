"""Scoped tools for starting the NixOS update and reading its logs.

Every tool invocation performs a synchronous, non-persisted human consent
request. Session, permanent, and YOLO command-approval settings are deliberately
not consulted. Only after consent does the handler ask the root-owned broker to
queue the fixed update unit or return its bounded journal excerpt.

Log retrieval is read-only, parameterless, and bounded to the latest 200 journal
lines. The broker socket is not mounted into the terminal container and accepts
only the live main PID of the managed Hermes gateway/dashboard services.
"""

from __future__ import annotations

import json
import socket
from typing import Any

_TOOL_NAME = "nixos_update"
_LOGS_TOOL_NAME = "nixos_update_logs"
_UNIT = "nixos-update.service"
_BROKER_SOCKET = "/run/hermes-nixos-update-broker/socket"
_LOG_LINES = 200
_MAX_LOG_BYTES = 65_536
_APPROVAL_MESSAGE = "Start the root-owned nixos-update.service"
_APPROVAL_DESCRIPTION = (
    "The service fetches and deploys the latest server configuration and may "
    "restart Hermes. This confirmation applies only to this invocation."
)
_LOGS_APPROVAL_MESSAGE = "Read the latest nixos-update.service journal entries"
_LOGS_APPROVAL_DESCRIPTION = (
    "Return at most the latest 200 lines (and 60,000 bytes) from only the fixed "
    "NixOS update service. This confirmation applies only to this invocation."
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
        "Always request a fresh user confirmation, then fetch the latest 200 "
        "journal lines for the fixed nixos-update.service. The output is bounded, "
        "this tool accepts no arguments, and confirmations are never reused."
    ),
    "parameters": {
        "type": "object",
        "properties": {},
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


def _request_update_logs_consent() -> str:
    """Request non-persisted consent before exposing the update journal."""
    from tools.approval import request_elicitation_consent

    return request_elicitation_consent(
        _LOGS_APPROVAL_MESSAGE,
        _LOGS_APPROVAL_DESCRIPTION,
        timeout_seconds=120,
        surface="nixos-update-logs",
    )


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


def _fetch_update_logs_via_broker() -> tuple[str, bool, int]:
    """Fetch a bounded journal excerpt and explicit truncation metadata."""
    response = bytearray()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        # The broker can spend up to 10 seconds authenticating both managed
        # service PIDs and 15 seconds collecting logs. Leave bounded headroom for
        # local socket setup and delivery without racing the server deadline.
        client.settimeout(45)
        client.connect(_BROKER_SOCKET)
        client.sendall(b"logs\n")
        client.shutdown(socket.SHUT_WR)
        while len(response) < _MAX_LOG_BYTES:
            chunk = client.recv(min(8_192, _MAX_LOG_BYTES - len(response)))
            if not chunk:
                break
            response.extend(chunk)

    header_bytes, separator, log_bytes = bytes(response).partition(b"\n")
    if not separator:
        detail = response.decode("utf-8", errors="replace").strip()
        raise RuntimeError(detail or "update broker returned an empty response")

    try:
        header = header_bytes.decode("ascii")
        status, truncated_field, lines_field = header.split()
        if (
            status != "ok"
            or not truncated_field.startswith("truncated=")
            or not lines_field.startswith("lines=")
        ):
            raise ValueError
        truncated_value = truncated_field.removeprefix("truncated=")
        lines_value = lines_field.removeprefix("lines=")
        if truncated_value not in {"0", "1"}:
            raise ValueError
        line_count = int(lines_value)
        if line_count < 0:
            raise ValueError
    except (UnicodeDecodeError, ValueError):
        detail = response.decode("utf-8", errors="replace").strip()
        raise RuntimeError(detail or "update broker returned an invalid response") from None

    logs = log_bytes.decode("utf-8", errors="replace")
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


def _handle_nixos_update_logs(params: dict[str, Any], **kwargs: Any) -> str:
    """Confirm this invocation, then return the fixed unit's bounded journal."""
    del kwargs
    if params:
        return json.dumps({"success": False, "error": "this tool accepts no parameters"})

    try:
        consent = _request_update_logs_consent()
    except Exception as exc:
        return json.dumps({"success": False, "error": f"approval failed closed: {exc}"})

    if consent != "accept":
        return json.dumps(
            {
                "success": False,
                "status": "denied" if consent == "decline" else "cancelled",
                "error": "the user did not approve this NixOS update log request",
            }
        )

    try:
        logs, truncated, returned_lines = _fetch_update_logs_via_broker()
    except (OSError, RuntimeError) as exc:
        return json.dumps({"success": False, "error": f"could not fetch update logs: {exc}"})

    return json.dumps(
        {
            "success": True,
            "unit": _UNIT,
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
        handler=_handle_nixos_update_logs,
        description=_LOGS_SCHEMA["description"],
        emoji="📜",
    )
