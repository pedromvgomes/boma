# Context — glossary

Canonical vocabulary for this repository. Terms here mean exactly this and nothing else.
This file is a glossary, not a specification: no implementation details, no decisions.
Decisions live in `docs/adr/`.

## boma

The whole system: the collection of scripts, systemd units and build workflows that run the
homelab on bare metal. Swahili for the fenced homestead where everything lives.

## Service

One self-hosted application managed by boma, with its own directory under `services/`, its own
scripts, systemd units, configuration and tests. `vaultwarden` is the first. A service is
self-contained: adding one adds a directory and changes nothing else.

## Host

The single Raspberry Pi that runs the services. See `PLATFORM.md`.

## wardnet

A separate system, outside this repository, that owns public DNS, TLS certificates, and the
tunnel that carries outside traffic to the host. boma never issues certificates.

## Ingress contract

The agreed boundary between boma and wardnet: the address and port a service listens on, the
headers wardnet must set, and the public domain the service is told to believe it has.
Written down in `docs/INGRESS.md` so neither side has to guess.

## Vault

The Vaultwarden instance and its data: user accounts, the family organization, collections,
items, attachments and sends.

## Restic repository

The encrypted, deduplicated backup store held in Cloudflare R2. It contains all snapshots and
the key files that unwrap them. There is exactly one per service.

## Snapshot

One point-in-time backup inside the restic repository.

## Repository password

A password that unwraps the restic repository's master key. Several exist; any one of them
opens the repository. Three are in use:

- **Pi password** — random, stored on the host, used by unattended backups.
- **Recovery passphrase** — random, held in a personal cloud account, used for disaster recovery.
- **Family passphrase** — random, held by a trusted family member, used when the operator is
  unavailable.

A repository password is *not* a Vaultwarden account password. The two never overlap.

## Soak period

The minimum age a built release must reach before unattended updates will install it. It buys
time for upstream regressions to surface elsewhere first.

## Drill

A deliberate rehearsal that proves recovery works. The *automated drill* restores the newest
snapshot and verifies the database opens. The *manual drill* additionally proves that a
human-held passphrase still unwraps the repository.

A backup that has never been restored is not a backup. Drills are what make the difference.

## Notify seam

The single function every script calls to reach the operator. Its backend is configurable;
wardnet's admin app is the default. Scripts never talk to a notification provider directly.

## Heartbeat

A periodic "I am alive" signal from the host. Distinct from a failure alert: only a heartbeat
can reveal a host that is dead or a timer that never fired, because a failure alert requires
something to still be running in order to send it.
