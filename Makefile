# =============================================================================
# Makefile for La Roca Micro-PubSub
# Toolchain: NASM + LD (x86_64)
# =============================================================================

# Tools
ASM = nasm
LD = ld

# Flags
ASMFLAGS = -f elf64 -g
LDFLAGS = -m elf_x86_64

# Directories
SRC_DIR = src
CORE_DIR = src/core
ROUTERS_DIR = src/routers
BUILD_DIR = build
BIN_DIR = bin

# Target Executable
TARGET = $(BIN_DIR)/micro-pubsub

# Find all .asm files in the directories
SOURCES = $(wildcard $(SRC_DIR)/*.asm) \
          $(wildcard $(CORE_DIR)/*.asm) \
          $(wildcard $(ROUTERS_DIR)/*.asm)

# Generate a list of .o files in the build directory
OBJECTS = $(patsubst %.asm, $(BUILD_DIR)/%.o, $(notdir $(SOURCES)))

# VPATH tells make where to look for dependencies
VPATH = $(SRC_DIR):$(CORE_DIR):$(ROUTERS_DIR)

# Default target
all: dirs $(TARGET)

# Create necessary directories
dirs:
	mkdir -p $(BUILD_DIR)
	mkdir -p $(BIN_DIR)

# Linking stage
$(TARGET): $(OBJECTS)
	$(LD) $(LDFLAGS) -o $@ $^
	@echo "Build complete! Executable is at: $(TARGET)"

# Assembly stage
$(BUILD_DIR)/%.o: %.asm
	$(ASM) $(ASMFLAGS) -i $(SRC_DIR)/ -i $(CORE_DIR)/ -i $(SRC_DIR)/include/ -o $@ $<

# Clean up build artifacts
clean:
	rm -rf $(BUILD_DIR) $(BIN_DIR)
	@echo "Cleaned build/ and bin/ directories."

# Run the server
run: all
	./$(TARGET)

# -----------------------------------------------------------------------------
# Fuzzing target: build the AFL++ harness for the pure L7 parser.
#   make fuzz                       -> gcc (plain harness, for smoke testing)
#   make fuzz FUZZ_CC=afl-clang-fast -> AFL++-instrumented harness (afl-gcc is
#                                       obsolete in AFL++ 4.x; use -fast variants)
# Then: afl-fuzz -i tests/corpus -o tests/findings -V 90 -- ./bin/fuzz_parser
# NOTE: this instruments the C harness only. To instrument the hand-written
# assembly you need QEMU mode (-Q), which requires afl-qemu-trace (not shipped
# in the Ubuntu afl++ package; build it from source via build_qemu_support.sh).
# -----------------------------------------------------------------------------
FUZZ_CC ?= gcc
FUZZ_BIN = $(BIN_DIR)/fuzz_parser

.PHONY: fuzz
fuzz: dirs $(BUILD_DIR)/parse_http_request.o
	$(FUZZ_CC) -o $(FUZZ_BIN) tests/afl_harness.c $(BUILD_DIR)/parse_http_request.o
	@echo "Fuzz harness built: $(FUZZ_BIN)"

.PHONY: all dirs clean run fuzz