# Testing

Two frameworks, deliberately. Each covers what the other cannot, and neither is a
substitute for the other. See ADR 0005.

## bats — the unit suite

```sh
bats lib/test/
```

Pure-function tests over `lib/`, one file per concern: `util.bats`, `config.bats`,
`version.bats`. They source the library directly and run anywhere, in under a second. This is
where atomic writes, mode enforcement, config parsing, version comparison and soak arithmetic
are pinned.

No third-party assertion helpers: the bats helper libraries were never vendored, so these use
plain `bats-core`. There is deliberately no `gitsubmodule` entry in `.gt-repo.yaml` for that
reason.

Write portable shell in the tests too. `mode_of` in `util.bats` tries GNU `stat -c` **first**
and falls back to BSD `stat -f` only on failure — on Linux `stat -f` is a valid flag meaning
"filesystem info", so a BSD-first chain never falls through and silently compares the wrong
thing.

## pytest — the end-to-end suite

```sh
uv run --group test pytest services/ -q
```

Needs **podman**. Each test builds and boots its own Debian `trixie-slim` container with
systemd as PID 1, mounts the repo read-only, and drives the real scripts inside it:
installing, updating, failing an update on purpose to prove rollback works, backing up,
restoring, and running the drill. Teardown is fixture-driven so an aborted run cannot leak
containers.

It uses a stand-in for the Vaultwarden binary (`fake_vaultwarden.py`). These tests cover
**boma's orchestration**, not Vaultwarden itself.

Three things about the harness worth knowing before you change it:

- **Releases are served over `file://`**, from a fake release tree laid out on disk. That
  removes host-to-container networking from the harness entirely. `VW_RELEASE_BASE` and
  `VW_RELEASE_API` are overridable precisely so this works with no code change.
- **Three versions are published**: `VERSION_OLD` installs first, `VERSION_NEW` has soaked
  and is the update target, `VERSION_UNSOAKED` is deliberately too recent to be eligible for
  an unattended update.
- **`BOMA_SKIP_PREFLIGHT=1` is set inside the container**, which is a Debian box and not a
  Raspberry Pi. That is the only sanctioned use of the flag.

The container image is named `Dockerfile`, not `Containerfile`, on purpose: Dependabot's
docker ecosystem only discovers `Dockerfile*`, so a `Containerfile` would leave the base
image untracked for security updates. podman reads either name.

Options live in `pyproject.toml`: a 600s `timeout` (a wedged systemd would otherwise block
CI until the job limit) and `-n 4` (the suite is almost entirely wait, and four workers cut
it from ~20 minutes to ~6; every fixture creates and tears down its own container, so there
is no shared state).

## The hardening gate is static, not runtime

`test_hardening.py` parses each unit with `systemd-analyze security` and asserts an exposure
score below a per-unit threshold.

It cannot be a runtime assertion. Under rootless podman `ProtectSystem=strict` and
`ProtectHome=yes` are **silently ignored** — the unit still reports success while `/usr`
stays writable — so a test asserting the sandbox were active would pass vacuously. That is
worse than no test: it would imply the Pi is protected when nothing had been verified.
`systemd-analyze` parses the unit instead of observing the sandbox, so it scores the same in
a container as on the host.

The thresholds are **ratchets**. Lowering one is welcome. Raising one should take a
deliberate edit and a stated reason in the PR.

## What to run when

| You changed | Run |
|---|---|
| anything | `shellcheck -x -S style lib/*.sh services/*/*.sh` |
| `lib/**` | the bats suite, plus pytest if a service script's behaviour could shift |
| `services/**` | both suites |
| a systemd unit | pytest — `test_hardening.py` is the gate that catches a widened sandbox |
