#!/usr/bin/env bash
# Structured logging for boma scripts.
#
# Output goes to stderr so that a script's stdout stays clean for real data
# (snapshot ids, versions) and remains pipeable.
#
# When running under systemd, journald captures stderr and applies the syslog
# priority prefixes emitted below, so `journalctl -p warning` filters correctly.

# Guard against double-sourcing: these are idempotent, but re-sourcing would
# reset BOMA_LOG_LEVEL if a caller had overridden it.
[[ -n "${_BOMA_LOG_SH:-}" ]] && return 0
_BOMA_LOG_SH=1

# debug | info | warn | error
BOMA_LOG_LEVEL="${BOMA_LOG_LEVEL:-info}"

# Colour only when stderr is a terminal; journald and CI logs get plain text.
if [[ -t 2 ]]; then
    _BOMA_C_RED=$'\033[31m'; _BOMA_C_YEL=$'\033[33m'
    _BOMA_C_BLU=$'\033[34m'; _BOMA_C_DIM=$'\033[2m'; _BOMA_C_OFF=$'\033[0m'
else
    _BOMA_C_RED=''; _BOMA_C_YEL=''; _BOMA_C_BLU=''; _BOMA_C_DIM=''; _BOMA_C_OFF=''
fi

_boma_log_level_num() {
    case "$1" in
        debug) printf '10' ;;
        info)  printf '20' ;;
        warn)  printf '30' ;;
        error) printf '40' ;;
        *)     printf '20' ;;
    esac
}

# _boma_log <level> <syslog-priority> <colour> <message...>
_boma_log() {
    local level="$1" prio="$2" colour="$3"; shift 3
    local want cur
    want=$(_boma_log_level_num "$level")
    cur=$(_boma_log_level_num "$BOMA_LOG_LEVEL")
    (( want < cur )) && return 0

    # The <N> prefix is journald's syslog priority convention; harmless elsewhere.
    printf '<%s>%s%-5s%s %s\n' \
        "$prio" "$colour" "$level" "$_BOMA_C_OFF" "$*" >&2
}

log_debug() { _boma_log debug 7 "$_BOMA_C_DIM" "$@"; }
log_info()  { _boma_log info  6 "$_BOMA_C_BLU" "$@"; }
log_warn()  { _boma_log warn  4 "$_BOMA_C_YEL" "$@"; }
log_error() { _boma_log error 3 "$_BOMA_C_RED" "$@"; }

# die <message...> — log at error level and exit non-zero.
die() {
    log_error "$@"
    exit 1
}
