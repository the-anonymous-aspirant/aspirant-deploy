#!/usr/bin/env bash
set -euo pipefail

# Unit tests for scripts/auto-pull.sh's pure logic — decide(),
# log_decision(), the known-bad cache helpers, the checkout gates and the
# checkout fast-forward. No docker required: the last section runs the whole
# script in cron shape inside a scratch clone, where `docker compose ps` finds
# no project and the sweep is empty.
#
# Usage: ./tests/auto_pull_unit.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export ASPIRANT_AUTO_PULL_LOG_DIR="$TMPDIR_TEST/log"
export ASPIRANT_AUTO_PULL_STATE_DIR="$TMPDIR_TEST/state"
export ASPIRANT_AUTO_PULL_LIB=1

# Source the script in library mode (returns before main loop).
# shellcheck disable=SC1091
source ./scripts/auto-pull.sh

PASS=0
FAIL=0

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL  %s — expected %q got %q\n" "$label" "$expected" "$actual"
  fi
}

# decide() — same SHA on both sides → no_change
got="$(decide "sha256:aaa" "sha256:aaa" "$KNOWN_BAD_FILE")"
assert_eq "no_change" "$got" "decide returns no_change when SHAs match"

# decide() — different SHA, latest not known-bad → deploy
got="$(decide "sha256:old" "sha256:new" "$KNOWN_BAD_FILE")"
assert_eq "deploy" "$got" "decide returns deploy when SHAs differ and latest is clean"

# decide() — different SHA, latest IS known-bad → deferred_known_bad
echo "sha256:bad" > "$KNOWN_BAD_FILE"
got="$(decide "sha256:old" "sha256:bad" "$KNOWN_BAD_FILE")"
assert_eq "deferred_known_bad" "$got" "decide defers when latest is in known-bad list"

# decide() — latest empty (image never pulled) → skip_no_image
got="$(decide "sha256:old" "" "$KNOWN_BAD_FILE")"
assert_eq "skip_no_image" "$got" "decide skips when latest image SHA is empty"

# decide() — no current container (fresh boot), latest available → deploy
got="$(decide "" "sha256:new" "$KNOWN_BAD_FILE")"
assert_eq "deploy" "$got" "decide deploys when no current SHA but latest is set"

# mark_known_bad — appends new sha
: > "$KNOWN_BAD_FILE"
mark_known_bad "sha256:fail1"
got="$(cat "$KNOWN_BAD_FILE")"
assert_eq "sha256:fail1" "$got" "mark_known_bad writes new sha"

# mark_known_bad — does not duplicate
mark_known_bad "sha256:fail1"
got="$(wc -l < "$KNOWN_BAD_FILE")"
assert_eq "1" "$got" "mark_known_bad is idempotent"

# mark_known_bad — empty sha is a no-op
mark_known_bad ""
got="$(wc -l < "$KNOWN_BAD_FILE")"
assert_eq "1" "$got" "mark_known_bad ignores empty sha"

# is_known_bad — recognises a recorded sha
if is_known_bad "sha256:fail1"; then
  PASS=$((PASS + 1)); printf "  PASS  is_known_bad detects recorded sha\n"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  is_known_bad missed recorded sha\n"
fi

# is_known_bad — false for unrecorded sha
if is_known_bad "sha256:never"; then
  FAIL=$((FAIL + 1)); printf "  FAIL  is_known_bad false-positive on unknown sha\n"
else
  PASS=$((PASS + 1)); printf "  PASS  is_known_bad returns false for unknown sha\n"
fi

# log_decision — writes one JSON line with all fields
: > "$DECISIONS_LOG"
log_decision "server" "deploy" "sha256:old" "sha256:new" "test_reason"
got="$(wc -l < "$DECISIONS_LOG")"
assert_eq "1" "$got" "log_decision appends one line"

line="$(cat "$DECISIONS_LOG")"
for field in '"service":"server"' '"action":"deploy"' '"from_sha":"sha256:old"' '"to_sha":"sha256:new"' '"reason":"test_reason"' '"ts":'; do
  if [[ "$line" == *"$field"* ]]; then
    PASS=$((PASS + 1)); printf "  PASS  log line contains %s\n" "$field"
  else
    FAIL=$((FAIL + 1)); printf "  FAIL  log line missing %s — got %s\n" "$field" "$line"
  fi
done

# --- maintenance_paused ------------------------------------------------------

MARKER="$TMPDIR_TEST/.maintenance-pause"

if maintenance_paused "$MARKER"; then
  FAIL=$((FAIL + 1)); printf "  FAIL  maintenance_paused true with no marker present\n"
