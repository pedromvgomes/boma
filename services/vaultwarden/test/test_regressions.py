"""Regression guards for defects found in review.

Each test here corresponds to a specific bug that shipped past the original
suite. They are grouped separately so it stays obvious why they exist.
"""

from __future__ import annotations

from conftest import VERSION_NEW, VERSION_OLD, Container, install_cmd

RESTIC_ENV = (
    "set -a; . /etc/boma/vaultwarden/restic.env; set +a; "
    "RESTIC_PASSWORD_FILE=/etc/boma/vaultwarden/restic-password "
)


def test_backup_uses_a_stable_staging_path(installed: Container) -> None:
    """restic retention is a no-op unless the backed-up path is stable.

    With a fresh `mktemp -d` per run, restic's default `--group-by host,paths`
    puts every snapshot in a group of one, so `--keep-daily 7` keeps all of them
    forever and the repository grows without bound.
    """
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag test")
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag test")

    paths = installed.exec(
        RESTIC_ENV + "restic snapshots --json | jq -r '.[].paths[0]' | sort -u | wc -l"
    ).stdout.strip()
    assert paths == "1", (
        "snapshots were taken from more than one path, so restic groups them "
        "separately and retention will never expire anything"
    )


def test_no_prune_setting_is_read_from_the_config_file(installed: Container) -> None:
    """VW_NO_PRUNE was evaluated before boma.env was loaded, so it was ignored.

    RECOVERY.md documents setting it in boma.env for immutable (bucket-locked)
    buckets, where prune fails and would fail the whole backup.
    """
    installed.exec("printf 'VW_NO_PRUNE=1\\n' >> /etc/boma/vaultwarden/boma.env")
    result = installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag test")
    assert "prune disabled" in result.stderr, (
        "VW_NO_PRUNE=1 in boma.env was ignored; backups would still prune and "
        "fail against a bucket-locked repository"
    )


def test_reinstall_preserves_notify_and_smtp_settings(
    container: Container, env_base: dict[str, str]
) -> None:
    """A re-run without the original flags must not silently drop settings.

    Losing BOMA_NOTIFY_URL means failure alerts stop reaching wardnet; losing
    SMTP means family invitations stop working. Neither reports an error.
    """
    container.exec("mkdir -p /srv/restic")
    container.exec(
        install_cmd(
            "--restic-repo /srv/restic "
            "--notify-url https://notify.example.test/hook "
            "--heartbeat-url https://beat.example.test "
            "--smtp-host smtp.example.test --smtp-from vault@example.test "
            "--smtp-username vaultuser --smtp-password sekret --port 8223"
        ),
        env=env_base,
    )

    # Re-run with only the two required flags, as an upgrade would.
    container.exec(
        "/work/services/vaultwarden/install.sh "
        "--domain https://vault.example.test --admin-email admin@example.test "
        f"--skip-smtp-test --non-interactive --version {VERSION_OLD}",
        env=env_base,
    )

    boma_env = container.read("/etc/boma/vaultwarden/boma.env")
    app_env = container.read("/etc/boma/vaultwarden/vaultwarden.env")

    assert "notify.example.test" in boma_env, "notify URL was dropped on re-install"
    assert "beat.example.test" in boma_env, "heartbeat URL was dropped on re-install"
    assert "smtp.example.test" in app_env, "SMTP host was dropped on re-install"
    assert "vaultuser" in app_env, "SMTP username was dropped on re-install"
    assert "8223" in app_env, "non-default port was reset on re-install"


def test_explicit_version_can_downgrade(
    installed: Container, env_base: dict[str, str]
) -> None:
    """--version is an operator decision, including going backwards.

    The newer-only guard made a downgrade exit 0 as a no-op, leaving a broken
    release running while reporting success.
    """
    installed.exec("/opt/boma/vaultwarden/bin/update.sh --force", env=env_base)
    upgraded = installed.read("/opt/boma/vaultwarden/installed-version").strip()
    assert upgraded != VERSION_OLD

    result = installed.exec(
        f"/opt/boma/vaultwarden/bin/update.sh --version {VERSION_OLD}", env=env_base
    )
    assert "DOWNGRADING" in result.stderr
    assert installed.read("/opt/boma/vaultwarden/installed-version").strip() == VERSION_OLD


