# Gmail → data lake, on demand (system_3 #8806)

Pull the operator's Gmail into the data lake on demand, read-only, stored at the
lake's highest sensitivity, so an agent on this box can answer questions about
the mail without anything being pasted into a chat. This runbook grows with the
epic: credentials (A1, this page), the pull (B1), the lake ingest (B2), the agent
read path (C1).

## What lives where

| thing | where | mode | in git? |
|---|---|---|---|
| OAuth client JSON (Desktop app; holds the client secret) | `~/secrets/gmail-oauth-client.json` | 600, dir 700 | never |
| refresh token, as a lake envelope (`AOBJ` object + wrapped DEK) | `~/secrets/gmail/token.aobj`, `token.wdek` (owned by you; the tool runs as your user, not root) | 600 | never |
| non-secret sidecar (obtained_at, scopes, kek version, fingerprint) | `~/secrets/gmail/token.meta.json` | 600 | never |
| the lake KEK | off-cell (operator), typed or passed one-shot per run | — | never |
| tools | `scripts/gmail/` in this repo, run through `scripts/gmail/gmail.sh` | — | yes |

The refresh token is a production credential. It is written only encrypted
under the lake KEK (`scripts/kek/dek_envelope.py` format), the same key that
protects `sensitivity=high` objects in the lake, so a copy of `~/secrets/gmail`
without the KEK is useless. Every tool here refuses to run without a KEK.

## One-time: put the client JSON on the cell

From your own machine (never through the chat upload or a comment):

```bash
ssh aspirant@<cell> 'mkdir -p ~/secrets && chmod 700 ~/secrets'
scp client_secret_*.json aspirant@<cell>:~/secrets/gmail-oauth-client.json
ssh aspirant@<cell> 'chmod 600 ~/secrets/gmail-oauth-client.json'
```

The client must be of type **Desktop app**. The scope used is exactly
`https://www.googleapis.com/auth/gmail.readonly`; the tool refuses any other.

## Consent (obtain the refresh token)

The consent flow runs a small web server on the cell's loopback and Google
redirects the browser to `http://localhost:8765/`. Your browser is on your
machine, so open the SSH session with a tunnel that carries that port to the
cell:

```bash
ssh -o ExitOnForwardFailure=yes -L 8765:127.0.0.1:8765 -p 41922 aspirant@home.the-aspirant.com
cd ~/aspirant-deploy
scripts/gmail/gmail.sh consent --note 'consent screen: Testing'
```

`ExitOnForwardFailure=yes` makes ssh abort if your local port 8765 is taken, so
Google's redirect can never land on some other local process; without it ssh
only warns and carries on.

The tool asks for the KEK on a hidden prompt (the way to enter it). If you need
it in the environment for a non-interactive run, read it hidden and export the
variable, never type the hex on a command line, which would write the lake
master key to the shell history on the cell:

```bash
read -rs LAKE_KEK_HEX && export LAKE_KEK_HEX    # one shell, one run; `unset LAKE_KEK_HEX` after
```

It then prints an authorisation URL, you open it in your browser,
grant read-only access, and Google's redirect lands on the cell through the
tunnel. The token is then stored as an envelope and the sidecar is printed.
Nothing secret is printed, ever.

## Status and re-consent

```bash
scripts/gmail/gmail.sh status           # presence, obtained_at, scopes, kek version; no KEK needed
scripts/gmail/gmail.sh status --check   # decrypts in memory and refreshes once; needs the KEK
```

`status --check` answers one of:

- `ok` (exit 0): the token still mints access tokens;
- `re-consent needed: ...` (exit 3): Google refused the refresh token. With the
  consent screen in **Testing**, Google expires it 7 days after consent, so this
  is expected weekly until the app is switched to production; run `consent` again;
- a transport error (exit 4): try again later; nothing was changed.

The pull (B1) runs the same check first and stops with the same line rather than
returning stale mail.

## Consent-screen status (decided on #8806)

`gmail.readonly` is a *restricted* scope. In Testing, refresh tokens expire after
7 days and the app may have up to 100 test users. Switching the app to production
removes the 7-day expiry; unverified, it shows an "unverified app" warning at
sign-in and allows up to 100 users over the project's lifetime, which is fine for
one. Production requires the branding fields, including a privacy policy URL,
which is the only real cost.
