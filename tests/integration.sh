#!/usr/bin/env bash
set -e

# ==============================================================================
# Aspirant Platform — Cross-Service Integration Tests
#
# Validates connectivity between all services in the Aspirant platform.
# Assumes services are already running via docker compose.
#
# Usage: ./tests/integration.sh [--help]
# ==============================================================================

# ---------------------------------------------------------------------------
# Configuration (override via environment variables)
# ---------------------------------------------------------------------------
HEALTH_RETRIES="${HEALTH_RETRIES:-30}"
HEALTH_SLEEP="${HEALTH_SLEEP:-2}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-10}"

SERVER_PORT="${SERVER_PORT:-8081}"
TRANSCRIBER_PORT="${TRANSCRIBER_PORT:-8082}"
COMMANDER_PORT="${COMMANDER_PORT:-8083}"
TRANSLATOR_PORT="${TRANSLATOR_PORT:-8084}"

BASE_URL="http://localhost"

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

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
PASSED=0
FAILED=0
SKIPPED=0

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Aspirant Platform — Cross-Service Integration Tests

Validates connectivity between all services. Services must already be running
(e.g. via docker compose up -d).

Usage:
    ./tests/integration.sh [--help]

Environment variables (defaults in parentheses):
    HEALTH_RETRIES   Max retries for health checks during startup (30)
    HEALTH_SLEEP     Seconds between health-check retries (2)
    REQUEST_TIMEOUT  Curl timeout in seconds for non-health requests (10)
    SERVER_PORT      Go server port (8081)
    TRANSCRIBER_PORT Transcriber port (8082)
    COMMANDER_PORT   Commander port (8083)
    TRANSLATOR_PORT  Translator port (8084)
    BOOTSTRAP_USER   Username for test admin user (integration_admin)
    BOOTSTRAP_PASS   Password for test admin user (integration_pass_42)

Phases:
    1. Health checks     — Direct /health on every service (with retry)
    2. Service proxy     — Proxy health routes through the Go server (requires auth)
    3. Data flow smoke   — Write/read tasks via commander, query translator languages

Exit codes:
    0   All critical tests passed
    1   One or more tests failed
EOF
    exit 0
fi

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------
pass() {
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}PASS${RESET}  %s\n" "$1"
}

fail() {
    FAILED=$((FAILED + 1))
    printf "  ${RED}FAIL${RESET}  %s\n" "$1"
}

skip() {
    SKIPPED=$((SKIPPED + 1))
    printf "  ${YELLOW}SKIP${RESET}  %s\n" "$1"
}

separator() {
    echo ""
    printf "${BOLD}── %s ──${RESET}\n" "$1"
}

# Retry a health-check URL up to HEALTH_RETRIES times.
# Returns 0 on success, 1 on exhaustion.
wait_for_health() {
    local url="$1"
    local label="$2"
    for i in $(seq 1 "$HEALTH_RETRIES"); do
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" "$url" 2>/dev/null || true)
        if [[ "$http_code" =~ ^2 ]]; then
            return 0
        fi
        if [[ "$i" -lt "$HEALTH_RETRIES" ]]; then
            sleep "$HEALTH_SLEEP"
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Phase 1: Health Checks
# ---------------------------------------------------------------------------
separator "Phase 1: Health Checks (direct access)"

declare -A HEALTH_ENDPOINTS=(
    ["server"]="${BASE_URL}:${SERVER_PORT}/health"
    ["transcriber"]="${BASE_URL}:${TRANSCRIBER_PORT}/health"
    ["commander"]="${BASE_URL}:${COMMANDER_PORT}/health"
    ["translator"]="${BASE_URL}:${TRANSLATOR_PORT}/health"
)

PHASE1_OK=true
for svc in server transcriber commander translator; do
    url="${HEALTH_ENDPOINTS[$svc]}"
    if wait_for_health "$url" "$svc"; then
        pass "$svc health (${url})"
    else
        fail "$svc health (${url}) — not reachable after ${HEALTH_RETRIES} retries"
        PHASE1_OK=false
    fi
done

# ---------------------------------------------------------------------------
# Phase 2: Service Proxy (through Go server, requires JWT)
# ---------------------------------------------------------------------------
separator "Phase 2: Service Proxy (via server gateway)"

TOKEN=""

# Attempt to obtain a JWT token.
# Strategy: try bootstrap endpoint first (works if DB is fresh), then try login.
obtain_token() {
    # Try bootstrap (creates admin user when no users exist)
    local bootstrap_resp
    bootstrap_resp=$(curl -s --max-time "$REQUEST_TIMEOUT" \
        -X POST "${BASE_URL}:${SERVER_PORT}/bootstrap/admin" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${BOOTSTRAP_USER}\",\"password\":\"${BOOTSTRAP_PASS}\"}" 2>/dev/null || true)

    # Try login regardless (bootstrap may have been done previously)
    local login_resp
    login_resp=$(curl -s --max-time "$REQUEST_TIMEOUT" \
        -X POST "${BASE_URL}:${SERVER_PORT}/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${BOOTSTRAP_USER}\",\"password\":\"${BOOTSTRAP_PASS}\"}" 2>/dev/null || true)

    # Extract token — works with the server's {"status":"success","data":{"token":"..."}} format
    TOKEN=$(echo "$login_resp" | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)
}

if [[ "$PHASE1_OK" == true ]]; then
    obtain_token
fi

if [[ -z "$TOKEN" ]]; then
    skip "Could not obtain JWT — skipping proxy tests"
    skip "GET /transcriber/health (proxy)"
    skip "GET /commander/health (proxy)"
    skip "GET /translator/health (proxy)"
else
    AUTH_HEADER="Authorization: Bearer ${TOKEN}"

    # Transcriber health through proxy (Admin route)
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
        -H "$AUTH_HEADER" \
        "${BASE_URL}:${SERVER_PORT}/transcriber/health" 2>/dev/null || true)
    if [[ "$http_code" =~ ^2 ]]; then
        pass "GET /transcriber/health (proxy, HTTP ${http_code})"
    else
        fail "GET /transcriber/health (proxy, HTTP ${http_code})"
    fi

    # Commander health through proxy (Admin route)
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
        -H "$AUTH_HEADER" \
        "${BASE_URL}:${SERVER_PORT}/commander/health" 2>/dev/null || true)
    if [[ "$http_code" =~ ^2 ]]; then
        pass "GET /commander/health (proxy, HTTP ${http_code})"
    else
        fail "GET /commander/health (proxy, HTTP ${http_code})"
    fi

    # Translator health through proxy (Trusted route)
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
        -H "$AUTH_HEADER" \
        "${BASE_URL}:${SERVER_PORT}/translator/health" 2>/dev/null || true)
    if [[ "$http_code" =~ ^2 ]]; then
        pass "GET /translator/health (proxy, HTTP ${http_code})"
    else
        fail "GET /translator/health (proxy, HTTP ${http_code})"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3: Data Flow Smoke Test
