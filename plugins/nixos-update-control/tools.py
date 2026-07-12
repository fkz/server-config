"""Fixed-command handler for the NixOS update-control plugin."""

import json
import subprocess

_SUDO = "/run/wrappers/bin/sudo"
_SYSTEMCTL = "/run/current-system/sw/bin/systemctl"
_COMMAND = (_SUDO, _SYSTEMCTL, "start", "nixos-update")


def start_nixos_update(args: dict, **kwargs) -> str:
    """Run only ``systemctl start nixos-update``; reject all arguments."""
    if args:
        return json.dumps({"ok": False, "error": "This tool accepts no arguments."})

    try:
        completed = subprocess.run(
            _COMMAND,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=660,
            check=False,
            env={"PATH": "/run/current-system/sw/bin:/usr/bin:/bin", "LANG": "C.UTF-8"},
        )
    except subprocess.TimeoutExpired:
        return json.dumps({
            "ok": False,
            "command": "systemctl start nixos-update",
            "error": "Timed out after 11 minutes; inspect nixos-update.service status.",
        })
    except OSError as exc:
        return json.dumps({"ok": False, "error": f"Could not execute systemctl: {exc}"})

    result = {
        "ok": completed.returncode == 0,
        "command": "systemctl start nixos-update",
        "returncode": completed.returncode,
    }
    if completed.stdout.strip():
        result["stdout"] = completed.stdout.strip()
    if completed.stderr.strip():
        result["stderr"] = completed.stderr.strip()
    return json.dumps(result)
