#!/usr/bin/env python3
"""Sign in to Google on a computer and write a token file for the KOReader plugin.

Google's limited-input-device ("TV") OAuth grant only supports openid/email/
profile, Drive and YouTube scopes -- not Gmail or Calendar -- so an e-reader
cannot complete a sign-in on its own. This script runs the ordinary loopback
flow here, then hands the resulting refresh token to the device as a file.

Standard library only; no pip install required.

    python3 google_auth.py --client-secrets client_secret.json

Afterwards copy the generated google_token.json onto the device and use
"Import token file" in the plugin.
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import socket
import sys
import threading
import urllib.parse
import urllib.request
import webbrowser

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"

# Keep in sync with lib/const.lua.
SCOPES = [
    "openid",
    "email",
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar.readonly",
]

SUCCESS_PAGE = b"""<!doctype html><meta charset="utf-8">
<title>Signed in</title>
<body style="font-family:system-ui;margin:4rem auto;max-width:32rem">
<h1>Signed in.</h1>
<p>Go back to the terminal; you can close this tab.</p>
"""


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def load_client(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    section = data.get("installed") or data.get("web")
    if not section:
        sys.exit(
            "That JSON has neither an 'installed' nor a 'web' section. Download the\n"
            "credentials for an OAuth client of type 'Desktop app'."
        )
    if "web" in data:
        print(
            "Warning: this is a 'Web application' client. A 'Desktop app' client is\n"
            "         the right type here; a web client also works only if you have\n"
            "         registered the loopback redirect URI yourself.",
            file=sys.stderr,
        )
    return section["client_id"], section["client_secret"]


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class CallbackHandler(http.server.BaseHTTPRequestHandler):
    result = {}
    done = threading.Event()

    def do_GET(self):  # noqa: N802 - name fixed by BaseHTTPRequestHandler
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        CallbackHandler.result = {k: v[0] for k, v in query.items()}
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(SUCCESS_PAGE)
        CallbackHandler.done.set()

    def log_message(self, *_args):
        pass


def post_form(url, fields):
    body = urllib.parse.urlencode(fields).encode("ascii")
    request = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/x-www-form-urlencoded"}
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        sys.exit(f"Token exchange failed ({error.code}):\n{detail}")


def email_from_id_token(id_token):
    if not id_token:
        return None
    try:
        payload = id_token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload)).get("email")
    except Exception:  # noqa: BLE001 - the email is a nicety, not a requirement
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--client-secrets", required=True,
                        help="OAuth client JSON downloaded from the Google Cloud console")
    parser.add_argument("--output", default="google_token.json",
                        help="where to write the token file (default: google_token.json)")
    parser.add_argument("--no-browser", action="store_true",
                        help="print the URL instead of opening a browser")
    args = parser.parse_args()

    client_id, client_secret = load_client(args.client_secrets)

    verifier = b64url(secrets.token_bytes(64))
    challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    state = b64url(secrets.token_bytes(24))

    port = free_port()
    redirect_uri = f"http://127.0.0.1:{port}"

    params = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": " ".join(SCOPES),
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
        # offline + consent is what makes Google return a refresh token every time.
        "access_type": "offline",
        "prompt": "consent",
    }
    auth_url = AUTH_URL + "?" + urllib.parse.urlencode(params)

    server = http.server.HTTPServer(("127.0.0.1", port), CallbackHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    print("Open this URL and approve access:\n")
    print(auth_url + "\n")
    if not args.no_browser:
        webbrowser.open(auth_url)

    if not CallbackHandler.done.wait(timeout=600):
        sys.exit("Timed out waiting for the browser to come back.")
    server.shutdown()

    result = CallbackHandler.result
    if result.get("error"):
        sys.exit(f"Google returned an error: {result['error']}")
    if result.get("state") != state:
        sys.exit("State mismatch; aborting rather than trusting that response.")
    code = result.get("code")
    if not code:
        sys.exit("No authorization code in the response.")

    tokens = post_form(TOKEN_URL, {
        "client_id": client_id,
        "client_secret": client_secret,
        "code": code,
        "code_verifier": verifier,
        "grant_type": "authorization_code",
        "redirect_uri": redirect_uri,
    })

    refresh_token = tokens.get("refresh_token")
    if not refresh_token:
        sys.exit(
            "Google did not return a refresh token. Remove this app's access at\n"
            "https://myaccount.google.com/permissions and run this script again."
        )

    payload = {
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": refresh_token,
        "scopes": SCOPES,
        "email": email_from_id_token(tokens.get("id_token")),
    }
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
    os.chmod(args.output, 0o600)

    print(f"Wrote {args.output} for {payload['email'] or 'your account'}.")
    print("Copy it to the device, import it in the plugin, then delete both copies.")


if __name__ == "__main__":
    main()
