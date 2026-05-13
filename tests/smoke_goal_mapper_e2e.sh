#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Goal Mapper E2E Smoke Test — Durable Closure Artifact
#
# Validates all 11 closure criteria from epic #11978 against a deployed
# environment. Creates two fresh test users, drives the API in the same shape
# the frontend uses, and asserts every criterion. Cleans up after itself.
#
# Idempotent: safe to run repeatedly. Uses timestamped usernames to avoid
# collisions with prior runs.
#
# Usage:
#   ./tests/smoke_goal_mapper_e2e.sh                    # default: localhost:8081
#   SERVER_PORT=443 BASE_URL=https://the-aspirant.com/api ./tests/smoke_goal_mapper_e2e.sh
#
# Requires: an admin user exists (BOOTSTRAP_USER/BOOTSTRAP_PASS) to create
# test users. The bootstrap endpoint is called first (idempotent).
# ==============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-10}"
SERVER_PORT="${SERVER_PORT:-8081}"
BASE_URL="${BASE_URL:-http://localhost:${SERVER_PORT}}"

BOOTSTRAP_USER="${BOOTSTRAP_USER:-integration_admin}"
BOOTSTRAP_PASS="${BOOTSTRAP_PASS:-integration_pass_42}"

RUN_ID=$(date +%s)
USER_A="smoke_user_a_${RUN_ID}"
USER_B="smoke_user_b_${RUN_ID}"
PASS_A="SmokePassA_${RUN_ID}!"
PASS_B="SmokePassB_${RUN_ID}!"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

PASSED=0
FAILED=0

pass() {
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}PASS${RESET}  %s\n" "$1"
}

fail() {
    FAILED=$((FAILED + 1))
    printf "  ${RED}FAIL${RESET}  %s — %s\n" "$1" "${2:-}"
}

separator() {
    echo ""
    printf "${BOLD}── %s ──${RESET}\n" "$1"
}

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
acurl() {
    local token=$1; shift
    curl -s --max-time "$REQUEST_TIMEOUT" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "$@" 2>/dev/null
}

scurl() {
    local token=$1; shift
    local session=$1; shift
    curl -s --max-time "$REQUEST_TIMEOUT" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -H "X-Editing-Session-ID: ${session}" \
        "$@" 2>/dev/null
}

extract_id() {
    echo "$1" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2
}

extract_token() {
    echo "$1" | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4
}

# ---------------------------------------------------------------------------
# Setup: Bootstrap admin + create two test users
# ---------------------------------------------------------------------------
separator "Setup: Create test users"

# Bootstrap admin (idempotent)
curl -s --max-time "$REQUEST_TIMEOUT" \
    -X POST "${BASE_URL}/bootstrap/admin" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${BOOTSTRAP_USER}\",\"password\":\"${BOOTSTRAP_PASS}\"}" > /dev/null 2>&1 || true

# Login as admin
ADMIN_RESP=$(curl -s --max-time "$REQUEST_TIMEOUT" \
    -X POST "${BASE_URL}/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${BOOTSTRAP_USER}\",\"password\":\"${BOOTSTRAP_PASS}\"}" 2>/dev/null)

ADMIN_TOKEN=$(extract_token "$ADMIN_RESP")
if [[ -z "$ADMIN_TOKEN" ]]; then
    printf "${RED}FATAL: Could not obtain admin JWT. Is the server running at ${BASE_URL}?${RESET}\n"
    exit 1
fi

pass "Admin authenticated"

# Create User A (Trusted role)
CREATE_A_RESP=$(acurl "$ADMIN_TOKEN" -X POST "${BASE_URL}/data_models/users" \
    -d "{\"username\":\"${USER_A}\",\"password\":\"${PASS_A}\",\"access_role\":\"Trusted\"}")

if echo "$CREATE_A_RESP" | grep -q '"username"'; then
    pass "Created User A (${USER_A})"
elif echo "$CREATE_A_RESP" | grep -q "already exists"; then
    pass "User A already exists (idempotent)"
