#!/usr/bin/env bash
#
# Install (or re-install) Vaultwarden on bare metal.
#
# Idempotent: re-running upgrades the binary and rewrites configuration, but
# never regenerates secrets or re-initialises the restic repository.
#
# See PLATFORM.md for the supported host and docs/INGRESS.md for the contract
# with wardnet, which owns TLS and DNS.

set -euo pipefail

# shellcheck source=services/vaultwarden/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
VW_DOMAIN=""
VW_ADMIN_EMAIL=""
VW_VERSION_REQ=""
SMTP_HOST=""; SMTP_PORT="587"; SMTP_FROM=""; SMTP_FROM_NAME="Vaultwarden"
SMTP_USERNAME=""; SMTP_PASSWORD=""; SMTP_SECURITY="starttls"
RESTIC_REPO_ARG=""; R2_ACCESS_KEY=""; R2_SECRET_KEY=""
NOTIFY_URL=""; HEARTBEAT_URL=""
SKIP_SMTP_TEST=0
NON_INTERACTIVE=0
RESTIC_PASSWORD_STDIN=0

usage() {
    cat <<'EOF'
Usage: install.sh --domain <url> --admin-email <email> [options]

Required:
  --domain <url>            Public URL wardnet serves, e.g.
                            https://vault.nairobi.my.wardnet.services
                            This is the WebAuthn relying-party ID: changing it
                            later invalidates every registered passkey.
  --admin-email <email>     Account allowed to create the family organization.

Networking (defaults suit a tunnel on the same host):
  --bind-ip <ip>            Listen address            (default: 127.0.0.1)
  --port <port>             Listen port               (default: 8222)

Version:
  --version <v>             Vaultwarden version       (default: latest boma build)
  --repo <owner/name>       Repo publishing builds    (default: pedromvgomes/boma)
  --soak-days <n>           Unattended update soak    (default: 3)

SMTP (required — family invitations are emailed):
  --smtp-host <host>
  --smtp-port <port>        (default: 587)
  --smtp-from <email>
  --smtp-from-name <name>   (default: Vaultwarden)
  --smtp-username <user>
  --smtp-password <pass>
  --smtp-security <mode>    starttls | force_tls | off  (default: starttls)
  --skip-smtp-test          Do not send a verification email (NOT recommended)

Backups:
  --restic-repo <url>       e.g. s3:https://<account>.r2.cloudflarestorage.com/<bucket>
  --r2-access-key <key>
  --r2-secret-key <key>
  --restic-password-stdin   Read an EXISTING repository password from stdin and
                            attach to that repository instead of creating a new
                            one. Required when rebuilding a host against
                            existing backups (see docs/RECOVERY.md).

Alerting:
  --notify-url <url>        Webhook for failures (wardnet admin app)
  --heartbeat-url <url>     Base URL pinged on success

Other:
  --non-interactive         Do not prompt for passphrase confirmation (tests only)
  -h, --help
EOF
}

# Flags are captured into ARG_* first and applied only AFTER existing config is
# loaded. Assigning straight into VW_* would not survive: load_config exports
# VW_PORT/VW_BIND_IP/VW_SOAK_DAYS/VW_BOMA_REPO from boma.env, silently undoing
# the flag the operator just passed.
ARG_BIND_IP=""; ARG_PORT=""; ARG_SOAK_DAYS=""; ARG_REPO=""
ARG_SMTP_PORT=""; ARG_SMTP_FROM_NAME=""; ARG_SMTP_SECURITY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)          VW_DOMAIN="$2"; shift 2 ;;
        --admin-email)     VW_ADMIN_EMAIL="$2"; shift 2 ;;
        --bind-ip)         ARG_BIND_IP="$2"; shift 2 ;;
        --port)            ARG_PORT="$2"; shift 2 ;;
        --version)         VW_VERSION_REQ="$2"; shift 2 ;;
        --repo)            ARG_REPO="$2"; shift 2 ;;
        --soak-days)       ARG_SOAK_DAYS="$2"; shift 2 ;;
        --smtp-host)       SMTP_HOST="$2"; shift 2 ;;
        --smtp-port)       ARG_SMTP_PORT="$2"; shift 2 ;;
        --smtp-from)       SMTP_FROM="$2"; shift 2 ;;
        --smtp-from-name)  ARG_SMTP_FROM_NAME="$2"; shift 2 ;;
        --smtp-username)   SMTP_USERNAME="$2"; shift 2 ;;
        --smtp-password)   SMTP_PASSWORD="$2"; shift 2 ;;
        --smtp-security)   ARG_SMTP_SECURITY="$2"; shift 2 ;;
        --skip-smtp-test)  SKIP_SMTP_TEST=1; shift ;;
        --restic-repo)     RESTIC_REPO_ARG="$2"; shift 2 ;;
        --r2-access-key)   R2_ACCESS_KEY="$2"; shift 2 ;;
        --r2-secret-key)   R2_SECRET_KEY="$2"; shift 2 ;;
        --restic-password-stdin) RESTIC_PASSWORD_STDIN=1; shift ;;
        --notify-url)      NOTIFY_URL="$2"; shift 2 ;;
        --heartbeat-url)   HEARTBEAT_URL="$2"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 usage >&2; die "unknown argument: $1" ;;
    esac
done

preflight_host
vw_require_tools
require_cmd jq
require_cmd argon2 argon2
require_cmd openssl openssl
require_cmd install coreutils

