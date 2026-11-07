# Disposable e2e stack for the invoicing app

`scripts/e2e-stack.sh` stands up a throwaway copy of the invoicing app for end-to-end tests: the **served** server and client images, a scratch Postgres, synthetic data and three fresh logins. It exists because of the security ruling on system_3 #9979: test logins live here, never on the served app. Built in system_3 #9980 / #10015.

## Use

```
scripts/e2e-stack.sh up              # prints the login URL, the users, the env-file path,
                                     # and: e2e-stack run: <run-id> server=<sha> client=<sha>
scripts/e2e-stack.sh down <run-id>   # removes everything that run created; safe to repeat
scripts/e2e-stack.sh status          # lists runs and their containers
```

State lives under `$E2E_STACK_ROOT` (default `${TMPDIR:-/tmp}/e2e-stack`), one 0700 directory per run. The logins' passwords are in `<run>/run.env` (0600). Read them from there; they are never printed. Quote the `e2e-stack run:` line in the task comment that reports a run: that line is the adherence signal `invoicing_e2e_stack_runs`.

## What it runs

- **Server:** the image of the live `aspirant-online-server-1`, pinned by image ID, on the run's network under the alias `server`, with `/data` on tmpfs.
- **Client:** the image of the live `aspirant-online-client-*`, pinned by image ID. Its nginx proxies `/api/` to `server:8080` through Docker's resolver, so the served edge works as it is. Its only secrets hook is a glob include, `/etc/nginx/secrets/*.conf`, which matches nothing without the prod mount, so the break-glass token stays empty.
- **Database:** `postgres:16-alpine` on a volume named for the run.
- **Data:** `scripts/e2e_stack_seed.py` signs in as the owner through the stack's own edge and writes invented records through the API: a profile, 3 clients, 7 payments, 4 issued invoices (1 then cancelled) and 2 drafts. That gives multiple items in the CSV, the ZIP and the merged PDF.
- **Logins:** `vinoly` (the owner, Member), `e2e_admin` (Admin) and `e2e_member` (Member, not the owner), so both sides of the `/invoicing` gate can be tested.

## Security rules (#9979) and how each is enforced

| Rule | How | Checked by |
|---|---|---|
| Isolation | Own network `s3e2e-<run>`; the only publish is `127.0.0.1:<port>` (a free port in 18900-18999); never `aspirant-online_default`; no `.env`, `/data/aspirant` or prod volume mounted | `tests/e2e_stack_unit.sh` |
| Synthetic data only | The seed writes invented records through the API and never reads `aspirant_db` | the seed's source |
| Per-run secrets | `openssl rand` at `up`, in 0600 env files, passed by `--env-file`; login hashes are written by SQL piped on stdin, never on an argv; never printed; deleted by `down` | `tests/e2e_stack_unit.sh` (no secret in stdout, stderr or any docker argv) |
| Both sides of the gate | The three logins above | the acceptance walk (non-owner Member: 403) |
| No prod token minting | The served containers are only inspected for their revision and image ID; their environment is never read | `tests/e2e_stack_unit.sh` |

The server accepts cross-origin requests only from its allowlist (`server/cors.go`). Each run sets `CORS_ALLOWED_ORIGINS=http://127.0.0.1:<port>` in its own server env, so a browser on the stack can sign in. The served app is untouched.

## Tests

`tests/e2e_stack_unit.sh` runs `up` and `down` against a stub `docker` that records every argv, and checks the rules above without Docker.
