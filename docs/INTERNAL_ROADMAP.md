# 🛠️ La Roca: Hacking & Internal Engineering Guide

This document is intended for systems engineers, low-level contributors, and the core team. It details the internal roadmap, architectural constraints, and exact implementation guidelines required to modify **La Roca Micro-PubSub** without breaking its $O(1)$ deterministic performance.

---

# ⚙️ Internal Engineering & DX Roadmap

While the main `README.md` outlines high-level features (like HTTP/1.1 Keep-Alive and `io_uring`), this document tracks the deep internal refactoring, low-level optimizations, and Developer Experience (DX) improvements planned for the core Assembly engine.

---

## 1. Network & I/O Optimization

While La Roca currently saturates network interfaces by eliminating `libc` overhead, the consumer fan-out process and state tracking still have room for extreme low-level optimization. Our goal is to completely bypass user-space memory copying and implement stateless, resilient offset tracking.

### 1.1. True Zero-Copy Payload Delivery (`sys_sendfile`)
> ✅ **Implemented in v1.4.0.** The registry now stores the open topic FD; `handle_sub` sends headers via `sys_write` and the payload via `sys_sendfile` (`locate_message` in `subscriber.asm` returns the file offset + length without copying).

Currently, when a subscriber requests a message, the engine calculates the $O(1)$ `mmap` pointer, loads the payload into the L1 cache, and dispatches it to the socket buffer using `sys_write`. For massive fan-out scenarios (1 publisher to 10,000 subscribers), this pollutes the CPU cache unnecessarily.

**The Goal:** Instruct the Linux Kernel to transfer bytes directly from the page cache (the topic file) to the network socket buffer, ensuring the payload bytes never touch user-space registers.

