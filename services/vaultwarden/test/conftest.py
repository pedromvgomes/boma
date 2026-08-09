"""Fixtures for the vaultwarden end-to-end suite.

Each test gets a fresh Debian container running systemd as PID 1, with the repo
mounted read-only and a local "release server" laid out on disk. Releases are
served over ``file://`` rather than HTTP, which removes host-to-container
networking from the harness entirely.

Teardown is fixture-driven so an aborted run cannot leak containers.
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import tarfile
import textwrap
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
TEST_DIR = Path(__file__).resolve().parent
IMAGE = "boma-vaultwarden-test"

# Versions the fake release server publishes. `OLD` installs first; `NEW` has
# soaked and is the update target; `UNSOAKED` is deliberately too recent to be
# eligible for an unattended update.
VERSION_OLD = "1.30.0"
VERSION_NEW = "1.31.0"
VERSION_UNSOAKED = "1.32.0"


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


@dataclass
class Container:
    """A running systemd container the tests drive commands inside."""

    name: str

    def exec(
        self,
        cmd: str,
        check: bool = True,
        env: dict[str, str] | None = None,
        stdin: str | None = None,
    ) -> subprocess.CompletedProcess:
        argv = ["podman", "exec", "-i"]
        for key, value in (env or {}).items():
            argv += ["-e", f"{key}={value}"]
        argv += [self.name, "bash", "-lc", cmd]

        result = subprocess.run(
            argv, capture_output=True, text=True, input=stdin
        )
        if check and result.returncode != 0:
            raise AssertionError(
                f"command failed ({result.returncode}): {cmd}\n"
                f"--- stdout ---\n{result.stdout}\n"
                f"--- stderr ---\n{result.stderr}"
            )
        return result

    def path_exists(self, path: str) -> bool:
        return self.exec(f"test -e {path}", check=False).returncode == 0

    def read(self, path: str) -> str:
        return self.exec(f"cat {path}").stdout

    def mode_of(self, path: str) -> str:
        return self.exec(f"stat -c '%a' {path}").stdout.strip()

    def sqlite(self, db: str, query: str, timeout_ms: int = 10000) -> str:
        """Query SQLite, waiting rather than failing if the vault holds the lock.

        The service keeps the database open, so a query issued right after a
        restart or restore can hit "database is locked" (SQLITE_BUSY). Without
        a busy timeout that is a race: it passed locally and failed on the
        slower CI runner. A flaky test is worse than no test, so the wait is
        built into the helper rather than sprinkled at call sites.
        """
        return self.exec(
            f'sqlite3 -cmd ".timeout {timeout_ms}" {db} "{query}"'
        ).stdout.strip()

    def unit_active(self, unit: str) -> bool:
        return (
            self.exec(f"systemctl is-active {unit}", check=False).stdout.strip()
            == "active"
        )


@pytest.fixture(scope="session")
def image() -> str:
    """Build the test image once per session."""
    result = run(
        [
            "podman", "build", "-q",
            "-f", str(TEST_DIR / "Dockerfile"),
            "-t", IMAGE, str(TEST_DIR),
        ]
    )
    if result.returncode != 0:
        pytest.fail(f"could not build test image:\n{result.stderr}")
    return IMAGE


def _fake_binary(version: str) -> bytes:
    source = (TEST_DIR / "fake_vaultwarden.py").read_text()
    return source.replace("__VERSION__", version).encode()


def _build_release_tree(root: Path) -> None:
    """Lay out a GitHub-releases-shaped tree plus a matching API index."""
    downloads = root / "vaultwarden"
    downloads.mkdir(parents=True, exist_ok=True)

    now = datetime.now(timezone.utc)
    published = {
        # Comfortably past any soak window.
        VERSION_OLD: now - timedelta(days=90),
        VERSION_NEW: now - timedelta(days=30),
        # Published just now: must NOT be picked up by an unattended update.
        VERSION_UNSOAKED: now - timedelta(minutes=5),
    }

    for version in (VERSION_OLD, VERSION_NEW, VERSION_UNSOAKED):
        vdir = downloads / version
        vdir.mkdir(parents=True, exist_ok=True)

        binary = vdir / "vaultwarden"
        binary.write_bytes(_fake_binary(version))
        binary.chmod(0o755)

        # A minimal web vault, shaped like the real archive.
        web_root = vdir / "_web" / "web-vault"
        web_root.mkdir(parents=True, exist_ok=True)
        (web_root / "index.html").write_text(
            f"<html><body>web vault {version}</body></html>"
        )
        web_asset = vdir / f"web-vault-v{version}.tar.gz"
        with tarfile.open(web_asset, "w:gz") as tar:
            tar.add(web_root, arcname="web-vault")
        shutil.rmtree(vdir / "_web")

        sums = []
        for asset in (binary, web_asset):
            digest = hashlib.sha256(asset.read_bytes()).hexdigest()
            sums.append(f"{digest}  {asset.name}")
        (vdir / "SHA256SUMS").write_text("\n".join(sums) + "\n")

    index = [
        {
            "tag_name": f"vaultwarden/{version}",
            "draft": False,
            "published_at": stamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        for version, stamp in published.items()
    ]
    (root / "releases.json").write_text(json.dumps(index))


@pytest.fixture()
def release_dir(tmp_path: Path) -> Path:
    root = tmp_path / "releases"
    root.mkdir()
    _build_release_tree(root)
    return root


@pytest.fixture()
def container(image: str, release_dir: Path):
    """A fresh systemd container per test, guaranteed to be torn down."""
    name = f"boma-test-{uuid.uuid4().hex[:10]}"

    result = run(
        [
            "podman", "run", "-d", "--name", name,
            "--systemd=always",
            "-v", f"{REPO_ROOT}:/repo:ro",
            "-v", f"{release_dir}:/srv/releases:ro",
            image,
        ]
    )
    if result.returncode != 0:
        pytest.fail(f"could not start container:\n{result.stderr}")

    ctr = Container(name)
    try:
        deadline = time.time() + 60
        while time.time() < deadline:
            state = ctr.exec("systemctl is-system-running", check=False).stdout.strip()
            if state in {"running", "degraded"}:
                break
            time.sleep(1)
        else:
            logs = run(["podman", "logs", name])
            pytest.fail(f"systemd did not start in the container:\n{logs.stdout}\n{logs.stderr}")

        # The repo is mounted read-only; the scripts must be run from a
        # writable copy because install.sh copies itself into place.
        ctr.exec("cp -a /repo /work && chmod -R u+w /work")
        yield ctr
    finally:
        run(["podman", "rm", "-f", name])


@pytest.fixture()
def env_base() -> dict[str, str]:
    """Environment every install invocation needs inside the container."""
    return {
        # The container is Debian arm64 but not a Raspberry Pi.
        "BOMA_SKIP_PREFLIGHT": "1",
        "VW_RELEASE_BASE": "file:///srv/releases",
        "VW_RELEASE_API": "file:///srv/releases/releases.json",
    }


INSTALL_ARGS = (
    "--domain https://vault.example.test "
    "--admin-email admin@example.test "
    "--skip-smtp-test "
    "--non-interactive "
)


def parse_passphrases(install_stdout: str) -> dict[str, str]:
    """Pull the one-time passphrases out of install.sh's output.

    They are displayed once and stored nowhere, so this is the only chance to
    capture them — which is exactly the situation a real operator is in.
    """
    found: dict[str, str] = {}
    lines = install_stdout.splitlines()
    labels = {"RECOVERY PASSPHRASE": "recovery", "FAMILY PASSPHRASE": "family"}
    for index, line in enumerate(lines):
        for label, key in labels.items():
            if label in line:
                for candidate in lines[index + 1 : index + 4]:
                    value = candidate.strip()
                    if re.fullmatch(r"[a-z2-9]{5}(-[a-z2-9]{5})+", value):
                        found[key] = value
                        break
    return found


@pytest.fixture()
def installed(container: Container, env_base: dict[str, str]) -> Container:
    """A container with Vaultwarden installed and backups configured."""
    container.exec("mkdir -p /srv/restic")
    result = container.exec(
        "/work/services/vaultwarden/install.sh "
        + INSTALL_ARGS
        + f"--version {VERSION_OLD} "
        + "--restic-repo /srv/restic",
        env=env_base,
    )
    # Attached so tests can use the passphrases the operator would have saved.
    container.passphrases = parse_passphrases(result.stdout)  # type: ignore[attr-defined]
    return container


def install_cmd(extra: str = "", version: str = VERSION_OLD) -> str:
    return textwrap.dedent(
        f"/work/services/vaultwarden/install.sh {INSTALL_ARGS} "
        f"--version {version} {extra}"
    ).strip()
