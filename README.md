# boma

Bare-metal deployment scripts for self-hosted services on Debian / Raspberry Pi OS — install,
update, backup and restore, driven by systemd units and timers. No Docker. "Boma" is Swahili
for the fenced homestead where everything lives.

## Layout

```
PLATFORM.md              target platform, asserted at runtime by lib/preflight.sh
CONTEXT.md               glossary — the canonical vocabulary
docs/
  RECOVERY.md            disaster-recovery runbook (written for someone who is not you)
  INGRESS.md             the contract with wardnet, which owns TLS and DNS
  adr/                   why things are the way they are
lib/                     shared shell library + bats unit tests
services/<name>/         one directory per service: scripts, systemd units, tests
.github/workflows/       build-vaultwarden.yml (artifacts), ci.yml (lint + tests)
```

Adding a service means adding one directory under `services/`, tests included.

## Services

### vaultwarden

A family password vault. Vaultwarden ships **no** prebuilt server binaries — releases are
source-only and the only distributed artifact is a Docker image — so
[`build-vaultwarden.yml`](.github/workflows/build-vaultwarden.yml) builds a statically linked
`aarch64-unknown-linux-musl` binary from the upstream release tag and publishes it to this
repository's releases under `vaultwarden/<version>` tags. Being static, it is unaffected by a
host OS upgrade changing glibc.

```bash
sudo ./services/vaultwarden/install.sh \
  --domain https://vault.example.com \
  --admin-email you@example.com \
  --smtp-host smtp.example.com --smtp-from vault@example.com \
  --smtp-username you --smtp-password '...' \
  --restic-repo 's3:https://<account>.r2.cloudflarestorage.com/<bucket>' \
  --r2-access-key '...' --r2-secret-key '...'
```

Everything is a flag with a sensible default. `--help` lists them all.

What gets installed:

| | |
|---|---|
| `vaultwarden.service` | the vault, bound to `127.0.0.1:8222` in plain HTTP |
| `boma-vw-backup.timer` | nightly restic backup to Cloudflare R2 |
| `boma-vw-update.timer` | unattended updates, after a 3-day soak, with transactional rollback |
| `boma-vw-verify.timer` | monthly restore drill that proves the backups actually restore |

TLS, DNS and the tunnel are **not** boma's job — see [docs/INGRESS.md](docs/INGRESS.md).

## Design decisions worth knowing

- **Updates soak before installing, and roll back the database as well as the binary.**
  Vaultwarden applies forward-only SQLite migrations at startup, so restoring the old binary
  alone would leave it facing a schema it cannot read. ([ADR 0004](docs/adr/0004-soak-then-unattended-updates.md))
- **Three restic passwords, none memorized.** One on the host for nightly backups, one in a
  personal cloud account, one with a trusted family member. Any one opens the backups; losing
  the host loses none of them. ([ADR 0002](docs/adr/0002-three-restic-repository-passwords.md))
- **Hardening is verified statically, not at runtime.** Under rootless podman,
  `ProtectSystem=strict` is silently ignored, so a runtime test would pass vacuously. CI gates
  on `systemd-analyze security` instead. ([ADR 0005](docs/adr/0005-two-test-frameworks-and-static-hardening-gate.md))

## Testing

```bash
bats lib/test/                              # shell unit tests
uv run --group test pytest services/        # end-to-end, in a systemd container
```

The end-to-end suite runs the real scripts inside a Debian `arm64` container with systemd as
PID 1 — installing, updating, failing an update on purpose to prove rollback works, backing up,
restoring, and running the drill. It uses a stand-in for the Vaultwarden binary, because these
tests cover *boma's orchestration*, not Vaultwarden itself.
