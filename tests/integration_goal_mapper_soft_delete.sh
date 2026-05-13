#!/usr/bin/env bash
set -e

# ==============================================================================
# Goal Mapper — V2 Integration Test: Soft-Delete & Edge Survival
#
# Per spec §3 (Soft Delete and Edge Survival). Scenarios:
#   1. Delete middle node (A→B→C) → verify A→C
#   2. Delete leaf node → just disappears, parent unaffected
#   3. Delete node with multiple children → all reattach to parent
#   4. Cascade: delete multiple levels sequentially, verify edges
#
# Requires: server running on SERVER_PORT with PostgreSQL connected.
# Usage: ./tests/integration_goal_mapper_soft_delete.sh
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

curl -s --max-time "$REQUEST_TIMEOUT" \
    -X POST "${BASE_URL}/bootstrap/admin" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${BOOTSTRAP_USER}\",\"password\":\"${BOOTSTRAP_PASS}\"}" > /dev/null 2>&1 || true

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

acurl() {
    curl -s --max-time "$REQUEST_TIMEOUT" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        "$@" 2>/dev/null
}

scurl() {
    curl -s --max-time "$REQUEST_TIMEOUT" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Editing-Session-ID: ${SESSION_ID}" \
        "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: extract ID from JSON response
# ---------------------------------------------------------------------------
extract_id() {
    echo "$1" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2
}

# ---------------------------------------------------------------------------
# Helper: get parent_id for a node
# ---------------------------------------------------------------------------
get_parent_id() {
    local tree_id=$1
    local node_id=$2
    local resp
    resp=$(acurl "${BASE_URL}/goals/trees/${tree_id}/nodes/${node_id}")
    echo "$resp" | grep -o '"parent_id":[0-9]*' | head -1 | cut -d: -f2
}

# ---------------------------------------------------------------------------
# Helper: get all edges for a tree and check if from→to exists
# ---------------------------------------------------------------------------
edge_exists() {
    local tree_id=$1
    local from_id=$2
    local to_id=$3
    local edges_resp
    edges_resp=$(acurl "${BASE_URL}/goals/trees/${tree_id}/edges")
    echo "$edges_resp" | grep -q "\"from_id\":${from_id}" && \
    echo "$edges_resp" | grep "\"from_id\":${from_id}" | grep -q "\"to_id\":${to_id}"
}

# ---------------------------------------------------------------------------
# Helper: check node is soft-deleted (GET returns 404)
# ---------------------------------------------------------------------------
is_deleted() {
    local tree_id=$1
    local node_id=$2
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
        -H "Authorization: Bearer ${TOKEN}" \
        "${BASE_URL}/goals/trees/${tree_id}/nodes/${node_id}" 2>/dev/null)
    [[ "$http_code" == "404" ]]
}

# ---------------------------------------------------------------------------
# Helper: count children of a node
# ---------------------------------------------------------------------------
count_children() {
    local tree_id=$1
    local parent_id=$2
    local nodes_resp
    nodes_resp=$(acurl "${BASE_URL}/goals/trees/${tree_id}/nodes")
    echo "$nodes_resp" | grep -o "\"parent_id\":${parent_id}" | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# Helper: count edges from a node
# ---------------------------------------------------------------------------
count_edges_from() {
    local tree_id=$1
    local from_id=$2
    local edges_resp
    edges_resp=$(acurl "${BASE_URL}/goals/trees/${tree_id}/edges")
    echo "$edges_resp" | grep -o "\"from_id\":${from_id}" | wc -l | tr -d ' '
}

# ===========================================================================
# Scenario 1: Delete Middle Node (A→B→C, delete B → verify A→C)
# ===========================================================================
separator "Scenario 1: Delete middle node — A→B→C, delete B"

TREE_RESP=$(acurl -X POST "${BASE_URL}/goals/trees" \
    -d '{"name":"Edge Survival Test 1"}')
TREE1_ID=$(extract_id "$TREE_RESP")

if [[ -z "$TREE1_ID" ]]; then
    printf "${RED}FATAL: Could not create tree.${RESET}\n"
    exit 1
fi

SESSION_RESP=$(acurl -X POST "${BASE_URL}/goals/trees/${TREE1_ID}/open")
SESSION_ID=$(echo "$SESSION_RESP" | grep -o '"editing_session_id":"[^"]*"' | cut -d'"' -f4)

# Create A (root)
A_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE1_ID}/nodes" \
    -d '{"name":"Node A","type":"goal","color":"#FF0000"}')
