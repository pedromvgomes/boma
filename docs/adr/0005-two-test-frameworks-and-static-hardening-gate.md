# Two test frameworks, and hardening gated statically rather than at runtime

Long-term maintainability was prioritised over speed of delivery, which produced two decisions
a future reader would otherwise find odd.

## bats for `lib/`, pytest for end-to-end

`bats-core` tests the pure shell functions in `lib/` — same language as the code under test, no
container required. `pytest` drives the end-to-end suites, where the work is orchestration and
state: bring up a systemd container, install, publish a fake release, inject a failing health
check, assert both binary and database rolled back. Fixtures guarantee teardown so aborted runs
do not leak containers, and parametrization covers all three restic passwords without
duplicated cases.

Using one framework for both was considered. Bash loses badly on the end-to-end cases (weak
failure diagnostics, no data structures for parsing restic's JSON, fragile teardown), and
pytest is clumsy for unit-testing shell functions. We accept **two frameworks and two sets of
CI wiring** as the cost of each layer using the right tool.

## Hardening is verified by `systemd-analyze security`, not by tests

A probe on 2026-08-08 established that under **rootless podman**, `ProtectSystem=strict` and
`ProtectHome=yes` **silently do not apply** — `/usr` and `/root` remained writable while the
unit still reported `success`. systemd cannot set up those mount namespaces without privileges
and skips them without error.

Runtime assertions about hardening would therefore **pass vacuously**, which is worse than no
test: green results would imply the Pi is protected when nothing had been verified. Hardening
is instead gated statically — `systemd-analyze security` parses the unit and is unaffected by
the sandbox. It was confirmed to discriminate correctly (a hardened unit scored 8.7, a
deliberately weak one 9.6), and CI fails if a unit exceeds its pinned exposure threshold.

The probe also showed the initially-planned directives were too thin, so units additionally set
`SystemCallFilter`, `CapabilityBoundingSet`, `RestrictAddressFamilies`, `PrivateDevices`,
`ProtectKernel*`, `RestrictSUIDSGID` and `UMask=0077`.

## Consequence

Everything systemd-related **except** sandbox enforcement is genuinely covered by the container
suite. Actual enforcement is only ever exercised on the real host, so a first deploy should be
followed by `systemd-analyze security vaultwarden.service` there.
