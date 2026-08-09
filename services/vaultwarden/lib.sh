#!/usr/bin/env bash
# Shared paths, configuration and restic plumbing for the vaultwarden service.

[[ -n "${_BOMA_VW_LIB_SH:-}" ]] && return 0
_BOMA_VW_LIB_SH=1

VW_SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOMA_LIB_DIR="${BOMA_LIB_DIR:-$(cd "${VW_SERVICE_DIR}/../../lib" && pwd)}"
export BOMA_LIB_DIR VW_SERVICE_DIR

# shellcheck source=lib/boma.sh
. "${BOMA_LIB_DIR}/boma.sh"

# ---------------------------------------------------------------------------
# Defaults. Every one is overridable by a CLI flag or the boma config file, so
# nothing here is baked in.
# ---------------------------------------------------------------------------
# Configuration precedence, in one place: environment > config file > default.
#
# Every path below is documented as overridable, so the rules have to hold for
# all of them uniformly. Earlier attempts tracked a handful with individual
# _VW_EXPLICIT_* flags, which kept missing cases — BOMA_LIB_TARGET was derived
# once at source time and never recomputed, and load_config unconditionally
# overwrote environment-supplied base directories.
#
# Values supplied in the environment are captured here, BEFORE defaults are
# applied, and re-applied after any config file is parsed.
_VW_TUNABLES=(
    VW_USER VW_GROUP
    VW_CONFIG_DIR VW_INSTALL_DIR VW_DATA_DIR
    VW_BIN_DIR VW_WEB_VAULT_DIR BOMA_LIB_TARGET
    VW_BOMA_ENV VW_APP_ENV VW_RESTIC_PASSWORD_FILE VW_RESTIC_ENV VW_VERSION_FILE
    VW_STAGING_DIR VW_SCRATCH_BASE
    VW_RELEASE_BASE VW_RELEASE_API
    VW_BIND_IP VW_PORT VW_SOAK_DAYS VW_BOMA_REPO VW_RETENTION
    # Runtime knobs the service scripts read. Omitting them meant boma.env
    # silently outranked an explicit environment value for these, unlike every
    # other tunable.
    VW_NO_PRUNE VW_MAX_SNAPSHOT_AGE_DAYS VW_DRILL_TAG VW_BACKUP_LOCK
    VW_BACKUP_LOCK_WAIT VW_REPLACED_RETENTION_DAYS VW_SKIP_ATTESTATION
)
declare -A _VW_ENV_PINNED=()
for _t in "${_VW_TUNABLES[@]}"; do
    [[ -n "${!_t:-}" ]] && _VW_ENV_PINNED["$_t"]="${!_t}"
done
unset _t

# vw_pin_environment — re-apply environment-supplied values.
#
# load_config assigns unconditionally, so without this a config file silently
# outranked an explicit environment override.
vw_pin_environment() {
    local k
    for k in "${!_VW_ENV_PINNED[@]}"; do
        printf -v "$k" '%s' "${_VW_ENV_PINNED[$k]}"
    done
}

# vw_is_pinned <name> — true if set in the environment or by a config file,
# i.e. deliberately chosen rather than derived.
vw_is_pinned() {
    [[ -n "${_VW_ENV_PINNED[$1]:-}" ]] && return 0
    boma_config_was_set "$1"
}

VW_USER="${VW_USER:-vaultwarden}"
VW_GROUP="${VW_GROUP:-vaultwarden}"
VW_CONFIG_DIR="${VW_CONFIG_DIR:-/etc/boma/vaultwarden}"
VW_INSTALL_DIR="${VW_INSTALL_DIR:-/opt/boma/vaultwarden}"
VW_DATA_DIR="${VW_DATA_DIR:-/var/lib/boma/vaultwarden}"
VW_BIN_DIR="${VW_BIN_DIR:-${VW_INSTALL_DIR}/bin}"
VW_WEB_VAULT_DIR="${VW_WEB_VAULT_DIR:-${VW_INSTALL_DIR}/web-vault}"
# Where the shared boma library is installed on the host. lib.sh resolves
# BOMA_LIB_DIR as ../../lib relative to itself, so installing scripts into
# /opt/boma/vaultwarden/bin/ and the library into /opt/boma/lib/ keeps the same
# relative layout as the repository.
# Derived from VW_INSTALL_DIR, not hardcoded: installed scripts resolve the
# library as ../../lib relative to themselves, so a non-default VW_INSTALL_DIR
# must place the library alongside it or every timer dies with "No such file".
BOMA_LIB_TARGET="${BOMA_LIB_TARGET:-$(dirname "$VW_INSTALL_DIR")/lib}"

