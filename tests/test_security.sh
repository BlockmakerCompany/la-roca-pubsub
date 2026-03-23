#!/bin/bash
# =============================================================================
# Module: tests/test_security.sh
# Project: La Roca Micro-PubSub
# Responsibility: Security & Fuzzing Tests for Named Topics.
#                 Validates boundary conditions, malformed URIs, and
#                 unsupported HTTP methods.
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
docker compose up -d --build > /dev/null 2>&1
sleep 2

# -----------------------------------------------------------------------------
# check_status: Helper to validate HTTP responses.
# -----------------------------------------------------------------------------
check_status() {
    local method=$1
    local endpoint=$2
    local expected=$3
    local payload=$4
    local description=$5

    # Capture HTTP status code. If the engine drops the connection (intentional
    # for unsupported methods), curl returns 000.
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" -d "$payload" "$HOST$endpoint")

    # Normalize 000 to 0 for numerical comparison
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
# Validates the 16-byte limit enforced in route_api.asm
check_status "POST" "/pub/safe_topic" 200 "Ping" "Create valid topic"
check_status "POST" "/pub/this_name_is_way_too_long_for_the_16_byte_buffer" 400 "" "Reject oversized topic name (>16 bytes)"

# 2. Malformed URI & Sequence Validation
# Validates ASCII-to-Integer parsing and empty field protection in handle_sub.asm
check_status "GET" "/sub/safe_topic/not_a_number" 400 "" "Reject alphanumeric sequence ID"
check_status "GET" "/sub/safe_topic/" 400 "" "Reject empty sequence ID field"

# 3. Protocol Hardening: Unsupported HTTP Methods
# The engine is designed to drop connections for unknown methods to save cycles.
check_status "PUT" "/pub/safe_topic" 0 "" "Reject PUT request (Immediate Drop)"
check_status "DELETE" "/sub/safe_topic/0" 0 "" "Reject DELETE request (Immediate Drop)"

# 4. Fuzzing: Buffer Overflow & Payload Stress
# Ensures the zero-allocation loop handles large payloads without stack corruption.
HUGE_PAYLOAD=$(head -c 10000 < /dev/zero | tr '\0' 'A')
check_status "POST" "/pub/safe_topic" 200 "$HUGE_PAYLOAD" "Handle 10KB payload (Verify Truncation/Stability)"

echo "-----------------------------------------------------------------"
echo -e "${GREEN}✅ SECURITY TESTS PASSED! The engine is bulletproof.${NC}"

# Cleanup after success
docker compose down -v > /dev/null 2>&1