else
    fail "Create User A" "$(echo "$CREATE_A_RESP" | head -c 200)"
    exit 1
fi

# Create User B (Trusted role)
CREATE_B_RESP=$(acurl "$ADMIN_TOKEN" -X POST "${BASE_URL}/data_models/users" \
    -d "{\"username\":\"${USER_B}\",\"password\":\"${PASS_B}\",\"access_role\":\"Trusted\"}")

if echo "$CREATE_B_RESP" | grep -q '"username"'; then
    pass "Created User B (${USER_B})"
elif echo "$CREATE_B_RESP" | grep -q "already exists"; then
    pass "User B already exists (idempotent)"
else
    fail "Create User B" "$(echo "$CREATE_B_RESP" | head -c 200)"
    exit 1
fi

# Login as User A
LOGIN_A_RESP=$(curl -s --max-time "$REQUEST_TIMEOUT" \
    -X POST "${BASE_URL}/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${USER_A}\",\"password\":\"${PASS_A}\"}" 2>/dev/null)
TOKEN_A=$(extract_token "$LOGIN_A_RESP")

if [[ -z "$TOKEN_A" ]]; then
    fail "Login User A" "$(echo "$LOGIN_A_RESP" | head -c 200)"
    exit 1
fi
pass "User A authenticated"

# Login as User B
LOGIN_B_RESP=$(curl -s --max-time "$REQUEST_TIMEOUT" \
    -X POST "${BASE_URL}/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${USER_B}\",\"password\":\"${PASS_B}\"}" 2>/dev/null)
TOKEN_B=$(extract_token "$LOGIN_B_RESP")

if [[ -z "$TOKEN_B" ]]; then
    fail "Login User B" "$(echo "$LOGIN_B_RESP" | head -c 200)"
    exit 1
fi
pass "User B authenticated"

# ===========================================================================
# Criterion 1: User can log in and access /goals/trees
# ===========================================================================
separator "Criterion 1: Login + access goals endpoint"

TREES_A_RESP=$(acurl "$TOKEN_A" "${BASE_URL}/goals/trees")
if echo "$TREES_A_RESP" | grep -qE '^\['; then
    pass "User A can access /goals/trees (returns array)"
else
    fail "User A /goals/trees" "$(echo "$TREES_A_RESP" | head -c 200)"
fi

# ===========================================================================
# Criterion 2: Create a tree; it appears in the list
# ===========================================================================
separator "Criterion 2: Create tree + list"

TREE_RESP=$(acurl "$TOKEN_A" -X POST "${BASE_URL}/goals/trees" \
    -d "{\"name\":\"Smoke E2E ${RUN_ID}\"}")
TREE_ID=$(extract_id "$TREE_RESP")

if [[ -z "$TREE_ID" || "$TREE_ID" == "null" ]]; then
    fail "Create tree" "$(echo "$TREE_RESP" | head -c 200)"
    exit 1
fi
pass "Created tree (id=${TREE_ID})"

# Verify it appears in list
TREES_LIST=$(acurl "$TOKEN_A" "${BASE_URL}/goals/trees")
if echo "$TREES_LIST" | grep -q "\"id\":${TREE_ID}"; then
    pass "Tree appears in list"
else
    fail "Tree not found in list" ""
fi

# ===========================================================================
# Criterion 3: Open tree without error (fetch nodes returns 200)
# ===========================================================================
separator "Criterion 3: Open tree (fetch nodes)"

NODES_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -H "Authorization: Bearer ${TOKEN_A}" \
    "${BASE_URL}/goals/trees/${TREE_ID}/nodes" 2>/dev/null)

if [[ "$NODES_CODE" == "200" ]]; then
    pass "GET /goals/trees/${TREE_ID}/nodes returns 200"
else
    fail "Open tree nodes" "HTTP ${NODES_CODE}"
fi

# Open editing session for write operations
SESSION_RESP=$(acurl "$TOKEN_A" -X POST "${BASE_URL}/goals/trees/${TREE_ID}/open")
SESSION_A=$(echo "$SESSION_RESP" | grep -o '"editing_session_id":"[^"]*"' | cut -d'"' -f4)

