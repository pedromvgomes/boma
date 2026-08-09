# TLS and ingress are owned by wardnet, not boma

wardnet already issues Let's Encrypt certificates, manages dynamic DNS, and runs a tunnel.
Duplicating any of that in boma would mean two systems competing for the same certificates. So
Vaultwarden binds `127.0.0.1:8222` in plain HTTP and wardnet owns everything outside that port.

Because "assumed to be handled elsewhere" is how integrations silently break, the boundary is
written down as a contract in `docs/INGRESS.md` rather than left implicit.

## Consequences

Three obligations land on boma's side of the seam and are easy to miss:

- **`DOMAIN` must be set correctly.** It is the WebAuthn relying-party ID, so a wrong value
  breaks passkeys, and changing it later invalidates every passkey already registered.
- **`IP_HEADER=X-Real-IP`**, which wardnet must overwrite rather than pass through. Without it
  every request appears to come from `127.0.0.1` and login rate limiting is meaningless.
- **A heartbeat is required from wardnet.** boma can report its own failures but cannot report
  its own death; only an off-host watcher can distinguish silence from success.
