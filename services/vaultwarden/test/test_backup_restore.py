"""Backup, restore and the drill — the path that has to work when it matters."""

from __future__ import annotations

import pytest

from conftest import Container

RESTIC_ENV = (
    "set -a; . /etc/boma/vaultwarden/restic.env; set +a; "
    "RESTIC_PASSWORD_FILE=/etc/boma/vaultwarden/restic-password "
)


def test_backup_creates_a_snapshot(installed: Container) -> None:
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag test")
    snapshots = installed.exec(RESTIC_ENV + "restic snapshots --json").stdout
    assert '"short_id"' in snapshots


def test_backup_snapshot_contains_the_database(installed: Container) -> None:
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag test")
    listing = installed.exec(RESTIC_ENV + "restic ls latest").stdout
    assert "db.sqlite3" in listing


def test_backup_does_not_include_the_restic_credentials(installed: Container) -> None:
    """Storing the key to the backups inside the backups would be circular."""
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag test")
    listing = installed.exec(RESTIC_ENV + "restic ls latest").stdout
    assert "restic-password" not in listing
    assert "restic.env" not in listing


def test_verify_backup_passes_on_a_healthy_snapshot(installed: Container) -> None:
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh")
    result = installed.exec("/opt/boma/vaultwarden/bin/verify-backup.sh")
    assert "restore drill passed" in result.stderr


def test_restore_round_trip_recovers_lost_data(installed: Container) -> None:
    """Destroy the live vault, restore it, and prove it serves again."""
    installed.exec(
        "sqlite3 -cmd '.timeout 10000' /var/lib/boma/vaultwarden/db.sqlite3 "
        "\"INSERT INTO ciphers (uuid, user_uuid, data) VALUES ('canary', 'seed-user-0001', 'secret');\""
    )
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag test")

    installed.exec("systemctl stop vaultwarden.service")
    installed.exec("rm -f /var/lib/boma/vaultwarden/db.sqlite3")
    installed.exec("systemctl start vaultwarden.service")

    # The stand-in recreates an empty database on start, so the canary is gone.
    found = installed.sqlite(
        "/var/lib/boma/vaultwarden/db.sqlite3",
        "SELECT COUNT(*) FROM ciphers WHERE uuid='canary';",
    )
    assert found == "0", "precondition: the canary should have been destroyed"

    installed.exec("/opt/boma/vaultwarden/bin/restore.sh --snapshot latest --force")

    found = installed.sqlite(
        "/var/lib/boma/vaultwarden/db.sqlite3",
        "SELECT COUNT(*) FROM ciphers WHERE uuid='canary';",
    )
    assert found == "1", "restore did not bring the canary row back"
    assert installed.unit_active("vaultwarden.service")


def test_restore_dry_run_changes_nothing(installed: Container) -> None:
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag test")
    before = installed.sqlite(
        "/var/lib/boma/vaultwarden/db.sqlite3", "SELECT COUNT(*) FROM users;"
    )

    result = installed.exec(
        "/opt/boma/vaultwarden/bin/restore.sh --snapshot latest --dry-run"
    )
    assert "[dry-run]" in result.stderr

    after = installed.sqlite(
        "/var/lib/boma/vaultwarden/db.sqlite3", "SELECT COUNT(*) FROM users;"
    )
    assert before == after
    assert installed.unit_active("vaultwarden.service")


def test_restore_refuses_live_replacement_without_a_tty_or_force(
    installed: Container,
) -> None:
    """An unconfirmed, non-interactive restore must not silently replace data."""
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag test")
    result = installed.exec(
        "/opt/boma/vaultwarden/bin/restore.sh --snapshot latest < /dev/null",
        check=False,
    )
    assert result.returncode != 0
    assert "refusing to replace live data" in result.stderr


@pytest.mark.parametrize("holder", ["recovery", "family"])
def test_each_repository_password_actually_opens_the_backups(
    installed: Container, holder: str
) -> None:
    """Every password must independently unlock the repository.

    This is the whole point of the multi-key design: if only the host's password
    worked, losing the host would mean losing the backups. So this restores with
    the passphrase as displayed at install time — the same string the operator
    would have saved — rather than merely checking the key is listed.
    """
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag test")

    passphrase = installed.passphrases.get(holder)
    assert passphrase, (
        f"install.sh did not display a {holder} passphrase; the operator would "
        f"have had nothing to record (captured: {installed.passphrases})"
    )

    # Use ONLY this passphrase: no password file, so a fallback cannot mask a
    # passphrase that does not actually work.
    result = installed.exec(
        "set -a; . /etc/boma/vaultwarden/restic.env; set +a; "
        f"RESTIC_PASSWORD='{passphrase}' restic snapshots --json",
        check=False,
    )
    assert result.returncode == 0, (
        f"the {holder} passphrase did not open the repository:\n{result.stderr}"
    )
    assert '"short_id"' in result.stdout


def test_host_password_opens_the_backups(installed: Container) -> None:
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag test")
    result = installed.exec(RESTIC_ENV + "restic snapshots --json")
    assert '"short_id"' in result.stdout


@pytest.mark.parametrize("holder", ["recovery", "family"])
def test_verify_drill_works_with_a_human_held_passphrase(
    installed: Container, holder: str
) -> None:
    """The quarterly manual drill path.

    This is the only check that catches a transcription error made when a
    passphrase was saved — a single wrong character stays invisible until the
    moment it is needed.
    """
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh")
    passphrase = installed.passphrases[holder]

    result = installed.exec(
        "/opt/boma/vaultwarden/bin/verify-backup.sh --password-stdin",
        stdin=passphrase + "\n",
    )
    assert "restore drill passed" in result.stderr


def test_restic_repository_has_exactly_three_passwords(installed: Container) -> None:
    count = installed.exec(RESTIC_ENV + "restic key list --json | jq 'length'").stdout
    assert count.strip() == "3"


def test_verify_backup_fails_when_the_vault_is_empty(installed: Container) -> None:
    """A backup of an empty vault must be reported as a failure, not a pass.

    A structurally valid database with no users restores "successfully" while
    containing nothing — the failure mode a naive integrity check would miss.
    """
    installed.exec("systemctl stop vaultwarden.service")
    installed.exec("sqlite3 -cmd '.timeout 10000' /var/lib/boma/vaultwarden/db.sqlite3 'DELETE FROM users;'")
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh")

    result = installed.exec(
        "/opt/boma/vaultwarden/bin/verify-backup.sh --snapshot latest", check=False
    )
    assert result.returncode != 0
    assert "0 users" in result.stderr