if [[ -z "$SESSION_A" ]]; then
    fail "Open editing session" "$(echo "$SESSION_RESP" | head -c 200)"
    exit 1
fi
pass "Opened editing session"

# ===========================================================================
# Criterion 4: Add a goal node; it appears in nodes list
# ===========================================================================
separator "Criterion 4: Add goal node"

GOAL_RESP=$(scurl "$TOKEN_A" "$SESSION_A" -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d '{"name":"Q1 Objective","type":"goal","color":"#4A90D9"}')
GOAL_ID=$(extract_id "$GOAL_RESP")

if [[ -z "$GOAL_ID" ]]; then
    fail "Create goal node" "$(echo "$GOAL_RESP" | head -c 200)"
    exit 1
fi
pass "Created goal node (id=${GOAL_ID})"

# Verify it appears in nodes list
NODES_AFTER=$(acurl "$TOKEN_A" "${BASE_URL}/goals/trees/${TREE_ID}/nodes")
if echo "$NODES_AFTER" | grep -q "\"id\":${GOAL_ID}"; then
    pass "Goal node appears in nodes list"
else
    fail "Goal node not in nodes list" ""
fi

# ===========================================================================
# Criterion 5: Add milestone child; it appears connected (parent_id set)
# ===========================================================================
separator "Criterion 5: Add milestone child"

MILE_RESP=$(scurl "$TOKEN_A" "$SESSION_A" -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Ship Feature X\",\"type\":\"milestone\",\"parent_id\":${GOAL_ID}}")
MILE_ID=$(extract_id "$MILE_RESP")

if [[ -z "$MILE_ID" ]]; then
    fail "Create milestone" "$(echo "$MILE_RESP" | head -c 200)"
    exit 1
fi

# Verify parent_id linkage (how the frontend derives edges)
MILE_PARENT=$(echo "$MILE_RESP" | grep -o '"parent_id":[0-9]*' | cut -d: -f2)
if [[ "$MILE_PARENT" == "$GOAL_ID" ]]; then
    pass "Milestone connected to goal (parent_id=${GOAL_ID})"
else
    fail "Milestone parent_id mismatch" "Expected ${GOAL_ID}, got ${MILE_PARENT}"
fi

# ===========================================================================
# Criterion 6: Add step child; it appears connected
# ===========================================================================
separator "Criterion 6: Add step children"

STEP1_RESP=$(scurl "$TOKEN_A" "$SESSION_A" -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Write tests\",\"type\":\"step\",\"parent_id\":${MILE_ID}}")
STEP1_ID=$(extract_id "$STEP1_RESP")

if [[ -z "$STEP1_ID" ]]; then
    fail "Create step 1" "$(echo "$STEP1_RESP" | head -c 200)"
    exit 1
fi
pass "Created step 1 (id=${STEP1_ID})"

# Also test with planned dates (exercises the date format fix from PR #87)
STEP2_RESP=$(scurl "$TOKEN_A" "$SESSION_A" -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Deploy\",\"type\":\"step\",\"parent_id\":${MILE_ID},\"planned_start\":\"2026-05-13T00:00:00Z\",\"planned_end\":\"2026-05-20T00:00:00Z\"}")
STEP2_ID=$(extract_id "$STEP2_RESP")

if [[ -z "$STEP2_ID" ]]; then
    fail "Create step 2 (with dates)" "$(echo "$STEP2_RESP" | head -c 200)"
    exit 1
fi
pass "Created step 2 with planned dates (id=${STEP2_ID})"

# Verify both have correct parent
STEP1_PARENT=$(echo "$STEP1_RESP" | grep -o '"parent_id":[0-9]*' | cut -d: -f2)
STEP2_PARENT=$(echo "$STEP2_RESP" | grep -o '"parent_id":[0-9]*' | cut -d: -f2)
if [[ "$STEP1_PARENT" == "$MILE_ID" && "$STEP2_PARENT" == "$MILE_ID" ]]; then
    pass "Both steps connected to milestone (parent_id=${MILE_ID})"
