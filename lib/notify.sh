#!/usr/bin/env bash
# The notify seam.
#
# Every script reaches the operator through notify() and never talks to a
# notification provider directly, so swapping backends is a config change.
# wardnet's admin app is the intended default (see docs/INGRESS.md).
#
# Backends, in precedence order:
#   BOMA_NOTIFY_CMD  — command invoked as: <cmd> <severity> <subject> <body>
#   BOMA_NOTIFY_URL  — webhook receiving a JSON POST
#   (neither)        — log only
#
# Contract: notify() NEVER fails the calling script. A backup that succeeded but
# could not be announced has still succeeded, and a failure handler that dies
# while reporting a failure loses the original error.

[[ -n "${_BOMA_NOTIFY_SH:-}" ]] && return 0
_BOMA_NOTIFY_SH=1

# shellcheck source=lib/log.sh
. "${BOMA_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/log.sh"

BOMA_NOTIFY_CMD="${BOMA_NOTIFY_CMD:-}"
BOMA_NOTIFY_URL="${BOMA_NOTIFY_URL:-}"
BOMA_NOTIFY_TIMEOUT="${BOMA_NOTIFY_TIMEOUT:-10}"
BOMA_HOSTNAME="${BOMA_HOSTNAME:-$(hostname 2>/dev/null || printf 'unknown')}"

# _boma_json_escape <string> — minimal JSON string escaping.
# Avoids a jq dependency on the host for what is only ever short status text.
_boma_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# notify <severity> <subject> [body]
#   severity: info | warn | error
notify() {
    local severity="$1" subject="$2" body="${3:-}"

    case "$severity" in
        info)  log_info  "notify: $subject${body:+ — $body}" ;;
        warn)  log_warn  "notify: $subject${body:+ — $body}" ;;
        error) log_error "notify: $subject${body:+ — $body}" ;;
        *)     log_warn  "notify: unknown severity '$severity' for: $subject"
               severity=info ;;
    esac

    if [[ -n "$BOMA_NOTIFY_CMD" ]]; then
        if ! "$BOMA_NOTIFY_CMD" "$severity" "$subject" "$body" >/dev/null 2>&1; then
            log_warn "notify backend command failed: $BOMA_NOTIFY_CMD"
        fi
        return 0
    fi

    if [[ -n "$BOMA_NOTIFY_URL" ]]; then
        if ! command -v curl >/dev/null 2>&1; then
            log_warn "BOMA_NOTIFY_URL is set but curl is not installed"
            return 0
        fi
        local payload
        payload=$(printf '{"host":"%s","severity":"%s","subject":"%s","body":"%s"}' \
            "$(_boma_json_escape "$BOMA_HOSTNAME")" \
            "$(_boma_json_escape "$severity")" \
            "$(_boma_json_escape "$subject")" \
            "$(_boma_json_escape "$body")")
        if ! curl -fsS -m "$BOMA_NOTIFY_TIMEOUT" \
                -H 'Content-Type: application/json' \
                -d "$payload" "$BOMA_NOTIFY_URL" >/dev/null 2>&1; then
            log_warn "notify webhook failed: $BOMA_NOTIFY_URL"
        fi
        return 0
    fi

    log_debug "no notify backend configured; logged only"
    return 0
}

# heartbeat <component> — signal "this ran and succeeded".
#
# Distinct from a success notification: wardnet is expected to alert on a
# MISSING heartbeat. Only an off-host watcher can tell a dead Pi or a timer that
# never fired apart from silence — the host cannot report its own death.
heartbeat() {
    local component="$1"
    if [[ -z "${BOMA_HEARTBEAT_URL:-}" ]]; then
        log_debug "no heartbeat URL configured; skipping heartbeat for $component"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        log_warn "BOMA_HEARTBEAT_URL is set but curl is not installed"
        return 0
    fi
    if ! curl -fsS -m "$BOMA_NOTIFY_TIMEOUT" \
            "${BOMA_HEARTBEAT_URL%/}/${component}" >/dev/null 2>&1; then
        log_warn "heartbeat failed for $component"
    fi
    return 0
}
