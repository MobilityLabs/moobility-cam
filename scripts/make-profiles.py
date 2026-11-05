#!/usr/bin/env python3
"""Create the Developer ID provisioning profiles the release needs, through the App Store Connect API.

The extension's system-extension entitlement needs a profile, and Xcode's cloud signing is refused for an
API key. A profile isn't a secret: it ships inside every app. Run this once, and again if one expires.

Usage: uv run --with 'pyjwt[crypto]' python scripts/make-profiles.py
"""
import base64
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

KEY_ID = "4XBH56T7RS"
ISSUER = "22e2fb14-d32b-4837-92b0-6280da32716d"
KEY = pathlib.Path(os.environ.get("ASC_KEY_PATH", pathlib.Path.home() / f".appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"))
SIGN_ID = os.environ.get("MACOS_IDENTITY", "Developer ID Application: Sean Perkins (HH3SJBAS42)")
OUT = pathlib.Path(__file__).resolve().parent / "profiles"
BUNDLES = {
    "com.mobilitylabs.MoobilityCam": "Moobility Cam Developer ID",
    "com.mobilitylabs.MoobilityCam.Extension": "Moobility Cam Extension Developer ID",
}


def api(path: str, body: dict | None = None) -> dict:
    now = int(time.time())
    token = jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                       KEY.read_text(), algorithm="ES256", headers={"kid": KEY_ID})
    request = urllib.request.Request(f"https://api.appstoreconnect.apple.com{path}",
                                     data=json.dumps(body).encode() if body else None,
                                     headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        details = json.load(error).get("errors", [{}])[0]
        sys.exit(f"{path}: HTTP {error.code}: {details.get('title')}: {details.get('detail')}")


def local_certificate_serial() -> str:
    pem = subprocess.run(["security", "find-certificate", "-c", SIGN_ID, "-p"], capture_output=True, text=True, check=True).stdout
    text = subprocess.run(["openssl", "x509", "-noout", "-serial"], input=pem, capture_output=True, text=True, check=True).stdout
    return text.strip().split("=")[1].upper().lstrip("0")


def main() -> None:
    serial = local_certificate_serial()
    certificates = api("/v1/certificates?limit=200")["data"]
    matching = [c for c in certificates if c["attributes"]["serialNumber"].upper().lstrip("0") == serial]
    if not matching:
        sys.exit(f"this Mac's '{SIGN_ID}' certificate isn't on the account")
    certificate = matching[0]["id"]
    print(f"certificate: {matching[0]['attributes']['certificateType']}, expires {matching[0]['attributes']['expirationDate'][:10]}")
    OUT.mkdir(exist_ok=True)
    for identifier, name in BUNDLES.items():
        query = urllib.parse.urlencode({"filter[identifier]": identifier})
        found = [b for b in api(f"/v1/bundleIds?{query}")["data"] if b["attributes"]["identifier"] == identifier]
        if found:
            bundle = found[0]["id"]
        else:
            bundle = api("/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
                "identifier": identifier, "name": name.replace(" Developer ID", ""), "platform": "MAC_OS"}}})["data"]["id"]
            print(f"{identifier}: created the App ID")
        query = urllib.parse.urlencode({"filter[name]": name})
        existing = [p for p in api(f"/v1/profiles?{query}")["data"]
                    if p["attributes"]["name"] == name and p["attributes"]["profileState"] == "ACTIVE"]
        if existing:
            profile = existing[0]
            print(f"{identifier}: using the active profile '{name}'")
        else:
            profile = api("/v1/profiles", {"data": {"type": "profiles",
                "attributes": {"name": name, "profileType": "MAC_APP_DIRECT"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                    "certificates": {"data": [{"type": "certificates", "id": certificate}]},
                }}})["data"]
            print(f"{identifier}: created '{name}'")
        print(f"  expires {profile['attributes']['expirationDate'][:10]}")
        (OUT / f"{identifier}.provisionprofile").write_bytes(base64.b64decode(profile["attributes"]["profileContent"]))


if __name__ == "__main__":
    main()
