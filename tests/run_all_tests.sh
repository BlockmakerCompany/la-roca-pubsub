#!/bin/bash

# -----------------------------------------------------------------------------
# Script: run_all_tests.sh
# Project: La Roca Micro-PubSub
# Responsibility: Master Test Orchestrator. Executes all suites and optional
#                 High-Frequency Go stress testing.
# -----------------------------------------------------------------------------

# --- UI Configuration ---
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'

echo -e "${BOLD}${BLUE}====================================================${NC}"
echo -e "${BOLD}${BLUE}   La Roca Micro-PubSub: Full Validation Pipeline   ${NC}"
echo -e "${BOLD}${BLUE}====================================================${NC}"

# Helper to run scripts and check exit codes
run_suite() {
    local script_path=$1
    local description=$2

    echo -e "\n${YELLOW}🚀 Running: $description...${NC}"

    if [ ! -f "$script_path" ]; then
        echo -e "${RED}  [ERROR] Script not found: $script_path${NC}"
        exit 1
    fi

    chmod +x "$script_path"
    ./"$script_path"

    if [ $? -ne 0 ]; then
        echo -e "\n${RED}❌ $description FAILED. Aborting pipeline.${NC}"
        exit 1
    fi
}

# --- 1. Core Test Suites (Mandatory) ---
run_suite "tests/test_config_persistence.sh" "Config & Disk Authority"
run_suite "tests/test_e2e.sh"                "Functional & Mmap Logic"
run_suite "tests/test_security.sh"           "Security Hardening & Protocol"

# --- 2. Optional Stress Testing (Go Benchmark) ---
if [[ "$1" == "--stress" ]]; then
    echo -e "\n${BOLD}${BLUE}🔥 Starting High-Frequency Stress Test Session...${NC}"

    # Check if Go is installed
    if command -v go &> /dev/null; then
        echo -e "${YELLOW}Target: > 3,000,000 Messages / sec (Multi-Publish)${NC}"
        go run tests/bench.go mpub

        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Stress test failed or crashed the engine.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}  [ERROR] Go compiler is not installed. Skipping stress test.${NC}"
        echo -e "  Please install Go from https://golang.org/ to run the high-performance benchmark."
    fi
fi

echo -e "\n${BOLD}${GREEN}====================================================${NC}"
echo -e "${BOLD}${GREEN}   ✔ ALL SYSTEMS OPERATIONAL - ENGINE IS STABLE     ${NC}"
echo -e "${BOLD}${GREEN}====================================================${NC}"