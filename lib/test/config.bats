#!/usr/bin/env bats
# Unit tests for load_config in lib/boma.sh.
#
# These files are read as root by systemd timers, so the parser is a security
# boundary, not a convenience.

setup() {
    BOMA_LIB_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export BOMA_LIB_DIR
    . "${BOMA_LIB_DIR}/boma.sh"
    TESTDIR="$(mktemp -d)"
}

teardown() {
    [ -n "${TESTDIR:-}" ] && rm -rf "$TESTDIR"
}

@test "load_config reads simple assignments" {
    printf 'FOO=bar\nBAZ=qux\n' > "$TESTDIR/c.env"
    load_config "$TESTDIR/c.env"
    [ "$FOO" = "bar" ]
    [ "$BAZ" = "qux" ]
}

@test "load_config ignores comments and blank lines" {
    printf '# a comment\n\n  \nFOO=bar\n' > "$TESTDIR/c.env"
    load_config "$TESTDIR/c.env"
    [ "$FOO" = "bar" ]
}

@test "load_config strips surrounding single quotes" {
    printf "FOO='bar baz'\n" > "$TESTDIR/c.env"
    load_config "$TESTDIR/c.env"
    [ "$FOO" = "bar baz" ]
}

@test "load_config strips surrounding double quotes" {
    printf 'FOO="bar baz"\n' > "$TESTDIR/c.env"
    load_config "$TESTDIR/c.env"
    [ "$FOO" = "bar baz" ]
}

@test "load_config keeps values containing an equals sign intact" {
    printf 'URL=https://h/p?a=1&b=2\n' > "$TESTDIR/c.env"
    load_config "$TESTDIR/c.env"
    [ "$URL" = "https://h/p?a=1&b=2" ]
}

@test "load_config does NOT execute command substitution" {
    # The file is parsed, never sourced. Sourcing would run this as root.
    printf 'FOO=$(touch %s/pwned)\n' "$TESTDIR" > "$TESTDIR/c.env"
    run load_config "$TESTDIR/c.env"
    [ ! -e "$TESTDIR/pwned" ] || {
        echo "command substitution executed — the config file was sourced"
        return 1
    }
}

@test "load_config does NOT execute a semicolon-separated command" {
    # Regression guard: a blacklist of \$( , backtick and \${ misses this
    # entirely, which is why the parser replaced the blacklist.
    printf 'URL=https://h/p;touch %s/pwned\n' "$TESTDIR" > "$TESTDIR/c.env"
    run load_config "$TESTDIR/c.env"
    [ ! -e "$TESTDIR/pwned" ] || {
        echo "semicolon-separated command executed as a side effect of loading config"
        return 1
    }
}

@test "load_config does NOT execute backtick substitution" {
    printf 'FOO=`touch %s/pwned`\n' "$TESTDIR" > "$TESTDIR/c.env"
    run load_config "$TESTDIR/c.env"
    [ ! -e "$TESTDIR/pwned" ]
}

@test "load_config tolerates a value with spaces instead of aborting" {
    # Sourcing made an unquoted space run a command; under `set -e` that killed
    # the nightly backup before restic ever ran.
    printf 'NOTE=hello world from boma\n' > "$TESTDIR/c.env"
    run load_config "$TESTDIR/c.env"
    [ "$status" -eq 0 ]
}

@test "load_config rejects a malformed line" {
    printf 'this is not an assignment\n' > "$TESTDIR/c.env"
    run load_config "$TESTDIR/c.env"
    [ "$status" -ne 0 ]
}

@test "load_config rejects an unreadable file" {
    run load_config "$TESTDIR/does-not-exist.env"
    [ "$status" -ne 0 ]
}

@test "load_config exports values to child processes" {
    printf 'EXPORTED_VAL=yes\n' > "$TESTDIR/c.env"
    load_config "$TESTDIR/c.env"
    [ "$(bash -c 'printf %s "$EXPORTED_VAL"')" = "yes" ]
}
