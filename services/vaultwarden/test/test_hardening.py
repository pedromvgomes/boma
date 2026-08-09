"""Static hardening gate for the systemd units.

Runtime assertions cannot be used here. Under rootless podman, options such as
``ProtectSystem=strict`` and ``ProtectHome=yes`` are SILENTLY IGNORED — the unit
still reports success while /usr stays writable. A test asserting the sandbox
were active would therefore pass vacuously, which is worse than no test: it
would imply the Pi is protected when nothing had been verified.

``systemd-analyze security`` parses the unit instead of observing the sandbox,
so it reports the same score in a container as on the host.

See docs/adr/0005-two-test-frameworks-and-static-hardening-gate.md
"""

from __future__ import annotations

import re

import pytest

from conftest import Container

# Exposure thresholds, pinned per unit. systemd-analyze scores 0 (locked down)
# to 10 (unconfined). These are ratchets: lowering them is welcome, raising one
# should require a deliberate edit and a reason.
THRESHOLDS = {
    "vaultwarden.service": 4.0,
    "boma-vw-backup.service": 6.5,
    "boma-vw-update.service": 7.5,
    "boma-vw-verify.service": 6.5,
}


def _exposure(ctr: Container, unit: str) -> float:
    out = ctr.exec(
        f"systemd-analyze security {unit} --no-pager 2>&1 | tail -5"
    ).stdout
    match = re.search(r"exposure level for .* (\d+\.\d+)", out)
    assert match, f"could not parse an exposure score for {unit} from:\n{out}"
    return float(match.group(1))


@pytest.mark.parametrize("unit", sorted(THRESHOLDS))
def test_unit_meets_its_exposure_threshold(installed: Container, unit: str) -> None:
    score = _exposure(installed, unit)
    limit = THRESHOLDS[unit]
    assert score <= limit, (
        f"{unit} scored {score} (limit {limit}). Hardening regressed — "
        f"run `systemd-analyze security {unit}` to see which directives were lost."
    )


def test_vault_service_drops_all_capabilities(installed: Container) -> None:
    """The vault process needs no capabilities; it binds an unprivileged port."""
    out = installed.exec(
        "systemctl show vaultwarden.service -p CapabilityBoundingSet --value"
    ).stdout.strip()
    assert out == "", f"expected an empty capability bounding set, got: {out!r}"


def test_vault_service_runs_as_its_own_user(installed: Container) -> None:
    user = installed.exec(
        "systemctl show vaultwarden.service -p User --value"
    ).stdout.strip()
    assert user == "vaultwarden", "the vault must not run as root"


def test_vault_service_cannot_write_its_own_binary(installed: Container) -> None:
    """Only the data directory is writable.

    Declared via ReadWritePaths so a compromised process cannot rewrite the
    executable it will run after the next restart.
    """
    paths = installed.exec(
        "systemctl show vaultwarden.service -p ReadWritePaths --value"
    ).stdout.strip()
    assert "/var/lib/boma/vaultwarden" in paths
    assert "/opt/boma" not in paths
