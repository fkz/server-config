"""Always-confirmed tool for starting the root-owned NixOS update service.

Every handler invocation performs a synchronous, non-persisted human consent
request. Session, permanent, and YOLO command-approval settings are deliberately
not consulted. Only after consent does the handler ask the root-owned broker to
queue the fixed update unit.

The broker socket is not mounted into the terminal container and accepts only
the live main PID of the managed Hermes gateway/dashboard services.
"""

from __future__ import annotations

import json
import socket
from typing import Any

_TOOL_NAME = "nixos_update"
_UNIT = "nixos-update.service"
_BROKER_SOCKET = "/run/hermes-nixos-update-broker/socket"
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


def _queue_update_via_broker() -> None:
    """Ask the fixed host broker to queue the update; never execute a command."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(20)
        client.connect(_BROKER_SOCKET)
        client.sendall(b"start\n")
        client.shutdown(socket.SHUT_WR)
        response = client.recv(2_048).decode("utf-8", errors="replace").strip()

    if response != "ok":
        raise RuntimeError(response or "update broker returned an empty response")


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


def register(ctx: Any) -> None:
    ctx.register_tool(
        name=_TOOL_NAME,
        toolset="nixos_update",
        schema=_SCHEMA,
        handler=_handle_nixos_update,
        description=_SCHEMA["description"],
        emoji="❄️",
    )
