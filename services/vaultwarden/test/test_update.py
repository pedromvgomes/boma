"""Updates: the soak window, and the transactional rollback that protects it."""

from __future__ import annotations

from conftest import VERSION_NEW, VERSION_OLD, VERSION_UNSOAKED, Container


def _running_version(ctr: Container) -> str:
    return ctr.exec("curl -fsS http://127.0.0.1:8222/alive").stdout.strip()


def _marker_version(ctr: Container) -> str:
    """Which binary last wrote to the database.

    Distinct from the running version: after a rollback these must agree, and a
    binary-only rollback would leave them disagreeing.
    """
    return ctr.sqlite(
        "/var/lib/boma/vaultwarden/db.sqlite3", "SELECT version FROM boma_marker;"
    )


def test_update_applies_a_soaked_release(
    installed: Container, env_base: dict[str, str]
) -> None:
    installed.exec("/opt/boma/vaultwarden/bin/update.sh", env=env_base)

    assert installed.read("/opt/boma/vaultwarden/installed-version").strip() == VERSION_NEW
    assert _running_version(installed) == VERSION_NEW
    assert installed.unit_active("vaultwarden.service")


def test_update_ignores_a_release_that_has_not_soaked(
    installed: Container, env_base: dict[str, str]
) -> None:
    """The newest release is minutes old and must not be installed unattended.

    This is the entire point of the soak window: upstream regressions get time
    to surface for other users before a family vault takes them.
    """
    installed.exec("/opt/boma/vaultwarden/bin/update.sh", env=env_base)

    installed_version = installed.read("/opt/boma/vaultwarden/installed-version").strip()
    assert installed_version == VERSION_NEW
    assert installed_version != VERSION_UNSOAKED


def test_force_bypasses_the_soak_window(
    installed: Container, env_base: dict[str, str]
) -> None:
    """--force exists for an operator who has read the advisory."""
    installed.exec("/opt/boma/vaultwarden/bin/update.sh --force", env=env_base)
    assert (
        installed.read("/opt/boma/vaultwarden/installed-version").strip()
        == VERSION_UNSOAKED
    )


def test_update_dry_run_changes_nothing(
    installed: Container, env_base: dict[str, str]
) -> None:
    result = installed.exec("/opt/boma/vaultwarden/bin/update.sh --dry-run", env=env_base)
    assert "[dry-run]" in result.stderr
    assert installed.read("/opt/boma/vaultwarden/installed-version").strip() == VERSION_OLD
    assert _running_version(installed) == VERSION_OLD


def test_update_is_a_noop_when_already_current(
    installed: Container, env_base: dict[str, str]
) -> None:
    installed.exec("/opt/boma/vaultwarden/bin/update.sh --force", env=env_base)
    result = installed.exec("/opt/boma/vaultwarden/bin/update.sh --force", env=env_base)
    assert "already up to date" in result.stderr


def test_failed_update_rolls_back_binary_and_database(
    installed: Container, env_base: dict[str, str]
) -> None:
    """The load-bearing test for ADR 0004.

    Vaultwarden applies forward-only SQLite migrations at startup, so rolling
    back the binary alone would leave it facing a schema it cannot read. Both
    must revert together.
    """
    assert _marker_version(installed) == VERSION_OLD

    env = dict(env_base)
    env["BOMA_UPDATE_FAIL_HEALTHCHECK"] = "1"

    result = installed.exec("/opt/boma/vaultwarden/bin/update.sh", env=env, check=False)
    assert result.returncode != 0, "a failed health check must fail the update"
    assert "rolling back" in result.stderr

    # Binary reverted...
    assert installed.read("/opt/boma/vaultwarden/installed-version").strip() == VERSION_OLD
    assert _running_version(installed) == VERSION_OLD

    # ...and so did the database. The newer binary started once and stamped the
    # marker; if only the binary had rolled back, this would still read the new
    # version and the schema would be ahead of the running code.
    assert _marker_version(installed) == VERSION_OLD, (
        "database was not rolled back: the schema may be ahead of the binary"
    )

    # And the service is actually serving, not merely 'not failed'.
    assert installed.unit_active("vaultwarden.service")


def test_rollback_keeps_a_local_copy_of_the_previous_binary(
    installed: Container, env_base: dict[str, str]
) -> None:
    """Rollback must not depend on the network or on restic being healthy."""
    env = dict(env_base)
    env["BOMA_UPDATE_FAIL_HEALTHCHECK"] = "1"
    installed.exec("/opt/boma/vaultwarden/bin/update.sh", env=env, check=False)

    assert installed.path_exists(
        f"/opt/boma/vaultwarden/rollback/vaultwarden.{VERSION_OLD}"
    )
    assert installed.path_exists(
        f"/opt/boma/vaultwarden/rollback/db.sqlite3.{VERSION_OLD}"
    )


def test_update_takes_a_pre_update_snapshot(
    installed: Container, env_base: dict[str, str]
) -> None:
    """The pre-update backup is part of the update transaction."""
    installed.exec("/opt/boma/vaultwarden/bin/update.sh", env=env_base)

    snapshots = installed.exec(
        "set -a; . /etc/boma/vaultwarden/restic.env; set +a; "
        "RESTIC_PASSWORD_FILE=/etc/boma/vaultwarden/restic-password "
        "restic snapshots --tag pre-update --json"
    ).stdout
    assert '"short_id"' in snapshots, "no pre-update snapshot was taken"