NODE_A=$(extract_id "$A_RESP")

# Create B (child of A)
B_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE1_ID}/nodes" \
    -d "{\"name\":\"Node B\",\"node_type\":\"milestone\",\"parent_id\":${NODE_A}}")
NODE_B=$(extract_id "$B_RESP")

# Create C (child of B)
C_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE1_ID}/nodes" \
    -d "{\"name\":\"Node C\",\"node_type\":\"step\",\"parent_id\":${NODE_B}}")
NODE_C=$(extract_id "$C_RESP")

# Verify initial structure: A→B edge and B→C edge
if edge_exists "$TREE1_ID" "$NODE_A" "$NODE_B"; then
    pass "Initial: A→B edge exists"
else
    fail "Initial: A→B edge should exist" ""
fi

if edge_exists "$TREE1_ID" "$NODE_B" "$NODE_C"; then
    pass "Initial: B→C edge exists"
else
    fail "Initial: B→C edge should exist" ""
fi

# Delete B
DELETE_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Editing-Session-ID: ${SESSION_ID}" \
    "${BASE_URL}/goals/trees/${TREE1_ID}/nodes/${NODE_B}" 2>/dev/null)

if [[ "$DELETE_CODE" =~ ^2 ]]; then
    pass "Deleted node B (HTTP ${DELETE_CODE})"
else
    fail "Delete node B" "HTTP ${DELETE_CODE}"
fi

# Verify B is gone (404)
if is_deleted "$TREE1_ID" "$NODE_B"; then
    pass "Node B is soft-deleted (404)"
else
    fail "Node B should return 404 after deletion" ""
fi

# Verify C's parent is now A
C_PARENT=$(get_parent_id "$TREE1_ID" "$NODE_C")
if [[ "$C_PARENT" == "$NODE_A" ]]; then
    pass "Node C's parent_id is now A (edge survival)"
else
    fail "Node C's parent_id should be A" "Got: ${C_PARENT}"
fi

# Verify A→C edge exists
if edge_exists "$TREE1_ID" "$NODE_A" "$NODE_C"; then
    pass "Edge A→C exists (reattached)"
else
    fail "Edge A→C should exist after deleting B" ""
fi

# Verify old edges are gone
EDGES_RESP=$(acurl "${BASE_URL}/goals/trees/${TREE1_ID}/edges")
if ! echo "$EDGES_RESP" | grep -q "\"from_id\":${NODE_B}"; then
    pass "No edges from B remain"
else
    fail "Edges from B should be removed" ""
fi

if ! echo "$EDGES_RESP" | grep -q "\"to_id\":${NODE_B}"; then
    pass "No edges to B remain"
else
    fail "Edges to B should be removed" ""
fi

# ===========================================================================
# Scenario 2: Delete Leaf Node (just disappears)
# ===========================================================================
separator "Scenario 2: Delete leaf node — parent unaffected"

TREE_RESP=$(acurl -X POST "${BASE_URL}/goals/trees" \
    -d '{"name":"Edge Survival Test 2"}')
TREE2_ID=$(extract_id "$TREE_RESP")

SESSION_RESP=$(acurl -X POST "${BASE_URL}/goals/trees/${TREE2_ID}/open")
SESSION_ID=$(echo "$SESSION_RESP" | grep -o '"editing_session_id":"[^"]*"' | cut -d'"' -f4)