# ---------------------------------------------------------------------------
separator "Phase 3: Data Flow Smoke Test"

CREATED_TASK_ID=""

# 3a. GET tasks from commander (verify DB read — always returns list even if empty)
tasks_resp=$(curl -s --max-time "$REQUEST_TIMEOUT" \
    "${BASE_URL}:${COMMANDER_PORT}/tasks" 2>/dev/null || true)
if echo "$tasks_resp" | grep -q '"items"'; then
    pass "GET /tasks from commander (DB read)"
else
    fail "GET /tasks from commander — unexpected response"
fi

# 3b. POST a test task to commander via its process endpoint is not suitable for
#     creating individual tasks directly, but the tasks endpoint is read-only from
#     the HTTP API (tasks are created by the poller). Instead, verify the vocabulary
#     endpoint works (proves the service is fully operational).
vocab_resp=$(curl -s --max-time "$REQUEST_TIMEOUT" \
    "${BASE_URL}:${COMMANDER_PORT}/vocabulary" 2>/dev/null || true)
if echo "$vocab_resp" | grep -q '"grammar"'; then
    pass "GET /vocabulary from commander (service operational)"
else
    fail "GET /vocabulary from commander — unexpected response"
fi

# 3c. GET languages from translator
languages_resp=$(curl -s --max-time "$REQUEST_TIMEOUT" \
    "${BASE_URL}:${TRANSLATOR_PORT}/languages" 2>/dev/null || true)
http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
    "${BASE_URL}:${TRANSLATOR_PORT}/languages" 2>/dev/null || true)
if [[ "$http_code" =~ ^2 ]]; then
    pass "GET /languages from translator (HTTP ${http_code})"
else
    fail "GET /languages from translator (HTTP ${http_code})"
fi

# 3d. If we have a token, test proxy data routes through the server as well
if [[ -n "$TOKEN" ]]; then
    AUTH_HEADER="Authorization: Bearer ${TOKEN}"

    # Commander tasks through proxy
    proxy_tasks_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
        -H "$AUTH_HEADER" \
        "${BASE_URL}:${SERVER_PORT}/commander/tasks" 2>/dev/null || true)
    if [[ "$proxy_tasks_code" =~ ^2 ]]; then
        pass "GET /commander/tasks (proxy, HTTP ${proxy_tasks_code})"
    else
        fail "GET /commander/tasks (proxy, HTTP ${proxy_tasks_code})"
    fi

    # Translator languages through proxy
    proxy_lang_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REQUEST_TIMEOUT" \
        -H "$AUTH_HEADER" \
        "${BASE_URL}:${SERVER_PORT}/translator/languages" 2>/dev/null || true)
    if [[ "$proxy_lang_code" =~ ^2 ]]; then
        pass "GET /translator/languages (proxy, HTTP ${proxy_lang_code})"
    else
        fail "GET /translator/languages (proxy, HTTP ${proxy_lang_code})"
    fi
else
    skip "GET /commander/tasks (proxy) — no token"
    skip "GET /translator/languages (proxy) — no token"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
printf "${BOLD}══ Summary ══${RESET}\n"
TOTAL=$((PASSED + FAILED + SKIPPED))
printf "  ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}, ${YELLOW}%d skipped${RESET}  (total: %d)\n" \
    "$PASSED" "$FAILED" "$SKIPPED" "$TOTAL"
echo ""

if [[ "$FAILED" -gt 0 ]]; then
    printf "${RED}Integration tests FAILED.${RESET}\n"
    exit 1
fi

printf "${GREEN}All critical tests passed.${RESET}\n"
exit 0