else
  PASS=$((PASS + 1)); printf "  PASS  maintenance_paused false when marker absent\n"
fi

touch "$MARKER"
if maintenance_paused "$MARKER"; then
  PASS=$((PASS + 1)); printf "  PASS  maintenance_paused true when marker present\n"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  maintenance_paused missed an existing marker\n"
fi

# An empty marker still pauses — presence is the signal, contents are advisory.
: > "$MARKER"
if maintenance_paused "$MARKER"; then
  PASS=$((PASS + 1)); printf "  PASS  maintenance_paused true for an empty marker\n"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  maintenance_paused required marker contents\n"
fi
rm -f "$MARKER"

# --- checkout_provenance -----------------------------------------------------

# A non-repo directory cannot prove its compose file's provenance.
NOT_A_REPO="$TMPDIR_TEST/not-a-repo"
mkdir -p "$NOT_A_REPO"
got="$(checkout_provenance "$NOT_A_REPO")"
assert_eq "not_a_git_checkout" "$got" "checkout_provenance refuses a non-git directory"

# Build a local "origin" and a clone of it so upstream tracking is real.
ORIGIN_REPO="$TMPDIR_TEST/origin.git"
git init -q --bare --initial-branch=main "$ORIGIN_REPO"

SEED="$TMPDIR_TEST/seed"
git init -q --initial-branch=main "$SEED"
git -C "$SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed"
git -C "$SEED" remote add origin "$ORIGIN_REPO"
git -C "$SEED" push -q origin main

CLONE="$TMPDIR_TEST/clone"
git clone -q "$ORIGIN_REPO" "$CLONE"

got="$(checkout_provenance "$CLONE")"
assert_eq "ok" "$got" "checkout_provenance passes on main tracking origin/main"

# Untracked and modified files must NOT read as drift — the cell carries stray
# .bak files, and sweeping them into the gate would wedge every deploy.
touch "$CLONE/docker-compose.yml.bak-20260710-044340"
echo "dirty" > "$CLONE/tracked-change.txt"
git -C "$CLONE" add tracked-change.txt
got="$(checkout_provenance "$CLONE")"
assert_eq "ok" "$got" "checkout_provenance ignores untracked and staged working-tree files"

# On a feature branch → drift, naming the branch.
git -C "$CLONE" checkout -q -b feature/wip
got="$(checkout_provenance "$CLONE")"
assert_eq "branch_not_main:feature/wip" "$got" "checkout_provenance refuses a feature branch"

# Detached HEAD → drift (rev-parse --abbrev-ref reports the literal "HEAD").
git -C "$CLONE" checkout -q --detach
got="$(checkout_provenance "$CLONE")"
assert_eq "branch_not_main:HEAD" "$got" "checkout_provenance refuses a detached HEAD"

# On main, but tracking nothing → drift.
git -C "$CLONE" checkout -q main
git -C "$CLONE" branch --unset-upstream
got="$(checkout_provenance "$CLONE")"
assert_eq "upstream_not_origin_main:none" "$got" "checkout_provenance refuses main with no upstream"

# On main, but tracking the wrong remote branch → drift.
git -C "$CLONE" push -q origin main:release
git -C "$CLONE" fetch -q origin
git -C "$CLONE" branch --set-upstream-to=origin/release main >/dev/null 2>&1
got="$(checkout_provenance "$CLONE")"
assert_eq "upstream_not_origin_main:origin/release" "$got" "checkout_provenance refuses main tracking a non-origin/main upstream"

# --- checkout_freshness (#2534) ---------------------------------------------
#
# The provenance gate proves the checkout is on main tracking origin/main. It
# does NOT prove the checkout is current, which is how the cell sat six PRs
# behind while passing every gate (#2520). These assert the freshness detector
# separately, because a checkout can be perfectly provenanced and badly stale.

# A fresh clone is current.
FRESH="$TMPDIR_TEST/fresh"
git clone -q "$ORIGIN_REPO" "$FRESH"
got="$(checkout_freshness "$FRESH")"
assert_eq "current" "$got" "checkout_freshness reports current on an up-to-date clone"

# Advance origin by two commits without pulling the clone -> behind:2.
git -C "$SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "one"
git -C "$SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "two"
git -C "$SEED" push -q origin main
got="$(checkout_freshness "$FRESH")"
assert_eq "behind:2" "$got" "checkout_freshness counts commits behind origin/main"

# The provenance gate still passes on that same stale checkout -- which is the
# whole point of adding a second gate rather than extending the first.
got="$(checkout_provenance "$FRESH")"
assert_eq "ok" "$got" "a STALE checkout still passes the provenance gate"