VW_BOMA_ENV="${VW_BOMA_ENV:-${VW_CONFIG_DIR}/boma.env}"
VW_APP_ENV="${VW_APP_ENV:-${VW_CONFIG_DIR}/vaultwarden.env}"
VW_RESTIC_PASSWORD_FILE="${VW_RESTIC_PASSWORD_FILE:-${VW_CONFIG_DIR}/restic-password}"
VW_RESTIC_ENV="${VW_RESTIC_ENV:-${VW_CONFIG_DIR}/restic.env}"
VW_VERSION_FILE="${VW_VERSION_FILE:-${VW_INSTALL_DIR}/installed-version}"

VW_BIND_IP="${VW_BIND_IP:-127.0.0.1}"
VW_PORT="${VW_PORT:-8222}"
VW_SOAK_DAYS="${VW_SOAK_DAYS:-3}"
VW_BOMA_REPO="${VW_BOMA_REPO:-pedromvgomes/boma}"

# Where release artifacts and the release index come from. Overridable so the
# test harness can serve a local mirror, and so a future air-gapped or mirrored
# install needs no code change.
VW_RELEASE_BASE="${VW_RELEASE_BASE:-https://github.com/${VW_BOMA_REPO}/releases/download}"
VW_RELEASE_API="${VW_RELEASE_API:-https://api.github.com/repos/${VW_BOMA_REPO}/releases?per_page=100}"
VW_SCRATCH_BASE="${VW_SCRATCH_BASE:-/var/lib/boma/scratch}"
VW_STAGING_DIR="${VW_STAGING_DIR:-/var/lib/boma/staging/vaultwarden}"
VW_RETENTION="${VW_RETENTION:---keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 3}"

# Exported so scripts sourcing this file inherit it (and so shellcheck can see
# that it is consumed elsewhere).
export VW_SYSTEMD_UNIT="vaultwarden.service"

# vw_derive_paths — recompute values derived from the base directories.
#
# Must run after boma.env is loaded: the derived paths and release URLs are
# built from VW_INSTALL_DIR / VW_CONFIG_DIR / VW_BOMA_REPO, and those can be
# changed by the config file. Without this they would keep the values computed
# from the compiled-in defaults at source time.
vw_derive_paths() {
    vw_is_pinned VW_BIN_DIR       || VW_BIN_DIR="${VW_INSTALL_DIR}/bin"
    vw_is_pinned VW_WEB_VAULT_DIR || VW_WEB_VAULT_DIR="${VW_INSTALL_DIR}/web-vault"
    # Installed scripts resolve the library as ../../lib relative to themselves,
    # so this MUST track VW_INSTALL_DIR. Deriving it once at source time meant a
    # config-file VW_INSTALL_DIR left the library where nothing looked for it,
    # and every timer died with "No such file or directory".
    # Derived from VW_BIN_DIR, not VW_INSTALL_DIR: the installed scripts live in
    # VW_BIN_DIR and resolve their library as ../../lib relative to THEMSELVES,
    # and VW_BIN_DIR is independently overridable. Deriving from VW_INSTALL_DIR
    # put the library somewhere the scripts would not look whenever the two
    # were not in their default relationship.
    vw_is_pinned BOMA_LIB_TARGET  || BOMA_LIB_TARGET="$(dirname "$(dirname "$VW_BIN_DIR")")/lib"

    vw_is_pinned VW_BOMA_ENV      || VW_BOMA_ENV="${VW_CONFIG_DIR}/boma.env"
    vw_is_pinned VW_APP_ENV       || VW_APP_ENV="${VW_CONFIG_DIR}/vaultwarden.env"
    vw_is_pinned VW_RESTIC_PASSWORD_FILE || VW_RESTIC_PASSWORD_FILE="${VW_CONFIG_DIR}/restic-password"
    vw_is_pinned VW_RESTIC_ENV    || VW_RESTIC_ENV="${VW_CONFIG_DIR}/restic.env"
    vw_is_pinned VW_VERSION_FILE  || VW_VERSION_FILE="${VW_INSTALL_DIR}/installed-version"

    vw_is_pinned VW_RELEASE_BASE  || VW_RELEASE_BASE="https://github.com/${VW_BOMA_REPO}/releases/download"
    vw_is_pinned VW_RELEASE_API   || VW_RELEASE_API="https://api.github.com/repos/${VW_BOMA_REPO}/releases?per_page=100"
}

