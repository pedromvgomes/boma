#!/usr/bin/env bash
#
# Restore the Vaultwarden vault from a restic snapshot.
#
# Used both for disaster recovery (docs/RECOVERY.md) and by update.sh to roll
# back a failed update.

set -euo pipefail

# shellcheck source=services/vaultwarden/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SNAPSHOT="latest"
TARGET=""
DRY_RUN=0
PASSWORD_STDIN=0
FORCE=0
ALLOW_VERSION_MISMATCH=0

usage() {
    cat <<'EOF'
Usage: restore.sh [options]

  --snapshot <id>     Snapshot to restore (default: latest)
  --target <dir>      Restore into this directory instead of the live service.
                      Nothing is stopped and no live data is touched.
  --dry-run           Show what would happen, change nothing.
  --password-stdin    Read the restic password from stdin instead of the host's
                      password file. Use with the recovery or family passphrase.
  --force             Skip the confirmation prompt (for automation).
  --allow-version-mismatch
                      Restore a snapshot taken by a NEWER Vaultwarden than the
                      one installed. Deliberately separate from --force:
                      automation needs --force to run without a tty, and that
                      must not silently disable a schema-compatibility check.
  -h, --help

Restoring into the live service STOPS vaultwarden, replaces its data directory,
and starts it again. The existing data directory is kept as a timestamped
sibling so a mistaken restore is itself reversible.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --snapshot)       SNAPSHOT="$2"; shift 2 ;;
        --target)         TARGET="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --password-stdin) PASSWORD_STDIN=1; shift ;;
        --force)          FORCE=1; shift ;;
        --allow-version-mismatch) ALLOW_VERSION_MISMATCH=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage >&2; die "unknown argument: $1" ;;
    esac
done

# Only the notify URL is extracted here, with grep rather than load_config.
# load_config fails closed on a malformed file, and running it before the trap
# is armed meant a hand-edited boma.env aborted the disaster-recovery flow with
# no notification at all. The validating load happens after the trap.
if [[ -r "$VW_BOMA_ENV" ]]; then
    _notify_line="$(grep -E '^[[:space:]]*BOMA_NOTIFY_URL=' "$VW_BOMA_ENV" 2>/dev/null | tail -1 || true)"
    if [[ -n "$_notify_line" ]]; then
        _notify_url="${_notify_line#*=}"
        _notify_url="${_notify_url%\'}"; _notify_url="${_notify_url#\'}"
        _notify_url="${_notify_url%\"}"; _notify_url="${_notify_url#\"}"
        export BOMA_NOTIFY_URL="$_notify_url"
    fi
fi

# Every failure between stopping the service and starting it again leaves the
# vault DOWN. Those paths previously called die() with no notify(), so an
# automated disaster-recovery restore could take the vault offline and report
# nothing on the only off-host channel there is.
RESTORE_HANDLED=0
SERVICE_STOPPED=0
STAGING=""
on_exit() {
    local rc=$?
    [[ -n "$STAGING" ]] && rm -rf "$STAGING"
    if (( rc != 0 )) && (( RESTORE_HANDLED == 0 )); then
        if (( SERVICE_STOPPED == 1 )); then
            notify error "Vaultwarden DOWN after a failed restore" \
                "restore.sh exited ${rc} on $(hostname) with the service stopped. Manual intervention required."
        else
            notify error "Vaultwarden restore FAILED" \
                "restore.sh exited ${rc} on $(hostname); the vault was not modified"
        fi
    fi
    return $rc
}
# TERM and INT as well as EXIT: bash's default SIGTERM disposition terminates
# without running the EXIT trap, so a systemd timeout would otherwise skip the
# failure notification entirely.
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

preflight_host
vw_require_tools
vw_load_config

if [[ "$PASSWORD_STDIN" -eq 1 ]]; then
    # Read before vw_restic_env so it takes precedence over the password file.
    IFS= read -r -s RESTIC_PASSWORD || die "could not read a password from stdin"
    [[ -n "$RESTIC_PASSWORD" ]] || die "empty password supplied on stdin"
    export RESTIC_PASSWORD
fi
vw_restic_env

