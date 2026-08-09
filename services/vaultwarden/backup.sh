#!/usr/bin/env bash
#
# Back up the Vaultwarden vault to the restic repository.
#
# Run nightly by boma-vw-backup.timer, and synchronously by update.sh before it
# touches anything (see docs/adr/0004-soak-then-unattended-updates.md).

set -euo pipefail

# shellcheck source=services/vaultwarden/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

BACKUP_TAG="scheduled"
QUIET=0
# Resolved after vw_load_config, not here: reading it at this point would ignore
# whatever boma.env sets.
NO_PRUNE=""

usage() {
    cat <<'EOF'
Usage: backup.sh [options]

  --tag <tag>     Tag applied to the snapshot (default: scheduled).
                  update.sh uses "pre-update" so its snapshots are findable.
  --quiet         Suppress progress output.
  --no-prune      Forget old snapshots but never delete data from the
                  repository. Required when the bucket has an R2 bucket lock:
                  immutability makes prune fail, which would fail the backup.
                  Also settable as VW_NO_PRUNE=1 in boma.env.
  --quiet-report  Do not send the success notification or heartbeat. Used by
                  update.sh for its pre-update snapshot, whose success must not
                  be indistinguishable from the nightly run — otherwise a dead
                  nightly timer stays hidden behind the update's heartbeat.
  --staging <dir> Directory the snapshot is assembled in. Must be STABLE across
                  runs, or restic groups every snapshot separately and
                  retention never expires anything.
  -h, --help
EOF
}

STAGING_OVERRIDE=""
QUIET_REPORT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)      BACKUP_TAG="$2"; shift 2 ;;
        --quiet)    QUIET=1; shift ;;
        --no-prune) NO_PRUNE=1; shift ;;
        --quiet-report) QUIET_REPORT=1; shift ;;
        --staging)  STAGING_OVERRIDE="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *)          usage >&2; die "unknown argument: $1" ;;
    esac
done

# Notification is driven by an EXIT trap, not by `|| fail` at each call site.
#
# Helpers in lib.sh call die(), which exits immediately, so a trailing
# `|| fail "..."` on such a call is dead code — the most likely backup failure
# (an unreadable or corrupt database) exited without ever notifying anyone. A
# trap catches every path, including ones added later.
#
# Armed BEFORE preflight, tool checks and config loading: a missing or
# unreadable restic.env used to exit before the trap existed, so the nightly
# unit failed silently night after night.
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

BACKUP_COMPLETED=0
STAGING=""
on_exit() {
    local rc=$?
    [[ -n "$STAGING" ]] && rm -rf "$STAGING"
    if (( rc != 0 )) && (( BACKUP_COMPLETED == 0 )); then
        notify error "Vaultwarden backup FAILED" \
            "backup.sh exited ${rc} on $(hostname); see: journalctl -u boma-vw-backup.service"
    fi
    return $rc
}
# TERM and INT as well as EXIT: bash's default SIGTERM disposition terminates
# without running the EXIT trap, so a systemd timeout would otherwise skip the
# failure notification entirely.
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# fail <msg> — annotate a known failure. The EXIT trap still sends the alert.
fail() {
    die "$1"
}

preflight_host
vw_require_tools
vw_load_config
# Only now is boma.env in scope, so config-backed settings become readable.
NO_PRUNE="${NO_PRUNE:-${VW_NO_PRUNE:-0}}"
vw_restic_env

# A FIXED staging path, not mktemp -d.
#
# restic records the backed-up path in each snapshot and its default
# `--group-by host,paths` then groups by it. With a random /tmp path per run,
# every snapshot lands in a group of one, so `forget --keep-daily 7` keeps all
# of them forever and retention silently never expires anything. A stable path
# also lets restic find the parent snapshot, making each backup incremental
# instead of a full re-scan.
STAGING_PATH="${STAGING_OVERRIDE:-${VW_STAGING_DIR:-/var/lib/boma/staging/vaultwarden}}"

# Serialise concurrent backups.
#
# update.sh runs backup.sh itself, and after downtime both Persistent=true
# timers fire at boot, so the nightly backup and the pre-update backup can
# overlap on the fixed staging path above.
#
# The lock lives NEXT TO the staging directory, not in /var/lock: under
# ProtectSystem=strict only the data, staging and scratch directories are
# writable, so /var/lock is read-only and opening it there failed EVERY
# systemd-driven backup before it staged anything.
LOCK_DIR="$(dirname "$STAGING_PATH")"
ensure_dir_if_missing "$LOCK_DIR" 0700 "root:root"
LOCKFILE="${VW_BACKUP_LOCK:-${LOCK_DIR}/.vaultwarden-backup.lock}"
exec 9>"$LOCKFILE" || fail "could not open the backup lock at ${LOCKFILE}"
if ! flock -w "${VW_BACKUP_LOCK_WAIT:-3600}" 9; then
    fail "another backup is still running (lock: ${LOCKFILE})"