**Execution Plan:**
1. **Syscall Transition:** Replace `sys_write` (syscall 1) with `sys_sendfile` (syscall 40) in the consumer delivery loop.
2. **File Descriptor Management:** The engine must keep the original file descriptor (`in_fd`) of the topic open, alongside the client socket (`out_fd`).
3. **Register Topology for `sys_sendfile`:**
   * `RAX`: `40` (syscall number for `sendfile`).
   * `RDI`: `out_fd` (The subscriber's `epoll` socket).
   * `RSI`: `in_fd` (The topic file descriptor).
   * `RDX`: Pointer to the absolute byte offset of the message inside the file (calculated using our $O(1)$ geometry: `BaseHeader + (Sequence * SlotSize)`).
   * `R10`: `count` (The exact length of the payload).

```nasm
; Zero-Copy Delivery Draft
mov rax, 40                 ; sys_sendfile
mov rdi, [client_socket]    ; out_fd
mov rsi, [topic_fd]         ; in_fd
lea rdx, [calculated_offset]; offset pointer (must be in memory, not literal)
mov r10, [payload_size]     ; count
syscall
```

4. **Impact:** The CPU strictly acts as an orchestrator, orchestrating DMA (Direct Memory Access) transfers. This practically eliminates CPU utilization during massive subscriber spikes.

### 1.2. Resilient Consumer Offset Tracking
Publisher sequence generation is mathematically flawless thanks to `lock xadd`. However, consumer state (where a subscriber left off) is currently handled purely in-memory by the client. If a subscriber disconnects, it must explicitly request a sequence number upon reconnect, or risk missing messages.

**The Goal:** Persist Consumer Group offsets persistently and synchronously without introducing locks or blocking I/O.

**Execution Plan:**
1. **The Offset Map:** Introduce a secondary, micro-`mmap` file per topic (e.g., `topic_name.idx`).
2. **Memory Layout:** This file is fundamentally an array of 64-bit integers (`QWORD`), where each index represents a unique Consumer Group ID.
   * `Slot 0` = Consumer Group 0 Offset
   * `Slot 1` = Consumer Group 1 Offset
3. **Wait-Free Updates:** Since each Consumer Group is assigned a specific, non-overlapping 8-byte slot in the index file, consumers can update their offsets concurrently without locks.
4. **Implementation Detail:** After a successful `sys_sendfile` or `sys_write` to the consumer, the engine executes a direct memory write:

```nasm
; R14 holds the base pointer to the mmap offset index
; RBX holds the Consumer Group ID
; R15 holds the next sequence number to fetch
mov [r14 + rbx * 8], r15    ; O(1) persistent offset update
sfence                      ; Ensure memory barrier before next read
```

5. **Impact:** Instant $O(1)$ resume capability. If a Kubernetes pod dies and reconnects presenting its Consumer Group ID, the engine instantly fetches `[r14 + group_id * 8]` and resumes streaming without rescanning.

---

## 2. CPU & Memory Mechanics

La Roca’s core performance relies on keeping the processor in its "hot path" (L1/L2 cache) and treating memory as strict mathematical geometry. The next evolution of the internal engine focuses on maximizing throughput per clock cycle via vectorization and ensuring infinite capacity without downtime.

### 2.1. Dynamic Hot-Resizing (`sys_mremap`)
Topics currently utilize a pre-allocated `mmap` region with a fixed memory geometry. If a topic reaches maximum capacity, it acts as a Ring Buffer (overwriting old data). For non-volatile stream processing, we need the ability to expand the memory space dynamically on the fly.

**The Goal:** Expand the memory-mapped file without halting the publisher hot-loop or invalidating existing memory offsets.

**Execution Plan:**
1. **Threshold Trapping:** The `lock xadd` publisher sequence logic must trap when the sequence counter exceeds 90% of the maximum capacity.
2. **File Truncation:** Trigger `sys_ftruncate` (syscall 77) to grow the underlying NVMe disk file allocation.
3. **Memory Remapping (`sys_mremap`):** Execute `sys_mremap` to expand the virtual memory mapping.
4. **Implementation Detail & Constraints:** We MUST pass the `MREMAP_MAYMOVE` flag (value `1`). If the kernel cannot grow the memory block in place, it will relocate the entire map to a new virtual address. We must atomically update our pinned `R12` register to the new address returned in `RAX`.

```nasm
; Dynamic Hot-Resize Draft
mov rax, 25                 ; sys_mremap syscall number
mov rdi, r12                ; old_address (our Pinned R12 base pointer)
mov rsi, [old_size]         ; old map size
mov rdx, [new_size]         ; requested new map size
mov r10, 1                  ; flags = MREMAP_MAYMOVE
syscall

; CRITICAL: Update the pinned base pointer immediately
; All subsequent O(1) calculations will natively use the new memory region
mov r12, rax
```

5. **Impact:** Infinite topic retention with zero downtime. Publishers and consumers experience a microsecond jitter during the remap, followed immediately by uninterrupted $O(1)$ memory access.

---

## 3. Security & Continuous Testing

Building a network-facing router in pure x86_64 Assembly removes the memory safety nets provided by compilers like Rust or Go. A single off-by-one error in our L7 HTTP parser could lead to a buffer over-read or a catastrophic segmentation fault. To mitigate this, we rely on mathematically proven boundaries and continuous automated fuzzing.

### 3.1. Continuous Fuzzing Pipeline (AFL++)
> ✅ **Implemented in v1.4.0.** `parse_http_request` extracted to `src/routers/parse_http_request.asm` (pure, no side effects); `tests/afl_harness.c` + `make fuzz` + `tests/test_fuzz_smoke.sh` added. Run `afl-fuzz -i tests/corpus -o tests/findings ./bin/fuzz_parser` for the campaign.

Our custom HTTP router (`route_api.asm`) manually inspects network buffers in the L1 cache. Because we expect highly specific structures (like `cmp eax, 0x20544547` for `"GET "`), an attacker might send malformed bytes to trick our bitmasking logic.

**The Goal:** Prove the absolute memory safety of the L7 Router by bombarding it with mutated payloads using AFL++ (American Fuzzy Lop).

**Execution Plan:**
1. **The C Harness:** We cannot easily fuzz the `epoll` network loop directly. Instead, we write a minimal C harness (`tests/afl_harness.c`) that bypasses the network layer. It reads mutated data from `STDIN` and passes the memory pointer directly to our Assembly routing subroutine.

```c
// tests/afl_harness.c
#include <unistd.h>

// Declare our external Assembly subroutine
extern void parse_http_request(char* buffer, int length);

int main() {
    char buffer[8192];
    // AFL++ feeds mutated payloads via STDIN (fd 0)
    int len = read(0, buffer, sizeof(buffer));
    if (len > 0) {
        // Jump directly into La Roca's L7 router
        parse_http_request(buffer, len);
    }
    return 0;
}
```

2. **Integration (`make fuzz`):**
   * Compile the Assembly router as a statically linked object (`nasm -f elf64 route_api.asm`).
   * Compile the harness with the AFL++ compiler: `afl-gcc tests/afl_harness.c route_api.o -o fuzzer_bin`.
   * Run AFL++ with a starting corpus of valid HTTP requests and massive `X-Roca-Key` payloads.
3. **Validation Criteria:** The router must NEVER crash (SegFault). It must gracefully exhaust its parsing loop and jump to the `400 Bad Request` fallback block regardless of how corrupted the input string is.

### 3.2. ABI Auditing & Test-Driven Assembly
When contributing new logic, developers often accidentally clobber volatile registers (like `RCX` or `R11` during a `syscall`).

**The Goal:** Catch ABI violations before they merge into the `main` branch.

**Execution Plan:**
* **`strace` Fault Injection:** Use `strace -e fault=write` during integration tests to intentionally make `sys_write` fail (simulating a broken pipe). The Assembly engine must catch the negative return value in `RAX`, correctly pop all preserved registers, and jump to the socket cleanup subroutine without leaking memory or leaving zombie file descriptors in the `epoll` instance.
* **GDB Scripting:** Implement automated GDB scripts in GitHub Actions that place breakpoints at the start and end of critical subroutines, asserting that the values of `R12` (mmap base) and `R13` (sequence counter) remain completely unmutated.

---

> **Final Note to Contributors:**
> La Roca is an exercise in extreme mechanical sympathy. Every instruction counts. Every byte of memory has a purpose. Do not add abstractions for comfort. Respect the silicon.