def test_rollback_also_restores_the_web_vault(
    installed: Container, env_base: dict[str, str]
) -> None:
    """A rolled-back binary must not be left serving the new release's UI.

    Otherwise the old server serves the new web vault — an API/UI mismatch —
    on a service that reports itself as 'rolled back and healthy'.
    """
    before = installed.read("/opt/boma/vaultwarden/web-vault/index.html")
    assert VERSION_OLD in before

    env = dict(env_base)
    env["BOMA_UPDATE_FAIL_HEALTHCHECK"] = "1"
    installed.exec("/opt/boma/vaultwarden/bin/update.sh", env=env, check=False)

    after = installed.read("/opt/boma/vaultwarden/web-vault/index.html")
    assert VERSION_OLD in after, (
        f"web vault was not rolled back: still serving {VERSION_NEW} assets "
        f"under the {VERSION_OLD} binary"
    )
    assert VERSION_NEW not in after


def test_rollback_directory_is_not_world_readable(
    installed: Container, env_base: dict[str, str]
) -> None:
    """vw_snapshot_sqlite re-applied a 0755 default over a deliberate 0700.

    The rollback directory holds a full plaintext copy of the vault database,
    so widening it exposes every stored credential to any local user.
    """
    installed.exec("/opt/boma/vaultwarden/bin/update.sh --force", env=env_base)

    assert installed.path_exists("/opt/boma/vaultwarden/rollback")
    assert installed.mode_of("/opt/boma/vaultwarden/rollback") == "700", (
        "the rollback directory holds a copy of the vault database and must "
        "not be readable by other local users"
    )


def test_systemd_backup_unit_can_actually_run(installed: Container) -> None:
    """Run the unit, not just the script.

    The seccomp filter on boma-vw-backup.service subtracted @privileged, which
    includes @chown, killing the `cp -a` that stages vaultwarden-owned files.
    Invoking backup.sh directly never exercised the filter, so the nightly
    backup would have failed on the Pi while the suite stayed green.
    """
    result = installed.exec(
        "systemctl start boma-vw-backup.service", check=False
    )
    status = installed.exec(
        "systemctl show boma-vw-backup.service -p Result --value"
    ).stdout.strip()

    if result.returncode != 0 or status != "success":
        journal = installed.exec(
            "journalctl -u boma-vw-backup.service --no-pager -n 40", check=False
        ).stdout
        raise AssertionError(
            f"boma-vw-backup.service failed (Result={status}):\n{journal}"
        )


def test_install_creates_the_staging_directory(installed: Container) -> None:
    """The backup and update units name it in ReadWritePaths.

    systemd refuses to start a unit whose ReadWritePaths entry does not exist,
    and it fails during namespace setup — before ExecStart — so the script's own
    alerting never runs. Both timers would be permanently dead on a fresh host.
    """
    assert installed.path_exists("/var/lib/boma/staging/vaultwarden")
    assert installed.mode_of("/var/lib/boma/staging/vaultwarden") == "700"


def test_flags_override_recorded_config_on_reinstall(
    container: Container, env_base: dict[str, str]
) -> None:
    """Carrying config forward must not outrank an explicit flag.

    load_config exports VW_PORT, so loading it after argument parsing silently
    undid --port: the vault came back on the old port while install reported
    success and the tunnel got connection-refused.
    """
    container.exec("mkdir -p /srv/restic")
    container.exec(install_cmd("--restic-repo /srv/restic"), env=env_base)
    assert "ROCKET_PORT=8222" in container.read("/etc/boma/vaultwarden/vaultwarden.env")

    container.exec(install_cmd("--port 9000"), env=env_base)

    app_env = container.read("/etc/boma/vaultwarden/vaultwarden.env")
    assert "ROCKET_PORT=9000" in app_env, "--port was overridden by the recorded config"
    assert "ROCKET_PORT=8222" not in app_env


