"""Registration for the narrowly scoped NixOS update-control plugin."""

from . import schemas, tools


def register(ctx):
    ctx.register_tool(
        name="start_nixos_update",
        toolset="nixos_update_control",
        schema=schemas.START_NIXOS_UPDATE,
        handler=tools.start_nixos_update,
    )