else
    fail "Step parent_id mismatch" "step1=${STEP1_PARENT}, step2=${STEP2_PARENT}"
fi

# ===========================================================================
# Criterion 7: Complete steps → milestone auto-completes (auto-rollup)
# ===========================================================================
separator "Criterion 7: Completion + auto-rollup"

# Complete step 1
COMP1_RESP=$(scurl "$TOKEN_A" "$SESSION_A" -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${STEP1_ID}/complete")
if echo "$COMP1_RESP" | grep -q '"completed_at"'; then
    pass "Step 1 completed"
else
    fail "Complete step 1" "$(echo "$COMP1_RESP" | head -c 200)"
fi

# Milestone should NOT be auto-complete yet (step 2 still open)
MILE_STATE=$(acurl "$TOKEN_A" "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${MILE_ID}")
if ! echo "$MILE_STATE" | grep -q '"completed_at"'; then
    pass "Milestone still incomplete (1/2 steps done)"
else
    fail "Milestone should not be complete yet" ""
fi

# Complete step 2
COMP2_RESP=$(scurl "$TOKEN_A" "$SESSION_A" -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${STEP2_ID}/complete")
if echo "$COMP2_RESP" | grep -q '"completed_at"'; then
    pass "Step 2 completed"
else
    fail "Complete step 2" "$(echo "$COMP2_RESP" | head -c 200)"
fi

# Now milestone should auto-complete
MILE_STATE2=$(acurl "$TOKEN_A" "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${MILE_ID}")
if echo "$MILE_STATE2" | grep -q '"completed_at"'; then
    pass "Milestone auto-completed (all steps done)"
else
    fail "Milestone should auto-complete" "$(echo "$MILE_STATE2" | head -c 200)"
fi

# Verify it was auto (not manual)
if echo "$MILE_STATE2" | grep -q '"manual_complete":false'; then
    pass "Auto-rollup flagged as non-manual"
else
    fail "manual_complete should be false" ""
fi

# Goal should also auto-complete (only child milestone is done)
GOAL_STATE=$(acurl "$TOKEN_A" "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${GOAL_ID}")
if echo "$GOAL_STATE" | grep -q '"completed_at"'; then
    pass "Goal auto-completed (cascade to root)"
else
    fail "Goal should auto-complete via cascade" ""
fi

# ===========================================================================
# Criterion 8: Switch trees and switch back; state persists
# ===========================================================================
separator "Criterion 8: Tree switching persistence"

# Create a second tree
TREE2_RESP=$(acurl "$TOKEN_A" -X POST "${BASE_URL}/goals/trees" \
    -d "{\"name\":\"Smoke E2E Tree2 ${RUN_ID}\"}")
TREE2_ID=$(extract_id "$TREE2_RESP")

if [[ -z "$TREE2_ID" ]]; then
    fail "Create second tree" "$(echo "$TREE2_RESP" | head -c 200)"
else
    pass "Created second tree (id=${TREE2_ID})"

    # "Switch" to tree 2 (fetch its nodes)
    TREE2_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
        -H "Authorization: Bearer ${TOKEN_A}" \
        "${BASE_URL}/goals/trees/${TREE2_ID}/nodes" 2>/dev/null)
    if [[ "$TREE2_CODE" == "200" ]]; then
        pass "Switched to tree 2 (HTTP 200)"
    else
        fail "Switch to tree 2" "HTTP ${TREE2_CODE}"
    fi

    # "Switch back" to tree 1 — verify our nodes are still there
    TREE1_NODES=$(acurl "$TOKEN_A" "${BASE_URL}/goals/trees/${TREE_ID}/nodes")
    TREE1_COUNT=$(echo "$TREE1_NODES" | grep -o '"id":' | wc -l | tr -d ' ')
    if [[ "$TREE1_COUNT" -ge 4 ]]; then
        pass "Switched back to tree 1, state persisted (${TREE1_COUNT} nodes)"
    else
        fail "Tree 1 state lost after switch" "Expected >=4 nodes, got ${TREE1_COUNT}"
    fi
fi

# ===========================================================================
# Criterion 9: Soft-delete middle node → edges reconnect (V2 invariant)
# ===========================================================================
separator "Criterion 9: Soft-delete edge survival"

# Uncomplete the goal first so we can work with the hierarchy
# Create a fresh sub-tree for this test: Goal2 → Mile2 → Step3
GOAL2_RESP=$(scurl "$TOKEN_A" "$SESSION_A" -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d '{"name":"Edge Test Goal","type":"goal","color":"#FF5500"}')
GOAL2_ID=$(extract_id "$GOAL2_RESP")

MILE2_RESP=$(scurl "$TOKEN_A" "$SESSION_A" -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Edge Test Mile\",\"type\":\"milestone\",\"parent_id\":${GOAL2_ID}}")
MILE2_ID=$(extract_id "$MILE2_RESP")

STEP3_RESP=$(scurl "$TOKEN_A" "$SESSION_A" -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Edge Test Step\",\"type\":\"step\",\"parent_id\":${MILE2_ID}}")
STEP3_ID=$(extract_id "$STEP3_RESP")

if [[ -z "$GOAL2_ID" || -z "$MILE2_ID" || -z "$STEP3_ID" ]]; then
    fail "Create edge-test hierarchy" "IDs: ${GOAL2_ID}, ${MILE2_ID}, ${STEP3_ID}"
else
    pass "Created hierarchy: Goal2(${GOAL2_ID}) → Mile2(${MILE2_ID}) → Step3(${STEP3_ID})"

    # Delete the middle node (Mile2)
    DEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
        -X DELETE \
        -H "Authorization: Bearer ${TOKEN_A}" \
        -H "Content-Type: application/json" \
        -H "X-Editing-Session-ID: ${SESSION_A}" \
        "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${MILE2_ID}" 2>/dev/null)

    if [[ "$DEL_CODE" =~ ^2 ]]; then
        pass "Deleted middle node Mile2 (HTTP ${DEL_CODE})"
    else
        fail "Delete Mile2" "HTTP ${DEL_CODE}"
    fi

    # Verify Mile2 is gone (404)
    MILE2_CHECK=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
        -H "Authorization: Bearer ${TOKEN_A}" \
        "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${MILE2_ID}" 2>/dev/null)
    if [[ "$MILE2_CHECK" == "404" ]]; then
        pass "Mile2 returns 404 (soft-deleted)"
    else
        fail "Mile2 should be 404" "HTTP ${MILE2_CHECK}"
    fi

    # Verify Step3's parent is now Goal2 (edge survival)
    STEP3_STATE=$(acurl "$TOKEN_A" "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${STEP3_ID}")
    STEP3_PARENT=$(echo "$STEP3_STATE" | grep -o '"parent_id":[0-9]*' | cut -d: -f2)
    if [[ "$STEP3_PARENT" == "$GOAL2_ID" ]]; then
        pass "Step3 reattached to Goal2 (edge survival confirmed)"
    else
        fail "Step3 parent should be Goal2" "Got parent_id=${STEP3_PARENT}"
    fi

    # Verify the edge is visible in the full nodes list (how frontend derives edges)
    ALL_NODES=$(acurl "$TOKEN_A" "${BASE_URL}/goals/trees/${TREE_ID}/nodes")
    if echo "$ALL_NODES" | grep -q "\"id\":${STEP3_ID}" && \
       ! echo "$ALL_NODES" | grep -q "\"id\":${MILE2_ID}"; then
        pass "Nodes list: Step3 present, Mile2 absent"
    else
        fail "Nodes list inconsistency" ""
    fi
