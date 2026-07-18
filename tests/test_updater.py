import os
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
UPDATER = REPO_ROOT / "scripts" / "nixos-update.sh"


def git(*args, cwd):
    subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
    )


def make_checkout(tmp_path):
    remote = tmp_path / "remote.git"
    source = tmp_path / "source"
    checkout = tmp_path / "checkout"
    git("init", "--bare", str(remote), cwd=tmp_path)
    git("clone", str(remote), str(source), cwd=tmp_path)
    git("config", "user.email", "test@example.invalid", cwd=source)
    git("config", "user.name", "Test", cwd=source)
    (source / "configuration.nix").write_text("{}\n")
    git("add", "configuration.nix", cwd=source)
    git("commit", "-m", "initial", cwd=source)
    git("push", "-u", "origin", "HEAD", cwd=source)
    git("clone", str(remote), str(checkout), cwd=tmp_path)
    return checkout


def make_fake_rebuild(tmp_path):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    rebuild = bindir / "nixos-rebuild"
    rebuild.write_text(
        "#!/bin/sh\n"
        "count_file=${REBUILD_COUNT_FILE:?}\n"
        "count=0\n"
        "test ! -f \"$count_file\" || count=$(cat \"$count_file\")\n"
        "echo $((count + 1)) > \"$count_file\"\n"
        "exit ${REBUILD_EXIT_CODE:-0}\n"
    )
    rebuild.chmod(0o755)
    return bindir


def run_updater(checkout, state_file, bindir, count_file, exit_code=0):
    env = os.environ.copy()
    env.update(
        {
            "NIXOS_CONFIG_DIR": str(checkout),
            "NIXOS_UPDATE_STATE_FILE": str(state_file),
            "REBUILD_COUNT_FILE": str(count_file),
            "REBUILD_EXIT_CODE": str(exit_code),
            "PATH": f"{bindir}:{env['PATH']}",
        }
    )
    return subprocess.run(
        ["bash", str(UPDATER)],
        env=env,
        capture_output=True,
        text=True,
    )


def test_rebuilds_current_checkout_when_no_success_marker_exists(tmp_path):
    checkout = make_checkout(tmp_path)
    bindir = make_fake_rebuild(tmp_path)
    state_file = tmp_path / "state" / "deployed-commit"
    count_file = tmp_path / "rebuild-count"

    result = run_updater(checkout, state_file, bindir, count_file)

    assert result.returncode == 0, result.stderr
    assert count_file.read_text().strip() == "1"
    assert state_file.read_text().strip() == subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=checkout, text=True
    ).strip()


def test_failed_rebuild_is_retried_and_only_success_is_recorded(tmp_path):
    checkout = make_checkout(tmp_path)
    bindir = make_fake_rebuild(tmp_path)
    state_file = tmp_path / "state" / "deployed-commit"
    count_file = tmp_path / "rebuild-count"

    failed = run_updater(
        checkout, state_file, bindir, count_file, exit_code=1
    )
    succeeded = run_updater(checkout, state_file, bindir, count_file)

    assert failed.returncode != 0
    assert succeeded.returncode == 0, succeeded.stderr
    assert count_file.read_text().strip() == "2"
    assert state_file.exists()


def test_skips_rebuild_after_same_commit_was_successfully_recorded(tmp_path):
    checkout = make_checkout(tmp_path)
    bindir = make_fake_rebuild(tmp_path)
    state_file = tmp_path / "state" / "deployed-commit"
    count_file = tmp_path / "rebuild-count"

    first = run_updater(checkout, state_file, bindir, count_file)
    second = run_updater(checkout, state_file, bindir, count_file)

    assert first.returncode == 0, first.stderr
    assert second.returncode == 0, second.stderr
    assert count_file.read_text().strip() == "1"
    assert "No update needed." in second.stdout