# ---------------------------------------------------------------------------
# Carry forward existing configuration
# ---------------------------------------------------------------------------
# Re-running install.sh (to upgrade, say) with only --domain and --admin-email
# used to regenerate both config files from flags and defaults alone, silently
# discarding the notify URL, heartbeat URL, SMTP settings and any non-default
# port. Failure alerts and family invitation emails would just stop, with no
# error anywhere. So existing values are loaded first and act as the defaults
# that flags then override.
if [[ -r "$VW_BOMA_ENV" ]]; then
    log_info "existing configuration found; unspecified options keep their current values"
    load_config "$VW_BOMA_ENV"
    # Environment beats config file. load_config assigns unconditionally, and
    # install.sh does not go through vw_load_config, so the pin is applied here.
    vw_pin_environment
    NOTIFY_URL="${NOTIFY_URL:-${BOMA_NOTIFY_URL:-}}"
    HEARTBEAT_URL="${HEARTBEAT_URL:-${BOMA_HEARTBEAT_URL:-}}"
fi

# R2 credentials likewise survive a re-run that does not repeat them. Without
# this, re-running with --restic-repo but no --r2-* keys rewrote restic.env
# with only the repository line, and the nightly backup then failed on
# authentication until the keys were re-entered by hand.
if [[ -r "$VW_RESTIC_ENV" ]]; then
    load_config "$VW_RESTIC_ENV"
    # restic honours RESTIC_PASSWORD over RESTIC_PASSWORD_FILE, so a hand-added
    # RESTIC_PASSWORD here would make the reachability probe below validate a
    # DIFFERENT credential than the one promoted to /etc — the install would
    # report the password proven while every later backup failed.
    unset RESTIC_PASSWORD
    RESTIC_REPO_ARG="${RESTIC_REPO_ARG:-${RESTIC_REPOSITORY:-}}"
    R2_ACCESS_KEY="${R2_ACCESS_KEY:-${AWS_ACCESS_KEY_ID:-}}"
    R2_SECRET_KEY="${R2_SECRET_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
fi

if [[ -r "$VW_APP_ENV" ]]; then
    # Read the previous Vaultwarden settings without exporting them into the
    # environment the service inherits.
    while IFS='=' read -r _k _v; do
        # Strip either quote style. SMTP_USERNAME/SMTP_PASSWORD are written
        # double-quoted, so stripping only single quotes re-quoted them on every
        # re-install, adding a layer of literal quote characters each time until
        # SMTP authentication failed.
        if [[ "$_v" == \"*\" && ${#_v} -ge 2 ]]; then
            _v="${_v:1:${#_v}-2}"
            # Unescape in the reverse order the writer escapes: quote first,
            # then backslash. Handling only the quote made every backslash
            # double on each re-install until SMTP authentication broke.
            _v="${_v//\\\"/\"}"; _v="${_v//\\\\/\\}"
        elif [[ "$_v" == \'*\' && ${#_v} -ge 2 ]]; then
            _v="${_v:1:${#_v}-2}"
        fi
        case "$_k" in
            DOMAIN)             VW_DOMAIN="${VW_DOMAIN:-$_v}" ;;
            ROCKET_ADDRESS)     PREV_BIND_IP="$_v" ;;
            ROCKET_PORT)        PREV_PORT="$_v" ;;
            ORG_CREATION_USERS) VW_ADMIN_EMAIL="${VW_ADMIN_EMAIL:-$_v}" ;;
            SMTP_HOST)          SMTP_HOST="${SMTP_HOST:-$_v}" ;;
            SMTP_PORT)          PREV_SMTP_PORT="$_v" ;;
            SMTP_FROM)          SMTP_FROM="${SMTP_FROM:-$_v}" ;;
            SMTP_FROM_NAME)     PREV_SMTP_FROM_NAME="$_v" ;;
            SMTP_SECURITY)      PREV_SMTP_SECURITY="$_v" ;;
            SMTP_USERNAME)      SMTP_USERNAME="${SMTP_USERNAME:-$_v}" ;;
            SMTP_PASSWORD)      SMTP_PASSWORD="${SMTP_PASSWORD:-$_v}" ;;
        esac
    done < <(grep -E '^[A-Za-z_]+=' "$VW_APP_ENV" || true)

    # These have non-empty built-in defaults, so "was the flag given?" cannot be
    # inferred from emptiness — the recorded value is used unless a flag overrides
    # it below.
    [[ -n "${PREV_BIND_IP:-}" ]] && VW_BIND_IP="$PREV_BIND_IP"
    [[ -n "${PREV_PORT:-}" ]] && VW_PORT="$PREV_PORT"
    [[ -n "${PREV_SMTP_PORT:-}" ]] && SMTP_PORT="$PREV_SMTP_PORT"
    [[ -n "${PREV_SMTP_FROM_NAME:-}" ]] && SMTP_FROM_NAME="$PREV_SMTP_FROM_NAME"
    [[ -n "${PREV_SMTP_SECURITY:-}" ]] && SMTP_SECURITY="$PREV_SMTP_SECURITY"
    true
fi

# Flags win over both the recorded configuration and the built-in defaults.
[[ -n "$ARG_BIND_IP" ]]   && VW_BIND_IP="$ARG_BIND_IP"
[[ -n "$ARG_PORT" ]]      && VW_PORT="$ARG_PORT"
[[ -n "$ARG_SOAK_DAYS" ]] && VW_SOAK_DAYS="$ARG_SOAK_DAYS"
[[ -n "$ARG_REPO" ]]      && VW_BOMA_REPO="$ARG_REPO"
# These three were previously overwritten by the recorded config unconditionally,
# so the flags were silently ignored on any re-install.
[[ -n "$ARG_SMTP_PORT" ]]      && SMTP_PORT="$ARG_SMTP_PORT"
[[ -n "$ARG_SMTP_FROM_NAME" ]] && SMTP_FROM_NAME="$ARG_SMTP_FROM_NAME"
[[ -n "$ARG_SMTP_SECURITY" ]]  && SMTP_SECURITY="$ARG_SMTP_SECURITY"
true

