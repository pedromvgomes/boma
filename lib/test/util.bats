#!/usr/bin/env bats
# Unit tests for lib/util.sh — atomic writes and secret generation.

setup() {
    BOMA_LIB_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export BOMA_LIB_DIR
    . "${BOMA_LIB_DIR}/util.sh"
    TESTDIR="$(mktemp -d)"
}

teardown() {
    [ -n "${TESTDIR:-}" ] && rm -rf "$TESTDIR"
}

@test "atomic_write creates a file with the requested content" {
    printf 'hello\n' | atomic_write "$TESTDIR/out.txt"
    [ "$(cat "$TESTDIR/out.txt")" = "hello" ]
}

@test "atomic_write applies the requested mode" {
    printf 'secret\n' | atomic_write "$TESTDIR/secret.txt" 0600
    mode=$(stat -f '%Lp' "$TESTDIR/secret.txt" 2>/dev/null || stat -c '%a' "$TESTDIR/secret.txt")
    [ "$mode" = "600" ]
}

@test "atomic_write leaves no temporary files behind" {
    printf 'x\n' | atomic_write "$TESTDIR/x.txt"
    # Temp files are dotfiles in the target directory; none should survive.
    leftovers=$(find "$TESTDIR" -name '.x.txt.*' | wc -l | tr -d ' ')
    [ "$leftovers" = "0" ]
}

@test "atomic_write replaces existing content rather than appending" {
    printf 'first\n'  | atomic_write "$TESTDIR/f.txt"
    printf 'second\n' | atomic_write "$TESTDIR/f.txt"
    [ "$(cat "$TESTDIR/f.txt")" = "second" ]
}

@test "atomic_write creates the parent directory when absent" {
    printf 'y\n' | atomic_write "$TESTDIR/nested/deep/y.txt"
    [ -f "$TESTDIR/nested/deep/y.txt" ]
}

@test "atomic_write does not relax the permissions of an existing directory" {
    # Regression guard: writing a secret into a 0750 directory must not widen
    # it to 0755. This silently exposed the whole secrets directory.
    mkdir -p "$TESTDIR/secrets"
    chmod 0750 "$TESTDIR/secrets"
    printf 'topsecret\n' | atomic_write "$TESTDIR/secrets/key" 0600

    mode=$(stat -f '%Lp' "$TESTDIR/secrets" 2>/dev/null || stat -c '%a' "$TESTDIR/secrets")
    [ "$mode" = "750" ] || {
        echo "directory mode changed to $mode, expected 750"
        return 1
    }
}

@test "generate_passphrase produces the requested shape" {
    pass=$(generate_passphrase 8 5)
    # 8 groups of 5 plus 7 hyphens.
    [ "${#pass}" -eq 47 ]
    [ "$(printf '%s' "$pass" | tr -cd '-' | wc -c | tr -d ' ')" = "7" ]
}

@test "generate_passphrase honours a custom shape" {
    pass=$(generate_passphrase 4 6)
    [ "${#pass}" -eq 27 ]
}

@test "generate_passphrase excludes visually ambiguous characters" {
    # A transcription error in a recovery passphrase stays invisible until the
    # moment it is needed, so 0/O/1/l/I must never appear.
    for _ in $(seq 1 20); do
        pass=$(generate_passphrase 8 5)
        [[ ! "$pass" =~ [01lIO] ]] || {
            echo "ambiguous character in: $pass"
            return 1
        }
    done
}

@test "generate_passphrase produces a different value each call" {
    a=$(generate_passphrase); b=$(generate_passphrase)
    [ "$a" != "$b" ]
}

@test "secret generation survives 'set -o pipefail'" {
    # Regression guard: `head -c` closes the pipe early, killing `tr` with
    # SIGPIPE. Under pipefail that fails the whole pipeline even though the
    # read succeeded. Every real script runs with pipefail, so generation must
    # be exercised with it enabled.
    run bash -c "
        set -euo pipefail
        . '${BOMA_LIB_DIR}/util.sh'
        generate_passphrase 8 5
        generate_token 32
    "
    [ "$status" -eq 0 ] || {
        echo "generation failed under pipefail: $output"
        return 1
    }
}

@test "generate_token produces the requested length" {
    tok=$(generate_token 32)
    [ "${#tok}" -eq 32 ]
}

@test "generate_token is alphanumeric only" {
    tok=$(generate_token 64)
    [[ "$tok" =~ ^[A-Za-z0-9]+$ ]]
}

@test "require_file_mode accepts a correctly restricted file" {
    printf 'x' | atomic_write "$TESTDIR/ok.txt" 0600
    run require_file_mode "$TESTDIR/ok.txt" 600
    [ "$status" -eq 0 ]
}

@test "require_file_mode rejects an over-permissive secret file" {
    printf 'x' | atomic_write "$TESTDIR/loose.txt" 0644
    run require_file_mode "$TESTDIR/loose.txt" 600
    [ "$status" -ne 0 ]
}

@test "require_file_mode fails when the file is absent" {
    run require_file_mode "$TESTDIR/nope.txt" 600
    [ "$status" -ne 0 ]
}
