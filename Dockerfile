# =============================================================================
# Stage 1: Builder
# Using Alpine to provide a clean environment with the necessary build tools.
# =============================================================================
FROM alpine:latest AS builder

# Install NASM, Make, and Binutils (required for the 'ld' linker)
RUN apk add --no-cache nasm make binutils

# Set the working directory
WORKDIR /build

# Copy the entire source code and the Makefile
COPY . .

# Compile the project using the provided Makefile
RUN make

# =============================================================================
# Stage 2: Final Production Image
# Using 'scratch' (completely empty). Zero dependencies, maximum security,
# and an ultra-minimal footprint.
# =============================================================================
FROM scratch

# Set the working directory
WORKDIR /app

# Copy ONLY the compiled static binary from the builder stage
COPY --from=builder /build/bin/micro-pubsub /app/micro-pubsub

# Expose the HTTP router port
EXPOSE 8080

# Declare the volume to ensure the Ring Buffers (mmap files)
# survive container restarts, enforcing Disk Authority.
VOLUME ["/app/topics"]

# Startup command
CMD ["/app/micro-pubsub"]