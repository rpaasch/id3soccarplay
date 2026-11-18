#!/usr/bin/env python3
"""
App Store Connect API helper for ID3Maps signing (runs in the cloud session).

Does the non-macOS half of Ad Hoc signing:
  * generate an RSA key + CSR
  * create an Apple Distribution certificate from the CSR
  * build a .p12 (cert + private key)
  * register/confirm the wildcard bundle id  com.porsche.*
  * register the iPhone UDID
  * create an iOS Ad Hoc provisioning profile (wildcard + device)
  * download the profile

The signed archive itself still happens on the macOS GitHub runner; this script
produces the material it needs (.p12 + .mobileprovision), which we then hand to
the runner via the Cloudflare Worker.

Credentials come from the environment (never hard-coded, repo is public):
  ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY (the AuthKey_*.p8 contents),
  APPLE_TEAM_ID.

Usage:
  python3 scripts/asc.py whoami
  python3 scripts/asc.py cert            --out signing/
  python3 scripts/asc.py bundle          --id 'com.porsche.*' --name 'Porsche Wildcard'
  python3 scripts/asc.py device          --udid <UDID> --name 'iPhone'
  python3 scripts/asc.py profile         --out signing/ --bundle 'com.porsche.*'
  python3 scripts/asc.py all             --udid <UDID> --out signing/
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error

import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com/v1"


def _env(name: str) -> str:
    v = os.environ.get(name)
    if not v:
        sys.exit(f"Missing required env var: {name}")
    return v


def _private_key_pem() -> str:
    """Return a well-formed .p8 PEM.

    Robust to how the value was pasted: real newlines, escaped ``\\n``, or a
    single line where the settings field flattened everything (header + body +
    footer separated by spaces). Also accepts ASC_KEY_PATH to a file.
    """
    raw = os.environ.get("ASC_PRIVATE_KEY")
    path = os.environ.get("ASC_KEY_PATH")
    if (not raw) and path and os.path.exists(path):
        raw = open(path).read()
    if not raw:
        sys.exit("Set ASC_PRIVATE_KEY (p8 contents) or ASC_KEY_PATH (file path).")

    raw = raw.replace("\\n", "\n")
    # Extract just the base64 body, ignoring any header/footer and whitespace.
    import re
    body = re.sub(r"-----(BEGIN|END) [A-Z ]+-----", " ", raw)
    body = re.sub(r"\s+", "", body)
    if not body:
        sys.exit("ASC_PRIVATE_KEY did not contain a key body.")
    wrapped = "\n".join(body[i:i + 64] for i in range(0, len(body), 64))
    return f"-----BEGIN PRIVATE KEY-----\n{wrapped}\n-----END PRIVATE KEY-----\n"


def token() -> str:
    key_id = _env("ASC_KEY_ID")
    issuer = _env("ASC_ISSUER_ID")
    now = int(time.time())
    payload = {"iss": issuer, "iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, _private_key_pem(), algorithm="ES256",
                      headers={"kid": key_id, "typ": "JWT"})


def api(method: str, path: str, body: dict | None = None) -> dict:
    url = path if path.startswith("http") else f"{API}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        sys.exit(f"ASC API {method} {path} -> HTTP {e.code}\n{detail}")


# ---------- commands ----------

def cmd_whoami(_args):
    # Any authenticated call proves the key works. List certs (cheap).
    data = api("GET", "/certificates?limit=5")
    print("Auth OK. Certificates visible:", len(data.get("data", [])))
    for c in data.get("data", []):
        a = c["attributes"]
        print(f"  - {a.get('certificateType')}  {a.get('name')}  exp {a.get('expirationDate')}")


def _openssl(args: list[str], **kw):
    return subprocess.run(["openssl", *args], check=True, capture_output=True, **kw)


def cmd_cert(args):
    os.makedirs(args.out, exist_ok=True)
    key_path = os.path.join(args.out, "dist.key")
    csr_path = os.path.join(args.out, "dist.csr")
    cer_path = os.path.join(args.out, "dist.cer")
    p12_path = os.path.join(args.out, "dist.p12")

    if not os.path.exists(key_path):
        _openssl(["genrsa", "-out", key_path, "2048"])
    _openssl(["req", "-new", "-key", key_path, "-out", csr_path,
              "-subj", "/CN=ID3Maps Distribution/O=ID3Maps/C=DK"])
    csr_pem = open(csr_path).read()

    body = {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION", "csrContent": csr_pem}}}
    resp = api("POST", "/certificates", body)
    attrs = resp["data"]["attributes"]
    cert_der = base64.b64decode(attrs["certificateContent"])
    open(cer_path, "wb").write(cert_der)
    print("Certificate created:", attrs.get("name"), "id", resp["data"]["id"])

    # Build .p12 (cert PEM + key) with a random password.
    pem_cert = os.path.join(args.out, "dist.pem")
    _openssl(["x509", "-inform", "DER", "-in", cer_path, "-out", pem_cert])
    password = base64.urlsafe_b64encode(os.urandom(18)).decode().rstrip("=")
    _openssl(["pkcs12", "-export", "-legacy", "-inkey", key_path, "-in", pem_cert,
              "-out", p12_path, "-passout", f"pass:{password}", "-name", "ID3Maps Distribution"])
    open(os.path.join(args.out, "p12-password.txt"), "w").write(password + "\n")
    print(f"Wrote {p12_path} (password in p12-password.txt)")


def cmd_bundle(args):
    # Does it already exist?
    existing = api("GET", f"/bundleIds?filter[identifier]={args.id}&limit=1")
    if existing.get("data"):
        b = existing["data"][0]
        print("Bundle id already registered:", b["attributes"]["identifier"], "id", b["id"])
        print(json.dumps(b["attributes"], indent=2))
        return
    body = {"data": {"type": "bundleIds", "attributes": {
        "identifier": args.id, "name": args.name, "platform": "IOS", "seedId": _env("APPLE_TEAM_ID")}}}
    resp = api("POST", "/bundleIds", body)
    print("Bundle id created:", resp["data"]["attributes"]["identifier"], "id", resp["data"]["id"])


def cmd_device(args):
    existing = api("GET", f"/devices?filter[udid]={args.udid}&limit=1")
    if existing.get("data"):
        print("Device already registered:", existing["data"][0]["id"])
        return existing["data"][0]["id"]
    body = {"data": {"type": "devices", "attributes": {
        "name": args.name, "platform": "IOS", "udid": args.udid}}}
    resp = api("POST", "/devices", body)
    print("Device registered:", resp["data"]["id"])
    return resp["data"]["id"]


def _ids(path: str) -> list[str]:
    out, nxt = [], path
    while nxt:
        page = api("GET", nxt)
        out += [d["id"] for d in page.get("data", [])]
        nxt = page.get("links", {}).get("next")
    return out


def cmd_profile(args):
    os.makedirs(args.out, exist_ok=True)
    bundles = api("GET", f"/bundleIds?filter[identifier]={args.bundle}&limit=1")
    if not bundles.get("data"):
        sys.exit(f"Bundle id {args.bundle} not found — run `bundle` first.")
    bundle_id = bundles["data"][0]["id"]
    cert_ids = _ids("/certificates?filter[certificateType]=DISTRIBUTION&limit=200")
    device_ids = _ids("/devices?filter[status]=ENABLED&limit=200")
    if not cert_ids:
        sys.exit("No distribution certificate — run `cert` first.")

    body = {"data": {
        "type": "profiles",
        "attributes": {"name": args.name, "profileType": "IOS_APP_ADHOC"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
            "certificates": {"data": [{"type": "certificates", "id": c} for c in cert_ids]},
            "devices": {"data": [{"type": "devices", "id": d} for d in device_ids]},
        },
    }}
    resp = api("POST", "/profiles", body)
    content = resp["data"]["attributes"]["profileContent"]
    out = os.path.join(args.out, "id3.mobileprovision")
    open(out, "wb").write(base64.b64decode(content))
    print(f"Profile created: {resp['data']['attributes']['name']} -> {out}")


def cmd_all(args):
    cmd_cert(argparse.Namespace(out=args.out))
    cmd_bundle(argparse.Namespace(id="com.porsche.*", name="Porsche Wildcard (ID3Maps)"))
    cmd_device(argparse.Namespace(udid=args.udid, name="iPhone (ID3Maps)"))
    cmd_profile(argparse.Namespace(out=args.out, bundle="com.porsche.*", name="ID3 Ad Hoc"))
    print("\nAll signing material in", args.out)


def main():
    p = argparse.ArgumentParser(description="App Store Connect helper for ID3Maps signing")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("whoami").set_defaults(func=cmd_whoami)

    c = sub.add_parser("cert"); c.add_argument("--out", default="signing"); c.set_defaults(func=cmd_cert)
    b = sub.add_parser("bundle"); b.add_argument("--id", default="com.porsche.*"); b.add_argument("--name", default="Porsche Wildcard (ID3Maps)"); b.set_defaults(func=cmd_bundle)
    d = sub.add_parser("device"); d.add_argument("--udid", required=True); d.add_argument("--name", default="iPhone (ID3Maps)"); d.set_defaults(func=cmd_device)
    pr = sub.add_parser("profile"); pr.add_argument("--out", default="signing"); pr.add_argument("--bundle", default="com.porsche.*"); pr.add_argument("--name", default="ID3 Ad Hoc"); pr.set_defaults(func=cmd_profile)
    a = sub.add_parser("all"); a.add_argument("--udid", required=True); a.add_argument("--out", default="signing"); a.set_defaults(func=cmd_all)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
