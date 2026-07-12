"""Schemas for the narrowly scoped NixOS update-control plugin."""

START_NIXOS_UPDATE = {
    "name": "start_nixos_update",
    "description": (
        "Start the preconfigured nixos-update systemd service. "
        "This tool has no parameters and can run no other command or unit."
    ),
    "parameters": {
        "type": "object",
        "properties": {},
        "additionalProperties": False,
    },
}
