#!/usr/bin/env bash
# Filesystem and secret-generation helpers.

[[ -n "${_BOMA_UTIL_SH:-}" ]] && return 0
_BOMA_UTIL_SH=1

# shellcheck source=lib/log.sh
. "${BOMA_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/log.sh"

# ensure_dir <path> [mode] [owner]
ensure_dir() {
    local path="$1" mode="${2:-0755}" owner="${3:-}"
    [[ -d "$path" ]] || mkdir -p "$path"
    chmod "$mode" "$path"
    [[ -n "$owner" ]] && chown "$owner" "$path"
    return 0
}

# ensure_dir_if_missing <path> [mode] [owner]
#
# Creates the directory only when absent and never touches an existing one.
# Distinct from ensure_dir, which ENFORCES the mode every call: applying a
# default 0755 to a directory a caller had deliberately created 0700 silently
# widened it. Several call sites were hand-patching `[[ -d x ]] || ensure_dir x`
# to work around that; this is that pattern, named.
ensure_dir_if_missing() {
    local path="$1"
    [[ -d "$path" ]] && return 0
    ensure_dir "$@"
}

# atomic_write <path> [mode] [owner]  — content on stdin.
#
# Writes to a temp file in the same directory and renames, so a reader never
# observes a half-written file and an interrupted write cannot destroy the
# previous contents. Permissions are applied BEFORE the rename so the file is
# never briefly world-readable — which matters because these hold secrets.
atomic_write() {
    local path="$1" mode="${2:-0644}" owner="${3:-}"
    local dir tmp
    dir=$(dirname "$path")
    # Create the parent only when missing, and never re-apply a mode to an
    # existing one: writing a file must not relax the permissions of the
    # directory holding it. Doing so silently widened the secrets directory
    # from 0750 to 0755 on every write.
    ensure_dir_if_missing "$dir" 0750
    tmp=$(mktemp "${dir}/.$(basename "$path").XXXXXX") \
        || die "could not create temporary file in $dir"

    # Cleanup is explicit rather than a RETURN trap. A RETURN trap would both
    # clobber any trap the caller had installed AND fail to fire on the die()
    # paths below, since die() exits rather than returning — so it cleaned up
    # in exactly the cases that did not need it and not in the ones that did.
    _atomic_fail() {
        rm -f "$tmp"
        die "$1"
    }

    cat >"$tmp" || _atomic_fail "failed writing to $tmp"
    chmod "$mode" "$tmp" || _atomic_fail "failed setting mode $mode on $tmp"
    if [[ -n "$owner" ]]; then
        chown "$owner" "$tmp" || _atomic_fail "failed setting owner $owner on $tmp"
    fi
    mv -f "$tmp" "$path" || _atomic_fail "failed moving $tmp to $path"
    return 0
}

# generate_passphrase [groups] [group-size]
#
# Produces e.g. "hk3mq-rv7tp-..." for secrets a human must transcribe into a
# password manager. Two deliberate choices:
#
#   * The alphabet excludes 0/O/1/l/I. A transcription error in a recovery
#     passphrase stays invisible until the moment it is needed, so ambiguous
#     glyphs are removed rather than merely warned about.
#   * Hyphenated groups make manual copying and verification far less error-prone.
#
# Default 8 groups of 5 from a 32-character alphabet is 40 chars ≈ 200 bits.
generate_passphrase() {
    local groups="${1:-8}" size="${2:-5}"
    local alphabet='abcdefghjkmnpqrstuvwxyz23456789'
    local total=$(( groups * size ))
    local raw out=''

    # `head -c` closes the pipe as soon as it has enough, which kills `tr` with
    # SIGPIPE (exit 141). Under `set -o pipefail` that would fail the pipeline
    # even though the read succeeded, so pipefail is disabled for this subshell
    # and the result is validated by length instead.
    raw=$(set +o pipefail; LC_ALL=C tr -dc "$alphabet" </dev/urandom 2>/dev/null | head -c "$total")
    [[ ${#raw} -eq $total ]] \
        || die "could not read ${total} random characters from /dev/urandom (got ${#raw})"

    local i
    for (( i = 0; i < groups; i++ )); do
        [[ -n "$out" ]] && out+='-'
        out+="${raw:i*size:size}"
    done
    printf '%s' "$out"
}

# generate_token [bytes] — opaque high-entropy token for machine use only.
generate_token() {
    local bytes="${1:-32}" raw
    # See generate_passphrase for why pipefail is disabled here.
    raw=$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$bytes")
    [[ ${#raw} -eq $bytes ]] \
        || die "could not read ${bytes} random characters from /dev/urandom (got ${#raw})"
    printf '%s' "$raw"
}

# have_tty — true when an interactive terminal can actually be opened.
#
# `[[ -r /dev/tty ]]` is NOT sufficient: inside a container the device node
# exists and tests as readable, but opening it fails with ENXIO. Only an actual
# open attempt distinguishes the two, and getting this wrong means a
# confirmation prompt is silently skipped.
have_tty() {
    { : </dev/tty; } 2>/dev/null
}

# require_file_mode <path> <expected-octal>
# Fails closed if a secret file is more permissive than expected.
require_file_mode() {
    local path="$1" expected="$2" actual
    [[ -e "$path" ]] || die "expected file not found: $path"
    actual=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null) \
        || die "could not stat $path"
    if [[ "$actual" != "$expected" ]]; then
        die "$path has mode $actual, expected $expected"
    fi
}
