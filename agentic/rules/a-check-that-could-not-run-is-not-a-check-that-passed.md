---
description: Distinguish "verification failed" from "verification was impossible", and never assert a property the environment cannot actually enforce.
---

# A check that could not run is not a check that passed

Two failures of this kind have already cost this repository real outages, and both classes
recur whenever a new check is added.

**Unverifiable is not verified.** `gh attestation verify` exits 4 without credentials,
having checked nothing. Treating that as a failure bricked every install and every unattended
update on a fresh Pi, which has no authenticated `gh`. Probe capability first — as
`vw_attestation_possible()` does — then branch three ways: matched (continue), mismatched
(**abort**), impossible (**warn and continue**, unless the operator opted in to
`VW_REQUIRE_ATTESTATION=1`). Any new authenticity or integrity check owes the same three
outcomes.

**A test that cannot observe the property must not assert it.** Under rootless podman,
`ProtectSystem=strict` and `ProtectHome=yes` are silently ignored while the unit still
reports success. A runtime assertion would pass vacuously and imply the Pi is protected when
nothing was verified — worse than no test. `test_hardening.py` parses the unit with
`systemd-analyze security` instead, which scores identically in a container and on the host.

When the environment cannot enforce what you want to assert, assert something the environment
can actually decide, or say out loud that the check did not run.
