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
| pulled mail, in clear until the lake ingest encrypts it | `/data/gmail/runs/<run_id>/` on the LUKS volume (`GMAIL_STAGING_DIR` overrides) | 600, dirs 700 | never |
| where the next pull starts (`history_id`; no secret) | `/data/gmail/state.json` | 600 | never |

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

The pull runs the same check first and stops with the same line rather than
returning stale mail.

## Pull (on demand)

```bash
scripts/gmail/gmail.sh pull          # incremental from the stored history id; a full pull the first time
scripts/gmail/gmail.sh pull --full   # ignore the stored history id and pull everything again
```

It needs the KEK the same way `status --check` does, because it opens the
token in memory. It writes nothing that holds a secret, and it never encrypts.
Encrypting for the lake is the ingest runner's job (#8806-B2).

- **First run (no `state.json`):** reads the mailbox's current history id,
  then lists and fetches every message (`format=full`).
- **Later runs:** read only what changed since the stored history id
  (`users.history.list`) and fetch those messages. Gmail keeps history for a
  limited time; when it has expired (404), the run falls back to a full pull
  and says `fallback=history_expired`.
- **Excluded:** spam and trash, on both paths.

Each run that finds something writes one directory, which appears only once it
is complete:

```
/data/gmail/runs/<YYYYMMDDTHHMMSSZ>-<full|incremental>/
  messages.json   {"messages": [...], "deleted_ids": [...], "mode", "base_history_id", "history_id", "pulled_at", "format"}
  manifest.json   the source manifest for scripts/lake_ingest.py: dataset_id gmail, kind message_export, sensitivity high
```

Each message has `id, threadId, date (UTC), from, to, cc, subject, labels, text,
attachments`. `text` is the text/plain part, or the visible text of the HTML
when there is none. `attachments` lists `name, mime, size` only: no attachment
content is fetched until the security review (#8806-D1) decides otherwise.

A full run's export is the whole mailbox. An incremental run's export is the
change: messages added or changed since the last run, and `deleted_ids` for
those that were deleted or moved to spam or trash. Applying the incremental
exports in order to the last full one gives what a fresh full pull would give;
`tests/gmail_pull_unit.sh` proves that on a synthetic mailbox. A run that finds
no change writes no directory.

The new history id goes into `state.json` last, after the run directory is in
place. A pull that dies earlier leaves the history id where it was, and the next
pull repeats the same window. Two pulls cannot run at once: the second exits 7.

The output is one line of counts, for example
`gmail pull: run_id=... mode=incremental exported=2 deleted=3 history=1002->1008 ...`.
No subject, address, body or token is ever printed.

## Consent-screen status (decided on #8806)

`gmail.readonly` is a *restricted* scope. In Testing, refresh tokens expire after
7 days and the app may have up to 100 test users. Switching the app to production
removes the 7-day expiry; unverified, it shows an "unverified app" warning at
sign-in and allows up to 100 users over the project's lifetime, which is fine for
one. Production requires the branding fields, including a privacy policy URL,
which is the only real cost.
