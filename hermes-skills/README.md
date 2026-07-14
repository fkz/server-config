# Hermes Skills

This private repository is an automated, read-only audit mirror of the active
Hermes profile on the NixOS server.

- `CATALOG.md` lists every skill visible to Hermes.
- `skills/` contains the complete files of local, installed, or agent-created
  skills that are not owned solely by the bundled Hermes distribution.
- `metadata/skills.json` provides the same inventory in machine-readable form.
- Bundled skills appear only in the catalog to avoid duplicating upstream
  content and update noise.

A NixOS-managed timer refreshes the mirror every 15 minutes and pushes a commit
only when the exported state changed. Cache files, usage counters, curator
state, hidden files, and Hermes memory are deliberately excluded.

## Direction of synchronization

This is currently a one-way audit mirror: **Hermes → GitHub**. Editing a managed
file in this repository does not update the live Hermes profile and may be
overwritten by the next snapshot. A reviewed GitOps import can be added later
as a separate feature.

## Security

The exporter rejects private-key blocks and common high-confidence token
patterns before committing. It never reads Hermes secrets, sessions, memory,
configuration, or authentication files. Keep the repository private anyway:
skills can document internal infrastructure and operational details.
