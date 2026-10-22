#!/usr/bin/env python3
"""Make sure both App IDs can receive push and use Sign in with Apple.

The signed bundle only carries an entitlement if the App ID behind it has the
capability enabled. When it does not, the build still succeeds, the app still
installs, and then: push registration fails with error 3000 and Sign in with Apple
fails before it reaches the network. Both look like product bugs and neither is.

This checks the two capabilities and enables them when they are missing. It is
idempotent, so it can run before every release.

Environment: KEY_ID, ISSUER_ID, PRIVATE_KEY (as for testflight_builds.py),
optional BUNDLE_IDS (comma separated).
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

import testflight_builds as asc

API = asc.API
WANTED = {
    "PUSH_NOTIFICATIONS": "push notifications",
    "APPLE_ID_AUTH": "Sign in with Apple",
}


def request(method: str, path: str, token: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:400]
        raise SystemExit(f"::error::{method} {path} failed: {error.code} {detail}")


def main() -> int:
    key_id = os.environ.get("KEY_ID", "")
    issuer = os.environ.get("ISSUER_ID", "")
    private_key = os.environ.get("PRIVATE_KEY", "")
    if not (key_id and issuer and private_key):
        print("::error::KEY_ID, ISSUER_ID and PRIVATE_KEY are required", file=sys.stderr)
        return 1

    bundle_ids = [value.strip() for value in os.environ.get("BUNDLE_IDS", "").split(",") if value.strip()]
    if not bundle_ids:
        bundle_ids = ["com.vkapps.wifisecurecall", "com.vkapps.wifisecurecall.watchkitapp"]

    token = asc.token(key_id, issuer, asc.pem_from_secret(private_key))
    response = request("GET", "/v1/bundleIds?limit=200", token)
    known = {item["attributes"]["identifier"]: item["id"] for item in response.get("data", [])}

    failures = 0
    for identifier in bundle_ids:
        bundle_id = known.get(identifier)
        if not bundle_id:
            print(f"::error::App ID {identifier} was not found for this team.")
            failures += 1
            continue

        capabilities = request("GET", f"/v1/bundleIds/{bundle_id}/bundleIdCapabilities?limit=200", token)
        enabled = {
            entry["attributes"]["capabilityType"]
            for entry in capabilities.get("data", [])
        }
        missing = {name: label for name, label in WANTED.items() if name not in enabled}
        print(f"{identifier}: enabled={sorted(enabled)}")

        for name, label in missing.items():
            request(
                "POST",
                "/v1/bundleIdCapabilities",
                token,
                {"data": {"type": "bundleIdCapabilities", "attributes": {"capabilityType": name},
                          "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}}}}},
            )
            print(f"{identifier}: enabled {label} ({name})")

        after = request("GET", f"/v1/bundleIds/{bundle_id}/bundleIdCapabilities?limit=200", token)
        now = {entry["attributes"]["capabilityType"] for entry in after.get("data", [])}
        still = [label for name, label in WANTED.items() if name not in now]
        if still:
            print(f"::error::{identifier} is still missing: {', '.join(still)}")
            failures += 1
        else:
            print(f"{identifier}: push and Sign in with Apple are enabled")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
