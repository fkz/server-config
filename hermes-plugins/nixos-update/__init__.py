"""Hermes tool for starting the server's declarative NixOS update."""

from __future__ import annotations

import json
import subprocess


NIXOS_UPDATE_SCHEMA = {
    "name": "nixos_update",
    "description": (
        "Fetch and deploy the latest fkz/server-config main branch through the "
        "root-owned nixos-update.service. The update continues independently if "
        "deploying it restarts Hermes. Takes no arguments."
    ),
    "parameters": {
        "type": "object",
        "properties": {},
        "additionalProperties": False,
    },
}


def _handle_nixos_update(args: dict, **kwargs) -> str:
    if args:
        return json.dumps({"success": False, "error": "This tool accepts no arguments."})

    command = (
        "/run/wrappers/bin/sudo",
        "/run/current-system/sw/bin/systemctl",
        "start",
        "--no-block",
        "nixos-update.service",
    )
    try:
        result = subprocess.run(
            command,
            shell=False,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return json.dumps({"success": False, "error": str(exc)})

    if result.returncode != 0:
        return json.dumps({
            "success": False,
            "error": (result.stderr or result.stdout or "systemctl failed").strip(),
            "returncode": result.returncode,
        })

    return json.dumps({
        "success": True,
        "status": "queued",
        "message": (
            "nixos-update.service was queued. The update runs independently and "
            "may restart Hermes while deploying."
        ),
    })


def register(ctx) -> None:
    ctx.register_tool(
        name="nixos_update",
        toolset="nixos_update",
        schema=NIXOS_UPDATE_SCHEMA,
        handler=_handle_nixos_update,
        emoji="❄️",
    )
