#!/usr/bin/env bash
set -e

# ==============================================================================
# Goal Mapper — V1 Integration Test
#
# End-to-end test exercising:
#   1. Tree creation
#   2. Node creation through depth 5
#   3. Completing leaves → verifying auto-rollup to root
#   4. Timeline filter (achieved mode) returning correct results
#
# Requires: server running on SERVER_PORT with PostgreSQL connected.
# Usage: ./tests/integration_goal_mapper.sh
# ==============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-10}"
SERVER_PORT="${SERVER_PORT:-8081}"
BASE_URL="http://localhost:${SERVER_PORT}"

BOOTSTRAP_USER="${BOOTSTRAP_USER:-integration_admin}"
BOOTSTRAP_PASS="${BOOTSTRAP_PASS:-integration_pass_42}"

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
# Auth setup
# ---------------------------------------------------------------------------
separator "Setup: Authentication"

# Bootstrap admin user (idempotent — ignores if already exists)
curl -s --max-time "$REQUEST_TIMEOUT" \
    -X POST "${BASE_URL}/bootstrap/admin" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${BOOTSTRAP_USER}\",\"password\":\"${BOOTSTRAP_PASS}\"}" > /dev/null 2>&1 || true

# Login to get JWT
LOGIN_RESP=$(curl -s --max-time "$REQUEST_TIMEOUT" \
    -X POST "${BASE_URL}/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${BOOTSTRAP_USER}\",\"password\":\"${BOOTSTRAP_PASS}\"}" 2>/dev/null)

TOKEN=$(echo "$LOGIN_RESP" | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ -z "$TOKEN" ]]; then
    printf "${RED}FATAL: Could not obtain JWT token. Is the server running?${RESET}\n"
    printf "Login response: %s\n" "$LOGIN_RESP"
    exit 1
fi

pass "Obtained JWT token"

AUTH="-H \"Authorization: Bearer ${TOKEN}\""

# Helper: authenticated curl
acurl() {
    curl -s --max-time "$REQUEST_TIMEOUT" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        "$@" 2>/dev/null
}

# Helper: authenticated curl with session header
scurl() {
    curl -s --max-time "$REQUEST_TIMEOUT" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Editing-Session-ID: ${SESSION_ID}" \
        "$@" 2>/dev/null
}

# ===========================================================================
# Phase 1: Tree Creation
# ===========================================================================
separator "Phase 1: Create Tree"

TREE_RESP=$(acurl -X POST "${BASE_URL}/goals/trees" \
    -d '{"name":"Integration Test Tree"}')

