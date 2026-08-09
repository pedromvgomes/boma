#!/usr/bin/env bats
# Unit tests for lib/version.sh — version ordering and soak-window arithmetic.

setup() {
    BOMA_LIB_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export BOMA_LIB_DIR
    . "${BOMA_LIB_DIR}/version.sh"
}

@test "version_normalise strips v prefix and tag namespace" {
    [ "$(version_normalise 'v1.37.1')" = "1.37.1" ]
    [ "$(version_normalise 'vaultwarden/1.37.1')" = "1.37.1" ]
    [ "$(version_normalise '1.37.1')" = "1.37.1" ]
}

@test "version_compare orders equal versions as 0" {
    [ "$(version_compare '1.37.1' '1.37.1')" = "0" ]
}

@test "version_compare treats missing components as zero" {
    [ "$(version_compare '1.37' '1.37.0')" = "0" ]
}

@test "version_compare orders by numeric component, not string" {
    # The bug this guards: string comparison puts "1.9.0" after "1.10.0".
    [ "$(version_compare '1.10.0' '1.9.0')" = "1" ]
    [ "$(version_compare '1.9.0' '1.10.0')" = "-1" ]
}

@test "version_compare does not treat zero-padded components as octal" {
    # 08 and 09 are invalid octal; arithmetic without base-10 forcing would error.
    [ "$(version_compare '1.08.0' '1.8.0')" = "0" ]
    [ "$(version_compare '1.09.0' '1.10.0')" = "-1" ]
}

@test "version_compare handles patch releases" {
    [ "$(version_compare '1.37.1' '1.37.0')" = "1" ]
    [ "$(version_compare '1.37.0' '1.37.1')" = "-1" ]
}

@test "version_gt is strict" {
    run version_gt '1.37.1' '1.37.0'; [ "$status" -eq 0 ]
    run version_gt '1.37.0' '1.37.1'; [ "$status" -ne 0 ]
    run version_gt '1.37.1' '1.37.1'; [ "$status" -ne 0 ]
}

@test "iso8601_to_epoch parses a UTC timestamp" {
    [ "$(iso8601_to_epoch '1970-01-01T00:00:00Z')" = "0" ]
    [ "$(iso8601_to_epoch '2026-08-01T00:00:00Z')" = "1785542400" ]
}

@test "iso8601_to_epoch fails on garbage rather than returning a wrong number" {
    run iso8601_to_epoch 'not-a-timestamp'
    [ "$status" -ne 0 ]
}

@test "age_days computes whole elapsed days against an injected now" {
    # 2026-08-01 plus 3 days exactly.
    [ "$(age_days '2026-08-01T00:00:00Z' 1785801600)" = "3" ]
}

@test "age_days floors partial days" {
    # 3 days minus one second is still 2 whole days.
    [ "$(age_days '2026-08-01T00:00:00Z' 1785801599)" = "2" ]
}

@test "age_days clamps future timestamps to zero" {
    # Clock skew must never make a release look OLDER than it is, because that
    # would let an unsoaked release install unattended.
    [ "$(age_days '2026-08-01T00:00:00Z' 1785542000)" = "0" ]
}

@test "soak_satisfied is true only once the soak window has fully elapsed" {
    run soak_satisfied '2026-08-01T00:00:00Z' 3 1785801600   # exactly 3 days
    [ "$status" -eq 0 ]
    run soak_satisfied '2026-08-01T00:00:00Z' 3 1785801599   # one second short
    [ "$status" -ne 0 ]
}

@test "soak_satisfied rejects a release published in the future" {
    run soak_satisfied '2026-08-01T00:00:00Z' 3 1785542000
    [ "$status" -ne 0 ]
}
