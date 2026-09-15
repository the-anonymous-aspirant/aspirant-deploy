#!/usr/bin/env bash
# Run the cross-service valuation smoke check against the deployed stack (#5921),
# and make a failure reach someone: on a non-zero exit it logs a system_3
# failure-mode row and prints a loud banner, then propagates the exit code so a
# deploy hook or cron treats it as the failure it is.
#
# Invoked (a) at the end of a client deploy — a bad build that breaks the journey
# fails the deploy loudly instead of going live silently — and (b) on a cadence
# from cron, to catch drift between deploys (a commander redeploy, a server route
# dropped, an OCR regression). Both are the "invariant with no checker is a
# convention" fix for the four defects that shipped in one day.
#
# Reads config from the deploy .env (JWT_SECRET etc). Override the target with
# SMOKE_CLIENT_BASE / SMOKE_CORPUS_DIR. Requires the on-cell one-time setup in
# docs/valuation-smoke.md (the smoke Member account + the corpus directory).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$HERE/.." && pwd)"
ENV_FILE="${SMOKE_ENV_FILE:-$DEPLOY_ROOT/.env}"
ACTOR_ID="${SMOKE_ACTOR_ID:-204}"

if [[ -f "$ENV_FILE" ]]; then
  set -a; . "$ENV_FILE"; set +a
fi

python3 "$HERE/smoke_valuation_e2e.py"
rc=$?

if [[ $rc -ne 0 ]]; then
  echo
  echo "########################################################################"
  echo "# VALUATION SMOKE FAILED (rc=$rc) — the deployed valuation journey is broken."
  echo "# This is the check that would have caught #5919/#5920 before a user did."
  echo "########################################################################"
  # Best-effort fleet signal; never let the signalling failure mask the smoke rc.
  s3 failure-mode log --kind tool_failure --actor-id "$ACTOR_ID" \
    --narrative "valuation e2e smoke check FAILED against the deployed stack (rc=$rc): a cross-service defect in the client->server->commander valuation journey. See scripts/smoke_valuation_e2e.py output; runbook docs/valuation-smoke.md." \
    >/dev/null 2>&1 || echo "(failure-mode log could not be recorded)"
fi

exit $rc
