#!/usr/bin/env bash
# Platform assertions.
#
# These scripts create system users, write to /etc, install systemd units and
# manage a password vault. Running them on an unintended host is not a harmless
# no-op, so preflight fails closed: an unrecognised platform is an error.
#
# See PLATFORM.md for the supported target.

[[ -n "${_BOMA_PREFLIGHT_SH:-}" ]] && return 0
_BOMA_PREFLIGHT_SH=1

# shellcheck source=lib/log.sh
. "${BOMA_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/log.sh"

BOMA_SUPPORTED_ARCH="${BOMA_SUPPORTED_ARCH:-aarch64 arm64}"
BOMA_SUPPORTED_DEBIAN="${BOMA_SUPPORTED_DEBIAN:-bookworm trixie}"
BOMA_MIN_SYSTEMD="${BOMA_MIN_SYSTEMD:-252}"

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "must run as root (try: sudo $0 ...)"
    fi
}

# require_cmd <command> [package-hint]
require_cmd() {
    local cmd="$1" hint="${2:-$1}"
    command -v "$cmd" >/dev/null 2>&1 \
        || die "required command '$cmd' not found (install it: apt-get install -y $hint)"
}

require_arch() {
    local arch; arch=$(uname -m)
    local supported
    for supported in $BOMA_SUPPORTED_ARCH; do
        [[ "$arch" == "$supported" ]] && return 0
    done
    die "unsupported architecture '$arch'; boma targets: $BOMA_SUPPORTED_ARCH (see PLATFORM.md)"
}

require_systemd() {
    command -v systemctl >/dev/null 2>&1 || die "systemd not found; boma manages services as systemd units"

    local ver
    # `systemctl --version` prints e.g. "systemd 257 (257.5-2)" on line 1.
    ver=$(systemctl --version 2>/dev/null | awk 'NR==1 {print $2}')
    ver="${ver%%[!0-9]*}"
    if [[ -z "$ver" ]]; then
        log_warn "could not determine systemd version; continuing"
        return 0
    fi
    if (( 10#$ver < BOMA_MIN_SYSTEMD )); then
        die "systemd $ver is older than the required $BOMA_MIN_SYSTEMD"
    fi
}

require_debian() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not readable; cannot identify the OS"

    local id="" version_codename="" id_like=""
    # shellcheck disable=SC1091  # runtime file, not present at lint time
    . /etc/os-release
    id="${ID:-}"; version_codename="${VERSION_CODENAME:-}"; id_like="${ID_LIKE:-}"

    if [[ "$id" != "debian" && "$id" != "raspbian" && "$id_like" != *debian* ]]; then
        die "unsupported OS '$id'; boma targets Debian / Raspberry Pi OS (see PLATFORM.md)"
    fi

    local supported
    for supported in $BOMA_SUPPORTED_DEBIAN; do
        [[ "$version_codename" == "$supported" ]] && return 0
    done
    die "unsupported Debian release '${version_codename:-unknown}'; supported: $BOMA_SUPPORTED_DEBIAN"
}

# preflight_host — the full platform assertion used by every service script.
#
# BOMA_SKIP_PREFLIGHT=1 bypasses it for the test harness, which runs these same
# scripts inside a Debian container that is deliberately not a Raspberry Pi.
# It is loud about being set so it cannot be left on by accident on a real host.
preflight_host() {
    if [[ "${BOMA_SKIP_PREFLIGHT:-0}" == "1" ]]; then
        log_warn "BOMA_SKIP_PREFLIGHT=1 — platform checks bypassed (expected only in tests)"
        return 0
    fi
    require_root
    require_arch
    require_debian
    require_systemd
    log_debug "preflight passed"
}
