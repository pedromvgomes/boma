#!/usr/bin/env bash
# Version comparison and release-age arithmetic.
#
# Implemented in pure bash rather than `sort -V` so the same code runs
# identically on the Pi and on macOS, where BSD sort's -V support varies.

[[ -n "${_BOMA_VERSION_SH:-}" ]] && return 0
_BOMA_VERSION_SH=1

# version_normalise <version> — strip a leading "v" and any "vaultwarden/" prefix.
version_normalise() {
    local v="$1"
    v="${v#vaultwarden/}"
    v="${v#v}"
    printf '%s' "$v"
}

# version_compare <a> <b> — echoes -1 if a<b, 0 if a==b, 1 if a>b.
#
# Compares dot-separated numeric components. Missing components count as 0, so
# "1.37" == "1.37.0". Non-numeric suffixes on a component (e.g. "1.37.1-rc1")
# are ignored for ordering, which is sufficient because we only ever compare
# upstream stable releases.
version_compare() {
    local a b
    a=$(version_normalise "$1")
    b=$(version_normalise "$2")

    local -a pa pb
    IFS='.' read -r -a pa <<<"$a"
    IFS='.' read -r -a pb <<<"$b"

    local len=${#pa[@]}
    (( ${#pb[@]} > len )) && len=${#pb[@]}

    local i x y
    for (( i = 0; i < len; i++ )); do
        x="${pa[i]:-0}"; y="${pb[i]:-0}"
        # Keep leading digits only, and force base 10 so "08" is not read as octal.
        x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
        x=$((10#${x:-0}));  y=$((10#${y:-0}))
        if   (( x < y )); then printf '%s' -1; return 0
        elif (( x > y )); then printf '%s' 1;  return 0
        fi
    done
    printf '%s' 0
}

# version_gt <a> <b> — true when a is strictly newer than b.
version_gt() {
    [[ "$(version_compare "$1" "$2")" == "1" ]]
}

# iso8601_to_epoch <timestamp> — convert e.g. 2026-08-01T12:00:00Z to epoch seconds.
#
# GNU date and BSD date have incompatible parsing flags, and this runs on both
# (the Pi, and macOS under bats), so try each.
iso8601_to_epoch() {
    local ts="$1" out
    if out=$(date -u -d "$ts" +%s 2>/dev/null); then
        printf '%s' "$out"; return 0
    fi
    if out=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null); then
        printf '%s' "$out"; return 0
    fi
    return 1
}

# age_days <iso8601-timestamp> [now-epoch] — whole days elapsed since the timestamp.
#
# `now` is injectable so tests do not depend on the wall clock. Timestamps in the
# future yield 0 rather than a negative age, so clock skew can never make a
# release look old enough to install.
age_days() {
    local ts="$1" now="${2:-}" published delta
    published=$(iso8601_to_epoch "$ts") || return 1
    [[ -z "$now" ]] && now=$(date -u +%s)
    delta=$(( now - published ))
    (( delta < 0 )) && delta=0
    printf '%s' $(( delta / 86400 ))
}

# soak_satisfied <iso8601-timestamp> <soak-days> [now-epoch]
# True when a release has been published long enough to install unattended.
soak_satisfied() {
    local ts="$1" soak="$2" now="${3:-}" age
    age=$(age_days "$ts" "$now") || return 1
    (( age >= soak ))
}
