# Test host for the vaultwarden service scripts.
#
# Deliberately named `Dockerfile`, not `Containerfile`: Dependabot's docker
# ecosystem only discovers files matching `Dockerfile*`, so a `Containerfile`
# would leave this base image untracked for security updates. podman reads
# either name.
#
# Debian trixie on arm64 matches the Raspberry Pi OS target closely enough that
# the statically-linked release artifact is byte-identical in both places.
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus \
        ca-certificates curl \
        sqlite3 restic jq argon2 openssl \
        procps iproute2 \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Units that are meaningless inside a container and only add noise/failures.
RUN find /etc/systemd/system /lib/systemd/system \
        -path '*.wants/*' \
        \( -name '*getty*' -o -name '*udev*' -o -name '*mount*' \
           -o -name '*swap*' -o -name '*journald-audit*' \) \
        -delete

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
