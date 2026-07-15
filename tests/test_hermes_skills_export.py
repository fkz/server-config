import importlib.util
import json
from pathlib import Path

import pytest


MODULE_PATH = (
    Path(__file__).parents[1] / "hermes-skills" / "export.py"
)
SPEC = importlib.util.spec_from_file_location("export_skills", MODULE_PATH)
EXPORT_SKILLS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORT_SKILLS)


def write_skill(root, relative, metadata, body="# Skill\n"):
    directory = root / relative
    directory.mkdir(parents=True)
    frontmatter = "\n".join(
        f"{key}: {value}" for key, value in metadata.items()
    )
    (directory / "SKILL.md").write_text(
        f"---\n{frontmatter}\n---\n\n{body}",
        encoding="utf-8",
    )
    return directory


def test_exports_local_skills_and_catalogs_bundled_skills(tmp_path):
    source = tmp_path / "source"
    destination = tmp_path / "repository"
    source.mkdir()
    destination.mkdir()
    (source / ".bundled_manifest").write_text(
        "bundled-one:abc123\n",
        encoding="utf-8",
    )
    write_skill(
        source,
        "category/bundled",
        {
            "name": "bundled-one",
            "description": "From upstream",
            "version": "1.0.0",
        },
    )
    local = write_skill(
        source,
        "category/local",
        {
            "name": "local-one",
            "description": "Created locally",
            "version": "2.0.0",
            "created_by": "agent",
        },
    )
    (local / "references").mkdir()
    (local / "references" / "guide.md").write_text(
        "safe reference\n",
        encoding="utf-8",
    )
    (local / ".cache").write_text("ignored\n", encoding="utf-8")

    EXPORT_SKILLS.export(source, destination)

    assert not (destination / "skills/category/bundled").exists()
    assert (destination / "skills/category/local/SKILL.md").exists()
    assert (
        destination / "skills/category/local/references/guide.md"
    ).exists()
    assert not (destination / "skills/category/local/.cache").exists()
    catalog = (destination / "CATALOG.md").read_text(encoding="utf-8")
    assert "`bundled-one` | bundled" in catalog
    assert "`local-one` | tracked" in catalog
    metadata = json.loads(
        (destination / "metadata/skills.json").read_text(encoding="utf-8")
    )
    assert [item["name"] for item in metadata] == [
        "bundled-one",
        "local-one",
    ]


def test_agent_created_skill_is_tracked_even_if_manifested(tmp_path):
    source = tmp_path / "source"
    destination = tmp_path / "repository"
    source.mkdir()
    destination.mkdir()
    (source / ".bundled_manifest").write_text(
        "learned:abc123\n",
        encoding="utf-8",
    )
    write_skill(
        source,
        "learned",
        {"name": "learned", "created_by": "agent"},
    )

    EXPORT_SKILLS.export(source, destination)

    assert (destination / "skills/learned/SKILL.md").exists()


def test_rejects_private_key_material(tmp_path):
    source = tmp_path / "source"
    destination = tmp_path / "repository"
    source.mkdir()
    destination.mkdir()
    write_skill(
        source,
        "unsafe",
        {"name": "unsafe"},
        body="-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n",
    )

    with pytest.raises(RuntimeError, match="private key"):
        EXPORT_SKILLS.export(source, destination)


def test_replaces_stale_managed_export(tmp_path):
    source = tmp_path / "source"
    destination = tmp_path / "repository"
    source.mkdir()
    (destination / "skills/stale").mkdir(parents=True)
    (destination / "skills/stale/SKILL.md").write_text(
        "stale\n",
        encoding="utf-8",
    )
    write_skill(source, "current", {"name": "current"})

    EXPORT_SKILLS.export(source, destination)

    assert not (destination / "skills/stale").exists()
    assert (destination / "skills/current/SKILL.md").exists()


def test_exports_only_non_empty_allowlisted_profile_files(tmp_path):
    profile = tmp_path / "profile"
    source = profile / "skills"
    destination = tmp_path / "repository"
    source.mkdir(parents=True)
    destination.mkdir()
    (profile / "memories").mkdir()
    (profile / "SOUL.md").write_text("# Custom soul\n", encoding="utf-8")
    (profile / "memories/MEMORY.md").write_text(
        "stable memory\n",
        encoding="utf-8",
    )
    (profile / "memories/USER.md").write_text("  \n", encoding="utf-8")
    (profile / "config.yaml").write_text("secret: no\n", encoding="utf-8")
    (profile / ".env").write_text("TOKEN=no\n", encoding="utf-8")

    EXPORT_SKILLS.export(source, destination, profile)

    assert (destination / "profile/SOUL.md").read_text() == "# Custom soul\n"
    assert (
        destination / "profile/memories/MEMORY.md"
    ).read_text() == "stable memory\n"
    assert not (destination / "profile/memories/USER.md").exists()
    assert not (destination / "profile/config.yaml").exists()
    assert not (destination / "profile/.env").exists()


def test_removes_stale_profile_files(tmp_path):
    profile = tmp_path / "profile"
    source = profile / "skills"
    destination = tmp_path / "repository"
    source.mkdir(parents=True)
    (destination / "profile/memories").mkdir(parents=True)
    (destination / "profile/memories/USER.md").write_text(
        "stale\n",
        encoding="utf-8",
    )

    EXPORT_SKILLS.export(source, destination, profile)

    assert (destination / "profile").is_dir()
    assert not any((destination / "profile").iterdir())


def test_rejects_secrets_in_profile_files(tmp_path):
    profile = tmp_path / "profile"
    source = profile / "skills"
    destination = tmp_path / "repository"
    source.mkdir(parents=True)
    destination.mkdir()
    (profile / "SOUL.md").write_text(
        "-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n",
        encoding="utf-8",
    )

    with pytest.raises(RuntimeError, match="private key"):
        EXPORT_SKILLS.export(source, destination, profile)
