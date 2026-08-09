#!/usr/bin/env bash
#
# Restore drill: prove the backups actually restore.
#
# `restic check` verifies repository structure. It does NOT prove a snapshot
# restores to a working database — only restoring it does. An unverified backup
# is a guess.
#
# Monthly and automatic with the host's password (boma-vw-verify.timer), and
# quarterly by hand with a human-held passphrase:
#
#     verify-backup.sh --password-stdin
#
# The manual run is the only thing that catches a transcription error made when
# the recovery passphrase was saved — a single wrong character stays invisible
# until the moment it is needed.

set -euo pipefail

# shellcheck source=services/vaultwarden/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SNAPSHOT="latest"
PASSWORD_STDIN=0
KEEP=0

usage() {
    cat <<'EOF'
Usage: verify-backup.sh [options]

  --snapshot <id>     Snapshot to verify (default: latest)
  --password-stdin    Read the restic password from stdin. Use this with the
                      recovery or family passphrase for the manual drill.
  --keep              Do not delete the restored copy (for inspection).
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --snapshot)       SNAPSHOT="$2"; shift 2 ;;
        --password-stdin) PASSWORD_STDIN=1; shift ;;
        --keep)           KEEP=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage >&2; die "unknown argument: $1" ;;
    esac
done

# Armed BEFORE preflight and config loading: helpers call die(), and a missing
# or unreadable restic.env used to exit before any trap existed, so a drill that
# never even started reported nothing at all.
# notify() reads BOMA_NOTIFY_URL, which only has a value once boma.env has been
# parsed. Arming the trap before that would produce a trap that fires but has
# nowhere to send anything, so the config is loaded first (best-effort: a
# missing config must not stop the script from reaching its own error handling).
# Only the notify URL is extracted here, with grep rather than load_config.
# load_config fails closed on a malformed file, and running it before the trap
# is armed meant a hand-edited boma.env killed the nightly run with no
# notification at all — the exact silent failure the trap exists to prevent.
# The authoritative, validating load happens after the trap is in place.
if [[ -r "$VW_BOMA_ENV" ]]; then
    # `|| true` matters: with no BOMA_NOTIFY_URL line, grep exits 1 and, under
    # `set -o pipefail`, that would abort the whole script here — silently, and
    # before the trap exists to report it.
    _notify_line="$(grep -E '^[[:space:]]*BOMA_NOTIFY_URL=' "$VW_BOMA_ENV" 2>/dev/null | tail -1 || true)"
    if [[ -n "$_notify_line" ]]; then
        _notify_url="${_notify_line#*=}"
        _notify_url="${_notify_url%\'}"; _notify_url="${_notify_url#\'}"
        _notify_url="${_notify_url%\"}"; _notify_url="${_notify_url#\"}"
        export BOMA_NOTIFY_URL="$_notify_url"
    fi
fi

DRILL_COMPLETED=0
SCRATCH=""
on_exit() {
    local rc=$?
    if [[ -n "$SCRATCH" ]]; then
        if [[ "$KEEP" -eq 1 ]]; then
            log_info "restored copy kept at ${SCRATCH}"
        else
            rm -rf "$SCRATCH"
        fi
    fi
    if (( rc != 0 )) && (( DRILL_COMPLETED == 0 )); then
        notify error "Vaultwarden restore drill FAILED" \
            "verify-backup.sh exited ${rc} on $(hostname); the backups may not be restorable"
    fi
    return $rc
}
# TERM and INT as well as EXIT: bash's default SIGTERM disposition terminates
# without running the EXIT trap, so a systemd timeout would otherwise skip the
# failure notification entirely.
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

fail() {
    die "$1"
}

preflight_host
vw_require_tools
vw_load_config

if [[ "$PASSWORD_STDIN" -eq 1 ]]; then
    IFS= read -r -s RESTIC_PASSWORD || die "could not read a password from stdin"
    [[ -n "$RESTIC_PASSWORD" ]] || die "empty password supplied on stdin"
    export RESTIC_PASSWORD
    log_info "using a passphrase supplied on stdin"
fi
vw_restic_env

ensure_dir "${VW_SCRATCH_BASE:-/var/lib/boma/scratch}" 0700 "root:root"

# Restored into a DISK-backed directory, not mktemp's /tmp.
#
# On the supported Debian trixie target /tmp is a tmpfs sized by RAM, and under
# systemd PrivateTmp it is a private tmpfs too. Restoring a full vault there
# consumes memory rather than disk and can exhaust a 4 GB Pi as attachments grow.
SCRATCH="$(mktemp -d "${VW_SCRATCH_BASE:-/var/lib/boma/scratch}/verify.XXXXXX")"
chmod 0700 "$SCRATCH"

# Which snapshot is this drill about, and how old is it?
#
# Verifying "the latest snapshot restores" says nothing if backups stopped
# months ago: the drill would keep passing on a stale snapshot and keep sending
# heartbeats, so a later host loss would recover a months-old vault with every
# credential added since simply gone.
# The full timestamp is passed through unmodified. Truncating it to 19
# characters and appending "Z" discarded restic's UTC offset, reinterpreting a
# local-time stamp as UTC — which skews the age by the offset and, on a host
# ahead of UTC, could make a stale snapshot look fresh.
# Freshness is judged on the SCHEDULED series specifically.
#
# A bare `latest` spans all tags, so a `pre-update` snapshot written by
# update.sh satisfies the check that exists to detect a dead nightly timer —
# re-opening the exact hole backup.sh's --quiet-report was added to close.
_age_args=("$SNAPSHOT")
[[ "$SNAPSHOT" == "latest" ]] && _age_args=(latest --tag "${VW_DRILL_TAG:-scheduled}")
SNAP_TIME_RAW=$(restic snapshots "${_age_args[@]}" --json 2>/dev/null | jq -r '.[-1].time // empty' || true)
# Resolve to a concrete id so the restore below cannot pick a different one.
SNAP_TARGET=$(restic snapshots "${_age_args[@]}" --json 2>/dev/null | jq -r '.[-1].short_id // empty' || true)
[[ -n "$SNAP_TARGET" ]] || SNAP_TARGET="$SNAPSHOT"
if [[ -z "$SNAP_TIME_RAW" && "$SNAPSHOT" == "latest" ]]; then
    fail "no '${VW_DRILL_TAG:-scheduled}' snapshot exists — the nightly backup timer has never produced one"
