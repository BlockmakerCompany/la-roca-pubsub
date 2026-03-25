#!/bin/bash

# -----------------------------------------------------------------------------
# Script: tests/test_config_persistence.sh
# Project: La Roca Micro-PubSub
# Responsibility: Disk Authority & Immutable Geometry Validation (v1.3.0).
#                 Validates MsgSize, MaxMsgs, and KeySize persistence.
# -----------------------------------------------------------------------------

# --- CHANGED: Use an isolated port to avoid collisions with docker-compose ---
PORT=8888
IMAGE_NAME="blockmaker/la-roca-pubsub:latest"
TEST_DIR="$(pwd)/asm_pubsub_config_test_$$"
TOPIC_NAME="auth_topic"

MSG_0_PAYLOAD="Data_protected_by_disk_authority_Seq_0"
MSG_1_PAYLOAD="Data_written_under_poisoned_env_Seq_1"

# Initial healthy geometry
INITIAL_MSG_SIZE=512
INITIAL_MAX_MSGS=100
INITIAL_KEY_SIZE=16

# Poisoned geometry for reboot simulation
POISON_MSG_SIZE=2048
POISON_MAX_MSGS=50
POISON_KEY_SIZE=64

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'

echo -e "${BLUE}--- Starting Configuration Hierarchy & Disk Authority Test ---${NC}"

# Limpieza inicial estricta
docker rm -f asm_pubsub_config_run > /dev/null 2>&1
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

# --- FUNCIÓN FORENSE: Muestra logs antes de morir ---
fail_with_logs() {
    echo -e "${RED}[FAIL] $1${NC}"
    echo -e "${YELLOW}=== 🕵️‍♂️ ENGINE FORENSICS (Last 20 lines) ===${NC}"
    docker logs --tail 20 asm_pubsub_config_run
    echo -e "${YELLOW}==========================================${NC}"
    exit 1
}

cleanup() {
    echo -e "\n[INFO] Performing post-test cleanup..."
    docker rm -f asm_pubsub_config_run > /dev/null 2>&1
    rm -rf "$TEST_DIR"
    echo -e "${BLUE}--- Test environment purged ---${NC}"
}
trap cleanup EXIT

wait_for_engine() {
    echo -n "[INFO] Waiting for engine on port $PORT..."
    for i in {1..10}; do
        if curl -s "http://localhost:$PORT/live" > /dev/null; then
            echo -e " ${GREEN}Ready!${NC}"
            return 0
        fi
        echo -n "."
        sleep 1
    done
    echo -e " ${RED}Timeout!${NC}"
    return 1
}

# --- Phase 1: Initial Boot ---
echo -e "\n[INFO] Phase 1: Launching engine (Msg=$INITIAL_MSG_SIZE, Key=$INITIAL_KEY_SIZE)"
docker run -d --name asm_pubsub_config_run \
    -p $PORT:8080 \
    -e ROCK_MSG_SIZE=$INITIAL_MSG_SIZE \
    -e ROCK_MAX_MSGS=$INITIAL_MAX_MSGS \
    -e ROCK_KEY_SIZE=$INITIAL_KEY_SIZE \
    -v "$TEST_DIR:/app/topics" \
    $IMAGE_NAME > /dev/null

wait_for_engine || exit 1

echo -e "[INFO] Publishing Sequence 0 with Routing Key..."
curl -s -H "X-Roca-Key: node_alpha" -X POST -d "$MSG_0_PAYLOAD" "http://localhost:$PORT/pub/$TOPIC_NAME" > /dev/null

# --- Phase 2: Reboot with Poison ---
echo -e "\n[INFO] ${YELLOW}Rebooting with POISON Env (Msg=$POISON_MSG_SIZE, Key=$POISON_KEY_SIZE)${NC}"
docker rm -f asm_pubsub_config_run > /dev/null
sleep 1

docker run -d --name asm_pubsub_config_run \
    -p $PORT:8080 \
    -e ROCK_MSG_SIZE=$POISON_MSG_SIZE \
    -e ROCK_MAX_MSGS=$POISON_MAX_MSGS \
    -e ROCK_KEY_SIZE=$POISON_KEY_SIZE \
    -v "$TEST_DIR:/app/topics" \
    $IMAGE_NAME > /dev/null

wait_for_engine || exit 1

# --- Phase 3: Final Audit ---
echo -e "\n[INFO] Performing Final Audit (O(1) Offset & Key Integrity)..."

# 3.1 Publish Sequence 1 (Under poisoned environment)
curl -s -H "X-Roca-Key: node_beta" -X POST -d "$MSG_1_PAYLOAD" "http://localhost:$PORT/pub/$TOPIC_NAME" > /dev/null

# 3.2 Read Sequence 0
READ_MSG_0=$(curl -s "http://localhost:$PORT/sub/$TOPIC_NAME/0" | tr -d '\0')
if [ "$READ_MSG_0" = "$MSG_0_PAYLOAD" ]; then
    echo -e "  [${GREEN}PASS${NC}] Sequence 0 Integrity: Data survived the reboot."
else
    fail_with_logs "Sequence 0 Corrupted! Expected: '$MSG_0_PAYLOAD', Got: '$READ_MSG_0'"
fi

# 3.3 Read Sequence 1
READ_MSG_1=$(curl -s "http://localhost:$PORT/sub/$TOPIC_NAME/1" | tr -d '\0')
if [ "$READ_MSG_1" = "$MSG_1_PAYLOAD" ]; then
    echo -e "  [${GREEN}PASS${NC}] Disk Authority: O(1) offsets and KeySize intact."
else
    fail_with_logs "Geometry Poisoning successful! Key/Msg offsets shifted. Got: '$READ_MSG_1'"
fi

# 3.4 File Size Verification
FILE_PATH=""
[ -f "$TEST_DIR/$TOPIC_NAME.log" ] && FILE_PATH="$TEST_DIR/$TOPIC_NAME.log"
[ -f "$TEST_DIR/topics/$TOPIC_NAME.log" ] && FILE_PATH="$TEST_DIR/topics/$TOPIC_NAME.log"

if [ -z "$FILE_PATH" ]; then
    fail_with_logs "Log file not found in host volume!"
fi

# The file size calculation remains the same since KeySize is part of the MsgSize allocation.
FILE_SIZE=$(stat -c %s "$FILE_PATH" 2>/dev/null || stat -f %z "$FILE_PATH")
EXPECTED_SIZE=$((256 + (INITIAL_MSG_SIZE * INITIAL_MAX_MSGS)))

if [ "$FILE_SIZE" -eq "$EXPECTED_SIZE" ]; then
    echo -e "  [${GREEN}PASS${NC}] File Geometry: Strictly $EXPECTED_SIZE bytes."
else
    fail_with_logs "Size mismatch! Expected $EXPECTED_SIZE, got $FILE_SIZE."
fi

echo -e "\n${GREEN}✔ All persistence and Disk Authority tests PASSED.${NC}"