fi

# ===========================================================================
# Criterion 10: Timeline filter works without errors
# ===========================================================================
separator "Criterion 10: Timeline filter"

CURRENT_MONTH=$(date +%Y-%m)
CURRENT_YEAR=$(date +%Y)

# Mode: achieved, current month — should include the completed nodes
ACHIEVED_RESP=$(acurl "$TOKEN_A" \
    "${BASE_URL}/goals/trees/${TREE_ID}/nodes?period=month&value=${CURRENT_MONTH}&mode=achieved")
ACHIEVED_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -H "Authorization: Bearer ${TOKEN_A}" \
    "${BASE_URL}/goals/trees/${TREE_ID}/nodes?period=month&value=${CURRENT_MONTH}&mode=achieved" 2>/dev/null)

if [[ "$ACHIEVED_CODE" == "200" ]]; then
    pass "Timeline achieved filter returns 200"
else
    fail "Timeline achieved filter" "HTTP ${ACHIEVED_CODE}"
fi

# Should include our completed nodes (goal + milestone + 2 steps = at least 4)
ACHIEVED_COUNT=$(echo "$ACHIEVED_RESP" | grep -o '"completed_at"' | wc -l | tr -d ' ')
if [[ "$ACHIEVED_COUNT" -ge 4 ]]; then
    pass "Achieved filter: ${ACHIEVED_COUNT} completed nodes returned"
