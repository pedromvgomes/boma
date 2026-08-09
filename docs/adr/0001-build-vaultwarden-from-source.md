# Build Vaultwarden from source in CI, rather than using upstream binaries

Vaultwarden publishes **no** prebuilt server binaries — releases carry source only, and the
sole distributed artifact is a Docker image. Since boma runs bare metal with no container
runtime, the binary has to come from somewhere. We build it ourselves in GitHub Actions from
the upstream release tag, targeting `aarch64-unknown-linux-musl` with `--features sqlite`, and
publish it to this repository's releases under `vaultwarden/<version>` tags.

## Considered options

**Extracting the binary from the official OCI image** (via `skopeo`, no Docker daemon) was the
initial preference: it is the exact artifact most users run, so it is the best-tested one. It
was rejected because the official image is Debian-based and dynamically linked, which couples
the binary to the host's glibc — a Raspberry Pi OS major upgrade could break the vault. It also
depends on the image's internal layout staying stable.

**Compiling on the Pi** was rejected because a 30–90 minute build at 100% CPU with OOM risk on
a 4 GB Pi makes every unattended update a long-running job that can fail overnight.

## Why this is affordable

Free, unlimited `ubuntu-24.04-arm` runners on public repositories mean a **native** arm64
build with no cross-compilation or QEMU. Upstream's own `Dockerfile.alpine` already builds
`aarch64-musl`, so a static musl binary is a configuration upstream supports and tests — not
one we invented.

## Consequences

- The binary is **statically linked**, so a host OS upgrade cannot break it. This is the main
  benefit and the reason the trade was worth making.
- We build with `sqlite` only, rather than the official image's `sqlite,mysql,postgresql`.
- **We now own a build pipeline that will break** on Rust or dependency churn, and it breaks
  *silently* — the Pi keeps running the last good binary. The workflow must therefore alert on
  failure; a green-checkmark-only signal is insufficient.
