# Ingress contract — boma ↔ wardnet

boma owns everything up to the listening port. wardnet owns DNS, TLS and the tunnel.
This document is the interface between them. If either side changes, this file changes first.

## What boma guarantees

| Property | Value | Configurable via |
|---|---|---|
| Listen address | `127.0.0.1` | `--bind-ip` |
| Listen port | `8222` | `--port` |
| Protocol | plain HTTP | — |
| Health endpoint | `GET /alive` → `200` | — |

Vaultwarden binds the loopback interface only. Nothing on the LAN can reach it directly, and
unencrypted vault traffic never crosses a network. The tunnel runs on the same host.

## What wardnet must provide

### 1. TLS termination for the public domain

`https://vault.nairobi.my.wardnet.services` terminates at wardnet and is forwarded to
`127.0.0.1:8222`.

### 2. `X-Real-IP` on every forwarded request

Vaultwarden reads the client address from the header named by `IP_HEADER` (set to `X-Real-IP`).

**Why this is not optional:** without it every request appears to originate from `127.0.0.1`.
Vaultwarden's login rate limiting then treats all family members plus any attacker as a single
client — so a brute-force attempt is indistinguishable from normal traffic, and the rate limiter
either blocks everyone or nobody.

wardnet must **overwrite** this header, never pass through a client-supplied value. A trusted
header that a client can set is worse than no header at all, because it lets an attacker forge
a different source IP for every attempt and evade rate limiting entirely.

### 3. WebSocket upgrade pass-through

Since Vaultwarden 1.29 the WebSocket endpoint is served on the same port as HTTP, so this is
one forward, not two. `Upgrade` and `Connection` headers must survive.

**Failure mode if dropped:** nothing errors. Clients fall back to polling and live sync stops
working silently — a change made on a phone simply takes a long time to appear on a laptop.

### 4. Heartbeat monitoring

boma pings wardnet on every successful backup and verification. **wardnet must alert on a
missing ping**, not merely relay the failures boma sends.

**Why boma cannot do this itself:** a failure alert requires something on the host to still be
running in order to send it. A dead Pi, a full disk, or a timer that never fired produce
silence, and silence is indistinguishable from success unless something off-host is watching
for it.

## The `DOMAIN` setting

boma configures Vaultwarden with `DOMAIN=https://vault.nairobi.my.wardnet.services`.

This is **not cosmetic**. It is:

- the **WebAuthn relying-party ID** — passkeys and hardware keys are cryptographically bound to
  it. If it is wrong, or left at its default, passkey registration and login fail with errors
  that do not mention the domain.
- the base URL for **invitation and password-reset emails**. Wrong value ⇒ family members
  receive invitation links that lead nowhere.

Changing `DOMAIN` after users have registered passkeys **invalidates those passkeys**. Treat it
as fixed once the family is onboarded.

## Verifying the contract

From the host:

```bash
curl -fsS http://127.0.0.1:8222/alive          # boma's side
```

From a client device, through wardnet:

```bash
curl -fsS https://vault.nairobi.my.wardnet.services/alive
```

To confirm `X-Real-IP` survives the tunnel, attempt a failed login from a device and check the
recorded address is that device, not `127.0.0.1`:

```bash
journalctl -u vaultwarden --no-pager | grep -i 'username or password'
```