# VW_BOMA_REPO may have changed via --repo or boma.env, and the release URLs are
# derived from it. Without this the download would silently target the default
# repository while error messages named the requested one.
vw_derive_paths

# ---------------------------------------------------------------------------
# Validation
#
# Runs AFTER carrying values forward, so a re-run that omits flags already
# recorded in the config is valid rather than an error.
# ---------------------------------------------------------------------------
[[ -n "$VW_DOMAIN" ]]      || { usage >&2; die "--domain is required"; }
[[ -n "$VW_ADMIN_EMAIL" ]] || { usage >&2; die "--admin-email is required"; }

# A DOMAIN that is not https:// breaks WebAuthn and produces invitation links
# that do not work. Catch it here rather than during family onboarding.
[[ "$VW_DOMAIN" =~ ^https:// ]] \
    || die "--domain must start with https:// (got: $VW_DOMAIN); see docs/INGRESS.md"
[[ "$VW_DOMAIN" != */ ]] || die "--domain must not end with a trailing slash"

[[ "$VW_PORT" =~ ^[0-9]+$ ]] || die "--port must be numeric (got: $VW_PORT)"
[[ "$VW_SOAK_DAYS" =~ ^[0-9]+$ ]] || die "--soak-days must be numeric (got: $VW_SOAK_DAYS)"

case "$SMTP_SECURITY" in
    starttls|force_tls|off) ;;
    *) die "--smtp-security must be starttls, force_tls or off (got: $SMTP_SECURITY)" ;;
esac

# ---------------------------------------------------------------------------
# Resolve the version to install
# ---------------------------------------------------------------------------
resolve_latest_version() {
    local json
    json=$(curl -fsSL -H 'Accept: application/vnd.github+json' \
                ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
                "$VW_RELEASE_API") || die "could not list releases from ${VW_BOMA_REPO}"

    local latest=""
    local tag
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        local v="${tag#vaultwarden/}"
        if [[ -z "$latest" ]] || version_gt "$v" "$latest"; then
            latest="$v"
        fi
    done < <(printf '%s' "$json" | jq -r '.[] | select(.draft == false) | .tag_name | select(startswith("vaultwarden/"))')

    [[ -n "$latest" ]] || die "no vaultwarden/* releases found in ${VW_BOMA_REPO}; run the build workflow first"
    printf '%s' "$latest"
}

if [[ -n "$VW_VERSION_REQ" ]]; then
    VW_VERSION="$(version_normalise "$VW_VERSION_REQ")"
else
    log_info "resolving latest build from ${VW_BOMA_REPO}"
    VW_VERSION="$(resolve_latest_version)"
fi
log_info "installing Vaultwarden ${VW_VERSION}"

# ---------------------------------------------------------------------------
# User, directories
# ---------------------------------------------------------------------------
if ! id -u "$VW_USER" >/dev/null 2>&1; then
    log_info "creating system user ${VW_USER}"
    useradd --system --create-home --home-dir "$VW_DATA_DIR" \
            --shell /usr/sbin/nologin "$VW_USER"
else
    log_debug "user ${VW_USER} already exists"
fi

ensure_dir "$VW_INSTALL_DIR" 0755
ensure_dir "$VW_BIN_DIR" 0755
ensure_dir "$BOMA_LIB_TARGET" 0755
# 0750 so the vaultwarden user can read its own config but nobody else can.
ensure_dir "$VW_CONFIG_DIR" 0750 "root:${VW_GROUP}"
ensure_dir "$VW_DATA_DIR" 0750 "${VW_USER}:${VW_GROUP}"
# The backup and update units name this in ReadWritePaths. systemd refuses to
# start a unit whose ReadWritePaths entry does not exist, and it fails during
# namespace setup — before ExecStart — so the script's own alerting never runs.
# Both timers would be permanently dead on a fresh host with no notification.
ensure_dir "$(dirname "$VW_STAGING_DIR")" 0700 "root:root"
ensure_dir "$VW_STAGING_DIR" 0700 "root:root"
# restore.sh and verify-backup.sh restore full snapshots here. It must be
# disk-backed and must exist, since the units name it in ReadWritePaths.
ensure_dir "${VW_SCRATCH_BASE:-/var/lib/boma/scratch}" 0700 "root:root"

# ---------------------------------------------------------------------------
# Download and verify the release
# ---------------------------------------------------------------------------
# Passphrase safety net.
#
# The recovery and family passphrases exist only in memory until displayed. Any
# die() between generating them and printing the banner — a failing second
# `restic key add`, for instance — lost them permanently, because a re-run then
# takes the "repository already configured" early return and never prints them
# again. That is total backup loss if the host is later gone.
PASSPHRASES_SHOWN=0
RECOVERY_PASSPHRASE=""
FAMILY_PASSPHRASE=""
NEW_ADMIN_TOKEN=""
show_passphrases_if_pending() {
    [[ "$PASSPHRASES_SHOWN" -eq 1 ]] && return 0
    [[ -z "$RECOVERY_PASSPHRASE" && -z "$FAMILY_PASSPHRASE" && -z "$NEW_ADMIN_TOKEN" ]] && return 0
    PASSPHRASES_SHOWN=1

    # The admin token is covered by the same net. It is marked "already
    # generated" the moment it is created but was only printed at the very end,
    # so any failure in between lost it permanently — only its Argon2 hash
    # survives, and the admin panel becomes unreachable.
    if [[ -n "$NEW_ADMIN_TOKEN" ]]; then
        cat <<EOF

 ADMIN TOKEN (for ${VW_DOMAIN}/admin)
   ${NEW_ADMIN_TOKEN}

 Stored on this host only as an Argon2 hash, so it cannot be read back.

EOF
    fi
    [[ -z "$RECOVERY_PASSPHRASE" && -z "$FAMILY_PASSPHRASE" ]] && return 0
    cat <<EOF

================================================================================
 RECORD THESE NOW — THEY ARE NOT SHOWN AGAIN AND CANNOT BE RECOVERED
================================================================================

 RECOVERY PASSPHRASE   (save in your personal cloud password manager)
   ${RECOVERY_PASSPHRASE:-<not generated>}

   Decrypts the backups if this host is lost. Not stored anywhere on this host,
   and deliberately NOT in Cloudflare — Cloudflare holds the encrypted backups,
   so keeping the key there would put both behind one account.

 FAMILY PASSPHRASE     (give to a trusted family member)
   ${FAMILY_PASSPHRASE:-<not generated>}

   Lets someone else restore the backups if you are unavailable. It recovers
   DATA ONLY — it does not make them an administrator of the vault.

 Either one opens the backups on its own. See docs/RECOVERY.md.
================================================================================

EOF
}

