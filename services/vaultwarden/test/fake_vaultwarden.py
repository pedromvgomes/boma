#!/usr/bin/env python3
"""Stand-in for the Vaultwarden binary, used by the end-to-end suite.

These tests exercise *boma's orchestration* — install, update, rollback, backup,
restore, drill — not Vaultwarden itself. Building the real binary takes ~15
minutes of CI and requires a published release, so the suite runs against a
stand-in that reproduces the behaviour boma actually depends on:

  * creates and owns a SQLite database with the tables the drill checks
  * serves ``GET /alive`` so health checks are real HTTP, not simulated
  * records its own version in the database, so a rollback that restores the
    binary but not the database is DETECTABLE — that being the exact bug the
    transactional-rollback design exists to prevent

``BOMA_FAKE_VW_CRASH=1`` makes it exit non-zero at startup, so the tests can
drive the failure paths.
"""

from __future__ import annotations

import os
import sqlite3
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

VERSION = "__VERSION__"  # substituted when the fake release is assembled

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    uuid TEXT PRIMARY KEY, email TEXT NOT NULL, name TEXT
);
CREATE TABLE IF NOT EXISTS ciphers (
    uuid TEXT PRIMARY KEY, user_uuid TEXT, data TEXT
);
CREATE TABLE IF NOT EXISTS organizations (
    uuid TEXT PRIMARY KEY, name TEXT
);
CREATE TABLE IF NOT EXISTS devices (
    uuid TEXT PRIMARY KEY, user_uuid TEXT
);
-- Not a Vaultwarden table. It records which binary last opened this database,
-- which is what lets a test tell "binary rolled back" apart from "binary AND
-- database rolled back".
CREATE TABLE IF NOT EXISTS boma_marker (
    id INTEGER PRIMARY KEY CHECK (id = 1), version TEXT NOT NULL
);
"""


def init_database(path: str) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.executescript(SCHEMA)
        # Seed a user so restore drills have something to assert on; a vault
        # with zero users must be treated as an empty backup, not a pass.
        conn.execute(
            "INSERT OR IGNORE INTO users (uuid, email, name) VALUES (?, ?, ?)",
            ("seed-user-0001", "family@example.test", "Seed User"),
        )
        conn.execute(
            "INSERT OR IGNORE INTO ciphers (uuid, user_uuid, data) VALUES (?, ?, ?)",
            ("seed-cipher-0001", "seed-user-0001", "{}"),
        )
        # Written on every start: an older binary re-opening a newer database
        # would overwrite this, so the tests assert on it after a rollback.
        conn.execute(
            "INSERT INTO boma_marker (id, version) VALUES (1, ?) "
            "ON CONFLICT(id) DO UPDATE SET version = excluded.version",
            (VERSION,),
        )
        conn.commit()
    finally:
        conn.close()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        if self.path == "/alive":
            body = VERSION.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write("fake-vaultwarden: " + (fmt % args) + "\n")


def main() -> int:
    if "--version" in sys.argv:
        print(f"vaultwarden {VERSION}")
        return 0

    if os.environ.get("BOMA_FAKE_VW_CRASH") == "1":
        sys.stderr.write("fake-vaultwarden: crashing on purpose\n")
        return 1

    data_folder = os.environ.get("DATA_FOLDER", "/var/lib/boma/vaultwarden")
    address = os.environ.get("ROCKET_ADDRESS", "127.0.0.1")
    port = int(os.environ.get("ROCKET_PORT", "8222"))

    os.makedirs(data_folder, exist_ok=True)
    init_database(os.path.join(data_folder, "db.sqlite3"))

    # Real Vaultwarden generates a JWT signing key in DATA_FOLDER on first run.
    # It matters to backups: restoring without it invalidates every client
    # session and push registration, forcing the whole family to sign in again.
    # The stand-in creates one so the drill's RSA-key check is exercised rather
    # than trivially unsatisfiable.
    rsa_key = os.path.join(data_folder, "rsa_key.pem")
    if not os.path.exists(rsa_key):
        with open(rsa_key, "w") as fh:
            fh.write(
                "-----BEGIN PRIVATE KEY-----\n"
                f"fake-jwt-signing-key-for-tests-{VERSION}\n"
                "-----END PRIVATE KEY-----\n"
            )
        os.chmod(rsa_key, 0o600)

    sys.stderr.write(f"fake-vaultwarden {VERSION} listening on {address}:{port}\n")
    sys.stderr.flush()
    HTTPServer((address, port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
