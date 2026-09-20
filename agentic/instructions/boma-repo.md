---
description: What boma is, how to build and test it, and the boundaries an agent works inside. Scoped to the boma repository — no shared stack should list it.
---

# boma

Bare-metal deployment scripts for self-hosted services on Debian / Raspberry Pi OS —
install, update, backup, restore — driven by systemd units and timers. No Docker, no
configuration-management tool: a service is a directory of shell scripts plus the units
that run them. "Boma" is Swahili for the fenced homestead where everything lives.

These scripts run as **root on a host that holds a family password vault**. A mistake here
is not a failed build; it is an unbootable Pi or a lost vault. Read before you write.

Start with [README.md](README.md) for what the repo ships, [CONTEXT.md](CONTEXT.md) for the
canonical vocabulary — **Service**, **Host**, **Ingress contract**, **Restic repository**,
**Repository password**, **Soak period**, **Drill**, **Notify seam**, **Heartbeat** — and
[PLATFORM.md](PLATFORM.md) for the single platform every script targets. Terms in `CONTEXT.md`
mean exactly what it says they mean; a wrong synonym reads as a misunderstanding.

`docs/adr/` holds the decisions that constrain the code. Consult it before re-opening one.

## Rules

This repository has prescriptive rules in `agentic/rules/`. **Read every file in that
directory before making changes here, and follow each rule strictly.** One rule per file,
kebab-case filename matching the rule's intent; new rules go there too.

## Where the detail is

This file is the map. Every deep narrative lives in `agentic/references/`, one file per
concern, and is read **on demand** — open the one that governs what you are about to change,
before you change it.

| Read | When you are changing |
|---|---|
| [`layout.md`](agentic/references/layout.md) | anything — the annotated tree, and which reference governs each path |
| [`shell-library.md`](agentic/references/shell-library.md) | `lib/**`, or any script that sources it — the seams, and the invariants they exist to hold |
| [`vaultwarden-service.md`](agentic/references/vaultwarden-service.md) | `services/vaultwarden/**` — install, update, backup, restore, the drill, and the rollback contract |
| [`testing.md`](agentic/references/testing.md) | `lib/test/**`, `services/*/test/**`, `pyproject.toml`, or anything you need to prove works |
| [`ci.md`](agentic/references/ci.md) | `.github/workflows/**`, `.gt-repo.yaml`, or reasoning about what blocks a merge |

## Commands

```sh
shellcheck -x -S style lib/*.sh services/*/*.sh   # lint — must be clean before a PR
bats lib/test/                                    # shell unit tests
uv run --group test pytest services/ -q           # end-to-end, in a systemd container
```

The end-to-end suite needs podman and takes minutes; see
[`testing.md`](agentic/references/testing.md) before reaching for it.

## Boundaries

- **Always:** run shellcheck and `bats lib/test/` before proposing a PR, and the pytest
  suite when you touched anything under `services/`.
- **Ask first:** changing the target platform, the installed paths under `/etc`, `/opt` or
  `/var/lib`, the unit or timer names, the restic repository layout, or the retention policy.
- **Never:** run an install, update, backup or restore script against a real host from a
  session; commit a secret, a passphrase or a `.env`; weaken the platform assertion; or
  reach a notification provider from anywhere but the notify seam.

## Worktrees

This repo uses a bare-repo + typed-worktree layout managed by the `gt` CLI — one session,
one `gt wt add <type/name>` worktree; never use raw `git worktree` or edit inside `.bare/`.
