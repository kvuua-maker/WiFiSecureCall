#!/usr/bin/env python3
"""Print the builds App Store Connect holds for this app.

Read-only. It exists so a CI run can be confirmed from the outside: an upload log
proves a file was sent, not that App Store Connect accepted and processed it.

Environment:
    KEY_ID       App Store Connect API key id
    ISSUER_ID    App Store Connect issuer id
    PRIVATE_KEY  contents of AuthKey_<KEY_ID>.p8, with or without PEM markers,
                 or base64 of either
    BUNDLE_ID    defaults to com.vkapps.wifisecurecall
"""

from __future__ import annotations

import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.serialization import load_der_private_key

API = "https://api.appstoreconnect.apple.com"


def pem_from_secret(raw: str) -> bytes:
    """Normalise whatever shape the secret holds into a PKCS#8 PEM."""
    flat = raw.replace("\\n", "\n").strip()
    if "BEGIN" in flat:
        body = "".join(flat.split("-----")[2].split())
    else:
        body = re.sub(r"\s+", "", flat)
        try:
            decoded = base64.b64decode(body, validate=True).decode()
            if "BEGIN" in decoded:
                body = "".join(decoded.split("-----")[2].split())
        except Exception:
            pass
    key = load_der_private_key(base64.b64decode(body), password=None)
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def token(key_id: str, issuer: str, pem: bytes) -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        pem.decode(),
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def get(path: str, bearer: str) -> dict:
    request = urllib.request.Request(API + path)
    request.add_header("Authorization", "Bearer " + bearer)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")[:400]
        raise SystemExit(f"App Store Connect returned HTTP {error.code} for {path}: {body}")


def list_apps(bearer: str) -> None:
    """Print every app record and its newest build.

    A build that is missing from the expected app is often attached to another app
    record in the same team, and this is what shows it.
    """
    apps = get("/v1/apps?" + urllib.parse.urlencode({"limit": 50}), bearer)
    for app in apps.get("data", []):
        attributes = app["attributes"]
        line = f"{attributes.get('bundleId','?'):<45} id={app['id']:<12}"
        builds = get(
            "/v1/builds?"
            + urllib.parse.urlencode({"filter[app]": app["id"], "limit": 1, "sort": "-uploadedDate"}),
            bearer,
        )
        if builds.get("data"):
            newest = builds["data"][0]["attributes"]
            line += f" newest={newest.get('version','?')} ({newest.get('processingState','?')}) {newest.get('uploadedDate','?')}"
        else:
            line += " newest=none"
        print(line)


def main() -> int:
    key_id = os.environ.get("KEY_ID", "").strip()
    issuer = os.environ.get("ISSUER_ID", "").strip()
    secret = os.environ.get("PRIVATE_KEY", "")
    bundle_id = os.environ.get("BUNDLE_ID", "com.vkapps.wifisecurecall")
    if os.environ.get("LIST_APPS") == "1":
        list_apps(token(key_id, issuer, pem_from_secret(secret)))
        return 0

    if not (key_id and issuer and secret):
        print("::error::KEY_ID, ISSUER_ID and PRIVATE_KEY are required.", file=sys.stderr)
        return 2

    bearer = token(key_id, issuer, pem_from_secret(secret))

    try:
        apps = get("/v1/apps?" + urllib.parse.urlencode({"filter[bundleId]": bundle_id}), bearer)
    except urllib.error.HTTPError as error:
        print(f"::error::App Store Connect rejected the request: HTTP {error.code}", file=sys.stderr)
        return 1

    if not apps.get("data"):
        print(f"::error::no app in App Store Connect has bundle id {bundle_id}.", file=sys.stderr)
        return 1
    app = apps["data"][0]
    print(f"app: {app['attributes']['name']}  id={app['id']}")

    # The collection endpoint accepts a sort; the app relationship endpoint does not.
    builds = get(
        "/v1/builds?"
        + urllib.parse.urlencode({"filter[app]": app["id"], "limit": 20, "sort": "-uploadedDate"}),
        bearer,
    )
    if not builds.get("data"):
        print("no builds uploaded for this app yet")
        return 0

    print(f"{'build':>7}  {'state':<12} uploaded                expired")
    for build in builds["data"]:
        attributes = build["attributes"]
        print(
            f"{attributes.get('version', '?'):>7}  "
            f"{attributes.get('processingState', '?'):<12} "
            f"{attributes.get('uploadedDate', '?'):<23} "
            f"{str(attributes.get('expired', '?'))}"
        )

    newest = builds["data"][0]
    try:
        detail = get(f"/v1/builds/{newest['id']}/buildBetaDetail", bearer)["data"]["attributes"]
        print(
            "newest build {}: internal={} external={} autoNotify={}".format(
                newest["attributes"].get("version", "?"),
                detail.get("internalBuildState", "?"),
                detail.get("externalBuildState", "?"),
                detail.get("autoNotifyEnabled", "?"),
            )
        )
    except SystemExit as failure:
        print(f"beta detail unavailable: {failure}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
