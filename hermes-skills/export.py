import json
import re
import shutil
import sys
from pathlib import Path


EXCLUDED_NAMES = {
    ".git",
    ".usage.json",
    "__pycache__",
}
SECRET_PATTERNS = {
    "private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "GitHub token": re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"),
    "AWS access key": re.compile(r"AKIA[0-9A-Z]{16}"),
}
PROFILE_FILES = (
    Path("SOUL.md"),
    Path("memories/MEMORY.md"),
    Path("memories/USER.md"),
)


def parse_frontmatter(path):
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    metadata = {}
    if not lines or lines[0].strip() != "---":
        return metadata
    for line in lines[1:]:
        if line.strip() == "---":
            break
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", line)
        if not match:
            continue
        key, value = match.groups()
        metadata[key] = value.strip().strip("\"'")
    return metadata


def bundled_skill_names(source):
    manifest = source / ".bundled_manifest"
    if not manifest.exists():
        return set()
    names = set()
    for line in manifest.read_text(encoding="utf-8").splitlines():
        if ":" in line:
            names.add(line.split(":", 1)[0])
    return names


def is_excluded(path):
    return any(
        part in EXCLUDED_NAMES or part.startswith(".")
        for part in path.parts
    )


def scan_for_secrets(root):
    findings = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            findings.append(f"binary file: {path.relative_to(root)}")
            continue
        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(text):
                findings.append(f"{label}: {path.relative_to(root)}")
    if findings:
        details = "\n".join(f"- {finding}" for finding in findings)
        message = f"secret scan rejected exported content:\n{details}"
        raise RuntimeError(message)


def copy_skill(source_dir, destination_dir):
    for path in sorted(source_dir.rglob("*")):
        relative = path.relative_to(source_dir)
        if is_excluded(relative):
            continue
        if path.is_symlink():
            raise RuntimeError(f"refusing skill symlink: {path}")
        target = destination_dir / relative
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        elif path.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)


def export_profile_files(profile_source, destination):
    export_root = destination / "profile"
    if export_root.exists():
        shutil.rmtree(export_root)
    export_root.mkdir(parents=True)

    exported = []
    for relative in PROFILE_FILES:
        source = profile_source / relative
        if not source.exists():
            continue
        if source.is_symlink() or not source.is_file():
            raise RuntimeError(f"refusing profile path: {source}")
        try:
            text = source.read_text(encoding="utf-8")
        except UnicodeDecodeError as error:
            message = f"refusing binary profile file: {source}"
            raise RuntimeError(message) from error
        if not text.strip():
            continue
        target = export_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        exported.append(relative)

    if export_root.exists():
        scan_for_secrets(export_root)
    return exported


def clean_text(value):
    return " ".join(value.replace("|", "\\|").split())


def build_catalog(skills):
    lines = [
        "# Hermes skill catalog",
        "",
        "This file is generated from the active Hermes profile. Skills marked",
        "`tracked` are mirrored in full under `skills/`; bundled skills are",
        "listed for visibility but remain owned by the Hermes installation.",
        "",
        "| Skill | Status | Version | Description |",
        "|---|---|---|---|",
    ]
    for skill in sorted(skills, key=lambda item: item["name"].lower()):
        lines.append(
            "| `{name}` | {status} | {version} | {description} |".format(
                name=clean_text(skill["name"]),
                status=skill["status"],
                version=clean_text(skill["version"]),
                description=clean_text(skill["description"]),
            )
        )
    lines.extend(["", f"Total: {len(skills)} skills.", ""])
    return "\n".join(lines)


def export(source, destination, profile_source=None):
    source = source.resolve()
    destination = destination.resolve()
    if profile_source is None:
        profile_source = source.parent
    profile_source = profile_source.resolve()
    if not source.is_dir():
        raise RuntimeError(f"skill source does not exist: {source}")
    if source == destination or source in destination.parents:
        raise RuntimeError("destination must not be inside the skill source")

    bundled = bundled_skill_names(source)
    discovered = []
    for skill_file in sorted(source.rglob("SKILL.md")):
        relative = skill_file.relative_to(source)
        if is_excluded(relative):
            continue
        metadata = parse_frontmatter(skill_file)
        name = metadata.get("name", skill_file.parent.name)
        tracked = name not in bundled or metadata.get("created_by") == "agent"
        discovered.append(
            {
                "name": name,
                "description": metadata.get("description", ""),
                "version": metadata.get("version", ""),
                "status": "tracked" if tracked else "bundled",
                "source": skill_file.parent,
                "relative": skill_file.parent.relative_to(source),
            }
        )

    export_root = destination / "skills"
    if export_root.exists():
        shutil.rmtree(export_root)
    export_root.mkdir(parents=True)
    for skill in discovered:
        if skill["status"] != "tracked":
            continue
        copy_skill(skill["source"], export_root / skill["relative"])

    scan_for_secrets(export_root)
    exported_profile_files = export_profile_files(profile_source, destination)
    (destination / "CATALOG.md").write_text(
        build_catalog(discovered),
        encoding="utf-8",
    )
    metadata = [
        {
            key: skill[key]
            for key in ("name", "description", "version", "status")
        }
        for skill in discovered
    ]
    metadata_dir = destination / "metadata"
    metadata_dir.mkdir(exist_ok=True)
    (metadata_dir / "skills.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    tracked_count = sum(skill["status"] == "tracked" for skill in discovered)
    print(
        f"exported {tracked_count} of {len(discovered)} skills and "
        f"{len(exported_profile_files)} profile files"
    )


def main():
    if len(sys.argv) != 4:
        usage = (
            "usage: export.py SOURCE_SKILLS SOURCE_PROFILE "
            "DESTINATION_REPOSITORY"
        )
        raise SystemExit(usage)
    export(Path(sys.argv[1]), Path(sys.argv[3]), Path(sys.argv[2]))


if __name__ == "__main__":
    main()