# Pulling clears it.
git -C "$FRESH" pull -q --ff-only
got="$(checkout_freshness "$FRESH")"
assert_eq "current" "$got" "checkout_freshness clears after a pull"

# A non-git directory cannot be measured, and reports unknown rather than
# failing: the detector must never turn an unmeasurable state into an outage.
got="$(ASPIRANT_AUTO_PULL_SKIP_FETCH=1 checkout_freshness "$NOT_A_REPO")"
assert_eq "unknown:no_rev_list" "$got" "checkout_freshness reports unknown on a non-git directory"

# An unreachable origin reports unknown, not stale. A dead uplink is routine on
# the cell, and a detector that read it as drift would cry wolf every tick.
UNREACHABLE="$TMPDIR_TEST/unreachable"
git clone -q "$ORIGIN_REPO" "$UNREACHABLE"
git -C "$UNREACHABLE" remote set-url origin "$TMPDIR_TEST/does-not-exist.git"
got="$(checkout_freshness "$UNREACHABLE")"
assert_eq "unknown:fetch_failed" "$got" "checkout_freshness reports unknown when origin is unreachable"

# --- service enumeration ------------------------------------------------------
#
# The sweep enumerates services by the ref each container was CREATED from
# (.Config.Image), never by the ref `docker compose ps` prints, because the ps
# column is resolved through the local tag store and turns into a bare
# `sha256:…` the moment `:latest` moves off the running image — after a hand
# `docker pull` (system_3 #4184) or after this script's own failed blue/green
# (#4489: 20 merged aspirant-client PRs undeployed for two days, no decision
# line). These cases pin the filter to the create-time ref.

if is_polled_image_ref "${IMAGE_PREFIX}client:latest"; then
  PASS=$((PASS + 1)); printf "  PASS  is_polled_image_ref accepts prefix + :latest\n"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  is_polled_image_ref rejected a prefix + :latest ref\n"
fi

if is_polled_image_ref "ghcr.io/kiwix/kiwix-serve:latest"; then
  FAIL=$((FAIL + 1)); printf "  FAIL  is_polled_image_ref accepted a foreign-prefix ref\n"
else
  PASS=$((PASS + 1)); printf "  PASS  is_polled_image_ref rejects a ref outside the prefix\n"
fi

if is_polled_image_ref "${IMAGE_PREFIX}penpot-backend:2.16.2@sha256:c322cb8f"; then
  FAIL=$((FAIL + 1)); printf "  FAIL  is_polled_image_ref accepted a digest-pinned ref\n"
else
  PASS=$((PASS + 1)); printf "  PASS  is_polled_image_ref rejects a digest-pinned ref\n"
fi

# The regression: a bare image ID is what `docker compose ps` prints once the
# tag has moved. It must never reach the filter as the ref — and if it does,
# the filter drops it, which is the two-day silence this change removes.
if is_polled_image_ref "sha256:ab6e35ed5f1ea70e70de7dbbda69bee18038567b2dad82a50252faf7dc4f06b9"; then
  FAIL=$((FAIL + 1)); printf "  FAIL  is_polled_image_ref accepted a bare image ID\n"
else
  PASS=$((PASS + 1)); printf "  PASS  is_polled_image_ref rejects a bare image ID\n"
fi

# select_polled_services keys on column 3 (the create-time ref) and passes
# the row through intact; rows without a ref or outside the prefix are dropped.
got="$(printf '%s\n' \
  "client-green|aspirant-online-client-green-1|${IMAGE_PREFIX}client:latest" \
  "client-blue|aspirant-online-client-blue-1|${IMAGE_PREFIX}client:latest" \
  "postgres|aspirant-online-postgres-1|pgvector/pgvector:pg16" \
  "penpot-redis|aspirant-online-penpot-redis-1|${IMAGE_PREFIX}penpot-redis:7@sha256:33d3a320" \
  "orphan|aspirant-online-orphan-1|" \
  "server|aspirant-online-server-1|${IMAGE_PREFIX}server:latest" \
  | select_polled_services | tr '\n' ';')"
assert_eq "client-green|aspirant-online-client-green-1|${IMAGE_PREFIX}client:latest;client-blue|aspirant-online-client-blue-1|${IMAGE_PREFIX}client:latest;server|aspirant-online-server-1|${IMAGE_PREFIX}server:latest;" \
  "$got" "select_polled_services keeps :latest rows under the prefix, in order, and drops the rest"

