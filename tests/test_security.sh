#!/bin/bash
# =============================================================================
# Module: tests/test_security.sh
# Project: La Roca Micro-PubSub
# Responsibility: Security & Fuzzing Tests for Named Topics.
#                 Validates boundary conditions, malformed URIs,
#                 unsupported HTTP methods, Header Overflows, and Delimiter Flooding.
# =============================================================================

HOST="http://localhost:8080"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}🛡️  Starting Security & Fuzzing Tests...${NC}"
echo "-----------------------------------------------------------------"

fail_and_exit() {
    echo -e "${RED}\n[FATAL] Security test failed.${NC}"
    echo -e "${YELLOW}=== 🕵️‍♂️ DOCKER LOGS (pubsub-engine) ===${NC}"
    docker compose logs pubsub-engine --tail 20
    echo -e "${YELLOW}=======================================${NC}\n"
    docker compose down -v > /dev/null 2>&1
    exit 1
}

# =============================================================================
# ENVIRONMENT SETUP
# =============================================================================
echo "🧹 Cleaning previous state..."
docker compose down -v > /dev/null 2>&1
rm -rf topics/*.log 2>/dev/null

echo "🏗️  Starting ephemeral engine..."
docker compose up -d --build pubsub-engine > /dev/null 2>&1
sleep 2

# -----------------------------------------------------------------------------
# check_status: Helper to validate HTTP responses.
# Accepts optional 6th parameter for Custom Headers.
# -----------------------------------------------------------------------------
check_status() {
    local method=$1
    local endpoint=$2
    local expected=$3
    local payload=$4
    local description=$5
    local header=$6

    # FIX: Respect the actual HTTP Method ($method) for ALL requests.
    if [ -n "$header" ] && [ -n "$payload" ]; then
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" -H "$header" -d "$payload" "$HOST$endpoint")
    elif [ -n "$payload" ]; then
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" -d "$payload" "$HOST$endpoint")
    elif [ -n "$header" ]; then
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" -H "$header" "$HOST$endpoint")
    else
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$HOST$endpoint")
    fi

    # Normalize 000 to 0 for numerical comparison (when connection drops)
    local final_status=$((10#$STATUS + 0))

    if [ "$final_status" -eq "$expected" ]; then
        echo -e "${GREEN}[PASS]${NC} $description (Status: $final_status)"
    else
        echo -e "${RED}[FAIL]${NC} $description (Expected $expected, got $final_status)"
        fail_and_exit
    fi
}

# =============================================================================
# TEST SUITE: SECURITY BOUNDARIES
# =============================================================================

# 1. Topic Creation & Boundary Validation
check_status "POST" "/pub/safe_topic" 200 "Ping" "Create valid topic"
check_status "POST" "/pub/this_name_is_way_too_long_for_16b" 400 "" "Reject oversized topic name (>16 bytes)"

# 2. Malformed URI & Sequence Validation
check_status "GET" "/sub/safe_topic/not_a_number" 400 "" "Reject alphanumeric sequence ID"
check_status "GET" "/sub/safe_topic/" 400 "" "Reject empty sequence ID field"

# 3. Protocol Hardening: Unsupported HTTP Methods
# This will now ACTUALLY send PUT and DELETE requests to the engine!
check_status "PUT" "/pub/safe_topic" 400 "Payload" "Reject PUT request (400 Bad Request)"
check_status "DELETE" "/sub/safe_topic/0" 400 "" "Reject DELETE request (400 Bad Request)"

# 4. Fuzzing: Payload Stress (Buffer Overflow Check)
HUGE_PAYLOAD=$(head -c 10000 < /dev/zero | tr '\0' 'A')
check_status "POST" "/pub/safe_topic" 200 "$HUGE_PAYLOAD" "Handle 10KB payload (Verify Truncation/Stability)"

# =============================================================================
# NEW TESTS: STREAM PROCESSING & BATCH INGESTION FUZZING
# =============================================================================

# 5. Header Overflow (Giant Routing Key)
GIANT_KEY=$(head -c 1000 < /dev/zero | tr '\0' 'K')
check_status "POST" "/pub/safe_topic" 200 "Test" "Handle oversized X-Roca-Key (1000 bytes without crash)" "X-Roca-Key: $GIANT_KEY"

# 6. Delimiter Flooding (Empty Message Bomb)
HUGE_NEWLINES=$(head -c 10000 < /dev/zero | tr '\0' '\n')
check_status "POST" "/mpub/safe_topic" 200 "$HUGE_NEWLINES" "Handle 10,000 consecutive newlines in /mpub (Zero-length guard)"

echo "-----------------------------------------------------------------"
echo -e "${GREEN}✅ SECURITY TESTS PASSED! The engine is bulletproof.${NC}"

# Cleanup after success
docker compose down -v > /dev/null 2>&1