else
    fail "Achieved filter: expected >=4 completed" "Got ${ACHIEVED_COUNT}"
fi

# Mode: planned, current year — should work without error
PLANNED_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -H "Authorization: Bearer ${TOKEN_A}" \
    "${BASE_URL}/goals/trees/${TREE_ID}/nodes?period=year&value=${CURRENT_YEAR}&mode=planned" 2>/dev/null)

if [[ "$PLANNED_CODE" == "200" ]]; then
    pass "Timeline planned filter returns 200"
else
    fail "Timeline planned filter" "HTTP ${PLANNED_CODE}"
fi

# Past month — should return 0 achieved nodes
PAST_RESP=$(acurl "$TOKEN_A" \
    "${BASE_URL}/goals/trees/${TREE_ID}/nodes?period=month&value=2020-01&mode=achieved")
PAST_COUNT=$(echo "$PAST_RESP" | grep -o '"id":' | wc -l | tr -d ' ')
if [[ "$PAST_COUNT" -eq 0 ]]; then
    pass "Timeline past month: 0 nodes (correct)"
else
    fail "Timeline past month: expected 0" "Got ${PAST_COUNT}"
fi

# ===========================================================================
# Criterion 11: User isolation (User B cannot see User A's trees)
# ===========================================================================
separator "Criterion 11: User isolation (V3 invariant)"

# User B lists their trees — should NOT include User A's tree
TREES_B=$(acurl "$TOKEN_B" "${BASE_URL}/goals/trees")
if ! echo "$TREES_B" | grep -q "\"id\":${TREE_ID}"; then
    pass "User B cannot see User A's tree in list"
else
    fail "User B can see User A's tree (isolation broken)" ""
fi

# User B tries to GET User A's tree directly
TREE_B_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -H "Authorization: Bearer ${TOKEN_B}" \
    "${BASE_URL}/goals/trees/${TREE_ID}" 2>/dev/null)
if [[ "$TREE_B_CODE" == "404" ]]; then
    pass "User B GET /goals/trees/${TREE_ID} returns 404"
else
    fail "User B should get 404 for User A's tree" "HTTP ${TREE_B_CODE}"
fi

# User B tries to fetch nodes from User A's tree
NODES_B_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -H "Authorization: Bearer ${TOKEN_B}" \
    "${BASE_URL}/goals/trees/${TREE_ID}/nodes" 2>/dev/null)
if [[ "$NODES_B_CODE" == "404" ]]; then
    pass "User B GET /goals/trees/${TREE_ID}/nodes returns 404"
else
    fail "User B should get 404 for User A's nodes" "HTTP ${NODES_B_CODE}"
fi

# User B tries to PATCH User A's tree
PATCH_B_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -X PATCH \
    -H "Authorization: Bearer ${TOKEN_B}" \
    -H "Content-Type: application/json" \
    -d '{"name":"Hacked"}' \
    "${BASE_URL}/goals/trees/${TREE_ID}" 2>/dev/null)
