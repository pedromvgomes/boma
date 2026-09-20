# CI and repository governance

## gt owns the pipeline

`.gt-repo.yaml` is the source of truth for everything gt manages. Edit it, then run
`gt repo sync` to re-render and `gt repo check` to verify. **Never hand-edit a file whose
header says "Managed by gt"** — the next sync overwrites it, and `gt repo check` fails the
governance stage in the meantime.

Only deliberate overrides belong in `.gt-repo.yaml`. Everything absent follows gt's default
and keeps following it as that default changes; a value pinned in the file stops tracking gt,
which is why sync removes entries that merely restate a default. `gt repo config` prints the
resolved spec with defaults included.

Shared policy — Dependabot cooldown, commit-message prefixes, the weekly sync schedule —
lives in gt's templates rather than here, so it stays consistent across every governed repo.

## The stages

`ci-orchestration.yml` is rendered by gt and calls one workflow per stage. The stage
workflows are **yours**: gt creates each one once and never touches it again.

| Stage | File | What it does |
|---|---|---|
| preflight | `ci-preflight.yml` | decides which later stages run; the stub runs everything |
| build | `ci-build.yml` | `shellcheck -x -S style lib/*.sh services/*/*.sh` |
| test | `ci-test.yml` | `bats lib/test/` |
| end2end | `ci-end2end.yml` | the pytest suite under podman, on `ubuntu-24.04-arm` |

end2end runs on native arm64 so the container exercises the same architecture as the
Raspberry Pi and the developer's Mac throughout.

Branch protection requires exactly **one** check, `ci-gate`, which aggregates every stage
with `needs:` rather than polling the checks API — so there is no timeout and no way to
confuse "absent" with "not started yet". A stage skipped by preflight still passes the gate.

CD is disabled (`pipeline.cd.enabled: false`); releases come from `build-vaultwarden.yml`.

`attest` short-circuits the pipeline when this exact tree already passed, so a push that
merely squashed an already-validated PR does not run everything again.

## Release builds

`build-vaultwarden.yml` is not part of the gt pipeline. It runs daily on a schedule and on
demand, builds a static `aarch64-unknown-linux-musl` Vaultwarden binary from the upstream
release tag, and publishes it with `SHA256SUMS` and a build-provenance attestation under a
`vaultwarden/<version>` tag. That attestation is what `vw_download_release()` verifies on the
host — see `vaultwarden-service.md`.

## Dependabot

Four ecosystems are declared in `.gt-repo.yaml` and rendered into `.github/dependabot.yml`:

- **docker** at `/services/vaultwarden/test` — the Debian base image of the end-to-end test
  container. This only works because the file is named `Dockerfile`; Dependabot's docker
  ecosystem does not discover a `Containerfile`.
- **github-actions** at `/`.
- **pip** at `/` — pytest and friends, pinned via `pyproject.toml` / `uv.lock`.

There is deliberately no `gitsubmodule` entry: the bats helper libraries were never vendored
as submodules, so the unit tests use plain `bats-core`.

`astral-sh/setup-uv` is pinned to an exact version in `ci-end2end.yml` because it publishes
no floating major tag — `@v10` does not resolve. `checkout`, `cache` and `attest` do publish
them and are pinned to the major.

## Upgrading gt

`gt repo check` warns when the rendered files were produced by an older gt than the one you
are running (`rendered by gt X — sync to re-render with current policy`). Run `gt repo sync`,
commit the re-render, and land it before running `gt repo settings apply` — the settings step
deliberately withholds rules that depend on triggers not yet live on the default branch.