def test_backup_notifies_when_the_database_cannot_be_read(
    installed: Container,
) -> None:
    """The most likely backup failure must still reach the operator.

    lib.sh helpers call die(), which exits immediately, so a trailing
    `|| fail ...` at the call site was dead code and the failure was silent.
    """
    installed.exec("systemctl stop vaultwarden.service")
    installed.exec("rm -f /var/lib/boma/vaultwarden/db.sqlite3")

    result = installed.exec(
        "/opt/boma/vaultwarden/bin/backup.sh --tag test", check=False
    )
    assert result.returncode != 0
    assert "Vaultwarden backup FAILED" in result.stderr, (
        "backup failed without notifying; a silently stopped backup is "
        "indistinguishable from a working one"
    )


def test_update_fails_loudly_when_no_releases_can_be_parsed(
    installed: Container, env_base: dict[str, str]
) -> None:
    """An empty release index is a broken index, not 'nothing has soaked'.

    Reporting success here let a renamed repo or changed tag prefix stop
    updates forever while the heartbeat kept saying healthy.
    """
    installed.exec("echo '[]' > /srv/empty-releases.json")
    env = dict(env_base)
    env["VW_RELEASE_API"] = "file:///srv/empty-releases.json"

    result = installed.exec(
        "/opt/boma/vaultwarden/bin/update.sh", env=env, check=False
    )
    assert result.returncode != 0
    assert "no vaultwarden/* releases found" in result.stderr


def test_rollback_directory_keeps_only_the_current_version(
    installed: Container, env_base: dict[str, str]
) -> None:
    """Each rollback point is a full plaintext copy of the vault database."""
    installed.exec("/opt/boma/vaultwarden/bin/update.sh --force", env=env_base)
    installed.exec("/opt/boma/vaultwarden/bin/update.sh --force", env=env_base, check=False)

    copies = installed.exec(
        "ls /opt/boma/vaultwarden/rollback/db.sqlite3.* 2>/dev/null | wc -l"
    ).stdout.strip()
    assert copies == "1", (
        f"{copies} plaintext database copies retained; each update should "
        "replace the previous rollback point, not accumulate one"
    )


def test_smtp_password_is_quoted_in_the_environment_file(
    container: Container, env_base: dict[str, str]
) -> None:
    """systemd's EnvironmentFile parser mangles unquoted awkward values."""
    container.exec("mkdir -p /srv/restic")
    container.exec(
        install_cmd(
            "--restic-repo /srv/restic --smtp-host smtp.example.test "
            "--smtp-from vault@example.test --smtp-username u "
            "--smtp-password '#pass with spaces'"
        ),
        env=env_base,
    )
    app_env = container.read("/etc/boma/vaultwarden/vaultwarden.env")
    assert 'SMTP_PASSWORD="#pass with spaces"' in app_env


def test_reinstall_does_not_accumulate_quotes_on_smtp_credentials(
    container: Container, env_base: dict[str, str]
) -> None:
    """SMTP values are written double-quoted, so carry-forward must strip both.

    Stripping only single quotes re-quoted them on every re-install, adding a
    layer of literal quote characters each time until SMTP auth failed.
    """
    container.exec("mkdir -p /srv/restic")
    container.exec(
        install_cmd(
            "--restic-repo /srv/restic --smtp-host smtp.example.test "
            "--smtp-from vault@example.test --smtp-username vaultuser "
            "--smtp-password sekret"
        ),
        env=env_base,
    )
    container.exec(install_cmd(), env=env_base)
    container.exec(install_cmd(), env=env_base)

    app_env = container.read("/etc/boma/vaultwarden/vaultwarden.env")
    assert 'SMTP_USERNAME="vaultuser"' in app_env, (
        f"quotes accumulated across re-installs:\n{app_env}"
    )
    assert '\\"' not in app_env


def test_reinstall_preserves_r2_credentials(
    container: Container, env_base: dict[str, str]
) -> None:
    """Re-running with --restic-repo but no --r2-* keys must not erase them."""
    container.exec("mkdir -p /srv/restic")
    container.exec(
        install_cmd(
            "--restic-repo /srv/restic --r2-access-key AKIATEST "
            "--r2-secret-key SECRETTEST"
        ),
        env=env_base,
    )
    container.exec(install_cmd("--restic-repo /srv/restic"), env=env_base)

    restic_env = container.read("/etc/boma/vaultwarden/restic.env")
    assert "AKIATEST" in restic_env, "R2 access key was destroyed on re-install"
    assert "SECRETTEST" in restic_env, "R2 secret key was destroyed on re-install"