# vw_load_config — load boma.env if present, so scripts invoked by systemd
# timers pick up the same settings install.sh recorded.
#
# Callers must read any config-backed setting AFTER calling this, not at script
# top level: `VW_NO_PRUNE` read before this ran silently ignored the config file.
vw_load_config() {
    if [[ -r "$VW_BOMA_ENV" ]]; then
        load_config "$VW_BOMA_ENV"
    fi
    # environment > config file > derived default
    vw_pin_environment
    vw_derive_paths
    return 0
}

# vw_health_url — the endpoint used to decide whether the service is alive.
vw_health_url() {
    printf 'http://%s:%s/alive' "$VW_BIND_IP" "$VW_PORT"
}

# vw_wait_healthy [timeout-seconds]
#
# Polls /alive until the service answers. Returns non-zero on timeout.
vw_wait_healthy() {
    local timeout="${1:-60}" url elapsed=0
    url="$(vw_health_url)"
    while (( elapsed < timeout )); do
        if curl -fsS -m 5 "$url" >/dev/null 2>&1; then
            log_debug "service healthy after ${elapsed}s"
            return 0
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
    log_error "service did not become healthy within ${timeout}s (${url})"
    return 1
}

# vw_restic_env — export everything restic needs.
#
# Credentials come from a 0600 file rather than the command line, because
# process arguments are world-readable via /proc.
vw_restic_env() {
    [[ -r "$VW_RESTIC_ENV" ]] || die "restic environment file not readable: $VW_RESTIC_ENV"

    # A password supplied on stdin (a manual drill with the recovery or family
    # passphrase) must outrank the file. load_config exports whatever it parses,
    # so a stray RESTIC_PASSWORD in restic.env would otherwise silently replace
    # the passphrase the operator just typed — and the drill would then prove
    # the wrong credential works.
    local supplied="${RESTIC_PASSWORD:-}"
    load_config "$VW_RESTIC_ENV"
    if [[ -n "$supplied" ]]; then
        RESTIC_PASSWORD="$supplied"
        export RESTIC_PASSWORD
    fi

    [[ -n "${RESTIC_REPOSITORY:-}" ]] || die "RESTIC_REPOSITORY is not set in $VW_RESTIC_ENV"

    # A password file is the default, but callers may supply one another way
    # (a prompt during a manual drill, for instance).
    if [[ -z "${RESTIC_PASSWORD:-}" && -z "${RESTIC_PASSWORD_COMMAND:-}" ]]; then
        [[ -r "$VW_RESTIC_PASSWORD_FILE" ]] \
            || die "restic password file not readable: $VW_RESTIC_PASSWORD_FILE"
        export RESTIC_PASSWORD_FILE="$VW_RESTIC_PASSWORD_FILE"
    fi
    export RESTIC_REPOSITORY
}

# vw_installed_version — the version currently deployed, or empty.
vw_installed_version() {
    [[ -r "$VW_VERSION_FILE" ]] && cat "$VW_VERSION_FILE" || printf ''
}

# vw_sqlite_path
vw_sqlite_path() {
    printf '%s/db.sqlite3' "$VW_DATA_DIR"
}

# vw_snapshot_sqlite <destination>
#
# Takes a hot-consistent copy of a live SQLite database using the backup API.
#
# Copying the file directly would be unsafe: with WAL journalling the database
# spans db.sqlite3, -wal and -shm, and a plain copy can capture them at
# different instants, producing a backup that restores to a corrupt database.
# `.backup` takes a proper read lock and resolves the WAL.
vw_snapshot_sqlite() {
    local dest="$1" src
    src="$(vw_sqlite_path)"
    [[ -r "$src" ]] || die "sqlite database not readable: $src"
    # Create the parent only when missing, and never re-apply a mode: both
    # callers deliberately create this directory 0700 first, and re-running
    # ensure_dir with its 0755 default would silently widen it, exposing a full
    # copy of the vault database to every local user.
    local destdir; destdir="$(dirname "$dest")"
    [[ -d "$destdir" ]] || ensure_dir "$destdir" 0700
    sqlite3 "$src" ".backup '${dest}'" \
        || die "sqlite backup failed for $src"
    # A truncated or corrupt snapshot must fail here, not at restore time.
    local check
    check=$(sqlite3 "$dest" 'PRAGMA integrity_check;' 2>&1) \
        || die "could not run integrity check on snapshot $dest"
    [[ "$check" == "ok" ]] || die "snapshot failed integrity check: $check"
    log_debug "sqlite snapshot written to $dest"
}

