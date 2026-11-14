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
| pulled mail, in clear until the lake ingest encrypts it; `gmail_pull_and_ingest.sh` deletes the run directory once its ingest has succeeded for real, and after a failed or `--dry-run` ingest keeps it and says `clear export kept at <dir>; re-run to ingest it` | `/data/gmail/runs/<run_id>/` on the LUKS volume (`GMAIL_STAGING_DIR` overrides) | 600, dirs 700 | never |
| where the next pull starts (`history_id`; no secret) | `/data/gmail/state.json` | 600 | never |

The refresh token is a production credential. It is written only encrypted
under the lake KEK (`scripts/kek/dek_envelope.py` format), the same key that
protects `sensitivity=high` objects in the lake, so a copy of `~/secrets/gmail`
without the KEK is useless. Every tool here refuses to run without a KEK.

## One-time: put the client JSON on the cell

From your own machine (never through the chat upload or a comment). There is
one value to fill in: the name of the file Google gave you.

First see which downloads exist:

```bash
ls -t ~/Downloads/client_secret_*.json
```

If your browser saves somewhere else, look there. If it lists more than one,
they are downloads of the same client; take the first line, which is the
newest. Put that one file's full name in `SRC`, then
paste the rest as it is:

```bash
SRC="$HOME/Downloads/client_secret_REPLACE_ME.json"

ssh -p 41922 aspirant@home.the-aspirant.com 'mkdir -p ~/secrets && chmod 700 ~/secrets && if [ -d ~/secrets/gmail-oauth-client.json ]; then echo "STOP: gmail-oauth-client.json is a folder; see the note below"; exit 1; fi' \
  && scp -P 41922 "$SRC" aspirant@home.the-aspirant.com:secrets/gmail-oauth-client.json \
  && ssh -p 41922 aspirant@home.the-aspirant.com 'chmod 600 ~/secrets/gmail-oauth-client.json && ls -l ~/secrets/gmail-oauth-client.json'
```

The last line it prints must start with `-rw-------` and end with
`gmail-oauth-client.json`: one file, readable only by you.

Give `scp` one file, never a pattern such as `client_secret_*.json`. When a
pattern matches two files, `scp` treats the destination as a folder and puts
both inside it (this happened on 2026-11-13, system_3 #10778). If the first
command printed `STOP`, a folder is there from such a copy. It holds only
copies of the client JSON. Remove it and paste the block again:

```bash
ssh -p 41922 aspirant@home.the-aspirant.com 'rm -r ~/secrets/gmail-oauth-client.json'
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

The commands from here on run on the cell, from the deploy checkout. Either
keep the session from the consent step open, or open a plain one:

```bash
ssh -p 41922 aspirant@home.the-aspirant.com
cd ~/aspirant-deploy
```

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

## Ingest into the lake (on demand, B2)

```bash
scripts/gmail/gmail_pull_and_ingest.sh            # incremental pull, then ingest the run
scripts/gmail/gmail_pull_and_ingest.sh --full     # full pull, then ingest
scripts/gmail/gmail_pull_and_ingest.sh --verify   # ... then scripts/lake-skeleton.sh verify-at-rest
scripts/gmail/gmail_pull_and_ingest.sh --dry-run  # pull for real; the ingest only reports what it would load
```

One KEK prompt for both halves (or `LAKE_KEK_HEX` exported one-shot as above).
The wrapper runs `gmail.sh pull`, reads the `run_id` from its one summary
line, and hands `/data/gmail/runs/<run_id>/manifest.json` to
`scripts/lake-skeleton.sh ingest`, which runs `scripts/lake_ingest.py`
(`docs/data-lake-design/REAL_DATA_INGEST.md`) in the lake client container with
the run directory mounted read-only. A pull that finds no change writes no run
and the wrapper stops with `no new run to ingest`; a pull that fails (3
re-consent, 4 transport, 7 lock) stops the chain with that exit code and
nothing is ingested.

The export under `/data/gmail/runs/<run_id>/` is the mail in clear. After a
successful real ingest the wrapper deletes that run directory: the lake holds
the envelope and the inventory row, and a re-ingest of the same bytes would be
a no-op by content address, so the clear copy has no consumer left. After a
failed ingest, or with `--dry-run` (which pulls for real and encrypts nothing),
the run directory is kept so a retry can load it, and the wrapper says
`clear export kept at <dir>; re-run to ingest it` on stderr. `state.json`
(the history id, no secret) is never touched.

What lands in the lake, per run:

- one object under `bronze/blobs/sha256/<aa>/<bb>/<sha256>` holding the run's
  `messages.json` as an `AOBJ` envelope (AES-256-GCM under a fresh DEK, the DEK
  wrapped under the lake KEK); the plaintext never reaches Garage;
- one `asset_inventory` row: `dataset_id gmail`, `kind message_export`,
  `sensitivity high` (`declared`), `wrapped_dek`, `kek_version`,
  `retention_class keep-forever`, `jurisdiction EU`, `source_path messages.json`;
- one `ingest_runs` row (`success`, or `failed` when the pre-flight refused for
  want of a KEK: the runner never falls back to plaintext).

A full run's export is the whole mailbox; an incremental run's export is the
change since the previous run, with `deleted_ids`. The lake keeps the sequence;
reading the current mailbox is a fold over it, which the agent read path
(#8806-C1) owns. Re-ingesting a run is a no-op (content-addressed on the
export's sha256).

`scripts/lake-skeleton.sh verify-at-rest` (or `--verify`) proves it: every
`high` row declares an envelope, the stored object starts with `AOBJ`, nothing
readable sits under a `high` row (a plaintext export would be named `readable
JSON`), the DEK unwraps under the KEK in custody and decrypts to the row's
content address, and no uncatalogued object exists.

The dataset's intake record is the `gmail` section of
`docs/data-lake-design/DATASET_INTAKE.md`; it is `PROPOSED` until the operator
answers its affirmation block, and the first real load (#8806-E1) waits for
that and for the security review (#8806-D1). `tests/gmail_lake_ingest_unit.sh`
runs the whole chain on the synthetic mailbox under an ephemeral KEK.

## Consent-screen status (decided on #8806)

`gmail.readonly` is a *restricted* scope. In Testing, refresh tokens expire after
7 days and the app may have up to 100 test users. Switching the app to production
removes the 7-day expiry; unverified, it shows an "unverified app" warning at
sign-in and allows up to 100 users over the project's lifetime, which is fine for
one. Production requires the branding fields, including a privacy policy URL,
which is the only real cost.