def test_install_can_attach_to_an_existing_repository(
    installed: Container, env_base: dict[str, str]
) -> None:
    """The documented disaster-recovery flow: rebuild a host onto existing backups.

    Without --restic-password-stdin, install generated a fresh password, failed
    against the existing repository, and died before installing anything.
    """
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag test")
    pi_password = installed.read("/etc/boma/vaultwarden/restic-password")

    # Simulate a rebuilt host: config gone, backups intact.
    installed.exec("systemctl stop vaultwarden.service")
    installed.exec("rm -rf /etc/boma/vaultwarden /opt/boma/vaultwarden")

    installed.exec(
        install_cmd("--restic-repo /srv/restic --restic-password-stdin"),
        env=env_base,
        stdin=pi_password + "\n",
    )

    result = installed.exec(
        "set -a; . /etc/boma/vaultwarden/restic.env; set +a; "
        "RESTIC_PASSWORD_FILE=/etc/boma/vaultwarden/restic-password "
        "restic snapshots --json"
    )
    assert '"short_id"' in result.stdout, "could not read the pre-existing backups"


def test_restore_refuses_a_newer_schema_snapshot(
    installed: Container, env_base: dict[str, str]
) -> None:
    """Migrations are forward-only, so a newer snapshot under an older binary
    would swap in a database the running code cannot read."""
    installed.exec("/opt/boma/vaultwarden/bin/update.sh --force", env=env_base)
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag newer")

    # Go back to the old binary, leaving the newer-version snapshot in place.
    installed.exec(
        f"/opt/boma/vaultwarden/bin/update.sh --version {VERSION_OLD}", env=env_base
    )

    # --force only skips the confirmation prompt. It must NOT disable the
    # schema-compatibility check, or every automated restore would lose it.
    result = installed.exec(
        "/opt/boma/vaultwarden/bin/restore.sh --snapshot latest --force", check=False
    )
    assert result.returncode != 0, "--force must not bypass the version guard"
    assert "forward-only" in result.stderr

    # The dedicated override does allow it.
    override = installed.exec(
        "/opt/boma/vaultwarden/bin/restore.sh --snapshot latest --force "
        "--allow-version-mismatch",
        check=False,
    )
    assert "--allow-version-mismatch was given" in override.stderr


def test_drill_fails_when_the_snapshot_lost_most_of_the_vault(
    installed: Container,
) -> None:
    """'Non-empty' is too weak a bar for a restore drill.

    A snapshot that kept one user but lost the rest would otherwise pass.
    """
    installed.exec(
        "sqlite3 -cmd '.timeout 10000' /var/lib/boma/vaultwarden/db.sqlite3 "
        "\"INSERT INTO users (uuid,email,name) VALUES ('u2','b@x.test','B'),"
        "('u3','c@x.test','C');\""
    )
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh")

    # Live vault keeps 3 users; the snapshot we verify has only 1.
    installed.exec("systemctl stop vaultwarden.service")
    installed.exec(
        "sqlite3 -cmd '.timeout 10000' /var/lib/boma/vaultwarden/db.sqlite3 \"DELETE FROM users WHERE uuid!='u2';\""
    )
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh")
    installed.exec(
        "sqlite3 -cmd '.timeout 10000' /var/lib/boma/vaultwarden/db.sqlite3 "
        "\"INSERT INTO users (uuid,email,name) VALUES ('u1','a@x.test','A'),('u3','c@x.test','C');\""
    )

    result = installed.exec(
        "/opt/boma/vaultwarden/bin/verify-backup.sh --snapshot latest", check=False
    )
    assert result.returncode != 0
    assert "incomplete" in result.stderr