fi

# STAGING is only set AFTER the lock is held. The EXIT trap removes $STAGING,
# so assigning it before acquiring the lock meant a lock-TIMEOUT run deleted the
# staging directory of the backup that actually held the lock — corrupting the
# snapshot the serialisation existed to protect.
STAGING="$STAGING_PATH"
rm -rf "$STAGING"
ensure_dir "$STAGING" 0700 "root:root"


log_info "starting backup (tag: ${BACKUP_TAG})"

# ---------------------------------------------------------------------------
# Stage a consistent copy of everything that matters
# ---------------------------------------------------------------------------
# The database is snapshotted through SQLite's backup API rather than copied,
# because a live WAL database spans three files that a plain copy can capture at
# different instants — producing a backup that restores to a corrupt database.
vw_snapshot_sqlite "${STAGING}/db.sqlite3" || fail "sqlite snapshot failed"

# Everything else is ordinary files. rsa_key* holds the JWT signing key: without
# it every client session and every push registration is invalidated on restore.
for item in attachments sends config.json rsa_key.pem rsa_key.pub.pem \
            private_rsa_key.pem private_rsa_key.der public_rsa_key.der; do
    src="${VW_DATA_DIR}/${item}"
    if [[ -e "$src" ]]; then
        cp -a "$src" "${STAGING}/" || fail "could not stage ${item}"
    fi
done

# Configuration is included so a restore does not depend on remembering flags.
# The restic credentials file is deliberately NOT included: storing the key to
# the backups inside the backups would be circular.
if [[ -r "$VW_APP_ENV" ]]; then
    mkdir -p "${STAGING}/config"
    cp -a "$VW_APP_ENV" "${STAGING}/config/vaultwarden.env" || fail "could not stage vaultwarden.env"
    if [[ -r "$VW_BOMA_ENV" ]]; then
        cp -a "$VW_BOMA_ENV" "${STAGING}/config/boma.env" || fail "could not stage boma.env"
    fi
fi

# An empty stamp would silently disable restore.sh's forward-migration guard
# for this snapshot, so a missing version file is a hard failure.
_installed="$(vw_installed_version)"
[[ -n "$_installed" ]] || fail "no installed version recorded; refusing to write a snapshot with no version stamp"
printf '%s\n' "$_installed" > "${STAGING}/installed-version"

# ---------------------------------------------------------------------------
# Send it to restic
# ---------------------------------------------------------------------------
restic_opts=(--tag "$BACKUP_TAG" --tag vaultwarden --host "$(hostname)")
[[ "$QUIET" -eq 1 ]] && restic_opts+=(--quiet)

restic backup "${restic_opts[@]}" "$STAGING" \
    || fail "restic backup failed"

# `--prune` is what actually reclaims space, and it is also what an R2 bucket
# lock forbids. With immutability enabled, prune fails and would fail the whole
# backup, so retention is applied to snapshot metadata only and the repository
# grows. See docs/adr/0002-three-restic-repository-passwords.md.
# `--group-by host,tags` rather than restic's default `host,paths`: retention
# should apply across the whole backup history for this host, and grouping by
# tags keeps the `scheduled` and `pre-update` series expiring independently.
# shellcheck disable=SC2054  # "host,tags" is one restic argument, not two elements
forget_opts=(--tag vaultwarden --group-by "host,tags")

if [[ "$NO_PRUNE" == "1" ]]; then
    log_info "forgetting old snapshots (prune disabled: bucket is immutable)"
    # shellcheck disable=SC2086  # VW_RETENTION is a deliberate word-split flag list
    restic forget "${forget_opts[@]}" $VW_RETENTION \
        || fail "restic forget failed"
else
    log_info "pruning old snapshots"
    # shellcheck disable=SC2086  # VW_RETENTION is a deliberate word-split flag list
    restic forget "${forget_opts[@]}" --prune $VW_RETENTION \
        || fail "restic forget/prune failed"
fi

# `check` verifies repository structure and metadata integrity. It is not a
# restore test — that is verify-backup.sh's job, monthly.
log_info "checking repository integrity"
restic check || fail "restic check reported repository problems"

SNAPSHOT_ID=$(restic snapshots --tag "$BACKUP_TAG" --latest 1 --json 2>/dev/null \
    | jq -r '.[0].short_id // empty' 2>/dev/null || printf '')

BACKUP_COMPLETED=1
log_info "backup complete${SNAPSHOT_ID:+ (snapshot ${SNAPSHOT_ID})}"
if [[ "$QUIET_REPORT" -eq 1 ]]; then
    log_debug "success reporting suppressed (--quiet-report)"
else
    heartbeat vaultwarden-backup
    notify info "Vaultwarden backup ok" "snapshot ${SNAPSHOT_ID:-unknown} on $(hostname)"
fi
