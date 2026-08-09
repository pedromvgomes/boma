# Recovery runbook

Read this when the vault is unavailable or the host is gone. It is written to be executable by
someone who is **not** the person who set it up.

---

## Part 1 — The Pi is down, vault is unreachable

**You are not locked out.** Bitwarden clients keep an encrypted copy of the vault on each
device, so anyone already signed in can still read their passwords.

Know the limits before you rely on it:

| | Works offline | Notes |
|---|---|---|
| Reading existing items | ✅ | Full access to what was there at last sync |
| Adding or editing items | ❌ | Read-only until the server returns |
| Attachments, sends, imports | ❌ | Require the server |
| **Signing in** | ❌ | **Requires the server** |
| Staying signed in | ⏳ | Offline sessions **expire after 30 days** |

**The two things that will hurt:**

1. **Do not sign out, and do not remove the app.** The local cache is what is keeping you
   working. Signing out during an outage locks you out until the server returns.
2. **An outage longer than 30 days is a full lockout**, because offline sessions expire.

If a device is lost or replaced during an outage, that person cannot sign in until the vault
is back. Restore the service first (Part 2), then onboard the device.

---

## Part 2 — Restoring the vault

### What you need

| Requirement | Where it is |
|---|---|
| A **repository password** | See the table below |
| **Cloudflare account access** | To reach the R2 bucket holding the backups |
| The email account for MFA | To get into Cloudflare if prompted |
| This repository | Public on GitHub |

Any **one** of these three passwords opens the backups:

| Password | Held by | Use when |
|---|---|---|
| **Pi password** | file on the host, `/etc/boma/vaultwarden/restic-password` | the host still exists |
| **Recovery passphrase** | operator's personal cloud account | the host is gone |
| **Family passphrase** | a trusted family member | the operator is unavailable |

You do **not** need all three. You need one, plus Cloudflare access.

### Steps

```bash
# 1. Install restic (Debian/Raspberry Pi OS)
sudo apt-get update && sudo apt-get install -y restic

# 2. Point restic at the backups
export RESTIC_REPOSITORY='s3:<r2-endpoint>/<bucket>'
export AWS_ACCESS_KEY_ID='<r2-access-key>'
export AWS_SECRET_ACCESS_KEY='<r2-secret-key>'
export RESTIC_PASSWORD='<any one of the three passwords>'

# 3. Confirm you can read it, and see what is available
restic snapshots

# 4. Restore the most recent snapshot
restic restore latest --target /tmp/vault-restore
```

If the R2 credentials are lost along with the host, mint new ones in the Cloudflare dashboard.
The credentials only control *access* to the bucket; they play no part in decryption.

### Bringing the service back up

On a fresh host, install the service and then restore data into it:

```bash
# --restic-password-stdin is REQUIRED here. Without it install.sh generates a
# brand-new repository password, which cannot open your existing backups.
printf '%s\n' '<one of the three passwords>' | \
  sudo ./services/vaultwarden/install.sh \
    --domain https://vault.nairobi.my.wardnet.services \
    --admin-email you@example.com \
    --restic-repo 's3:<r2-endpoint>/<bucket>' \
    --r2-access-key '...' --r2-secret-key '...' \
    --restic-password-stdin

sudo ./services/vaultwarden/restore.sh --snapshot latest
```

`--restic-password-stdin` attaches the new host to the **existing** repository:
the password is verified before anything is written, and the recovery and family
passwords already in the repository are left untouched.

`restore.sh --dry-run` shows what would happen without touching anything. Use it first.

---

## Part 3 — What this runbook does NOT cover

**A repository password recovers *data*. It does not grant *administration*.**

The family passphrase lets a family member restore the backups and stand the service back up.
It does **not** make them an administrator of the Vaultwarden organization — they cannot invite
members, manage collections, or reset another person's account.

If the operator is permanently unavailable and no second organization administrator exists, the
family's data is recoverable but the organization cannot be administered.

> **Open item, to be resolved before 1Password is cancelled:** appoint a second organization
> administrator, or configure Vaultwarden Emergency Access. Until then this gap is real.

---

## Part 4 — If a password is compromised

Repository passwords are independently revocable. Losing one does not require re-encrypting
anything or rotating the others.

```bash
restic key list                 # identify the compromised key by ID
restic key remove <id>          # revoke it
restic key add                  # issue a replacement
```

A compromised host leaks only the **Pi password**. Revoke it, issue a new one, and write it to
`/etc/boma/vaultwarden/restic-password`. The recovery and family passphrases are unaffected
because they were never on the host.

### Protecting history from a compromised host

Every repository password grants **write** access, so an attacker who roots the Pi can run
`restic forget --prune` and destroy the backup history. restic cannot prevent this — the
defence has to sit at the storage layer.

**R2 bucket locks** do exactly that, and they apply even to an S3 client holding valid
credentials. The trade-off is that a lock also blocks `restic prune`, so backups must run with
pruning disabled or they will fail:

```bash
# In /etc/boma/vaultwarden/boma.env
VW_NO_PRUNE=1
```

With that set, retention still forgets old snapshots but no repository data is ever deleted, so
the bucket grows over time. For a password vault that is usually the right trade — the data is
small, and an attacker being unable to erase your backups is worth more than reclaimed space.

---

## Part 5 — Verifying this runbook still works

An untested runbook is a guess. Two drills keep it honest:

- **Monthly, automatic.** `verify-backup.sh` restores the newest snapshot and checks the
  database opens. Uses the Pi password. Reports through the notify seam.
- **Quarterly, manual.** Run the same script with the **recovery passphrase** from the cloud
  account:

  ```bash
  sudo ./services/vaultwarden/verify-backup.sh --password-stdin
  ```

  This is the only check that catches a transcription error made when the passphrase was saved.
  A single wrong character stays invisible until the exact moment it is needed.

The family passphrase holder should complete this at least once, so the procedure is known to
work in their hands and not just in principle.