# Create parent
P_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE2_ID}/nodes" \
    -d '{"name":"Parent","type":"goal","color":"#00FF00"}')
PARENT_ID=$(extract_id "$P_RESP")

# Create leaf child
LEAF_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE2_ID}/nodes" \
    -d "{\"name\":\"Leaf\",\"node_type\":\"milestone\",\"parent_id\":${PARENT_ID}}")
LEAF_ID=$(extract_id "$LEAF_RESP")

# Create another child so parent isn't left childless
SIBLING_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE2_ID}/nodes" \
    -d "{\"name\":\"Sibling\",\"node_type\":\"milestone\",\"parent_id\":${PARENT_ID}}")
SIBLING_ID=$(extract_id "$SIBLING_RESP")

# Verify initial: parent has 2 children
INITIAL_CHILDREN=$(count_children "$TREE2_ID" "$PARENT_ID")
if [[ "$INITIAL_CHILDREN" -eq 2 ]]; then
    pass "Initial: parent has 2 children"
else
    fail "Initial: parent should have 2 children" "Got: ${INITIAL_CHILDREN}"
fi

# Delete the leaf
DELETE_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Editing-Session-ID: ${SESSION_ID}" \
    "${BASE_URL}/goals/trees/${TREE2_ID}/nodes/${LEAF_ID}" 2>/dev/null)

if [[ "$DELETE_CODE" =~ ^2 ]]; then
    pass "Deleted leaf node (HTTP ${DELETE_CODE})"
else
    fail "Delete leaf node" "HTTP ${DELETE_CODE}"
fi

# Verify leaf is gone
if is_deleted "$TREE2_ID" "$LEAF_ID"; then
    pass "Leaf node is soft-deleted (404)"
else
    fail "Leaf should return 404" ""
fi

# Verify parent still exists and now has 1 child
AFTER_CHILDREN=$(count_children "$TREE2_ID" "$PARENT_ID")
if [[ "$AFTER_CHILDREN" -eq 1 ]]; then
    pass "Parent now has 1 child (leaf removed, sibling remains)"
else
    fail "Parent should have 1 child after leaf deletion" "Got: ${AFTER_CHILDREN}"
fi

# Verify sibling is unaffected
SIBLING_PARENT=$(get_parent_id "$TREE2_ID" "$SIBLING_ID")
if [[ "$SIBLING_PARENT" == "$PARENT_ID" ]]; then
    pass "Sibling's parent unchanged"
else
    fail "Sibling's parent should still be Parent" "Got: ${SIBLING_PARENT}"
fi

# Verify no edges reference the deleted leaf
EDGES_RESP=$(acurl "${BASE_URL}/goals/trees/${TREE2_ID}/edges")
if ! echo "$EDGES_RESP" | grep -q "\"to_id\":${LEAF_ID}"; then
    pass "No edge to deleted leaf remains"
else
    fail "Edge to deleted leaf should be gone" ""
fi

# ===========================================================================
# Scenario 3: Delete node with multiple children (all reattach to parent)
#
# Structure: A→B→{C, D, E}  — delete B → A→{C, D, E}
# ===========================================================================
separator "Scenario 3: Delete node with multiple children"

TREE_RESP=$(acurl -X POST "${BASE_URL}/goals/trees" \
    -d '{"name":"Edge Survival Test 3"}')
TREE3_ID=$(extract_id "$TREE_RESP")

SESSION_RESP=$(acurl -X POST "${BASE_URL}/goals/trees/${TREE3_ID}/open")
SESSION_ID=$(echo "$SESSION_RESP" | grep -o '"editing_session_id":"[^"]*"' | cut -d'"' -f4)

# Create A (root)
A_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE3_ID}/nodes" \
    -d '{"name":"Node A","type":"goal","color":"#0000FF"}')
S3_A=$(extract_id "$A_RESP")