fi
SNAP_AGE_DAYS=""
if [[ -n "$SNAP_TIME_RAW" ]]; then
    SNAP_AGE_DAYS=$(age_days "$SNAP_TIME_RAW" 2>/dev/null || printf '')
fi
# An age that cannot be determined is a failure, not a pass. Skipping the check
# when the pipeline yielded nothing meant the drill still reported green.
[[ -n "$SNAP_AGE_DAYS" ]] \
    || fail "could not determine the age of snapshot ${SNAPSHOT}; refusing to report the drill as passing"
if (( SNAP_AGE_DAYS > ${VW_MAX_SNAPSHOT_AGE_DAYS:-7} )); then
    fail "the newest snapshot is ${SNAP_AGE_DAYS} days old (limit ${VW_MAX_SNAPSHOT_AGE_DAYS:-7}) — backups have stopped"
fi


log_info "restore drill starting (snapshot: ${SNAP_TARGET})"

# The snapshot that is age-checked is the one that gets restored.
#
# Restoring a bare `latest` while ageing `latest --tag scheduled` meant the
# drill could prove a pre-update snapshot restorable while reporting on the
# scheduled series — so a nightly chain producing broken snapshots would still
# be reported as verified.
restic restore "$SNAP_TARGET" --target "$SCRATCH" \
    || fail "could not restore snapshot ${SNAP_TARGET}"

DB=$(find "$SCRATCH" -name 'db.sqlite3' -print -quit)
[[ -n "$DB" ]] || fail "snapshot ${SNAP_TARGET} contains no db.sqlite3"

# 1. Does the database open and is it structurally sound?
integrity=$(sqlite3 "$DB" 'PRAGMA integrity_check;' 2>&1) \
    || fail "restored database could not be opened"
[[ "$integrity" == "ok" ]] || fail "restored database failed integrity check: ${integrity}"

# 2. Does it contain the tables Vaultwarden needs? A structurally valid but
#    empty database would pass the check above while being useless.
for table in users ciphers organizations devices; do
    if ! sqlite3 "$DB" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name='${table}';" \
        | grep -q "$table"; then
        fail "restored database is missing the '${table}' table"
    fi
done

USERS=$(sqlite3 "$DB" 'SELECT COUNT(*) FROM users;' 2>/dev/null || printf '0')
CIPHERS=$(sqlite3 "$DB" 'SELECT COUNT(*) FROM ciphers;' 2>/dev/null || printf '0')

# 3. Sanity-check the contents. A vault with zero users restored "successfully"
#    is a backup of nothing, and would otherwise be reported as a pass.
if [[ "$USERS" -eq 0 ]]; then
    fail "restored database has 0 users — the backup is empty"
fi

# 4. Compare against the live vault. "Non-empty" is a weak bar: a snapshot that
#    lost most of its rows but kept one would pass every check above. The live
#    database is the only reference for what the backup should contain.
if [[ -r "$(vw_sqlite_path)" ]]; then
    LIVE_USERS=$(sqlite3 "$(vw_sqlite_path)" 'SELECT COUNT(*) FROM users;' 2>/dev/null || printf '0')
    LIVE_CIPHERS=$(sqlite3 "$(vw_sqlite_path)" 'SELECT COUNT(*) FROM ciphers;' 2>/dev/null || printf '0')
    # A snapshot legitimately lags the live vault: a family member invited after
    # the snapshot was taken means fewer users in it, and that is correct
    # behaviour, not a bad backup. Failing on any shortfall made the monthly
    # drill cry wolf after every invitation — training the operator to ignore
    # the one alert that proves the backups work.
    #
    # So only a LARGE shortfall counts: losing more than half the users or items
    # is data loss, not lag.
    if [[ "$LIVE_USERS" -gt 0 && $(( USERS * 2 )) -lt "$LIVE_USERS" ]]; then
        fail "restored snapshot has ${USERS} users but the live vault has ${LIVE_USERS} — the backup is incomplete"
    fi
    if [[ "$LIVE_CIPHERS" -gt 10 && $(( CIPHERS * 2 )) -lt "$LIVE_CIPHERS" ]]; then
        fail "restored snapshot has ${CIPHERS} items but the live vault has ${LIVE_CIPHERS} — the backup looks truncated"
    fi
    if [[ "$USERS" -lt "$LIVE_USERS" ]]; then
        log_info "snapshot has ${USERS} users, live vault has ${LIVE_USERS} (expected: the snapshot predates recent invitations)"
    fi
fi

# 5. The JWT signing key must be in the snapshot. Restoring without it
#    invalidates every client session and push registration, turning a restore
#    into a forced re-login for the whole family.
if ! find "$SCRATCH" -name '*rsa_key*' -print -quit | grep -q .; then
    fail "snapshot ${SNAP_TARGET} contains no RSA key: a restore would sign every family member out"
fi

DRILL_COMPLETED=1
log_info "restore drill passed: ${USERS} users, ${CIPHERS} items"
heartbeat vaultwarden-verify
notify info "Vaultwarden restore drill ok" \
    "snapshot ${SNAP_TARGET}: ${USERS} users, ${CIPHERS} items on $(hostname)"