# vw_attestation_possible — can build provenance actually be checked here?
#
# `gh attestation verify` needs credentials: unauthenticated it exits 4 without
# checking anything. Probing capability up front lets the caller tell "cannot
# check" apart from "check failed", which are very different events.
_VW_ATTESTATION_REASON=""
vw_attestation_possible() {
    if ! command -v gh >/dev/null 2>&1; then
        _VW_ATTESTATION_REASON="gh is not installed"
        return 1
    fi
    if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
        return 0
    fi
    if gh auth status >/dev/null 2>&1; then
        return 0
    fi
    _VW_ATTESTATION_REASON="gh is installed but not authenticated (no GITHUB_TOKEN and no gh auth login)"
    return 1
}

# vw_download_release <version> <destination-dir>
#
# Downloads the binary, web vault and SHA256SUMS for a release, verifies the
# checksums and unpacks the web vault. Shared by install.sh and update.sh: the
# two had copy-pasted versions that had already diverged (only one validated
# that the archive actually contained web-vault/), and a divergence in the
# checksum step is exactly the kind that would not be noticed.
vw_download_release() {
    local version="$1" dest="$2"
    local base="${VW_RELEASE_BASE}/vaultwarden/${version}"

    log_info "downloading release ${version}"
    curl -fsSL -o "${dest}/vaultwarden" "${base}/vaultwarden" \
        || die "could not download the vaultwarden binary for ${version}"
    curl -fsSL -o "${dest}/SHA256SUMS" "${base}/SHA256SUMS" \
        || die "could not download SHA256SUMS for ${version}"

    local web_asset
    web_asset=$(grep -oE 'web-vault-[^ ]+\.tar\.gz' "${dest}/SHA256SUMS" | head -1)
    [[ -n "$web_asset" ]] || die "SHA256SUMS for ${version} does not reference a web-vault asset"
    curl -fsSL -o "${dest}/${web_asset}" "${base}/${web_asset}" \
        || die "could not download ${web_asset}"

    ( cd "$dest" && sha256sum -c SHA256SUMS ) \
        || die "checksum verification failed for release ${version}; refusing to install"
    log_info "checksums verified"

    # The checksum proves TRANSFER integrity only: SHA256SUMS ships from the
    # same release, so anyone who can rewrite the release can rewrite both. The
    # build-provenance attestation is what proves the binary came from our
    # workflow building the upstream source.
    #
    # Two outcomes are deliberately NOT the same thing:
    #
    #   verification FAILED      the artifact does not match its attestation.
    #                            That is an attack or a corrupt release. Abort.
    #
    #   verification IMPOSSIBLE  we have no way to check (gh missing, or gh
    #                            present but unauthenticated — `gh attestation
    #                            verify` requires credentials and exits 4
    #                            without them). Warn loudly and continue.
    #
    # Conflating them bricked the host: a fresh Pi has no authenticated gh, so
    # EVERY install and every unattended update aborted, turning a defence-in-
    # depth control into a total outage. Set VW_REQUIRE_ATTESTATION=1 to make
    # "impossible" fatal too, once a token is in place.
    if [[ "${VW_SKIP_ATTESTATION:-0}" == "1" ]]; then
        log_warn "attestation verification skipped (VW_SKIP_ATTESTATION=1)"
    elif vw_attestation_possible; then
        if gh attestation verify "${dest}/vaultwarden" \
             --repo "$VW_BOMA_REPO" >/dev/null 2>&1; then
            log_info "build provenance attestation verified"
        else
            die "build provenance attestation FAILED for ${version}.
The checksum matched, but the binary cannot be shown to have come from ${VW_BOMA_REPO}'s build workflow.
Refusing to install."
        fi
    elif [[ "${VW_REQUIRE_ATTESTATION:-0}" == "1" ]]; then
        die "cannot verify build provenance for ${version} and VW_REQUIRE_ATTESTATION=1.
Install gh and provide a GitHub token (GITHUB_TOKEN in ${VW_BOMA_ENV}) so attestations can be checked."
    else
        log_warn "build provenance NOT verified: ${_VW_ATTESTATION_REASON}"
        log_warn "checksums matched, but authenticity was not established"
        log_warn "set GITHUB_TOKEN in ${VW_BOMA_ENV} to enable verification (see README)"
    fi

    tar xzf "${dest}/${web_asset}" -C "$dest" || die "could not unpack ${web_asset}"
    [[ -d "${dest}/web-vault" ]] \
        || die "web vault archive for ${version} did not contain web-vault/"
}