# Both client slots stay in the sweep with the same ref; the main loop's
# SEEN_CLIENT guard, not the filter, is what collapses them to one deploy.
got="$(printf '%s\n' \
  "client-green|aspirant-online-client-green-1|${IMAGE_PREFIX}client:latest" \
  "client-blue|aspirant-online-client-blue-1|${IMAGE_PREFIX}client:latest" \
  | select_polled_services | wc -l)"
assert_eq "2" "$got" "select_polled_services does not dedupe the two client slots"

# Empty input is an empty sweep, not an error.
got="$(printf '' | select_polled_services | wc -l)"
assert_eq "0" "$got" "select_polled_services is empty on empty input"

# --- checkout_ff (#4537) -----------------------------------------------------
#
# Gate 3 reported `checkout_stale` on every tick for forty days and nothing
# pulled. These pin the self-heal: a fast-forward happens exactly when git can
# prove it loses nothing, and every refusal names its reason so the log line
# a human eventually reads says what to do.

# A stale clone with a clean tracked tree fast-forwards to origin/main.
STALE="$TMPDIR_TEST/stale"
git clone -q "$ORIGIN_REPO" "$STALE"
git -C "$SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "three"
git -C "$SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "four"
git -C "$SEED" push -q origin main
got="$(checkout_freshness "$STALE")"
assert_eq "behind:2" "$got" "checkout_ff fixture starts two behind"
before="$(git -C "$STALE" rev-parse HEAD)"
target="$(git -C "$STALE" rev-parse origin/main)"
got="$(checkout_ff_preflight "$STALE")"
assert_eq "ok" "$got" "checkout_ff_preflight passes on a clean stale clone"
got="$(checkout_ff "$STALE")"
assert_eq "ff:${before}..${target}" "$got" "checkout_ff fast-forwards and reports old..new"
assert_eq "$target" "$(git -C "$STALE" rev-parse HEAD)" "checkout_ff leaves HEAD at origin/main"
got="$(ASPIRANT_AUTO_PULL_SKIP_FETCH=1 checkout_freshness "$STALE")"
assert_eq "current" "$got" "checkout_ff clears the freshness gate"

# Untracked files do not block the fast-forward — the cell carries stray .bak
# files and a fast-forward never touches an untracked path.
git -C "$SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "five"
git -C "$SEED" push -q origin main
git -C "$STALE" fetch -q origin
touch "$STALE/docker-compose.yml.bak-20260710-044340"
before="$(git -C "$STALE" rev-parse HEAD)"
target="$(git -C "$STALE" rev-parse origin/main)"
got="$(checkout_ff "$STALE")"
assert_eq "ff:${before}..${target}" "$got" "checkout_ff ignores untracked files"

# A modified tracked file is someone's work in flight: refuse, touch nothing.
git -C "$SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "six"
git -C "$SEED" push -q origin main
git -C "$STALE" fetch -q origin
echo "edit" > "$STALE/tracked-change.txt"
git -C "$STALE" add tracked-change.txt
before="$(git -C "$STALE" rev-parse HEAD)"
got="$(checkout_ff "$STALE")"
assert_eq "refused:tracked_changes" "$got" "checkout_ff refuses when a tracked file is staged"
assert_eq "$before" "$(git -C "$STALE" rev-parse HEAD)" "checkout_ff leaves HEAD alone on refusal"
git -C "$STALE" reset -q --hard HEAD

# A local commit on main means HEAD is not an ancestor of origin/main: a
# fast-forward is impossible and only a human can say whether the local
# commit is a hotfix or a mistake. Refuse, and say which.
DIVERGED="$TMPDIR_TEST/diverged"
git clone -q "$ORIGIN_REPO" "$DIVERGED"
git -C "$DIVERGED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "local-only"
git -C "$SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seven"
git -C "$SEED" push -q origin main
git -C "$DIVERGED" fetch -q origin
before="$(git -C "$DIVERGED" rev-parse HEAD)"
got="$(checkout_ff "$DIVERGED")"
assert_eq "refused:not_fast_forward" "$got" "checkout_ff refuses a diverged main"
assert_eq "$before" "$(git -C "$DIVERGED" rev-parse HEAD)" "checkout_ff leaves a diverged HEAD alone"

# --- gate 3 in cron shape ----------------------------------------------------
#
# Run the real script, from a clone that carries it, as cron would: gates run,
# `docker compose ps` finds no project here so the sweep is empty, and the
# decisions ledger shows what gate 3 did. A separate log/state dir per run so
# the assertions read only this run's lines.

