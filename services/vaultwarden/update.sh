#!/usr/bin/env bash
#
# Update Vaultwarden to the newest release that has finished soaking.
#
# The update is transactional. Vaultwarden runs FORWARD-ONLY SQLite migrations
# at startup, so restoring the old binary alone would leave it facing a schema
# it cannot read — a failed update would become an outage. Rollback therefore
# restores the database as well as the binary.
#
# See docs/adr/0004-soak-then-unattended-updates.md

set -euo pipefail

# shellcheck source=services/vaultwarden/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FORCE=0
DRY_RUN=0
TARGET_VERSION=""

usage() {
    cat <<'EOF'
Usage: update.sh [options]

  --force           Ignore the soak window. Use for an urgent security fix you
                    have actually read the advisory for.
  --version <v>     Update to a specific version (implies --force).
  --dry-run         Report what would happen, change nothing.
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)    FORCE=1; shift ;;
        --version)  TARGET_VERSION="$(version_normalise "$2")"; FORCE=1; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          usage >&2; die "unknown argument: $1" ;;
    esac
done

# notify() needs BOMA_NOTIFY_URL, so the config is loaded before the trap is
# armed and the trap is armed before anything that can die().
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

# Without this, every failure BEFORE the apply phase was completely silent:
# a checksum mismatch on a downloaded release — the single most
# security-relevant thing this script can detect — exited non-zero at 03:30
# with no notification, and the vault simply stayed on the old version.
# notify() was only ever called from rollback().
UPDATE_HANDLED=0
on_exit() {
    local rc=$?
    [[ -n "${STAGING:-}" ]] && rm -rf "$STAGING"
    if (( rc != 0 )) && (( UPDATE_HANDLED == 0 )); then
        notify error "Vaultwarden update FAILED" \
            "update.sh exited ${rc} on $(hostname) before applying anything; see: journalctl -u boma-vw-update.service"
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

CURRENT="$(vw_installed_version)"
[[ -n "$CURRENT" ]] || die "no installed version recorded at ${VW_VERSION_FILE}; run install.sh first"
log_info "installed version: ${CURRENT}"

# ---------------------------------------------------------------------------
# Choose a candidate release
# ---------------------------------------------------------------------------
# Only releases older than the soak window are eligible, so upstream
# regressions have had time to surface for other users first.
select_candidate() {
    local json
    json=$(curl -fsSL -H 'Accept: application/vnd.github+json' \
                ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
                "$VW_RELEASE_API") || die "could not list releases from ${VW_BOMA_REPO}"

    local best="" tag published version seen=0
    while IFS=$'\t' read -r tag published; do
        [[ -z "$tag" ]] && continue
        seen=$((seen + 1))
        version="${tag#vaultwarden/}"

        # An unparseable timestamp is a broken release index, not a young
        # release. Treating the two alike meant a renamed or empty published_at
        # field made every release look permanently unsoaked: updates stopped
        # forever while the heartbeat kept reporting healthy.
        if ! age_days "$published" >/dev/null 2>&1; then
            log_error "release ${version} has an unparseable published_at: '${published}'"
            SELECT_BAD_TIMESTAMP=1
            continue
        fi
        if [[ "$FORCE" -ne 1 ]] && ! soak_satisfied "$published" "$VW_SOAK_DAYS"; then
            log_debug "skipping ${version}: published ${published}, still soaking"
            continue
        fi
        if [[ -z "$best" ]] || version_gt "$version" "$best"; then
            best="$version"
        fi
    done < <(printf '%s' "$json" \
        | jq -r '.[] | select(.draft == false) | select(.tag_name | startswith("vaultwarden/")) | [.tag_name, .published_at] | @tsv')

    # "Nothing has soaked yet" and "no releases could be parsed at all" are very
    # different. Treating them alike let a renamed repo, a changed tag prefix or
    # a broken jq filter report success forever while updates silently stopped —
    # and because the heartbeat is the only off-host signal, nothing would alert.
    if (( seen == 0 )); then
        SELECT_NO_RELEASES=1
    fi
    # Assigned to a global rather than echoed: command substitution runs in a
    # subshell, so SELECT_NO_RELEASES set here would not reach the caller.
    CANDIDATE="$best"
}
SELECT_NO_RELEASES=0
SELECT_BAD_TIMESTAMP=0
CANDIDATE=""

if [[ -n "$TARGET_VERSION" ]]; then
    CANDIDATE="$TARGET_VERSION"
else
    select_candidate
fi

if [[ "$SELECT_NO_RELEASES" == "1" ]]; then
    UPDATE_HANDLED=1
    notify error "Vaultwarden update check FAILED" \
        "no vaultwarden/* releases could be parsed from ${VW_BOMA_REPO} on $(hostname); updates have stopped"
    die "no vaultwarden/* releases found in ${VW_BOMA_REPO} — the release index looks wrong, not merely unsoaked"
fi

if [[ -z "$CANDIDATE" && "$SELECT_BAD_TIMESTAMP" == "1" ]]; then
    UPDATE_HANDLED=1
    notify error "Vaultwarden update check FAILED" \
        "release timestamps from ${VW_BOMA_REPO} could not be parsed on $(hostname); updates have stopped"
    die "could not parse any release timestamp — the release index looks wrong, not merely unsoaked"
fi

if [[ -z "$CANDIDATE" ]]; then
    log_info "no release has finished soaking (${VW_SOAK_DAYS} days); nothing to do"
    heartbeat vaultwarden-update
    exit 0
fi

if [[ -n "$TARGET_VERSION" ]]; then
    # An explicitly requested version is an operator decision, including a
    # downgrade — the reason to reach for --version is usually that the current
    # release is broken. Applying the newer-only guard here made that a silent
    # no-op that exited 0 while leaving the bad release running.
    if [[ "$CANDIDATE" == "$CURRENT" ]]; then
        log_info "${CURRENT} is already installed; nothing to do"
        exit 0
    fi
    if ! version_gt "$CANDIDATE" "$CURRENT"; then
        log_warn "DOWNGRADING ${CURRENT} -> ${CANDIDATE}"
        log_warn "Vaultwarden migrations are forward-only: if the newer release already"
        log_warn "migrated the schema, the older binary may not be able to read it."
        log_warn "Restore a pre-update snapshot with restore.sh if it fails to start."
    fi
elif ! version_gt "$CANDIDATE" "$CURRENT"; then
    log_info "already up to date (installed ${CURRENT}, newest eligible ${CANDIDATE})"
    heartbeat vaultwarden-update
    exit 0
fi

log_info "update available: ${CURRENT} -> ${CANDIDATE}"
if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "[dry-run] would back up, install ${CANDIDATE}, restart and health-check"
    exit 0
fi

# ---------------------------------------------------------------------------
# Download and verify before touching anything
# ---------------------------------------------------------------------------
STAGING="$(mktemp -d)"
chmod 0700 "$STAGING"

vw_download_release "$CANDIDATE" "$STAGING"

# ---------------------------------------------------------------------------
# Snapshot: the rollback point for BOTH binary and database
# ---------------------------------------------------------------------------
ROLLBACK_DIR="${VW_INSTALL_DIR}/rollback"
ensure_dir "$ROLLBACK_DIR" 0700 "root:root"

log_info "taking a pre-update snapshot"
if [[ -r "$VW_RESTIC_ENV" ]]; then
    "${VW_BIN_DIR}/backup.sh" --tag pre-update --quiet --quiet-report \
        || die "pre-update backup failed; refusing to update without a rollback point"
else
    log_warn "backups are not configured; proceeding with a local rollback copy only"
fi

# A local copy as well as the restic snapshot: rolling back must not depend on
# the network or on restic being healthy at the worst possible moment.
vw_capture_rollback_point "$CURRENT" "$ROLLBACK_DIR"

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
rollback() {
    local reason="$1"
    UPDATE_HANDLED=1
    log_error "update failed: ${reason}"
    log_warn "rolling back to ${CURRENT}"

    local outcome
    outcome="$(vw_rollback_to "$CURRENT" "$ROLLBACK_DIR")"

    case "$outcome" in
        healthy)
            notify error "Vaultwarden update rolled back" \
                "${CURRENT} -> ${CANDIDATE} failed (${reason}); rolled back and healthy on $(hostname)"
            die "update failed and was rolled back to ${CURRENT}"
            ;;
        incomplete)
            # Serving, but not necessarily on the release the version file now
            # claims — "rolled back and healthy" here would be a lie.
            notify error "Vaultwarden rollback INCOMPLETE" \
                "${CURRENT} -> ${CANDIDATE} failed (${reason}) on $(hostname). The service is answering but the rollback did not fully succeed. Manual verification required."
            die "update failed and the rollback was incomplete"
            ;;
        *)
            notify error "Vaultwarden DOWN after a failed update" \
                "${CURRENT} -> ${CANDIDATE} failed (${reason}) and rollback did not restore service on $(hostname). Manual intervention required."
            die "update failed and rollback did not restore service"
            ;;
    esac
}