def test_drill_tolerates_a_vault_that_gained_users_since_the_snapshot(
    installed: Container,
) -> None:
    """A snapshot legitimately lags the live vault.

    Failing on any shortfall made the monthly drill cry wolf after every
    accepted invitation, training the operator to ignore the one alert that
    proves the backups work.
    """
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh")

    # Someone accepts an invitation after the snapshot was taken.
    installed.exec(
        "sqlite3 -cmd '.timeout 10000' /var/lib/boma/vaultwarden/db.sqlite3 "
        "\"INSERT INTO users (uuid,email,name) VALUES ('newbie','n@x.test','N');\""
    )

    result = installed.exec("/opt/boma/vaultwarden/bin/verify-backup.sh --snapshot latest")
    assert "restore drill passed" in result.stderr


def test_installed_units_contain_no_unsubstituted_placeholders(
    installed: Container,
) -> None:
    """The units are templates rendered at install time.

    They used to hardcode /opt/boma/vaultwarden and /var/lib/boma/*, so a
    non-default VW_DATA_DIR produced a unit whose ReadWritePaths pointed
    elsewhere — and under ProtectSystem=strict the vault could not create its
    own database.
    """
    for unit in (
        "vaultwarden.service",
        "boma-vw-backup.service",
        "boma-vw-update.service",
        "boma-vw-verify.service",
    ):
        content = installed.read(f"/etc/systemd/system/{unit}")
        assert "@VW_" not in content, f"{unit} has unsubstituted placeholders"
        assert "/opt/boma/vaultwarden" in content or "/var/lib/boma" in content

    # systemd's own @-prefixed syscall groups must survive untouched.
    vw = installed.read("/etc/systemd/system/vaultwarden.service")
    assert "SystemCallFilter=@system-service" in vw


def test_reinstall_preserves_operator_added_config_keys(
    installed: Container, env_base: dict[str, str]
) -> None:
    """boma.env was regenerated from a fixed key list, dropping VW_NO_PRUNE.

    backup.sh reads it at runtime, so an immutable-bucket setup would silently
    revert to pruning and start failing every night.
    """
    installed.exec(
        "printf 'VW_NO_PRUNE=1\\nVW_RETENTION=--keep-daily 3\\n' "
        ">> /etc/boma/vaultwarden/boma.env"
    )
    installed.exec(install_cmd("--restic-repo /srv/restic"), env=env_base)

    boma_env = installed.read("/etc/boma/vaultwarden/boma.env")
    assert "VW_NO_PRUNE=1" in boma_env, "operator-set VW_NO_PRUNE was dropped"
    assert "VW_RETENTION" in boma_env, "operator-set VW_RETENTION was dropped"


def test_smtp_flags_override_recorded_config(
    container: Container, env_base: dict[str, str]
) -> None:
    """--smtp-port/--smtp-from-name/--smtp-security were silently ignored."""
    container.exec("mkdir -p /srv/restic")
    container.exec(
        install_cmd(
            "--restic-repo /srv/restic --smtp-host smtp.example.test "
            "--smtp-from vault@example.test --smtp-port 587"
        ),
        env=env_base,
    )
    container.exec(install_cmd("--smtp-port 2525 --smtp-security force_tls"), env=env_base)

    app_env = container.read("/etc/boma/vaultwarden/vaultwarden.env")
    assert "SMTP_PORT=2525" in app_env, "--smtp-port was ignored on re-install"
    assert "SMTP_SECURITY=force_tls" in app_env, "--smtp-security was ignored"


def test_install_takes_a_rollback_point_when_upgrading(
    installed: Container, env_base: dict[str, str]
) -> None:
    """install.sh is a documented upgrade path, so it needs update.sh's safety net.

    Migrations are forward-only: a new binary that starts, migrates and then
    fails leaves the old one unable to read its own database.
    """
    from conftest import VERSION_NEW

    installed.exec(install_cmd(version=VERSION_NEW), env=env_base)

    assert installed.path_exists(
        f"/opt/boma/vaultwarden/rollback/vaultwarden.{VERSION_OLD}"
    ), "no rollback copy of the previous binary was taken"
    assert installed.path_exists(
        f"/opt/boma/vaultwarden/rollback/db.sqlite3.{VERSION_OLD}"
    ), "no pre-upgrade database snapshot was taken"


