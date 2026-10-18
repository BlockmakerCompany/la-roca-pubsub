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
# Fuzzing targets for the pure L7 parser.
#
#   make fuzz                          -> gcc harness, plain parser (smoke test)
#   make fuzz FUZZ_CC=afl-clang-fast   -> AFL++-instrumented C harness only (the
#                                         assembly stays UNinstrumented; low value)
#   make fuzz-afl                      -> REAL coverage: the parser assembly is
#                                         manually instrumented (AFL_EDGE calls
#                                         __afl_trace) and linked against the
#                                         AFL++ runtime. No QEMU mode needed.
#
# Run the guided campaign:
#   afl-fuzz -i tests/corpus -o tests/findings -V 90 -- ./bin/fuzz_parser_afl
# -----------------------------------------------------------------------------
FUZZ_CC ?= gcc
FUZZ_BIN = $(BIN_DIR)/fuzz_parser

AFL_RT = /usr/lib/afl/afl-compiler-rt.o
FUZZ_AFL_BIN = $(BIN_DIR)/fuzz_parser_afl

.PHONY: fuzz
fuzz: dirs $(BUILD_DIR)/parse_http_request.o tests/afl_harness.c
	$(FUZZ_CC) -o $(FUZZ_BIN) tests/afl_harness.c $(BUILD_DIR)/parse_http_request.o
	@echo "Fuzz harness built: $(FUZZ_BIN)"

# Instrumented parser object (only for fuzzing; production object is untouched).
$(BUILD_DIR)/parse_http_request_afl.o: src/routers/parse_http_request.asm
	$(ASM) $(ASMFLAGS) -DAFL_INSTRUMENTED -i $(SRC_DIR)/ -i $(CORE_DIR)/ -i $(SRC_DIR)/include/ -o $@ $<

.PHONY: fuzz-afl
fuzz-afl: dirs $(BUILD_DIR)/parse_http_request_afl.o tests/afl_harness.c
	$(FUZZ_CC) -no-pie -o $(FUZZ_AFL_BIN) tests/afl_harness.c $(BUILD_DIR)/parse_http_request_afl.o $(AFL_RT)
	@echo "AFL-instrumented fuzz harness built: $(FUZZ_AFL_BIN)"

.PHONY: all dirs clean run fuzz fuzz-afl