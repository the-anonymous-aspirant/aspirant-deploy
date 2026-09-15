# Valuation cross-service smoke check (#5921)

The layer above the per-service suites. On one feature in one day, four defects
shipped that every per-service test passed — because each suite runs one service
in isolation and nothing drove a real document through the deployed proxy chain a
browser uses:

| defect | found by |
|---|---|
| #5910 two contradictory banners on one scan | reading code vs a real doc |
| #5915 `/decide` took 16–83s, not the ~1.4s design | dogfooding `DV.pdf` |
| #5920 `/decide` had no route on aspirant-server | probing the served endpoint |
| #5919 Member uploads 502 at the 30s ceiling | a real user, Jenny |

`scripts/smoke_valuation_e2e.py` is the checker for that gap.

## What it asserts

- **Part A — route contract.** Every commander endpoint the client calls resolves
  to a route on aspirant-server, probed unauthenticated at the served surface:
  a registered auth-gated route answers **401**, a missing one **404**. 404-where-
  401 is the whole of #5920, and a list comparison catches it.
- **Part B — real-document journey.** As a Member, `POST /decide` then `/extract`
  for each corpus document through the client nginx `/api` proxy (the real chain),
  asserting the pre-flight classifies it and the extract returns **200** (not the
  #5919 502) with the expected field structure.

It asserts only **structure** — classification, field counts, outcome, HTTP status.
The corpus documents are real client valuations; their bytes and field *values*
never leave the cell and are never committed or logged.

## Where it runs

- **Post-deploy:** `scripts/deploy-client.sh deploy` invokes `post-deploy-smoke.sh`
  after the traffic swap. A failure warns loudly and logs a fleet signal but does
  not auto-rollback (the cause may be the server or commander, which a client
  rollback would not fix). Opt out with `SMOKE_SKIP=1`.
- **On a cadence:** a system_3 cron runs `post-deploy-smoke.sh` to catch drift
  between deploys (a commander redeploy, a dropped route, an OCR regression).
- **Failure reaches someone:** `post-deploy-smoke.sh` logs an `s3 failure-mode`
  row and prints a banner on any non-zero exit, and propagates the exit code.

## One-time on-cell setup

These live on the cell, never in the repo (a login-impossible account and real
client documents).

### 1. The smoke Member account

A dedicated, login-impossible Member (password `NULL`) so the check never appears
in the audit trail as a real user. Its `session_epoch` stays `0` forever — with no
password it can never open a session, so nothing revokes it — which is why the
token is minted with a constant epoch and no live DB read.

```sql
INSERT INTO users (username, email, password, role_id, session_epoch,
                   email_verified_at, created_at, updated_at)
SELECT 'smoke_valuation', 'smoke_valuation@invalid.local', NULL, r.id, 0,
       now(), now(), now()
FROM roles r WHERE r.role_name = 'Member'
ON CONFLICT (username) DO NOTHING;
```

Run it against the deployed DB, then set `SMOKE_USER_ID` to the resulting id
(default `14`). If the account is re-seeded or its epoch bumped, Part B 401s
loudly and names the cause.

### 2. The corpus directory

`/data/aspirant/smoke-corpus/` (override with `SMOKE_CORPUS_DIR`), holding the
documents named in `CORPUS_MANIFEST`:

| file | what it exercises |
|---|---|
| `native_text.pdf` | native text extraction, no OCR (`extracted`, fields) |
| `dv_reprinted_vector.pdf` | outlined-vector → OCR yields fields (`partial`) |
| `aspstigen_raster_scan.pdf` | Jenny's raster scan → OCR runs, 0 fields today; asserts the journey completes (200, no 502) — field *yield* on a noisy scan is #5909's domain, not this check's |

These are copies of real uploads, kept on-cell. Do not commit them.

## Running it by hand

```bash
cd /home/aspirant/aspirant-deploy
set -a; . ./.env; set +a
./scripts/post-deploy-smoke.sh        # runs the check, logs a signal on failure
python3 tests/smoke_valuation_unit.py # the assertion logic's own unit test
```

`tests/smoke_valuation_unit.py` pins the other half of the acceptance: the
assertions REJECT the exact shapes the pre-fix stack returned (#5920's 404,
#5919's 502), so the check cannot be quietly loosened until it stops seeing them.