def test_concurrent_backups_are_serialised(installed: Container) -> None:
    """update.sh runs backup.sh, which rm -rf's a FIXED staging directory.

    After downtime both Persistent=true timers fire at boot, so the nightly
    backup and the pre-update backup can overlap and delete each other's
    staged files mid-restic-backup.
    """
    # The lock lives beside the staging directory, NOT in /var/lock: under
    # ProtectSystem=strict only the data, staging and scratch directories are
    # writable, so a lock in /var/lock failed every systemd-driven backup.
    lock = "/var/lib/boma/staging/.vaultwarden-backup.lock"
    assert installed.path_exists("/var/lib/boma/staging"), "staging base missing"

    result = installed.exec(
        f"flock -n {lock} -c 'sleep 8' & "
        "sleep 1; "
        "VW_BACKUP_LOCK_WAIT=2 /opt/boma/vaultwarden/bin/backup.sh --tag test; "
        "echo rc=$?",
        check=False,
    )
    assert "another backup is still running" in result.stderr, (
        f"a second concurrent backup was not blocked by the lock at {lock}"
    )


def test_backup_lock_lives_in_a_writable_sandbox_path(installed: Container) -> None:
    """The lock must sit inside a directory the unit can actually write to.

    boma-vw-backup.service runs under ProtectSystem=strict with ReadWritePaths
    limited to the data, staging and scratch directories, so /var/lock is
    read-only there and every scheduled backup aborted before staging anything.
    Rootless podman ignores those directives (ADR 0005), so this asserts on the
    unit's declared paths rather than trying to observe enforcement.
    """
    unit = installed.read("/etc/systemd/system/boma-vw-backup.service")
    rw_line = next(l for l in unit.splitlines() if l.startswith("ReadWritePaths="))
    writable = rw_line.split("=", 1)[1].split()

    installed.exec("/opt/boma/vaultwarden/bin/backup.sh --tag test")
    lock = "/var/lib/boma/staging/.vaultwarden-backup.lock"
    assert installed.path_exists(lock), "backup did not create its lock file"
    assert any(lock.startswith(p.rstrip("/") + "/") for p in writable), (
        f"lock {lock} is outside the unit's writable paths {writable}"
    )


def test_environment_overrides_outrank_the_config_file(
    installed: Container, env_base: dict[str, str]
) -> None:
    """Precedence must be environment > config file > derived default.

    load_config assigns unconditionally, so without re-pinning, a value recorded
    in boma.env silently outranked an explicit environment override.
    """
    installed.exec(
        "printf 'VW_SOAK_DAYS=99\\n' >> /etc/boma/vaultwarden/boma.env"
    )
    env = dict(env_base)
    env["VW_SOAK_DAYS"] = "0"

    # With the config's 99 winning, nothing would ever be eligible; with the
    # environment's 0 winning, the newest release is.
    result = installed.exec("/opt/boma/vaultwarden/bin/update.sh --dry-run", env=env)
    assert "update available" in result.stderr, (
        "the config file overrode an explicit environment value"
    )


def test_drill_fails_on_a_stale_snapshot(installed: Container) -> None:
    """A drill that only proves 'the latest snapshot restores' is not enough.

    If backups stopped months ago it keeps passing on a stale snapshot and keeps
    sending heartbeats, so a later host loss recovers a months-old vault.
    """
    installed.exec("/opt/boma/vaultwarden/bin/backup.sh")

    result = installed.exec(
        "VW_MAX_SNAPSHOT_AGE_DAYS=-1 /opt/boma/vaultwarden/bin/verify-backup.sh",
        check=False,
    )
    assert result.returncode != 0
    assert "backups have stopped" in result.stderr


def test_unreachable_repository_does_not_destroy_working_config(
    installed: Container, env_base: dict[str, str]
) -> None:
    """A typo'd --restic-repo must not overwrite a working restic.env."""
    before = installed.read("/etc/boma/vaultwarden/restic.env")

    result = installed.exec(
        install_cmd("--restic-repo /srv/does-not-exist"), env=env_base, check=False
    )
    assert result.returncode != 0
    assert "left untouched" in result.stderr

    assert installed.read("/etc/boma/vaultwarden/restic.env") == before, (
        "a failed re-configuration destroyed the working restic settings"
    )