# Create B (child of A)
B_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE3_ID}/nodes" \
    -d "{\"name\":\"Node B\",\"node_type\":\"milestone\",\"parent_id\":${S3_A}}")
S3_B=$(extract_id "$B_RESP")

# Create C, D, E (children of B)
C_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE3_ID}/nodes" \
    -d "{\"name\":\"Node C\",\"node_type\":\"step\",\"parent_id\":${S3_B}}")
S3_C=$(extract_id "$C_RESP")

D_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE3_ID}/nodes" \
    -d "{\"name\":\"Node D\",\"node_type\":\"step\",\"parent_id\":${S3_B}}")
S3_D=$(extract_id "$D_RESP")

E_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE3_ID}/nodes" \
    -d "{\"name\":\"Node E\",\"node_type\":\"step\",\"parent_id\":${S3_B}}")
S3_E=$(extract_id "$E_RESP")

# Verify initial: B has 3 children
B_CHILDREN=$(count_children "$TREE3_ID" "$S3_B")
if [[ "$B_CHILDREN" -eq 3 ]]; then
    pass "Initial: B has 3 children (C, D, E)"
else
    fail "Initial: B should have 3 children" "Got: ${B_CHILDREN}"
fi

# Delete B
DELETE_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Editing-Session-ID: ${SESSION_ID}" \
    "${BASE_URL}/goals/trees/${TREE3_ID}/nodes/${S3_B}" 2>/dev/null)

if [[ "$DELETE_CODE" =~ ^2 ]]; then
    pass "Deleted node B (HTTP ${DELETE_CODE})"
else
    fail "Delete node B" "HTTP ${DELETE_CODE}"
fi

# Verify B is gone
if is_deleted "$TREE3_ID" "$S3_B"; then
    pass "Node B is soft-deleted (404)"
else
    fail "Node B should return 404" ""
fi

# Verify all three children now point to A
C_PARENT=$(get_parent_id "$TREE3_ID" "$S3_C")
D_PARENT=$(get_parent_id "$TREE3_ID" "$S3_D")
E_PARENT=$(get_parent_id "$TREE3_ID" "$S3_E")

if [[ "$C_PARENT" == "$S3_A" ]]; then
    pass "Node C reattached to A"
else
    fail "Node C should point to A" "Got: ${C_PARENT}"
fi

if [[ "$D_PARENT" == "$S3_A" ]]; then
    pass "Node D reattached to A"
else
    fail "Node D should point to A" "Got: ${D_PARENT}"
fi

if [[ "$E_PARENT" == "$S3_A" ]]; then
    pass "Node E reattached to A"
else
    fail "Node E should point to A" "Got: ${E_PARENT}"
fi

# Verify A now has 3 edges going out (to C, D, E)
A_EDGE_COUNT=$(count_edges_from "$TREE3_ID" "$S3_A")
if [[ "$A_EDGE_COUNT" -eq 3 ]]; then
    pass "A now has 3 outgoing edges (C, D, E)"
else
    fail "A should have 3 outgoing edges" "Got: ${A_EDGE_COUNT}"
fi

# Verify each A→child edge exists
if edge_exists "$TREE3_ID" "$S3_A" "$S3_C"; then
    pass "Edge A→C exists"
else
    fail "Edge A→C should exist" ""
fi

if edge_exists "$TREE3_ID" "$S3_A" "$S3_D"; then
    pass "Edge A→D exists"
else
    fail "Edge A→D should exist" ""
fi

if edge_exists "$TREE3_ID" "$S3_A" "$S3_E"; then
    pass "Edge A→E exists"
else
    fail "Edge A→E should exist" ""
fi

# ===========================================================================
# Scenario 4: Cascade deletion through 3+ levels
#
# Structure: A→B→C→D→E
# Delete B → A→C→D→E
# Delete C → A→D→E
# Delete D → A→E
# Each deletion should reattach the remaining chain to the previous parent.
# ===========================================================================
separator "Scenario 4: Cascade deletion through multiple levels"

