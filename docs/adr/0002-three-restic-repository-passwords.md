# Three restic repository passwords, none memorized

Backups are encrypted by restic, so whoever holds a repository password can read the family's
entire vault — and whoever holds none can read nothing, ever. restic supports multiple
passwords per repository, so we issue three independent ones instead of choosing a single
custodian.

| Password | Held where | Purpose |
|---|---|---|
| **Pi password** | random, `0600` on the host | unattended nightly backups |
| **Recovery passphrase** | random, in the operator's personal cloud account | disaster recovery |
| **Family passphrase** | random, with a trusted family member | operator unavailable |

Total loss requires all three to be unavailable at once.

## Why not a memorized master password

The original design had the operator memorize a passphrase. It was dropped once it became clear
the password is only ever needed for disaster recovery — the host uses its own password file
for nightly backups. A secret typed perhaps twice a year is one that gets forgotten, and a
machine-generated passphrase has far more entropy than any memorable one.

This also removed an entire layer: an earlier design derived the key with argon2id from a
memorized password, which required pinning KDF parameters in the repository forever. restic
performs its own KDF, so that machinery was unnecessary.

## Why key and ciphertext live with different providers

The backups sit in Cloudflare R2, so no repository password may be stored in Cloudflare. This
specifically rules out Cloudflare Secrets Store — which is doubly unsuitable, since secrets
there cannot be read back after creation at all.

## Consequences

- **Adding a fourth holder is instant.** `restic key add` re-wraps the same master key; no data
  is re-encrypted regardless of repository size.
- **Revocation is independent.** A compromised host leaks only the Pi password;
  `restic key remove` revokes it without disturbing the others.
- **Key files live inside the repository**, so leaked R2 credentials permit an offline attack
  against scrypt. Mitigated by all passwords being machine-generated at full entropy.
- **Every restic password grants write access**, so a compromised host could destroy history
  with `forget --prune`. restic cannot prevent this. The mitigation is an **R2 bucket lock**,
  which does apply to S3 API clients holding valid credentials — verified against Cloudflare's
  documentation: locks "prevent the deletion and overwriting of objects in an R2 bucket for a
  specified period — or indefinitely", and "a bucket cannot be emptied while any bucket lock
  rules are configured".

  **The catch, which forces a choice:** a bucket lock also forbids `restic prune`, because
  pruning deletes and rewrites pack files. Nightly backups run `forget --prune`, so simply
  enabling a lock would fail every backup. Two supported configurations therefore exist:

  | | Ransomware protection | Repository size |
  |---|---|---|
  | **No bucket lock** (default) | none — a rooted host can erase history | bounded by retention |
  | **Bucket lock + `--no-prune`** | a rooted host cannot destroy backups | grows indefinitely |

  `backup.sh --no-prune` (or `VW_NO_PRUNE=1`) applies retention to snapshot metadata only and
  never deletes repository data, which is what makes the locked configuration usable. Given a
  vault's small size, unbounded growth is usually the better trade.
- A repository password recovers **data, not administration**. Family access to the vault's
  *organization* is a separate, unsolved problem.