def test_unit_environment_file_follows_the_configured_path(
    installed: Container,
) -> None:
    """VW_APP_ENV is documented as overridable, so the unit must track it."""
    unit = installed.read("/etc/systemd/system/vaultwarden.service")
    assert "EnvironmentFile=/etc/boma/vaultwarden/vaultwarden.env" in unit
    assert "@VW_APP_ENV@" not in unit


def test_drill_ignores_pre_update_snapshots_when_judging_freshness(
    installed: Container, env_base: dict[str, str]
) -> None:
    """A pre-update snapshot must not mask a dead nightly backup timer.

    The drill exists to prove the SCHEDULED chain is alive. Resolving a bare
    `latest` across all tags let update.sh's own snapshot satisfy the freshness
    check, re-opening the hole --quiet-report was added to close.
    """
    # Only a pre-update snapshot exists; the nightly series never ran.
    installed.exec("/opt/boma/vaultwarden/bin/update.sh --force", env=env_base)

    result = installed.exec(
        "/opt/boma/vaultwarden/bin/verify-backup.sh", check=False
    )
    assert result.returncode != 0
    assert "never produced one" in result.stderr, (
        "a pre-update snapshot satisfied the nightly-freshness check"
    )


def _stub_gh(container: Container, auth_exit: int, verify_exit: int) -> None:
    """Install a fake `gh` so attestation behaviour can be driven precisely.

    Real gh needs credentials and network; what matters here is only how boma
    reacts to the two distinct outcomes.
    """
    container.exec(
        "cat > /usr/local/bin/gh <<'EOF'\n"
        "#!/bin/sh\n"
        'case "$1" in\n'
        f"  auth) exit {auth_exit} ;;\n"
        f"  attestation) exit {verify_exit} ;;\n"
        "esac\n"
        "exit 0\n"
        "EOF\n"
        "chmod 0755 /usr/local/bin/gh"
    )


def test_install_proceeds_when_attestation_cannot_be_checked(
    container: Container, env_base: dict[str, str]
) -> None:
    """An unauthenticated gh must not brick the host.

    `gh attestation verify` requires credentials and exits 4 without them. A
    fresh Pi has no authenticated gh, so treating that as a verification
    FAILURE aborted every install and every unattended update — turning a
    defence-in-depth control into a total outage.
    """
    container.exec("mkdir -p /srv/restic")
    _stub_gh(container, auth_exit=1, verify_exit=4)

    result = container.exec(
        install_cmd("--restic-repo /srv/restic"), env=env_base, check=False
    )
    assert result.returncode == 0, (
        f"install aborted because provenance could not be checked:\n{result.stderr}"
    )
    assert "NOT verified" in result.stderr
    assert "not authenticated" in result.stderr
    assert container.unit_active("vaultwarden.service")


def test_install_aborts_when_attestation_actually_fails(
    container: Container, env_base: dict[str, str]
) -> None:
    """A real verification failure is an attack signal and must still abort."""
    container.exec("mkdir -p /srv/restic")
    # Authenticated, and verification genuinely fails.
    _stub_gh(container, auth_exit=0, verify_exit=1)

    result = container.exec(
        install_cmd("--restic-repo /srv/restic"), env=env_base, check=False
    )
    assert result.returncode != 0, "a failed attestation must abort the install"
    assert "attestation FAILED" in result.stderr
    assert not container.path_exists("/opt/boma/vaultwarden/bin/vaultwarden")


def test_require_attestation_makes_unverifiable_fatal(
    container: Container, env_base: dict[str, str]
) -> None:
    """Operators who have a token can opt into strictness."""
    container.exec("mkdir -p /srv/restic")
    _stub_gh(container, auth_exit=1, verify_exit=4)

    env = dict(env_base)
    env["VW_REQUIRE_ATTESTATION"] = "1"
    result = container.exec(
        install_cmd("--restic-repo /srv/restic"), env=env, check=False
    )
    assert result.returncode != 0
    assert "VW_REQUIRE_ATTESTATION=1" in result.stderr
