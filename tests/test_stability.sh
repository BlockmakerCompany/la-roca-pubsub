#!/bin/bash
# =============================================================================
# Post-Stress Stability Test for La Roca Micro-PubSub (v1.3.0)
# =============================================================================
# Responsibility: hammer the engine with 100 concurrent TCP connections, then
#                 verify it is STILL responsive (/live and /stats return 200).
#                 Catches register-corruption hangs that leave the epoll event
#                 loop alive but unresponsive to new connections.
# =============================================================================

HOST="http://localhost:8080"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

fail_and_exit() {
    echo -e "${YELLOW}\n=== 🕵️‍♂️ DOCKER LOGS (pubsub-engine) ===${NC}"
    docker compose logs pubsub-engine
    echo -e "${YELLOW}=======================================${NC}\n"

    echo "🧹 Tearing down containers..."
    docker compose down -v > /dev/null 2>&1
    exit 1
}

# --- START SETUP ---
echo "🧹 Cleaning previous state..."
docker compose down -v > /dev/null 2>&1
rm -rf topics/*.log 2>/dev/null

echo "🏗️  Starting ephemeral engine (Stability Testing Mode)..."
docker compose up -d --build pubsub-engine > /dev/null 2>&1
sleep 2

# Precondition: engine must be reachable before we start hammering.
echo "🔎 Verifying engine is reachable..."
LIVE_STATUS=""
for _ in $(seq 1 10); do
    LIVE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$HOST/live")
    if [ "$LIVE_STATUS" == "200" ]; then
        break
    fi
    sleep 1
done

if [ "$LIVE_STATUS" != "200" ]; then
    echo -e "${RED}[FAIL]${NC} Engine not reachable at $HOST/live (got $LIVE_STATUS)"
    fail_and_exit
fi
echo -e "${GREEN}[PASS]${NC} Engine reachable (GET /live -> 200)"
# --- END SETUP ---

echo "-----------------------------------------------------------------"
echo -e "${YELLOW}🔥 Hammering engine with 100 concurrent connections (3s)...${NC}"

# Check Go availability
if ! command -v go &> /dev/null; then
    echo -e "${RED}[FAIL]${NC} Go compiler not installed. Cannot run the stability hammer."
    fail_and_exit
fi

# Run the hammer + post-stress healthcheck in one shot.
# bench.go exits non-zero on any error OR if /live//stats do not answer 200.
go run tests/bench.go mpub --verify -duration=3
BENCH_EXIT=$?

if [ "$BENCH_EXIT" -ne 0 ]; then
    echo -e "${RED}[FAIL]${NC} Stability test failed (bench exit=$BENCH_EXIT): engine unresponsive after stress."
    fail_and_exit
fi

echo "-----------------------------------------------------------------"
echo -e "${GREEN}✅ STABILITY TEST PASSED: engine survived the hammer and stayed responsive.${NC}"

# --- START TEARDOWN ---
docker compose down -v > /dev/null 2>&1
# --- END TEARDOWN ---
