# The vaultwarden service

`services/vaultwarden/` is the only service today and the template for any second one.
`lib.sh` holds everything shared between its scripts; the five entry points
(`install.sh`, `update.sh`, `backup.sh`, `restore.sh`, `verify-backup.sh`) each source it,
call `preflight_host` and `vw_require_tools`, and own one operation.

Vaultwarden ships no prebuilt server binaries — releases are source-only — so
`.github/workflows/build-vaultwarden.yml` builds a static
`aarch64-unknown-linux-musl` binary from the upstream tag and publishes it under a
`vaultwarden/<version>` tag on this repository. Static linking is why a host OS upgrade
changing glibc cannot break the vault. See ADR 0001.

## Configuration precedence

**environment > config file > derived default**, uniformly, for every tunable in
`_VW_TUNABLES`. Holding that uniformly is what `lib.sh`'s three helpers exist for:

- Environment-supplied values are captured into `_VW_ENV_PINNED` **at source time**, before
  defaults are applied, and re-applied by `vw_pin_environment()` after any config file is
  parsed — `load_config` assigns unconditionally, so without this a config file silently
  outranked an explicit environment override.
- `vw_is_pinned <name>` is true when a value was deliberately chosen (environment or config
  file) rather than derived.
- `vw_derive_paths()` recomputes every derived path **after** `boma.env` is loaded. Earlier
  versions tracked a handful of tunables with individual `_VW_EXPLICIT_*` flags and kept
  missing cases.

Read any config-backed setting **after** `vw_load_config`, never at script top level.
`VW_NO_PRUNE` read too early silently ignored the config file.

`BOMA_LIB_TARGET` derives from `VW_BIN_DIR`, not `VW_INSTALL_DIR`: installed scripts resolve
the library as `../../lib` relative to **themselves**, and `VW_BIN_DIR` is independently
overridable. Getting this wrong makes every timer die with "No such file or directory".

## Installed layout

| Path | Holds |
|---|---|
| `/etc/boma/vaultwarden/` | `boma.env`, `vaultwarden.env`, `restic-password`, `restic.env` |
| `/opt/boma/vaultwarden/` | `bin/vaultwarden`, `web-vault/`, `installed-version` |
| `/opt/boma/lib/` | the shared shell library, at `../../lib` from the installed scripts |
| `/var/lib/boma/vaultwarden/` | `db.sqlite3` and the vault's data |
| `/var/lib/boma/staging/`, `/var/lib/boma/scratch/` | download staging and scratch |

The service binds `127.0.0.1:8222` in plain HTTP. TLS, DNS and the tunnel belong to wardnet
— see `docs/INGRESS.md` and ADR 0003.

## Download and authenticity

`vw_download_release()` is shared by install and update. It fetches the binary, `SHA256SUMS`
and the web-vault archive, runs `sha256sum -c`, checks the build-provenance attestation, then
unpacks — and fails if the archive did not contain `web-vault/`.

The checksum proves **transfer** integrity only: `SHA256SUMS` ships from the same release, so
anyone who can rewrite the release can rewrite both. The attestation is what proves
provenance. Two outcomes are deliberately distinct, and must stay so:

| Situation | Behaviour |
|---|---|
| Attestation does not match | **abort** — the artifact is not what the workflow built |
| Cannot check (`gh` missing or unauthenticated) | **warn and continue** — checksums still verified |

Conflating them bricked the host: `gh attestation verify` exits 4 unauthenticated without
checking anything, and a fresh Pi has no authenticated `gh`, so every install and every
unattended update aborted. `vw_attestation_possible()` probes capability up front so the
caller can tell the two apart. `VW_REQUIRE_ATTESTATION=1` makes "cannot check" fatal once a
token is in place; `VW_SKIP_ATTESTATION=1` disables the check entirely.

## Update: soak, then transactional install

`update.sh` installs the newest release that has finished soaking — `VW_SOAK_DAYS`, default
3, evaluated by `soak_satisfied` in `lib/version.sh`. The soak buys time for upstream
regressions to surface elsewhere first. `--force` ignores it, `--version <v>` implies
`--force`, `--dry-run` changes nothing. See ADR 0004.

**Rollback restores the database as well as the binary.** Vaultwarden applies forward-only
SQLite migrations at startup, so restoring the old binary alone would leave it facing a
schema it cannot read — a failed update would become an outage.

`vw_capture_rollback_point()` saves the binary plus a database snapshot and keeps **only the
current point**, because each one is a full binary and a full plaintext copy of the vault.

`vw_rollback_to()` restores binary, database and web vault, rewrites the version stamp,
restarts and health-checks, and echoes `healthy | incomplete | down`. It runs with `errexit`
off on purpose: every step reports itself, and aborting midway would skip both the restart
and the caller's notification. The web vault is restored too — it must match the binary or
the browser UI mismatches the API. Both `install.sh` and `update.sh` call these shared
helpers; they previously had drifting copies, which produced defects in five consecutive
review rounds. **Do not re-inline them.**

## Backups

`backup.sh` writes a restic snapshot to the repository in Cloudflare R2 — nightly via
`boma-vw-backup.timer`, and synchronously by `update.sh` before it touches anything, tagged
`pre-update` so its snapshots are findable.

`vw_snapshot_sqlite()` uses SQLite's `.backup` API, never a file copy: with WAL journalling
the database spans `db.sqlite3`, `-wal` and `-shm`, and a plain copy can capture them at
different instants, producing a backup that restores to a corrupt database. It then runs
`PRAGMA integrity_check` so a truncated snapshot fails at backup time, not at restore time.
The snapshot directory is created `0700` and never re-moded — it is a full plaintext copy of
the vault.

Concurrent backups serialise with `flock`. `--no-prune` forgets old snapshots without
deleting data, which is required when the R2 bucket has a lock: immutability makes prune
fail, and that would fail the backup.

There are **three repository passwords**, any one of which opens the repository: the random
one on the host, a recovery passphrase in a personal cloud account, and a family passphrase
held by a trusted relative. None is memorized. See ADR 0002 and `CONTEXT.md`.

## Restore and the drill

`restore.sh` serves both disaster recovery (`docs/RECOVERY.md`) and update rollback.
`--target <dir>` restores beside the live service without stopping anything — use it for
anything exploratory.

`verify-backup.sh` is the drill. `restic check` verifies repository *structure*; it does not
prove a snapshot restores to a working database — only restoring it does. It runs monthly and
automatically with the host's password (`boma-vw-verify.timer`), and quarterly by hand with
`--password-stdin`. The manual run is the only thing that catches a transcription error made
when a recovery passphrase was saved: a single wrong character stays invisible until the
moment it is needed.

## Units

`vaultwarden.service` plus `boma-vw-{backup,update,verify}.{service,timer}` under
`systemd/`. Hardening directives on these units are gated statically by
`systemd-analyze security` in the test suite, not at runtime — under rootless podman
`ProtectSystem=strict` is silently ignored, so a runtime assertion would pass vacuously.
See ADR 0005 and `testing.md`.