if [[ "$PATCH_B_CODE" == "404" ]]; then
    pass "User B PATCH /goals/trees/${TREE_ID} returns 404"
else
    fail "User B should get 404 for PATCH" "HTTP ${PATCH_B_CODE}"
fi

# User B tries to DELETE User A's tree
DEL_B_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -X DELETE \
    -H "Authorization: Bearer ${TOKEN_B}" \
    "${BASE_URL}/goals/trees/${TREE_ID}" 2>/dev/null)
if [[ "$DEL_B_CODE" == "404" ]]; then
    pass "User B DELETE /goals/trees/${TREE_ID} returns 404"
else
    fail "User B should get 404 for DELETE" "HTTP ${DEL_B_CODE}"
fi

# ===========================================================================
# Cleanup: Delete test trees
# ===========================================================================
separator "Cleanup"

# Delete tree 1 (User A)
DEL1_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -X DELETE \
    -H "Authorization: Bearer ${TOKEN_A}" \
    -H "X-Editing-Session-ID: ${SESSION_A}" \
    "${BASE_URL}/goals/trees/${TREE_ID}" 2>/dev/null)

if [[ "$DEL1_CODE" =~ ^2 ]]; then
    pass "Deleted tree 1 (HTTP ${DEL1_CODE})"
else
    fail "Delete tree 1" "HTTP ${DEL1_CODE}"
fi

# Delete tree 2 if it was created
if [[ -n "${TREE2_ID:-}" ]]; then
    # Need a session for tree 2
    SESSION2_RESP=$(acurl "$TOKEN_A" -X POST "${BASE_URL}/goals/trees/${TREE2_ID}/open")
    SESSION2=$(echo "$SESSION2_RESP" | grep -o '"editing_session_id":"[^"]*"' | cut -d'"' -f4)

    DEL2_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
        -X DELETE \
        -H "Authorization: Bearer ${TOKEN_A}" \
        -H "X-Editing-Session-ID: ${SESSION2:-none}" \
        "${BASE_URL}/goals/trees/${TREE2_ID}" 2>/dev/null)

    if [[ "$DEL2_CODE" =~ ^2 ]]; then
        pass "Deleted tree 2 (HTTP ${DEL2_CODE})"
    else
        fail "Delete tree 2" "HTTP ${DEL2_CODE}"
    fi
fi

# Delete test users (admin endpoint)
for UNAME in "$USER_A" "$USER_B"; do
    # Get user ID first
    USERS_RESP=$(acurl "$ADMIN_TOKEN" "${BASE_URL}/data_models/users")
    UID_VAL=$(echo "$USERS_RESP" | grep -o "\"id\":[0-9]*,\"username\":\"${UNAME}\"" | grep -o '"id":[0-9]*' | cut -d: -f2)
    if [[ -n "$UID_VAL" ]]; then
        DEL_U_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
            -X DELETE \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" \
            "${BASE_URL}/data_models/users/${UID_VAL}" 2>/dev/null)
        if [[ "$DEL_U_CODE" =~ ^2 ]]; then
            pass "Deleted user ${UNAME} (HTTP ${DEL_U_CODE})"
        else
            # Not fatal — test users will be orphaned but won't interfere
            printf "  ${YELLOW}WARN${RESET}  Could not delete ${UNAME} (HTTP ${DEL_U_CODE})\n"
        fi
    fi
done

# ===========================================================================
# Summary
# ===========================================================================
echo ""
printf "${BOLD}══ Goal Mapper E2E Smoke Summary ══${RESET}\n"
TOTAL=$((PASSED + FAILED))
printf "  ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}  (total: %d)\n" \
    "$PASSED" "$FAILED" "$TOTAL"
echo ""

if [[ "$FAILED" -gt 0 ]]; then
    printf "${RED}Goal Mapper E2E smoke FAILED.${RESET}\n"
    exit 1
fi

printf "${GREEN}All 11 closure criteria verified.${RESET}\n"
exit 0
