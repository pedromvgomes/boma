# Updates soak for 3 days, then apply unattended with transactional rollback

This is a family vault: leaving it unpatched is a security problem, but a bad unattended update
locks several people out of every password they own. So updates apply automatically, but only
once a release is at least `SOAK_DAYS` (default 3) old, giving upstream regressions time to
surface for other users first.

## Rollback restores the database, not just the binary

Vaultwarden runs **forward-only** SQLite migrations at startup. If an update migrates the
schema and then fails its health check, swapping the old binary back leaves it facing a schema
it cannot read — so a binary-only rollback would turn a failed update into an outage.

Every update therefore takes a snapshot first and, on failure, restores **both** the binary and
the database. The pre-update snapshot is part of the update transaction, not a nice-to-have.

## Rejected: parsing release notes to fast-track security fixes

Tempting, but it makes the vault's patch latency depend on string-matching upstream prose. A
formatting change upstream would silently break it in whichever direction is worse. Instead
`update.sh --force` bypasses the soak for a human who has read the advisory.

## Consequences

- Security fixes are delayed by up to `SOAK_DAYS` unless applied by hand.
- A health check that returns `200` is the definition of success, so breakage subtler than
  "the process is up and serving" will not trigger a rollback.