TREE_RESP=$(acurl -X POST "${BASE_URL}/goals/trees" \
    -d '{"name":"Edge Survival Test 4"}')
TREE4_ID=$(extract_id "$TREE_RESP")

SESSION_RESP=$(acurl -X POST "${BASE_URL}/goals/trees/${TREE4_ID}/open")
SESSION_ID=$(echo "$SESSION_RESP" | grep -o '"editing_session_id":"[^"]*"' | cut -d'"' -f4)

# Create chain: A→B→C→D→E
S4_A_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE4_ID}/nodes" \
    -d '{"name":"Chain A","type":"goal","color":"#FFAA00"}')
S4_A=$(extract_id "$S4_A_RESP")

S4_B_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE4_ID}/nodes" \
    -d "{\"name\":\"Chain B\",\"node_type\":\"milestone\",\"parent_id\":${S4_A}}")
S4_B=$(extract_id "$S4_B_RESP")

S4_C_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE4_ID}/nodes" \
    -d "{\"name\":\"Chain C\",\"node_type\":\"step\",\"parent_id\":${S4_B}}")
S4_C=$(extract_id "$S4_C_RESP")

S4_D_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE4_ID}/nodes" \
    -d "{\"name\":\"Chain D\",\"node_type\":\"step\",\"parent_id\":${S4_C}}")
S4_D=$(extract_id "$S4_D_RESP")

S4_E_RESP=$(scurl -X POST "${BASE_URL}/goals/trees/${TREE4_ID}/nodes" \
    -d "{\"name\":\"Chain E\",\"node_type\":\"step\",\"parent_id\":${S4_D}}")
S4_E=$(extract_id "$S4_E_RESP")

# Verify initial chain
if edge_exists "$TREE4_ID" "$S4_A" "$S4_B" && \
   edge_exists "$TREE4_ID" "$S4_B" "$S4_C" && \
   edge_exists "$TREE4_ID" "$S4_C" "$S4_D" && \
   edge_exists "$TREE4_ID" "$S4_D" "$S4_E"; then
    pass "Initial chain A→B→C→D→E verified"
else
    fail "Initial chain should be A→B→C→D→E" ""
fi

# --- Step 1: Delete B → chain becomes A→C→D→E ---
DELETE_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Editing-Session-ID: ${SESSION_ID}" \
    "${BASE_URL}/goals/trees/${TREE4_ID}/nodes/${S4_B}" 2>/dev/null)

if [[ "$DELETE_CODE" =~ ^2 ]]; then
    pass "Step 1: Deleted B (HTTP ${DELETE_CODE})"
else
    fail "Step 1: Delete B" "HTTP ${DELETE_CODE}"
fi

C_PARENT=$(get_parent_id "$TREE4_ID" "$S4_C")
if [[ "$C_PARENT" == "$S4_A" ]]; then
    pass "Step 1: C now points to A"
else
    fail "Step 1: C should point to A" "Got: ${C_PARENT}"
fi

if edge_exists "$TREE4_ID" "$S4_A" "$S4_C"; then
    pass "Step 1: Edge A→C exists"
else
    fail "Step 1: Edge A→C should exist" ""
fi

# Verify deeper chain is intact
if edge_exists "$TREE4_ID" "$S4_C" "$S4_D" && edge_exists "$TREE4_ID" "$S4_D" "$S4_E"; then
    pass "Step 1: Chain C→D→E still intact"
else
    fail "Step 1: Chain C→D→E should remain" ""
fi

# --- Step 2: Delete C → chain becomes A→D→E ---
DELETE_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Editing-Session-ID: ${SESSION_ID}" \
    "${BASE_URL}/goals/trees/${TREE4_ID}/nodes/${S4_C}" 2>/dev/null)

if [[ "$DELETE_CODE" =~ ^2 ]]; then
    pass "Step 2: Deleted C (HTTP ${DELETE_CODE})"