TREE_ID=$(echo "$TREE_RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [[ -z "$TREE_ID" || "$TREE_ID" == "null" ]]; then
    printf "${RED}FATAL: Could not create tree.${RESET}\n"
    printf "Response: %s\n" "$TREE_RESP"
    exit 1
fi

pass "Created tree (id=${TREE_ID})"

# Open editing session for write operations
SESSION_RESP=$(acurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/open")
SESSION_ID=$(echo "$SESSION_RESP" | grep -o '"editing_session_id":"[^"]*"' | cut -d'"' -f4)

if [[ -z "$SESSION_ID" ]]; then
    printf "${RED}FATAL: Could not open editing session.${RESET}\n"
    printf "Response: %s\n" "$SESSION_RESP"
    exit 1
fi

pass "Opened editing session"

# ===========================================================================
# Phase 2: Create Nodes Through Depth 5
#
# Structure:
#   Root Goal (depth 1)
#   ├── Milestone A (depth 2)
#   │   ├── Step A1 (depth 3)
#   │   │   ├── Sub-step A1a (depth 4)
#   │   │   │   └── Leaf A1a-i (depth 5)
#   │   │   └── Sub-step A1b (depth 4)
#   │   │       └── Leaf A1b-i (depth 5)
#   │   └── Step A2 (depth 3) — a leaf at depth 3
#   └── Milestone B (depth 2)
#       └── Step B1 (depth 3) — a leaf at depth 3
# ===========================================================================
separator "Phase 2: Create Node Hierarchy (depth 1-5)"

# Depth 1: Root goal
ROOT_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d '{"name":"Root Goal","type":"goal","color":"#4A90D9"}')
ROOT_ID=$(echo "$ROOT_RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [[ -z "$ROOT_ID" ]]; then
    fail "Create root goal" "$(echo "$ROOT_RESP" | head -c 200)"
    exit 1
fi
pass "Created root goal (id=${ROOT_ID}, depth=1)"

# Depth 2: Milestone A
MILE_A_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Milestone A\",\"node_type\":\"milestone\",\"parent_id\":${ROOT_ID}}")
MILE_A_ID=$(echo "$MILE_A_RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [[ -z "$MILE_A_ID" ]]; then
    fail "Create Milestone A" "$(echo "$MILE_A_RESP" | head -c 200)"
    exit 1
fi
pass "Created Milestone A (id=${MILE_A_ID}, depth=2)"

# Depth 2: Milestone B
MILE_B_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Milestone B\",\"node_type\":\"milestone\",\"parent_id\":${ROOT_ID}}")
MILE_B_ID=$(echo "$MILE_B_RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [[ -z "$MILE_B_ID" ]]; then
    fail "Create Milestone B" "$(echo "$MILE_B_RESP" | head -c 200)"
    exit 1
fi
pass "Created Milestone B (id=${MILE_B_ID}, depth=2)"

# Depth 3: Step A1 (under Milestone A)
STEP_A1_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Step A1\",\"node_type\":\"step\",\"parent_id\":${MILE_A_ID}}")
STEP_A1_ID=$(echo "$STEP_A1_RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [[ -z "$STEP_A1_ID" ]]; then
    fail "Create Step A1" "$(echo "$STEP_A1_RESP" | head -c 200)"
    exit 1
fi
pass "Created Step A1 (id=${STEP_A1_ID}, depth=3)"

# Depth 3: Step A2 (under Milestone A, leaf)
STEP_A2_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Step A2\",\"node_type\":\"step\",\"parent_id\":${MILE_A_ID}}")
STEP_A2_ID=$(echo "$STEP_A2_RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [[ -z "$STEP_A2_ID" ]]; then
    fail "Create Step A2" "$(echo "$STEP_A2_RESP" | head -c 200)"
    exit 1
fi
pass "Created Step A2 (id=${STEP_A2_ID}, depth=3, leaf)"

# Depth 3: Step B1 (under Milestone B, leaf)
STEP_B1_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Step B1\",\"node_type\":\"step\",\"parent_id\":${MILE_B_ID}}")
STEP_B1_ID=$(echo "$STEP_B1_RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [[ -z "$STEP_B1_ID" ]]; then
    fail "Create Step B1" "$(echo "$STEP_B1_RESP" | head -c 200)"
    exit 1
fi
pass "Created Step B1 (id=${STEP_B1_ID}, depth=3, leaf)"

# Depth 4: Sub-step A1a (under Step A1)
SUB_A1A_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Sub-step A1a\",\"node_type\":\"step\",\"parent_id\":${STEP_A1_ID}}")
SUB_A1A_ID=$(echo "$SUB_A1A_RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [[ -z "$SUB_A1A_ID" ]]; then
    fail "Create Sub-step A1a" "$(echo "$SUB_A1A_RESP" | head -c 200)"
    exit 1
fi
pass "Created Sub-step A1a (id=${SUB_A1A_ID}, depth=4)"

# Depth 4: Sub-step A1b (under Step A1)
SUB_A1B_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Sub-step A1b\",\"node_type\":\"step\",\"parent_id\":${STEP_A1_ID}}")
SUB_A1B_ID=$(echo "$SUB_A1B_RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [[ -z "$SUB_A1B_ID" ]]; then
    fail "Create Sub-step A1b" "$(echo "$SUB_A1B_RESP" | head -c 200)"
    exit 1
fi
pass "Created Sub-step A1b (id=${SUB_A1B_ID}, depth=4)"

# Depth 5: Leaf A1a-i (under Sub-step A1a)
LEAF_A1AI_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Leaf A1a-i\",\"node_type\":\"step\",\"parent_id\":${SUB_A1A_ID}}")
LEAF_A1AI_ID=$(echo "$LEAF_A1AI_RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [[ -z "$LEAF_A1AI_ID" ]]; then
    fail "Create Leaf A1a-i" "$(echo "$LEAF_A1AI_RESP" | head -c 200)"
    exit 1
fi
pass "Created Leaf A1a-i (id=${LEAF_A1AI_ID}, depth=5)"

# Depth 5: Leaf A1b-i (under Sub-step A1b)
LEAF_A1BI_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Leaf A1b-i\",\"node_type\":\"step\",\"parent_id\":${SUB_A1B_ID}}")
LEAF_A1BI_ID=$(echo "$LEAF_A1BI_RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [[ -z "$LEAF_A1BI_ID" ]]; then
    fail "Create Leaf A1b-i" "$(echo "$LEAF_A1BI_RESP" | head -c 200)"
    exit 1
fi
pass "Created Leaf A1b-i (id=${LEAF_A1BI_ID}, depth=5)"

# Verify depth limit: attempt to create depth 6 (should fail with 422)
DEPTH6_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes" \
    -d "{\"name\":\"Too Deep\",\"node_type\":\"step\",\"parent_id\":${LEAF_A1AI_ID}}")
DEPTH6_CODE=$(echo "$DEPTH6_RESP" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)

if [[ "$DEPTH6_CODE" == "max_depth_exceeded" ]]; then
    pass "Depth 6 rejected (max_depth_exceeded)"
else
    fail "Depth 6 should be rejected" "Got: $(echo "$DEPTH6_RESP" | head -c 200)"
fi

# Verify total node count
ALL_NODES_RESP=$(acurl "${BASE_URL}/goals/trees/${TREE_ID}/nodes")
NODE_COUNT=$(echo "$ALL_NODES_RESP" | grep -o '"id":' | wc -l | tr -d ' ')

if [[ "$NODE_COUNT" -eq 10 ]]; then
    pass "Total node count is 10"
else
    fail "Expected 10 nodes, got ${NODE_COUNT}" ""
fi

# ===========================================================================
# Phase 3: Complete Leaves → Assert Auto-Rollup to Root
#
# Strategy: complete all leaf nodes bottom-up and verify cascading.
#
# Step 1: Complete Leaf A1a-i → Sub-step A1a should auto-complete (only child)
# Step 2: Complete Leaf A1b-i → Sub-step A1b should auto-complete (only child)
#         → Step A1 should auto-complete (both children A1a, A1b done)
# Step 3: Complete Step A2 → Milestone A should auto-complete (A1+A2 done)
# Step 4: Complete Step B1 → Milestone B should auto-complete (only child)
#         → Root Goal should auto-complete (both milestones done)
# ===========================================================================
separator "Phase 3: Complete Leaves → Assert Auto-Rollup"

# Helper: check if a node is completed
is_completed() {
    local node_id=$1
    local resp
    resp=$(acurl "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${node_id}")
    echo "$resp" | grep -q '"completed_at"'
}

# Helper: check if a node is NOT completed
is_not_completed() {
    local node_id=$1
    local resp
    resp=$(acurl "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${node_id}")
    ! echo "$resp" | grep -q '"completed_at"'
}

# Step 1: Complete Leaf A1a-i
COMPLETE_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${LEAF_A1AI_ID}/complete")
if echo "$COMPLETE_RESP" | grep -q '"completed_at"'; then
    pass "Completed Leaf A1a-i"
else
    fail "Complete Leaf A1a-i" "$(echo "$COMPLETE_RESP" | head -c 200)"
fi

# Verify: Sub-step A1a should auto-complete (single child done)
if is_completed "$SUB_A1A_ID"; then
    pass "Auto-rollup: Sub-step A1a completed (single child done)"
else
    fail "Auto-rollup: Sub-step A1a should be completed" ""
fi

# Verify: Step A1 should NOT be complete yet (A1b still incomplete)
if is_not_completed "$STEP_A1_ID"; then
    pass "Step A1 still incomplete (sibling A1b not done)"
else
    fail "Step A1 should not be complete yet" ""
fi

# Step 2: Complete Leaf A1b-i
COMPLETE_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${LEAF_A1BI_ID}/complete")
if echo "$COMPLETE_RESP" | grep -q '"completed_at"'; then
    pass "Completed Leaf A1b-i"
else
    fail "Complete Leaf A1b-i" "$(echo "$COMPLETE_RESP" | head -c 200)"
fi

# Verify: Sub-step A1b should auto-complete
if is_completed "$SUB_A1B_ID"; then
    pass "Auto-rollup: Sub-step A1b completed"
else
    fail "Auto-rollup: Sub-step A1b should be completed" ""
fi

# Verify: Step A1 should now auto-complete (both A1a and A1b done)
if is_completed "$STEP_A1_ID"; then
    pass "Auto-rollup: Step A1 completed (all children done)"
else
    fail "Auto-rollup: Step A1 should be completed" ""
fi

# Verify: Milestone A should NOT be complete yet (Step A2 still incomplete)
if is_not_completed "$MILE_A_ID"; then
    pass "Milestone A still incomplete (Step A2 not done)"
else
    fail "Milestone A should not be complete yet" ""
fi

# Step 3: Complete Step A2 (leaf at depth 3)
COMPLETE_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${STEP_A2_ID}/complete")
if echo "$COMPLETE_RESP" | grep -q '"completed_at"'; then
    pass "Completed Step A2"
else
    fail "Complete Step A2" "$(echo "$COMPLETE_RESP" | head -c 200)"
fi

# Verify: Milestone A should now auto-complete (both Step A1 and A2 done)
if is_completed "$MILE_A_ID"; then
    pass "Auto-rollup: Milestone A completed (all children done)"
else
    fail "Auto-rollup: Milestone A should be completed" ""
fi

# Verify: Root Goal should NOT be complete yet (Milestone B still incomplete)
if is_not_completed "$ROOT_ID"; then
    pass "Root Goal still incomplete (Milestone B not done)"
else
    fail "Root Goal should not be complete yet" ""
fi

# Step 4: Complete Step B1 (only child of Milestone B)
COMPLETE_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE_ID}/nodes/${STEP_B1_ID}/complete")
if echo "$COMPLETE_RESP" | grep -q '"completed_at"'; then
    pass "Completed Step B1"
else
    fail "Complete Step B1" "$(echo "$COMPLETE_RESP" | head -c 200)"
fi

# Verify: Milestone B should auto-complete
if is_completed "$MILE_B_ID"; then
    pass "Auto-rollup: Milestone B completed (single child done)"
else
    fail "Auto-rollup: Milestone B should be completed" ""
fi

# Verify: Root Goal should now auto-complete (both milestones done)
if is_completed "$ROOT_ID"; then
    pass "Auto-rollup: Root Goal completed (full cascade to root)"
else
    fail "Auto-rollup: Root Goal should be completed" ""
fi

# ===========================================================================
# Phase 4: Timeline Filter — Achieved Mode
#
# All nodes were completed "now" (today). Query with achieved mode for
# the current month should return all 10 nodes. Query for a past month
# should return 0 nodes.
# ===========================================================================
separator "Phase 4: Timeline Filter (achieved mode)"

CURRENT_YEAR=$(date +%Y)
CURRENT_MONTH=$(date +%Y-%m)

# Filter: achieved in current month — should return all 9 completed nodes
ACHIEVED_RESP=$(acurl "${BASE_URL}/goals/trees/${TREE_ID}/nodes?period=month&value=${CURRENT_MONTH}&mode=achieved")
ACHIEVED_COUNT=$(echo "$ACHIEVED_RESP" | grep -o '"id":' | wc -l | tr -d ' ')

if [[ "$ACHIEVED_COUNT" -eq 10 ]]; then
    pass "Timeline achieved (month=${CURRENT_MONTH}): all 10 nodes returned"
else
    fail "Timeline achieved (month=${CURRENT_MONTH}): expected 10, got ${ACHIEVED_COUNT}" ""
fi

# Filter: achieved in a past month (2020-01) — should return 0 nodes
PAST_RESP=$(acurl "${BASE_URL}/goals/trees/${TREE_ID}/nodes?period=month&value=2020-01&mode=achieved")
PAST_COUNT=$(echo "$PAST_RESP" | grep -o '"id":' | wc -l | tr -d ' ')

if [[ "$PAST_COUNT" -eq 0 ]]; then
    pass "Timeline achieved (month=2020-01): 0 nodes returned (correct)"
else
    fail "Timeline achieved (month=2020-01): expected 0, got ${PAST_COUNT}" ""
fi

# Filter: achieved in current year — should return all 9 nodes
YEAR_RESP=$(acurl "${BASE_URL}/goals/trees/${TREE_ID}/nodes?period=year&value=${CURRENT_YEAR}&mode=achieved")
YEAR_COUNT=$(echo "$YEAR_RESP" | grep -o '"id":' | wc -l | tr -d ' ')

if [[ "$YEAR_COUNT" -eq 10 ]]; then
    pass "Timeline achieved (year=${CURRENT_YEAR}): all 10 nodes returned"
else
    fail "Timeline achieved (year=${CURRENT_YEAR}): expected 10, got ${YEAR_COUNT}" ""
fi

# Filter: no filter — should return all 9 nodes regardless
NOFILTER_RESP=$(acurl "${BASE_URL}/goals/trees/${TREE_ID}/nodes")
NOFILTER_COUNT=$(echo "$NOFILTER_RESP" | grep -o '"id":' | wc -l | tr -d ' ')

if [[ "$NOFILTER_COUNT" -eq 10 ]]; then
    pass "No filter: all 10 nodes returned"
else
    fail "No filter: expected 10, got ${NOFILTER_COUNT}" ""
fi

# ===========================================================================
# Cleanup: Delete the test tree (cascades to all nodes/edges)
# ===========================================================================
separator "Cleanup"

DELETE_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "X-Editing-Session-ID: ${SESSION_ID}" \
    "${BASE_URL}/goals/trees/${TREE_ID}" 2>/dev/null)

if [[ "$DELETE_CODE" =~ ^2 ]]; then
    pass "Deleted test tree (HTTP ${DELETE_CODE})"
else
    fail "Delete test tree" "HTTP ${DELETE_CODE}"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
printf "${BOLD}══ Goal Mapper V1 Summary ══${RESET}\n"
TOTAL=$((PASSED + FAILED))
printf "  ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}  (total: %d)\n" \
    "$PASSED" "$FAILED" "$TOTAL"
echo ""

if [[ "$FAILED" -gt 0 ]]; then
    printf "${RED}Goal Mapper integration tests FAILED.${RESET}\n"
    exit 1
fi

printf "${GREEN}All Goal Mapper V1 tests passed.${RESET}\n"
exit 0