log_info "stopping ${VW_SYSTEMD_UNIT}"
systemctl stop "$VW_SYSTEMD_UNIT" || die "could not stop ${VW_SYSTEMD_UNIT}"

install -m 0755 -o root -g root "${STAGING}/vaultwarden" "${VW_BIN_DIR}/vaultwarden" \
    || rollback "could not install the new binary"

# Every step from here until the health check must route failure to rollback().
# The service is already stopped: an unguarded `set -e` exit here would leave
# the vault DOWN after an unattended 03:30 run, with no rollback and — because
# notify() is the only alerting seam — no alert either.
rm -rf "${VW_WEB_VAULT_DIR}.new" || rollback "could not clear the staged web vault"
cp -a "${STAGING}/web-vault" "${VW_WEB_VAULT_DIR}.new" \
    || rollback "could not stage the new web vault"
rm -rf "${VW_WEB_VAULT_DIR}.old" || rollback "could not clear the previous web vault"
if [[ -d "$VW_WEB_VAULT_DIR" ]]; then
    mv "$VW_WEB_VAULT_DIR" "${VW_WEB_VAULT_DIR}.old" \
        || rollback "could not set the previous web vault aside"
fi
mv "${VW_WEB_VAULT_DIR}.new" "$VW_WEB_VAULT_DIR" \
    || rollback "could not move the new web vault into place"
