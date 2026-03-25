#!/bin/bash
# =============================================================================
# Functional End-to-End Tests for La Roca Micro-PubSub (v1.3.0)
# =============================================================================

HOST="http://localhost:8080"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- START SETUP ---
echo "🧹 Cleaning previous state..."
docker compose down -v > /dev/null 2>&1

rm -rf topics/*.log 2>/dev/null

echo "🏗️  Starting ephemeral engine (Named Topics & Stream Processing Mode)..."
docker compose up -d --build pubsub-engine > /dev/null 2>&1
sleep 2
# --- END SETUP ---

echo "🚀 Starting La Roca Micro-PubSub E2E Tests..."
echo "Target: $HOST"
echo "-----------------------------------------------------------------"

# Helper function to print logs and exit on failure
fail_and_exit() {
    echo -e "${YELLOW}\n=== 🕵️‍♂️ DOCKER LOGS (pubsub-engine) ===${NC}"
    docker compose logs pubsub-engine
    echo -e "${YELLOW}=======================================${NC}\n"

    echo "🧹 Tearing down containers..."
    docker compose down -v > /dev/null 2>&1
    exit 1
}

# Helper function to check HTTP status codes
check_status() {
    local endpoint=$1
    local method=$2
    local expected=$3
    local payload=$4
    local description=$5

    if [ "$method" == "POST" ]; then
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -d "$payload" "$HOST$endpoint")
    else
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$HOST$endpoint")
    fi

    if [ "$STATUS" -eq "$expected" ]; then
        echo -e "${GREEN}[PASS]${NC} $description (Got $STATUS)"
    else
        echo -e "${RED}[FAIL]${NC} $description (Expected $expected, got $STATUS)"
        fail_and_exit
    fi
}

# Helper function to check exact response payload
check_payload() {
    local endpoint=$1
    local expected_payload=$2
    local description=$3

    # Command substitution automatically trims the trailing newline
    RESPONSE=$(curl -s -X GET "$HOST$endpoint" | tr -d '\0')

    if [ "$RESPONSE" == "$expected_payload" ]; then
        echo -e "${GREEN}[PASS]${NC} $description"
    else
        echo -e "${RED}[FAIL]${NC} $description"
        echo "       Expected: $expected_payload"
        echo "       Got:      $RESPONSE"
        fail_and_exit
    fi
}

# =============================================================================
# TEST SUITE
# =============================================================================

# 1. System Health
check_status "/live" "GET" 200 "" "Healthcheck endpoint is reachable"

# 2. The Auto-Provisioning Test
check_status "/pub/auto_created" "POST" 200 "data" "Auto-create a non-existent topic on the fly"

# 3. Invalid Requests
check_status "/sub/btc/not_a_number" "GET" 400 "" "Reject non-numeric sequence (400 Bad Request)"

# 4. Named Topic Lifecycle
check_status "/pub/ticker_btc" "POST" 200 "BTC_72000" "Publish valid message to 'ticker_btc'"

# 5. Read by Sequence (O(log N) lookup)
check_payload "/sub/ticker_btc/0" "BTC_72000" "Consume 'ticker_btc' sequence 0"

# 6. Read Future Sequence (404 Not Found)
check_status "/sub/ticker_btc/99" "GET" 404 "" "Attempt to read future sequence returns 404"

# 7. Multiple Messages
check_status "/pub/orders_eth" "POST" 200 "ETH_3500" "Publish to second named topic 'orders_eth'"
check_status "/pub/orders_eth" "POST" 200 "ETH_3600" "Publish another message to 'orders_eth'"

# 8. Read Back Orders
check_payload "/sub/orders_eth/0" "ETH_3500" "Verify 'orders_eth' sequence 0"
check_payload "/sub/orders_eth/1" "ETH_3600" "Verify 'orders_eth' sequence 1"

# 9. BATCH CONSUMPTION (THE HOT LOOP)
check_status "/pub/batch_test" "POST" 200 "Msg_1" "Publish Msg 1 for batching"
check_status "/pub/batch_test" "POST" 200 "Msg_2" "Publish Msg 2 for batching"
check_status "/pub/batch_test" "POST" 200 "Msg_3" "Publish Msg 3 for batching"

EXPECTED_BATCH=$(printf "Msg_1\nMsg_2\nMsg_3")
check_payload "/batch/batch_test/0/10" "$EXPECTED_BATCH" "Consume 3 messages via Batch Endpoint (Limit 10)"

# =============================================================================
# NEW TESTS: MULTI-PUBLISH & STREAM PROCESSING (X-Roca-Key)
# =============================================================================

# 10. MULTI-PUBLISH (Batch Ingestion via \n)
MPUB_PAYLOAD=$(printf "Line_1\nLine_2\nLine_3")
MPUB_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -d "$MPUB_PAYLOAD" "$HOST/mpub/mpub_test")
if [ "$MPUB_STATUS" -eq "200" ]; then
    echo -e "${GREEN}[PASS]${NC} Multi-Publish 3 delimited messages to 'mpub_test'"
else
    echo -e "${RED}[FAIL]${NC} Multi-Publish ingestion failed (Got $MPUB_STATUS)"
    fail_and_exit
fi
check_payload "/sub/mpub_test/1" "Line_2" "Verify 'mpub_test' sequence 1 (Ingested via mpub)"

# 11. STREAM PROCESSING (Routing Key Storage & Extraction)
# Publish a message with a custom Routing Key Header
curl -s -o /dev/null -H "X-Roca-Key: sensor_99" -X POST -d "Temp: 45C" "$HOST/pub/telemetry"

# Fetch the raw HTTP response (Headers + Body) using curl -i
KEY_RES=$(curl -s -i "$HOST/sub/telemetry/0")

# Check if the Header exists in the response
if echo "$KEY_RES" | grep -q "X-Roca-Key: sensor_99"; then
    echo -e "${GREEN}[PASS]${NC} Extracted X-Roca-Key from HTTP Response Header"
else
    echo -e "${RED}[FAIL]${NC} Missing X-Roca-Key in HTTP Response"
    fail_and_exit
fi

# Check if the Payload is intact (Not corrupted by the Key extraction)
if echo "$KEY_RES" | grep -q "Temp: 45C"; then
    echo -e "${GREEN}[PASS]${NC} Payload strictly isolated from Routing Key"
else
    echo -e "${RED}[FAIL]${NC} Payload corrupted during Key extraction"
    fail_and_exit
fi

# 12. Check System Metrics
check_status "/stats" "GET" 200 "" "Stats endpoint returns 200 OK"

echo "-----------------------------------------------------------------"
echo -e "${GREEN}✅ ALL TESTS PASSED SUCCESSFULLY!${NC}"
echo "Named Topics, Batching, and Stream Processing (X-Roca-Key) are rock solid."

# --- START TEARDOWN ---
docker compose down -v > /dev/null 2>&1
# --- END TEARDOWN ---