STAGING="$(mktemp -d)"
# Explicit rather than relying on mktemp's default: passphrase material is
# written under here before being displayed.
chmod 0700 "$STAGING"
INSTALL_COMPLETED=0
cleanup() {
    local rc=$?
    # Runs before the temp dir goes away, so a failure part-way through
    # provisioning still surfaces whatever was generated.
    if (( rc != 0 )); then
        show_passphrases_if_pending
        if (( INSTALL_COMPLETED == 0 )); then
            notify error "Vaultwarden install/upgrade FAILED" \
                "install.sh exited ${rc} on $(hostname); see the journal for details"
        fi
    fi
    rm -rf "$STAGING"
    return $rc
}
trap cleanup EXIT
# bash's default SIGTERM/SIGINT disposition terminates WITHOUT running the EXIT
# trap. Here that trap is the only thing that ever displays the unrecoverable
# recovery/family passphrases, so a dropped SSH session or Ctrl-C during the
# health-check wait would lose them for good.
trap 'exit 143' TERM
trap 'exit 130' INT

vw_download_release "$VW_VERSION" "$STAGING"

# ---------------------------------------------------------------------------
# Install binary, web vault, scripts and library
# ---------------------------------------------------------------------------
for script in backup.sh restore.sh update.sh verify-backup.sh lib.sh; do
    install -m 0755 -o root -g root "${VW_SERVICE_DIR}/${script}" "${VW_BIN_DIR}/${script}"