chown -R root:root "$VW_WEB_VAULT_DIR" || rollback "could not set web vault ownership"

printf '%s\n' "$CANDIDATE" | atomic_write "$VW_VERSION_FILE" 0644 \
    || rollback "could not record the new version"

log_info "starting ${VW_SYSTEMD_UNIT}"
systemctl start "$VW_SYSTEMD_UNIT" || rollback "service failed to start"

# BOMA_UPDATE_FAIL_HEALTHCHECK lets the test suite exercise the rollback path
# without needing a genuinely broken binary.
if [[ "${BOMA_UPDATE_FAIL_HEALTHCHECK:-0}" == "1" ]]; then
    rollback "health check failure injected for testing"
fi

vw_wait_healthy 90 || rollback "health check did not pass after update"

# Set BEFORE the cleanup below: the update has fully succeeded at this point,
# and a failure of the tidy-up `rm -rf` must not make the EXIT trap announce a
# successful update as one that never applied anything.
UPDATE_HANDLED=1
rm -rf "${VW_WEB_VAULT_DIR}.old" || log_warn "could not remove the previous web vault copy"
log_info "updated ${CURRENT} -> ${CANDIDATE}"
heartbeat vaultwarden-update
notify info "Vaultwarden updated" "${CURRENT} -> ${CANDIDATE} on $(hostname)"