# vw_capture_rollback_point <version> <rollback-dir>
#
# Saves the binary and a database snapshot for <version> and prunes older
# points. Shared by install.sh and update.sh, which had identical copies —
# the same duplication that made their rollback paths drift apart.
vw_capture_rollback_point() {
    local version="$1" rollback_dir="$2"
    ensure_dir "$rollback_dir" 0700 "root:root"
    cp -a "${VW_BIN_DIR}/vaultwarden" "${rollback_dir}/vaultwarden.${version}" \
        || die "could not save a rollback copy of the current binary"
    if [[ -r "$(vw_sqlite_path)" ]]; then
        vw_snapshot_sqlite "${rollback_dir}/db.sqlite3.${version}"
    fi
    printf '%s\n' "$version" > "${rollback_dir}/version"
    # Each point is a full binary plus a full PLAINTEXT copy of the vault
    # database, so only the current one is kept.
    find "$rollback_dir" -maxdepth 1 -type f \
        \( -name 'vaultwarden.*' -o -name 'db.sqlite3.*' \) \
        ! -name "*.${version}" -delete 2>/dev/null || true
}

# vw_rollback_to <version> <rollback-dir>
#
# Restores the binary, database and web vault for <version>, rewrites the
# version stamp, restarts the service and health-checks it.
#
# Shared by update.sh and install.sh, which both need it and had drifting
# copies: the two implementations disagreed about whether the web vault was
# restored, whether a partial failure was reported, and whether the service was
# health-checked at all — and those divergences produced defects in five
# consecutive review rounds.
#
# Echoes one of: healthy | incomplete | down
vw_rollback_to() {
    local version="$1" rollback_dir="$2"
    local ok=1

    # errexit off for the whole handler: every step reports itself, and aborting
    # midway would skip the restart AND the caller's notification.
    set +e

    systemctl stop "$VW_SYSTEMD_UNIT"

    if ! install -m 0755 -o root -g root \
        "${rollback_dir}/vaultwarden.${version}" "${VW_BIN_DIR}/vaultwarden"; then
        log_error "could not restore the ${version} binary"
        ok=0
    fi

    # Forward-only migrations mean the database must revert with the binary.
    if [[ -f "${rollback_dir}/db.sqlite3.${version}" ]]; then
        rm -f "${VW_DATA_DIR}/db.sqlite3" "${VW_DATA_DIR}/db.sqlite3-wal" "${VW_DATA_DIR}/db.sqlite3-shm"
        if cp -a "${rollback_dir}/db.sqlite3.${version}" "${VW_DATA_DIR}/db.sqlite3" \
           && chown "${VW_USER}:${VW_GROUP}" "${VW_DATA_DIR}/db.sqlite3"; then
            log_info "database restored to the ${version} snapshot"
        else
            log_error "could not restore the ${version} database"
            ok=0
        fi
    else
        log_error "no ${version} database snapshot found; the schema may be ahead of the binary"
        ok=0
    fi

    # The web vault must match the binary, or the browser UI mismatches the API.
    if [[ -d "${VW_WEB_VAULT_DIR}.old" ]]; then
        rm -rf "${VW_WEB_VAULT_DIR}.failed"
        # The result is checked: if the current directory could not be moved
        # aside it still exists, and the next mv would nest the old web vault
        # INSIDE it rather than replacing it.
        if [[ -d "$VW_WEB_VAULT_DIR" ]] && ! mv "$VW_WEB_VAULT_DIR" "${VW_WEB_VAULT_DIR}.failed"; then
            log_error "could not move the failed web vault aside; leaving it in place"
            ok=0
        elif mv "${VW_WEB_VAULT_DIR}.old" "$VW_WEB_VAULT_DIR"; then
            log_info "web vault restored to ${version}"
            rm -rf "${VW_WEB_VAULT_DIR}.failed"
        else
            log_error "could not restore the ${version} web vault"
            ok=0
        fi
    fi

    if ! printf '%s\n' "$version" > "$VW_VERSION_FILE"; then
        log_error "could not rewrite ${VW_VERSION_FILE} to ${version}"
        ok=0
    fi

    systemctl start "$VW_SYSTEMD_UNIT"
    if vw_wait_healthy 90; then
        (( ok == 1 )) && printf 'healthy' || printf 'incomplete'
    else
        printf 'down'
    fi
    set -e
}

# vw_require_tools — commands every service script depends on.
vw_require_tools() {
    require_cmd curl
    require_cmd sqlite3 sqlite3
    require_cmd restic
    require_cmd tar
    # Every script that resolves snapshots or releases parses JSON with jq.
    # restore.sh and verify-backup.sh relied on it without checking, so a host
    # missing jq failed mid-restore rather than at the preflight.
    require_cmd jq
    # Concurrent backups are serialised with flock (util-linux).
    require_cmd flock util-linux
}
