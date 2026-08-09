"""Install behaviour: correctness, idempotency, and the gates that fail closed."""

from __future__ import annotations

import pytest

from conftest import VERSION_OLD, Container, install_cmd


def test_install_leaves_the_service_healthy(installed: Container) -> None:
    assert installed.unit_active("vaultwarden.service")
    body = installed.exec("curl -fsS http://127.0.0.1:8222/alive").stdout.strip()
    assert body == VERSION_OLD


def test_install_records_the_version(installed: Container) -> None:
    assert installed.read("/opt/boma/vaultwarden/installed-version").strip() == VERSION_OLD


def test_install_enables_the_timers(installed: Container) -> None:
    for timer in ("boma-vw-backup.timer", "boma-vw-update.timer", "boma-vw-verify.timer"):
        assert installed.unit_active(timer), f"{timer} should be active"


def test_install_is_idempotent(installed: Container, env_base: dict[str, str]) -> None:
    """A second run must converge, not fail and not rotate secrets."""
    before = installed.read("/etc/boma/vaultwarden/restic-password")

    installed.exec(
        install_cmd("--restic-repo /srv/restic"), env=env_base
    )

    assert installed.read("/etc/boma/vaultwarden/restic-password") == before, (
        "re-running install rotated the restic password; existing backups "
        "would become unreachable with the stored credential"
    )
    assert installed.unit_active("vaultwarden.service")


def test_reinstall_does_not_add_duplicate_restic_keys(
    installed: Container, env_base: dict[str, str]
) -> None:
    """Re-running install must not accumulate repository passwords."""
    count_cmd = (
        "set -a; . /etc/boma/vaultwarden/restic.env; set +a; "
        "RESTIC_PASSWORD_FILE=/etc/boma/vaultwarden/restic-password "
        "restic key list --json | jq 'length'"
    )
    before = int(installed.exec(count_cmd).stdout.strip())

    installed.exec(install_cmd("--restic-repo /srv/restic"), env=env_base)

    after = int(installed.exec(count_cmd).stdout.strip())
    assert after == before == 3, (
        f"expected exactly 3 repository passwords, found {after} "
        "(re-install should not add more)"
    )


@pytest.mark.parametrize(
    ("flag", "reason"),
    [
        ("--domain http://vault.example.test", "http:// breaks WebAuthn"),
        ("--domain https://vault.example.test/", "trailing slash"),
        ("--port not-a-number", "non-numeric port"),
        ("--soak-days maybe", "non-numeric soak"),
        ("--smtp-security sometimes", "invalid smtp security mode"),
    ],
)
def test_install_rejects_invalid_arguments(
    container: Container, env_base: dict[str, str], flag: str, reason: str
) -> None:
    result = container.exec(
        f"/work/services/vaultwarden/install.sh "
        f"--domain https://vault.example.test --admin-email a@b.test "
        f"--skip-smtp-test --non-interactive --version {VERSION_OLD} {flag}",
        env=env_base,
        check=False,
    )
    assert result.returncode != 0, f"install should reject: {reason}"


def test_install_fails_when_smtp_is_unreachable(
    container: Container, env_base: dict[str, str]
) -> None:
    """SMTP is verified at install time, not assumed.

    A silently broken SMTP configuration otherwise surfaces during family
    onboarding, which is the worst possible moment to discover it.
    """
    result = container.exec(
        f"/work/services/vaultwarden/install.sh "
        f"--domain https://vault.example.test --admin-email admin@example.test "
        f"--non-interactive --version {VERSION_OLD} "
        # Nothing is listening on this port inside the container.
        f"--smtp-host 127.0.0.1 --smtp-port 2525 --smtp-from vault@example.test "
        f"--smtp-security off",
        env=env_base,
        check=False,
    )
    assert result.returncode != 0, "install must fail when SMTP does not work"
    assert "SMTP verification failed" in result.stderr


def test_secrets_are_not_world_readable(installed: Container) -> None:
    """Anything that grants access to the backups must be root-only."""
    assert installed.mode_of("/etc/boma/vaultwarden/restic-password") == "600"
    assert installed.mode_of("/etc/boma/vaultwarden/restic.env") == "600"


def test_config_is_not_world_readable(installed: Container) -> None:
    assert installed.mode_of("/etc/boma/vaultwarden/vaultwarden.env") == "640"
    assert installed.mode_of("/etc/boma/vaultwarden") == "750"


def test_admin_token_is_stored_hashed_not_in_clear(installed: Container) -> None:
    env = installed.read("/etc/boma/vaultwarden/vaultwarden.env")
    assert "ADMIN_TOKEN='$argon2" in env, (
        "ADMIN_TOKEN must be an Argon2 PHC hash so reading the config file "
        "does not yield a usable admin credential"
    )


def test_domain_and_ip_header_are_configured(installed: Container) -> None:
    """Both are load-bearing and easy to get silently wrong (docs/INGRESS.md)."""
    env = installed.read("/etc/boma/vaultwarden/vaultwarden.env")
    assert "DOMAIN=https://vault.example.test" in env
    assert "IP_HEADER=X-Real-IP" in env
    assert "SIGNUPS_ALLOWED=false" in env
    assert "ORG_CREATION_USERS=admin@example.test" in env


def test_service_binds_loopback_only(installed: Container) -> None:
    env = installed.read("/etc/boma/vaultwarden/vaultwarden.env")
    assert "ROCKET_ADDRESS=127.0.0.1" in env


def test_preflight_rejects_an_unsupported_architecture(
    container: Container, env_base: dict[str, str]
) -> None:
    """preflight must fail closed on an unexpected host."""
    env = dict(env_base)
    env.pop("BOMA_SKIP_PREFLIGHT")
    env["BOMA_SUPPORTED_ARCH"] = "s390x"

    result = container.exec(install_cmd(), env=env, check=False)
    assert result.returncode != 0
    assert "unsupported architecture" in result.stderr