else
    fail "Step 2: Delete C" "HTTP ${DELETE_CODE}"
fi

D_PARENT=$(get_parent_id "$TREE4_ID" "$S4_D")
if [[ "$D_PARENT" == "$S4_A" ]]; then
    pass "Step 2: D now points to A"
else
    fail "Step 2: D should point to A" "Got: ${D_PARENT}"
fi

if edge_exists "$TREE4_ID" "$S4_A" "$S4_D"; then
    pass "Step 2: Edge A→D exists"
else
    fail "Step 2: Edge A→D should exist" ""
fi

if edge_exists "$TREE4_ID" "$S4_D" "$S4_E"; then
    pass "Step 2: Edge D→E still intact"
else
    fail "Step 2: Edge D→E should remain" ""
fi

# --- Step 3: Delete D → chain becomes A→E ---
DELETE_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Editing-Session-ID: ${SESSION_ID}" \
    "${BASE_URL}/goals/trees/${TREE4_ID}/nodes/${S4_D}" 2>/dev/null)

if [[ "$DELETE_CODE" =~ ^2 ]]; then
    pass "Step 3: Deleted D (HTTP ${DELETE_CODE})"
else
    fail "Step 3: Delete D" "HTTP ${DELETE_CODE}"
fi

E_PARENT=$(get_parent_id "$TREE4_ID" "$S4_E")
if [[ "$E_PARENT" == "$S4_A" ]]; then
    pass "Step 3: E now points to A"
else
    fail "Step 3: E should point to A" "Got: ${E_PARENT}"
fi

if edge_exists "$TREE4_ID" "$S4_A" "$S4_E"; then
    pass "Step 3: Edge A→E exists (final chain)"
else
    fail "Step 3: Edge A→E should exist" ""
fi

# Verify only 2 live nodes remain (A and E)
LIVE_NODES=$(acurl "${BASE_URL}/goals/trees/${TREE4_ID}/nodes")
LIVE_COUNT=$(echo "$LIVE_NODES" | grep -o '"id":' | wc -l | tr -d ' ')
if [[ "$LIVE_COUNT" -eq 2 ]]; then
    pass "Step 3: Only 2 live nodes remain (A, E)"
else
    fail "Step 3: Expected 2 live nodes" "Got: ${LIVE_COUNT}"
fi

# ===========================================================================
# Cleanup: Delete all test trees
# ===========================================================================
separator "Cleanup"

for TID in "$TREE1_ID" "$TREE2_ID" "$TREE3_ID" "$TREE4_ID"; do
    # Re-open session for each tree to allow deletion
    SESSION_RESP=$(acurl -X POST "${BASE_URL}/goals/trees/${TID}/open")
    SESSION_ID=$(echo "$SESSION_RESP" | grep -o '"editing_session_id":"[^"]*"' | cut -d'"' -f4)

    DELETE_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
        -X DELETE \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Editing-Session-ID: ${SESSION_ID}" \
        "${BASE_URL}/goals/trees/${TID}" 2>/dev/null)

    if [[ "$DELETE_CODE" =~ ^2 ]]; then
        pass "Deleted tree ${TID} (HTTP ${DELETE_CODE})"
    else
        fail "Delete tree ${TID}" "HTTP ${DELETE_CODE}"
    fi
done

# ===========================================================================
# Summary
# ===========================================================================
echo ""
printf "${BOLD}== Soft-Delete & Edge Survival V2 Summary ==${RESET}\n"
TOTAL=$((PASSED + FAILED))
printf "  ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}  (total: %d)\n" \
    "$PASSED" "$FAILED" "$TOTAL"
echo ""

if [[ "$FAILED" -gt 0 ]]; then
    printf "${RED}Soft-delete edge survival tests FAILED.${RESET}\n"
    exit 1
fi

printf "${GREEN}All soft-delete edge survival tests passed.${RESET}\n"
exit 0
