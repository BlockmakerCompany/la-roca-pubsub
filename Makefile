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
	$(ASM) $(ASMFLAGS) -i $(SRC_DIR)/ -i $(CORE_DIR)/ -o $@ $<

# Clean up build artifacts
clean:
	rm -rf $(BUILD_DIR) $(BIN_DIR)
	@echo "Cleaned build/ and bin/ directories."

# Run the server
run: all
	./$(TARGET)

.PHONY: all dirs clean run