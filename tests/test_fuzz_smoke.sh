#!/bin/bash
# -----------------------------------------------------------------------------
# Script: test_fuzz_smoke.sh
# Project: La Roca Micro-PubSub
# Responsibility: Smoke test for the AFL++ harness. Verifies the pure L7 parser
#                 never crashes (exit 0) across corpus seeds, edge cases, and a
#                 deterministic burst of random inputs. This is NOT a substitute
#                 for a real afl-fuzz campaign; run AFL++ separately (see the
#                 Makefile `fuzz` target and tests/afl_harness.c header).
# -----------------------------------------------------------------------------
set -u

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BLUE='\033[0;34m'
BOLD='\033[1m'

BIN="bin/fuzz_parser"
CORPUS="tests/corpus"
RANDOM_ROUNDS=2000

echo -e "${BOLD}${BLUE}============================================${NC}"
echo -e "${BOLD}${BLUE}  La Roca: Fuzz Harness Smoke Test (no-crash)${NC}"
echo -e "${BOLD}${BLUE}============================================${NC}"

# Build the harness (plain gcc unless FUZZ_CC is set)
make fuzz >/dev/null 2>&1
if [ ! -x "$BIN" ]; then
    echo -e "${RED}[FAIL] Could not build $BIN (make fuzz)${NC}"
    exit 1
fi

fail=0

# --- 1. Corpus seeds ---
echo -e "${BLUE}[1/3] Corpus seeds...${NC}"
for f in "$CORPUS"/*; do
    [ -f "$f" ] || continue
    if "$BIN" < "$f" >/dev/null 2>&1; then
        echo -e "${GREEN}[PASS]${NC} seed $(basename "$f")"
    else
        echo -e "${RED}[FAIL]${NC} seed $(basename "$f") (exit $?)"
        fail=1
    fi
done

# --- 2. Edge cases (short reads, malformed methods, oversized topics) ---
echo -e "${BLUE}[2/3] Edge cases...${NC}"
edge_cases=(
    ""
    "A"
    "GET"
    "GET "
    "POST"
    "PUT /live HTTP/1.1"
    "GET /sub/"
    "GET /sub/12345678901234567/0 HTTP/1.1"
    "POST /mpub/"
    "GET /unknown/path"
    "GET /livex"
    "POST /pub/x"
)
for input in "${edge_cases[@]}"; do
    if printf '%s' "$input" | "$BIN" >/dev/null 2>&1; then
        echo -e "${GREEN}[PASS]${NC} edge: '${input:0:42}'"
    else
        echo -e "${RED}[FAIL]${NC} edge: '${input:0:42}' (exit $?)"
        fail=1
    fi
done

# --- 3. Deterministic random burst (crash check) ---
echo -e "${BLUE}[3/3] Random burst ($RANDOM_ROUNDS inputs)...${NC}"
for i in $(seq 1 "$RANDOM_ROUNDS"); do
    if ! head -c $((RANDOM % 512)) /dev/urandom | "$BIN" >/dev/null 2>&1; then
        echo -e "${RED}[FAIL]${NC} random input #$i crashed the parser"
        fail=1
        break
    fi
done

if [ "$fail" -eq 0 ]; then
    echo -e "${GREEN}[PASS]${NC} random burst: no crashes"
    echo -e "\n${BOLD}${GREEN}=== FUZZ SMOKE TEST PASSED ===${NC}"
    exit 0
else
    echo -e "\n${BOLD}${RED}=== FUZZ SMOKE TEST FAILED ===${NC}"
    exit 1
fi