CRON_ORIGIN="$TMPDIR_TEST/cron-origin.git"
git init -q --bare --initial-branch=main "$CRON_ORIGIN"
CRON_SEED="$TMPDIR_TEST/cron-seed"
git init -q --initial-branch=main "$CRON_SEED"
mkdir -p "$CRON_SEED/scripts"
cp scripts/auto-pull.sh "$CRON_SEED/scripts/auto-pull.sh"
git -C "$CRON_SEED" add scripts/auto-pull.sh
git -C "$CRON_SEED" -c user.email=t@t -c user.name=t commit -q -m "seed script"
git -C "$CRON_SEED" remote add origin "$CRON_ORIGIN"
git -C "$CRON_SEED" push -q origin main
CRON_CLONE="$TMPDIR_TEST/cron-clone"
git clone -q "$CRON_ORIGIN" "$CRON_CLONE"
git -C "$CRON_SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "released"
git -C "$CRON_SEED" push -q origin main
cron_target="$(git -C "$CRON_SEED" rev-parse HEAD)"
cron_before="$(git -C "$CRON_CLONE" rev-parse HEAD)"

run_cron_shape() {
  # $1 = log dir; remaining args go to the script. Runs in a subshell with the
  # library flag cleared so the main loop executes.
  local logdir="$1"; shift
  (
    unset ASPIRANT_AUTO_PULL_LIB
    ASPIRANT_AUTO_PULL_LOG_DIR="$logdir" \
    ASPIRANT_AUTO_PULL_STATE_DIR="$logdir/state" \
      "$CRON_CLONE/scripts/auto-pull.sh" "$@" >/dev/null 2>&1
  )
}

# --dry-run: reports what it would do, touches nothing.
DRY_LOG="$TMPDIR_TEST/dry-log"
run_cron_shape "$DRY_LOG" --dry-run
line="$(grep -F '"service":"-"' "$DRY_LOG/decisions.jsonl" | tail -1)"
if [[ "$line" == *'"action":"would_checkout_ff"'* && "$line" == *'"reason":"behind:1;ok"'* ]]; then
  PASS=$((PASS + 1)); printf "  PASS  dry-run logs would_checkout_ff with the preflight verdict\n"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  dry-run gate line unexpected — got %s\n" "$line"
fi
assert_eq "$cron_before" "$(git -C "$CRON_CLONE" rev-parse HEAD)" "dry-run does not move the checkout"

# Live: fast-forwards, logs checkout_ff with from/to SHAs, exits 0.
LIVE_LOG="$TMPDIR_TEST/live-log"
if run_cron_shape "$LIVE_LOG"; then
  PASS=$((PASS + 1)); printf "  PASS  cron-shape run exits 0 after fast-forwarding\n"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  cron-shape run exited non-zero\n"
fi
line="$(grep -F '"action":"checkout_ff"' "$LIVE_LOG/decisions.jsonl" | tail -1)"
if [[ "$line" == *"\"from_sha\":\"$cron_before\""* && "$line" == *"\"to_sha\":\"$cron_target\""* && "$line" == *'"reason":"behind:1"'* ]]; then
  PASS=$((PASS + 1)); printf "  PASS  live run logs checkout_ff with from/to SHAs and the behind-count\n"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  live checkout_ff line unexpected — got %s\n" "$line"
fi
assert_eq "$cron_target" "$(git -C "$CRON_CLONE" rev-parse HEAD)" "live run leaves the clone at origin/main"
if grep -qF '"action":"checkout_stale"' "$LIVE_LOG/decisions.jsonl"; then
  FAIL=$((FAIL + 1)); printf "  FAIL  live run still logged checkout_stale\n"
else
  PASS=$((PASS + 1)); printf "  PASS  live run logs no checkout_stale\n"
fi

# Live, with a tracked edit in flight: refuses, names the reason, exits 0.
git -C "$CRON_SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "released-2"
git -C "$CRON_SEED" push -q origin main
echo "# local edit" >> "$CRON_CLONE/scripts/auto-pull.sh"
REFUSE_LOG="$TMPDIR_TEST/refuse-log"
if run_cron_shape "$REFUSE_LOG"; then
  PASS=$((PASS + 1)); printf "  PASS  cron-shape run exits 0 when it refuses to fast-forward\n"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  refused run exited non-zero\n"
fi
line="$(grep -F '"action":"checkout_stale"' "$REFUSE_LOG/decisions.jsonl" | tail -1)"
if [[ "$line" == *'"reason":"behind:1;refused:tracked_changes"'* ]]; then
  PASS=$((PASS + 1)); printf "  PASS  refused run logs checkout_stale with the refusal reason\n"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  refused checkout_stale line unexpected — got %s\n" "$line"
fi
assert_eq "$cron_target" "$(git -C "$CRON_CLONE" rev-parse HEAD)" "refused run does not move the checkout"

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
