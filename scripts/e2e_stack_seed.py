"""Synthetic seed for scripts/e2e-stack.sh (system_3 #9980).

Every name, address and amount below is invented. The seed signs in as the
owner through the stack's own client edge (POST /api/login, the same path a
browser takes) and writes through the server's API, so it exercises the real
code and never touches a database row directly. Nothing is read from the
served database: that is a third party's real financial record.

Usage: python3 -I e2e_stack_seed.py <run.env>
Prints counts only. Secrets stay in run.env.
"""

import http.cookiejar
import json
import sys
import urllib.error
import urllib.request

CLIENTS = [
    {"name": "Galerie Beispiel", "address": "Musterweg 1\n10115 Berlin", "email": "galerie@example.test"},
    {"name": "Studio Erfunden", "address": "Probestraße 7\n20095 Hamburg", "email": ""},
    {"name": "Max Platzhalter", "address": "", "email": ""},
]

# (client index, paid_on, gross cents, what it was for)
PAYMENTS = [
    (0, "2026-07-03", 35000, "Tattoo (big)"),
    (0, "2026-07-21", 12000, "Tattoo (small)"),
    (1, "2026-08-02", 9000, "Tattoo (small)"),
    (1, "2026-08-19", 48000, "Tattoo (big)"),
    (2, "2026-09-05", 15000, "Tattoo"),
    (0, "2026-09-12", 22000, "Tattoo"),
    (2, "2026-09-28", 6000, "Tattoo (small)"),
]
ISSUE = 5  # the first five drafts are issued
CANCEL = 1  # of those, the second is cancelled (Storno)


def env(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        if "=" in line:
            k, v = line.rstrip("\n").split("=", 1)
            out[k] = v
    return out


def main():
    cfg = env(sys.argv[1])
    base = cfg["E2E_URL"] + "/api"
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    def call(method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(base + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with opener.open(req) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            raise SystemExit(f"e2e-stack seed: {method} {path} -> {e.code} {e.read()[:200]!r}")

    # The auth cookie is Secure; over plain http to 127.0.0.1 the jar would
    # hold it back, so the token is copied into a Cookie header explicitly.
    req = urllib.request.Request(base + "/login", data=json.dumps({"username": cfg["E2E_OWNER"], "password": cfg["E2E_OWNER_PASSWORD"]}).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req) as r:
        cookie = next((h.split(";", 1)[0] for k, h in r.getheaders() if k.lower() == "set-cookie" and h.startswith("auth_token=")), None)
    if not cookie:
        raise SystemExit("e2e-stack seed: owner login set no auth_token")
    opener.addheaders = [("Cookie", cookie)]

    call("PUT", "/invoicing/profile", {
        "full_name": "Flora Testperson", "address": "Erfundene Allee 3\n10117 Berlin", "steuernummer": "11/111/11111",
        "email": "flora@example.test", "is_kleinunternehmer": True, "invoice_number_prefix": "2026", "next_invoice_number": 1,
    })
    client_ids = [call("POST", "/invoicing/clients", c)[1]["client"]["id"] for c in CLIENTS]

    drafts = []
    for n, (ci, paid_on, cents, note) in enumerate(PAYMENTS, start=1):
        _, p = call("POST", "/invoicing/payments/manual", {
            "client_id": client_ids[ci], "paid_on": paid_on, "gross_cents": cents, "method": "bank_transfer",
            "reference": f"E2E-{n:03d}", "sender_name": CLIENTS[ci]["name"], "note": note,
        })
        _, d = call("POST", "/invoicing/invoices", {"payment_ids": [p["payment"]["id"]]})
        drafts.append(d["invoice"]["id"])

    issued = []
    for iid in drafts[:ISSUE]:
        call("POST", f"/invoicing/invoices/{iid}/issue", {})
        issued.append(iid)
    call("POST", f"/invoicing/invoices/{issued[CANCEL]}/cancel", {"reason": "e2e seed: Storno"})

    print(f"seeded: clients={len(client_ids)} payments={len(PAYMENTS)} issued={ISSUE - 1} cancelled=1 drafts={len(drafts) - ISSUE}")


if __name__ == "__main__":
    main()
