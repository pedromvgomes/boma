# Target platform

Every script in this repository targets **one** platform. It is stated here once, and asserted
at runtime by `lib/preflight.sh` so a script cannot quietly run somewhere it was never tested.

| Property | Value |
|---|---|
| OS | Raspberry Pi OS 64-bit (Debian derivative) |
| Debian base | `bookworm` (12) or `trixie` (13) |
| Architecture | `aarch64` / `arm64` |
| Init | systemd (>= 252) |
| Container runtime | **none** — services run as native systemd units |
| Privileges | scripts run as `root` |

## Why this is asserted, not assumed

These scripts create system users, write to `/etc`, install systemd units and manage a password
vault. Running them on an unintended host is not a harmless no-op. `preflight` fails closed:
an unrecognised platform is an error, never a warning.

## Overriding the check

`BOMA_SKIP_PREFLIGHT=1` bypasses the platform assertion. It exists for the test harness, which
runs the same scripts inside a Debian container that is deliberately not a Raspberry Pi.
Do not set it on a real host.

## Development machine

Development and testing happen on macOS `arm64` via podman. Because the Vaultwarden binary is
statically linked for `aarch64-unknown-linux-musl`, the container exercises the byte-identical
artifact that runs on the Pi — the test is not an approximation.

See `docs/adr/0001-build-from-source.md` for how that binary is produced.