# ---------------------------------------------------------------------------
# Locate the snapshot
# ---------------------------------------------------------------------------
log_info "resolving snapshot '${SNAPSHOT}'"
if ! snap_json=$(restic snapshots "$SNAPSHOT" --json 2>/dev/null) \
   || [[ "$(printf '%s' "$snap_json" | jq -r 'length')" == "0" ]]; then
    die "snapshot '${SNAPSHOT}' not found (list them with: restic snapshots)"
fi
SNAP_ID=$(printf '%s' "$snap_json" | jq -r '.[-1].short_id')
SNAP_TIME=$(printf '%s' "$snap_json" | jq -r '.[-1].time')
log_info "snapshot ${SNAP_ID} from ${SNAP_TIME}"

# ---------------------------------------------------------------------------
# Restore out-of-place
# ---------------------------------------------------------------------------
if [[ -n "$TARGET" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[dry-run] would restore ${SNAP_ID} into ${TARGET}"
        exit 0
    fi
    ensure_dir "$TARGET" 0700
    restic restore "$SNAP_ID" --target "$TARGET" || die "restic restore failed"
    log_info "restored ${SNAP_ID} into ${TARGET}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Restore into the live service
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "[dry-run] would stop ${VW_SYSTEMD_UNIT}"
    log_info "[dry-run] would move ${VW_DATA_DIR} aside and restore ${SNAP_ID} in its place"
    log_info "[dry-run] would start ${VW_SYSTEMD_UNIT} and wait for ${VW_BIND_IP}:${VW_PORT}/alive"
    exit 0
fi

if [[ "$FORCE" -ne 1 ]]; then
    if have_tty; then
        printf '\nThis will REPLACE the live vault data at %s with snapshot %s (%s).\nType "restore" to continue: ' \
            "$VW_DATA_DIR" "$SNAP_ID" "$SNAP_TIME" >/dev/tty
        IFS= read -r answer </dev/tty || true
        [[ "$answer" == "restore" ]] || die "aborted"
    else
        die "refusing to replace live data without a tty; pass --force if this is automated"
    fi
fi

# Restored into a DISK-backed directory, not mktemp's /tmp.
#
# On the supported Debian trixie target /tmp is a tmpfs sized by RAM, and under
# systemd PrivateTmp it is a private tmpfs too. Restoring a full vault there
# consumes memory rather than disk and can exhaust a 4 GB Pi as attachments grow.
ensure_dir "${VW_SCRATCH_BASE:-/var/lib/boma/scratch}" 0700 "root:root"
STAGING="$(mktemp -d "${VW_SCRATCH_BASE:-/var/lib/boma/scratch}/restore.XXXXXX")"
chmod 0700 "$STAGING"
# NOT a second `trap ... EXIT`: that would replace the on_exit notification
# trap armed above, silently removing the failure alert for every path from
# here on — including all the ones that run with the vault stopped.

log_info "restoring ${SNAP_ID} to a staging directory"
restic restore "$SNAP_ID" --target "$STAGING" || die "restic restore failed"

# restic preserves absolute paths, so the payload sits under the staged tmpdir
# path it was backed up from. Find the directory holding the database.
#
# The database path is checked BEFORE calling dirname: `dirname ""` returns ".",
# which is a real directory, so testing the dirname result would silently accept
# a snapshot containing no database at all.
RESTORED_DB=$(find "$STAGING" -name 'db.sqlite3' -print -quit)
[[ -n "$RESTORED_DB" ]] || die "snapshot ${SNAP_ID} does not contain db.sqlite3"
RESTORED_DIR=$(dirname "$RESTORED_DB")
[[ -d "$RESTORED_DIR" ]] || die "restored path is not a directory: ${RESTORED_DIR}"

# Verify BEFORE touching the live service: a restore that swaps in a corrupt
# database would turn a recoverable situation into an outage.
integrity=$(sqlite3 "${RESTORED_DIR}/db.sqlite3" 'PRAGMA integrity_check;' 2>&1) \
    || die "could not open the restored database"
[[ "$integrity" == "ok" ]] || die "restored database failed integrity check: ${integrity}"
log_info "restored database passed integrity check"

# Every snapshot records the version that produced it. Vaultwarden's migrations
# are forward-only, so restoring a snapshot taken by a NEWER release under the
# currently installed binary gives it a schema it cannot read — swapping an
# unusable database into a working service.
SNAP_VERSION=""
[[ -r "${RESTORED_DIR}/installed-version" ]] \
    && SNAP_VERSION="$(tr -d '[:space:]' < "${RESTORED_DIR}/installed-version")"
RUNNING_VERSION="$(vw_installed_version)"
if [[ -n "$SNAP_VERSION" && -n "$RUNNING_VERSION" ]] \
   && version_gt "$SNAP_VERSION" "$RUNNING_VERSION"; then
    if [[ "$ALLOW_VERSION_MISMATCH" -eq 1 ]]; then
        log_warn "snapshot was taken by ${SNAP_VERSION} but ${RUNNING_VERSION} is installed; continuing because --allow-version-mismatch was given"
    else
        die "snapshot was taken by Vaultwarden ${SNAP_VERSION} but ${RUNNING_VERSION} is installed.
Migrations are forward-only, so the installed binary may not be able to read this schema.
Update to ${SNAP_VERSION} first (update.sh --version ${SNAP_VERSION}), or pass --allow-version-mismatch to override."
    fi
fi

# The JWT signing key must be present, or the restore silently signs every
# family member out. verify-backup.sh already checks this; restore.sh is the
# path that actually swaps data into the live service, so it matters more here.
if ! find "$RESTORED_DIR" -name '*rsa_key*' -print -quit | grep -q .; then
    die "snapshot ${SNAP_ID} contains no RSA key: restoring it would sign every family member out. Pick another snapshot."
fi

log_info "stopping ${VW_SYSTEMD_UNIT}"
systemctl stop "$VW_SYSTEMD_UNIT" || die "could not stop ${VW_SYSTEMD_UNIT}"
SERVICE_STOPPED=1

# Keep the previous data directory so a mistaken restore is itself reversible.
BACKUP_OF_CURRENT="${VW_DATA_DIR}.replaced-$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -d "$VW_DATA_DIR" ]]; then
    mv "$VW_DATA_DIR" "$BACKUP_OF_CURRENT"
    log_info "previous data directory kept at ${BACKUP_OF_CURRENT}"
    # Pruned by AGE, not by "keep only the newest".
    #
    # Keeping only the newest is wrong on a retry: a failed restore leaves the
    # genuine pre-restore vault as the older copy, and the retry would then
    # delete exactly that — the only on-disk copy of the family's real data,
    # including anything created since the last snapshot. Age-based pruning
    # keeps recent history (so a retry is still reversible) while preventing
    # unbounded growth of full plaintext copies.
    find "$(dirname "$VW_DATA_DIR")" -maxdepth 1 -type d \
        -name "$(basename "$VW_DATA_DIR").replaced-*" \
        ! -name "$(basename "$BACKUP_OF_CURRENT")" \
        -mtime "+${VW_REPLACED_RETENTION_DAYS:-14}" \
        -exec rm -rf {} + 2>/dev/null || true
fi

ensure_dir "$VW_DATA_DIR" 0750 "${VW_USER}:${VW_GROUP}"
cp -a "${RESTORED_DIR}/." "${VW_DATA_DIR}/" || die "could not copy restored data into place"
# `cp -a` propagates the staging directory's 0700 root-owned mode onto the live
# data directory, and the chown below fixes ownership but not the mode — leaving
# the vault user unable to traverse its own directory.
chmod 0750 "$VW_DATA_DIR"
# Config and bookkeeping files travel in the snapshot but do not belong in the
# data directory.
rm -rf "${VW_DATA_DIR}/config" "${VW_DATA_DIR}/installed-version"
chown -R "${VW_USER}:${VW_GROUP}" "$VW_DATA_DIR"

log_info "starting ${VW_SYSTEMD_UNIT}"
systemctl start "$VW_SYSTEMD_UNIT" || die "could not start ${VW_SYSTEMD_UNIT}"

if vw_wait_healthy 90; then
    RESTORE_HANDLED=1
    log_info "restore complete; vault healthy at $(vw_health_url)"
    notify info "Vaultwarden restored" "snapshot ${SNAP_ID} on $(hostname)"
else
    RESTORE_HANDLED=1
    notify error "Vaultwarden restore FAILED" \
        "snapshot ${SNAP_ID} restored but the service is unhealthy; previous data kept at ${BACKUP_OF_CURRENT}"
    die "service did not become healthy after restore; previous data is at ${BACKUP_OF_CURRENT}"
fi