done
for libfile in "${BOMA_LIB_DIR}"/*.sh; do
    install -m 0644 -o root -g root "$libfile" "${BOMA_LIB_TARGET}/$(basename "$libfile")"
done


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# ADMIN_TOKEN is stored as an Argon2 PHC hash, so reading the config file does
# not yield a usable admin credential.
if [[ ! -f "${VW_CONFIG_DIR}/.admin-token-generated" ]]; then
    ADMIN_TOKEN_PLAIN="$(generate_passphrase 6 5)"
    ADMIN_TOKEN_HASH="$(printf '%s' "$ADMIN_TOKEN_PLAIN" \
        | argon2 "$(openssl rand -base64 32)" -e -id -k 65540 -t 3 -p 4)" \
        || die "could not hash the admin token"
    printf '%s' "$ADMIN_TOKEN_HASH" | atomic_write "${VW_CONFIG_DIR}/admin-token-hash" 0640 "root:${VW_GROUP}"
    : > "${VW_CONFIG_DIR}/.admin-token-generated"
    chmod 0600 "${VW_CONFIG_DIR}/.admin-token-generated"
    NEW_ADMIN_TOKEN="$ADMIN_TOKEN_PLAIN"
else
    ADMIN_TOKEN_HASH="$(cat "${VW_CONFIG_DIR}/admin-token-hash")"
    NEW_ADMIN_TOKEN=""
fi

{
    cat <<EOF
# Managed by boma install.sh — regenerated on every run. Do not hand-edit.
#
# DOMAIN is the WebAuthn relying-party ID and the base for invitation emails.
# Changing it invalidates every passkey already registered. See docs/INGRESS.md.
DOMAIN=${VW_DOMAIN}

ROCKET_ADDRESS=${VW_BIND_IP}
ROCKET_PORT=${VW_PORT}

DATA_FOLDER=${VW_DATA_DIR}
WEB_VAULT_FOLDER=${VW_WEB_VAULT_DIR}
WEB_VAULT_ENABLED=true

# Invite-only: this is a family vault, not an open registration server.
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true
ORG_CREATION_USERS=${VW_ADMIN_EMAIL}

# wardnet terminates TLS and MUST overwrite this header. Without it every
# request appears to come from 127.0.0.1 and login rate limiting is defeated.
IP_HEADER=X-Real-IP

ADMIN_TOKEN='${ADMIN_TOKEN_HASH}'
EOF

    if [[ -n "$SMTP_HOST" ]]; then
        cat <<EOF

SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_FROM=${SMTP_FROM}
SMTP_FROM_NAME=${SMTP_FROM_NAME}
SMTP_SECURITY=${SMTP_SECURITY}
EOF
        # Quoted, like every other secret-bearing value. systemd's
        # EnvironmentFile parser otherwise mangles passwords that contain
        # quotes, a leading '#', or leading/trailing spaces — and the install
        # would still report success, because smtp_test uses the shell variable
        # rather than the file it just wrote.
        # systemd processes escape sequences inside double-quoted values, so
        # BOTH backslash and quote must be escaped. Escaping only the quote left
        # a password containing a backslash mangled — and the install still
        # reported success, because smtp_test uses the in-memory variable rather
        # than the file it just wrote.
        _esc_username="${SMTP_USERNAME//\\/\\\\}"; _esc_username="${_esc_username//\"/\\\"}"
        _esc_password="${SMTP_PASSWORD//\\/\\\\}"; _esc_password="${_esc_password//\"/\\\"}"
        [[ -n "$SMTP_USERNAME" ]] && printf 'SMTP_USERNAME="%s"\n' "$_esc_username"
        [[ -n "$SMTP_PASSWORD" ]] && printf 'SMTP_PASSWORD="%s"\n' "$_esc_password"
    fi
    # A trailing `[[ ... ]] && printf` that evaluates false returns 1, which
    # becomes the exit status of this whole group and — under pipefail — aborts
    # the script mid-install. Anchor the group to a successful command.
    true
} > "${STAGING}/vaultwarden.env.candidate"
# Validated before replacing the live file: a malformed config would otherwise
# be promoted over a working one and only surface when systemd failed to parse
# it at the next restart.
# Validated in a SUBSHELL. Loading it into this shell re-imported the ESCAPED
# SMTP values (systemd's escaping, not the shell's), so smtp_test then
# authenticated with a corrupted password and the install failed on config it
# had just written correctly.
( load_config "${STAGING}/vaultwarden.env.candidate" >/dev/null ) \
    || die "generated vaultwarden.env is malformed; the existing file was left untouched"
install -m 0640 -o root -g "${VW_GROUP}" "${STAGING}/vaultwarden.env.candidate" "$VW_APP_ENV"

{
    cat <<EOF
# Managed by boma install.sh — boma's own settings (not Vaultwarden's).
VW_BIND_IP=${VW_BIND_IP}
VW_PORT=${VW_PORT}
VW_SOAK_DAYS=${VW_SOAK_DAYS}
VW_BOMA_REPO=${VW_BOMA_REPO}
VW_USER=${VW_USER}
VW_GROUP=${VW_GROUP}
VW_DATA_DIR=${VW_DATA_DIR}
VW_INSTALL_DIR=${VW_INSTALL_DIR}
VW_CONFIG_DIR=${VW_CONFIG_DIR}
VW_STAGING_DIR=${VW_STAGING_DIR}
VW_SCRATCH_BASE=${VW_SCRATCH_BASE}
EOF
    [[ -n "$NOTIFY_URL" ]]    && printf "BOMA_NOTIFY_URL='%s'\n" "$NOTIFY_URL"
    [[ -n "$HEARTBEAT_URL" ]] && printf "BOMA_HEARTBEAT_URL='%s'\n" "$HEARTBEAT_URL"
    # Re-emit any other setting the operator added by hand. The file was
    # previously regenerated from a fixed key list, which silently dropped
    # VW_NO_PRUNE and VW_RETENTION — both read by backup.sh at runtime, so an
    # immutable-bucket configuration would revert to pruning and start failing.
    if [[ -r "$VW_BOMA_ENV" ]]; then
        grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$VW_BOMA_ENV" 2>/dev/null \
            | grep -Ev '^(VW_BIND_IP|VW_PORT|VW_SOAK_DAYS|VW_BOMA_REPO|VW_USER|VW_GROUP|VW_DATA_DIR|VW_INSTALL_DIR|VW_CONFIG_DIR|VW_STAGING_DIR|VW_SCRATCH_BASE|BOMA_NOTIFY_URL|BOMA_HEARTBEAT_URL)=' \
            || true
    fi
    true
} > "${STAGING}/boma.env.candidate"
( load_config "${STAGING}/boma.env.candidate" >/dev/null ) \
    || die "generated boma.env is malformed; the existing file was left untouched"
install -m 0640 -o root -g "${VW_GROUP}" "${STAGING}/boma.env.candidate" "$VW_BOMA_ENV"

# ---------------------------------------------------------------------------
# SMTP verification
# ---------------------------------------------------------------------------
# A silently broken SMTP configuration surfaces during family onboarding, which
# is the worst possible moment. Prove it works now.
smtp_test() {
    local recipient="$VW_ADMIN_EMAIL"
    local msg="${STAGING}/smtp-test.txt"
    cat >"$msg" <<EOF
From: ${SMTP_FROM_NAME} <${SMTP_FROM}>
To: <${recipient}>
Subject: boma — Vaultwarden SMTP verification

Sent by install.sh to prove SMTP works before the family is onboarded.
Host: $(hostname)
EOF

    local url proto_opts=()
    case "$SMTP_SECURITY" in
        force_tls) url="smtps://${SMTP_HOST}:${SMTP_PORT}" ;;
        starttls)  url="smtp://${SMTP_HOST}:${SMTP_PORT}";  proto_opts+=(--ssl-reqd) ;;
        off)       url="smtp://${SMTP_HOST}:${SMTP_PORT}" ;;
    esac

    # Credentials go to curl through a config file on stdin, never on the
    # command line: process arguments are world-readable via /proc, so
    # `--user user:pass` would expose the SMTP password of the account that
    # sends the family's vault invitations to any local user running `ps`.
    local curlrc="${STAGING}/curlrc"
    : > "$curlrc"
    chmod 0600 "$curlrc"
    if [[ -n "$SMTP_USERNAME" ]]; then
        # curl processes backslash escapes inside double-quoted config values,
        # so backslash must be escaped too — the same asymmetry that mangled
        # the systemd EnvironmentFile.
        _cu="${SMTP_USERNAME//\\/\\\\}"; _cu="${_cu//\"/\\\"}"
        _cp="${SMTP_PASSWORD//\\/\\\\}"; _cp="${_cp//\"/\\\"}"
        printf 'user = "%s:%s"\n' "$_cu" "$_cp" >"$curlrc"
    fi

    curl -fsS -m 30 --config "$curlrc" --url "$url" "${proto_opts[@]}" \
        --mail-from "$SMTP_FROM" --mail-rcpt "$recipient" \
        --upload-file "$msg"
}

if [[ -n "$SMTP_HOST" && "$SKIP_SMTP_TEST" -eq 0 ]]; then
    log_info "sending SMTP verification email to ${VW_ADMIN_EMAIL}"
    if smtp_test; then
        log_info "SMTP verification email sent"
    else
        die "SMTP verification failed. Fix the settings and re-run, or pass --skip-smtp-test to proceed without it (family invitations will not work)."
    fi
elif [[ -z "$SMTP_HOST" ]]; then
    log_warn "no --smtp-host given: family invitations will require manual admin-panel confirmation"
fi

# ---------------------------------------------------------------------------
# Backups: restic repository and the three passwords
# ---------------------------------------------------------------------------
setup_restic() {
    [[ -n "$RESTIC_REPO_ARG" ]] || {
        log_warn "no --restic-repo given: backups are NOT configured"
        log_warn "the vault is running but UNPROTECTED — configure backups before storing real data"
        return 0
    }

    # Candidate settings are assembled first and only promoted to the live file
    # once the repository has been proven reachable with the password that will
    # actually be used. Writing restic.env first meant a typo'd --restic-repo
    # destroyed a working configuration before failing.
    {
        printf "RESTIC_REPOSITORY='%s'\n" "$RESTIC_REPO_ARG"
        [[ -n "$R2_ACCESS_KEY" ]] && printf "AWS_ACCESS_KEY_ID='%s'\n" "$R2_ACCESS_KEY"
        [[ -n "$R2_SECRET_KEY" ]] && printf "AWS_SECRET_ACCESS_KEY='%s'\n" "$R2_SECRET_KEY"
        true
    } > "${STAGING}/restic.env.candidate"
    chmod 0600 "${STAGING}/restic.env.candidate"

    # Resolve the password BEFORE any probing, so --restic-password-stdin is
    # honoured even when a password file already exists. Previously the stdin
    # password was never read on such a host, and the reachability guard was
    # skipped as well.
    local pw_source pw_file
    pw_file="${STAGING}/restic-password.candidate"
    if [[ "$RESTIC_PASSWORD_STDIN" -eq 1 ]]; then
        local supplied
        IFS= read -r -s supplied || die "could not read a repository password from stdin"
        [[ -n "$supplied" ]] || die "empty repository password supplied on stdin"
        printf '%s' "$supplied" > "$pw_file"
        pw_source="stdin"
    elif [[ -f "$VW_RESTIC_PASSWORD_FILE" ]]; then
        cp -a "$VW_RESTIC_PASSWORD_FILE" "$pw_file"
        pw_source="existing"
    else
        # Assigned to a variable and validated FIRST. `printf '%s' "$(gen...)"`
        # would not abort on failure: die() inside a command substitution exits
        # only that subshell, printf still runs with an empty argument and
        # returns 0, so `set -e` never fires — and the repository would end up
        # encrypted under an EMPTY passphrase.
        local generated
        generated="$(generate_passphrase 10 5)"
        [[ -n "$generated" ]] || die "could not generate a repository password"
        printf '%s' "$generated" > "$pw_file"
        pw_source="generated"
    fi
    chmod 0600 "$pw_file"
    [[ -s "$pw_file" ]] || die "refusing to use an empty repository password"

    # Probe with the candidate settings in a SUBSHELL, parsed rather than
    # sourced — sourcing would reintroduce exactly the shell evaluation
    # load_config exists to prevent, on a file holding credentials.
    local reachable=0
    if (
        load_config "${STAGING}/restic.env.candidate"
        unset RESTIC_PASSWORD
        RESTIC_PASSWORD_FILE="$pw_file" restic cat config >/dev/null 2>&1
    ); then
        reachable=1
    fi

    case "$pw_source" in
        stdin)
            (( reachable == 1 )) || die "the supplied password does not open ${RESTIC_REPO_ARG} (or the repository does not exist).
${VW_RESTIC_ENV} has been left untouched."
            ;;
        existing)
            (( reachable == 1 )) || die "restic repository '${RESTIC_REPO_ARG}' is not reachable with the existing password.
${VW_RESTIC_ENV} has been left untouched.
To attach to a DIFFERENT repository, re-run with --restic-password-stdin and supply its password."
            ;;
    esac

    load_config "${STAGING}/restic.env.candidate"
    export RESTIC_REPOSITORY
    [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && export AWS_ACCESS_KEY_ID
    [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && export AWS_SECRET_ACCESS_KEY
    export RESTIC_PASSWORD_FILE="$pw_file"

    if (( reachable == 1 )); then
        log_info "attached to the existing restic repository (${pw_source} password)"
        promote_restic_config
        export RESTIC_PASSWORD_FILE="$VW_RESTIC_PASSWORD_FILE"
        return 0
    fi

    # Initialise BEFORE promoting anything to /etc. Promoting first meant a
    # failed `restic init` left a password file behind, which made every later
    # run take the "existing password" branch and die with advice that could not
    # work — install.sh could then never create the repository, and the operator
    # had to know to hand-delete /etc/boma/vaultwarden/restic-password.
    log_info "initialising restic repository"
    restic init || die "restic init failed for ${RESTIC_REPOSITORY}.
Nothing was written to ${VW_CONFIG_DIR}; fix the repository or credentials and re-run."

    # Promoted IMMEDIATELY after init, before the key adds. The repository now
    # exists under this password, and $STAGING is removed by the EXIT trap — so
    # a failing `restic key add` would otherwise destroy the only copy of the
    # password to a live repository, leaving it permanently unreachable.
    promote_restic_config
    export RESTIC_PASSWORD_FILE="$VW_RESTIC_PASSWORD_FILE"

    # Two further passwords for the same repository. `restic key add` re-wraps
    # the SAME master key, so this is instant and re-encrypts nothing.
    # See docs/adr/0002-three-restic-repository-passwords.md
    local keydir="${STAGING}/keys"
    mkdir -p "$keydir"
    chmod 0700 "$keydir"

    RECOVERY_PASSPHRASE="$(generate_passphrase 10 5)"
    FAMILY_PASSPHRASE="$(generate_passphrase 10 5)"
    printf '%s' "$RECOVERY_PASSPHRASE" >"${keydir}/recovery"
    printf '%s' "$FAMILY_PASSPHRASE"   >"${keydir}/family"
    chmod 0600 "${keydir}/recovery" "${keydir}/family"

    restic key add --host "$(hostname)" --user recovery \
        --new-password-file "${keydir}/recovery" >/dev/null \
        || die "could not add the recovery key to the restic repository"
    restic key add --host "$(hostname)" --user family \
        --new-password-file "${keydir}/family" >/dev/null \
        || die "could not add the family key to the restic repository"

    rm -rf "$keydir"
    RESTIC_KEYS_CREATED=1
}

# promote_restic_config — publish the verified candidate settings to /etc.
promote_restic_config() {
    install -m 0600 -o root -g root "${STAGING}/restic.env.candidate" "$VW_RESTIC_ENV"
    install -m 0600 -o root -g root "${STAGING}/restic-password.candidate" "$VW_RESTIC_PASSWORD_FILE"
}
RESTIC_KEYS_CREATED=0
setup_restic

# ---------------------------------------------------------------------------
# Activate the new build
# ---------------------------------------------------------------------------
# Deliberately AFTER SMTP verification and restic setup. Swapping the binary
# first meant a die() in either of those left a half-upgraded host: the vault
# kept serving the old binary from its open inode while installed-version
# already named the new one, so the rollback point was never applied and the
# untested binary was silently activated at the next reboot.
# When install.sh is used to UPGRADE an existing host — a documented use — it
# must take the same rollback point update.sh does. Vaultwarden's migrations are
# forward-only (ADR 0004), so a new binary that starts, migrates the schema and
# then fails leaves the old binary unable to read its own database. Without a
# pre-upgrade snapshot the only way back is a manual restic restore.
PREVIOUS_VERSION="$(vw_installed_version)"
if [[ -n "$PREVIOUS_VERSION" && "$PREVIOUS_VERSION" != "$VW_VERSION" \
      && -x "${VW_BIN_DIR}/vaultwarden" ]]; then
    log_info "upgrading ${PREVIOUS_VERSION} -> ${VW_VERSION}; taking a rollback point"
    UPGRADE_ROLLBACK_DIR="${VW_INSTALL_DIR}/rollback"
    vw_capture_rollback_point "$PREVIOUS_VERSION" "$UPGRADE_ROLLBACK_DIR"
    log_info "rollback point saved at ${UPGRADE_ROLLBACK_DIR}"
fi

install -m 0755 -o root -g root "${STAGING}/vaultwarden" "${VW_BIN_DIR}/vaultwarden"

# Written only now. Stamping it earlier meant PREVIOUS_VERSION below read the
# NEW version, so no rollback point was ever taken on an upgrade.
printf '%s\n' "$VW_VERSION" | atomic_write "$VW_VERSION_FILE" 0644

rm -rf "${VW_WEB_VAULT_DIR}.new"
cp -a "${STAGING}/web-vault" "${VW_WEB_VAULT_DIR}.new"
rm -rf "${VW_WEB_VAULT_DIR}.old"
[[ -d "$VW_WEB_VAULT_DIR" ]] && mv "$VW_WEB_VAULT_DIR" "${VW_WEB_VAULT_DIR}.old"
mv "${VW_WEB_VAULT_DIR}.new" "$VW_WEB_VAULT_DIR"
# The previous web vault is KEPT until the health check passes. Deleting it
# here left the rollback path below able to restore the binary and database but
# not the UI, so a rolled-back host served a mismatched web vault it could no
# longer replace.
chown -R root:root "$VW_WEB_VAULT_DIR"


# ---------------------------------------------------------------------------
# systemd units
# ---------------------------------------------------------------------------
log_info "installing systemd units"
# The units are templates. They previously hardcoded /opt/boma/vaultwarden and
# /var/lib/boma/*, while the library advertises VW_INSTALL_DIR / VW_DATA_DIR /
# VW_CONFIG_DIR as overridable — so a non-default VW_DATA_DIR produced a unit
# whose ReadWritePaths pointed somewhere else and, under ProtectSystem=strict,
# the vault could not create its own database.
#
# Only @VW_*@ placeholders are substituted; systemd's own @-prefixed syscall
# group names (e.g. @system-service) are left untouched.
render_unit() {
    sed -e "s|@VW_USER@|${VW_USER}|g" \
        -e "s|@VW_GROUP@|${VW_GROUP}|g" \
        -e "s|@VW_BIN_DIR@|${VW_BIN_DIR}|g" \
        -e "s|@VW_INSTALL_DIR@|${VW_INSTALL_DIR}|g" \
        -e "s|@VW_CONFIG_DIR@|${VW_CONFIG_DIR}|g" \
        -e "s|@VW_APP_ENV@|${VW_APP_ENV}|g" \
        -e "s|@VW_DATA_DIR@|${VW_DATA_DIR}|g" \
        -e "s|@VW_STAGING_BASE@|$(dirname "$VW_STAGING_DIR")|g" \
        -e "s|@VW_SCRATCH_BASE@|${VW_SCRATCH_BASE:-/var/lib/boma/scratch}|g" \
        "$1"
}

for unit in "${VW_SERVICE_DIR}"/systemd/*.service "${VW_SERVICE_DIR}"/systemd/*.timer; do
    rendered="${STAGING}/$(basename "$unit")"
    render_unit "$unit" > "$rendered" || die "could not render $(basename "$unit")"
    if grep -q '@VW_[A-Z_]*@' "$rendered"; then
        die "unsubstituted placeholder left in $(basename "$unit"): $(grep -o '@VW_[A-Z_]*@' "$rendered" | sort -u | tr '\n' ' ')"
    fi
    install -m 0644 -o root -g root "$rendered" "/etc/systemd/system/$(basename "$unit")"
done
systemctl daemon-reload

systemctl enable "$VW_SYSTEMD_UNIT" >/dev/null
systemctl restart "$VW_SYSTEMD_UNIT"

if vw_wait_healthy 90; then
    log_info "vaultwarden is healthy at $(vw_health_url)"
    rm -rf "${VW_WEB_VAULT_DIR}.old"
else
    journalctl -u "$VW_SYSTEMD_UNIT" --no-pager -n 40 >&2 || true
    # Apply the rollback point taken before the swap. Without this, a failed
    # upgrade left the vault DOWN on the broken binary with installed-version
    # already advanced — so update.sh would then report "already up to date"
    # and never retry.
    if [[ -n "${PREVIOUS_VERSION:-}" && -f "${VW_INSTALL_DIR}/rollback/vaultwarden.${PREVIOUS_VERSION}" ]]; then
        log_warn "upgrade failed; rolling back to ${PREVIOUS_VERSION}"
        rb_outcome="$(vw_rollback_to "$PREVIOUS_VERSION" "${VW_INSTALL_DIR}/rollback")"
        case "$rb_outcome" in
            healthy)
                notify error "Vaultwarden upgrade rolled back" \
                    "install.sh ${PREVIOUS_VERSION} -> ${VW_VERSION} failed its health check on $(hostname); rolled back and healthy"
                die "upgrade failed and was rolled back to ${PREVIOUS_VERSION}"
                ;;
            incomplete)
                notify error "Vaultwarden rollback INCOMPLETE" \
                    "install.sh ${PREVIOUS_VERSION} -> ${VW_VERSION} failed on $(hostname). The service is answering but the rollback did not fully succeed. Manual verification required."
                die "upgrade failed and the rollback was incomplete"
                ;;
            *)
                notify error "Vaultwarden DOWN after a failed upgrade" \
                    "install.sh ${PREVIOUS_VERSION} -> ${VW_VERSION} failed and the rollback did not restore service on $(hostname). Manual intervention required."
                die "upgrade failed and the rollback did not restore service"
                ;;
        esac
    fi
    die "vaultwarden did not become healthy; see the journal output above"
fi

for timer in boma-vw-backup.timer boma-vw-update.timer boma-vw-verify.timer; do
    if [[ -n "$RESTIC_REPO_ARG" ]] || [[ "$timer" == "boma-vw-update.timer" ]]; then
        systemctl enable --now "$timer" >/dev/null
        log_debug "enabled ${timer}"
    else
        log_warn "not enabling ${timer}: backups are not configured"
    fi
done

# ---------------------------------------------------------------------------
# Secrets the operator must record
# ---------------------------------------------------------------------------
confirm_recorded() {
    local label="$1" expected="$2"
    [[ "$NON_INTERACTIVE" -eq 1 ]] && return 0
    have_tty || { log_warn "no tty: cannot confirm ${label} was recorded"; return 0; }

    local attempt
    for attempt in 1 2 3; do
        printf '\nType the %s back to confirm you saved it: ' "$label" >/dev/tty
        local answer=""
        IFS= read -r answer </dev/tty || true
        if [[ "$answer" == "$expected" ]]; then
            printf 'Confirmed.\n' >/dev/tty
            return 0
        fi
        printf 'That does not match (attempt %d of 3).\n' "$attempt" >/dev/tty
    done
    # Deliberately NOT fatal. Dying here would abort after the repository and
    # both keys already exist, and a re-run takes the "already configured"
    # branch — so the passphrases could never be displayed again. They are on
    # screen right now; the only useful thing to do is say so loudly and let
    # the install finish.
    printf '\n!! %s WAS NOT CONFIRMED — it is shown above and cannot be displayed again.\n' \
        "$(printf '%s' "$label" | tr '[:lower:]' '[:upper:]')" >&2
    # shellcheck disable=SC2016  # backticks here are prose, not substitution
    printf '!! Record it now. See docs/RECOVERY.md for how to replace it with `restic key add`.\n\n' >&2
    return 0
}

# Called unconditionally: the admin token is generated on EVERY first install,
# but this used to run only when a brand-new restic repository was created — so
# attaching to an existing repository (the documented rebuild flow) left the
# admin panel permanently unreachable.
show_passphrases_if_pending
if [[ "$RESTIC_KEYS_CREATED" -eq 1 ]]; then
    confirm_recorded "recovery passphrase" "$RECOVERY_PASSPHRASE"
    confirm_recorded "family passphrase"   "$FAMILY_PASSPHRASE"
fi

INSTALL_COMPLETED=1
log_info "install complete: Vaultwarden ${VW_VERSION} on ${VW_BIND_IP}:${VW_PORT}"
log_info "wardnet must now forward ${VW_DOMAIN} to ${VW_BIND_IP}:${VW_PORT} (see docs/INGRESS.md)"
notify info "Vaultwarden installed" "version ${VW_VERSION} on $(hostname)"
