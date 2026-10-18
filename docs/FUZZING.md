# L7 Router Fuzzing (AFL++ with real assembly coverage)

This document explains **how** we fuzz La Roca's HTTP router, **why** guided
coverage over hand-written assembly is non-trivial, and **what results** we got.
It is the technical backing for the engine's robustness claim.

---

## 1. What we fuzz and why

The network entry point of La Roca is the L7 parser (`src/routers/parse_http_request.asm`).
It is the first code that touches **any byte arriving on the socket**, and is
therefore the largest attack surface (malformed requests, overflows, out-of-range
reads). If this parser has a memory bug, the whole engine goes down.

We extracted it into a **pure** module —no syscalls, no handlers, no side effects—,
so it can be fuzzed in isolation, without network or engine:

```asm
; parse_http_request(buffer_ptr, length) -> route_code
; No syscalls, no global state, no side effects.
```

The harness (`tests/afl_harness.c`) reads STDIN, calls the parser and exits.
AFL++ uses its fork-server to restart the process on every mutation, so a segfault
shows up immediately as a crash.

---

## 2. The problem: assembly does not instrument itself

`afl-clang-fast` instruments **the C code** it compiles. But the parser is
**assembly assembled with NASM**: afl-clang-fast does not touch it. The result is
an illusion of coverage: the C harness has 2 basic blocks, so `afl-showmap`
always reported **2 tuples with the same hash**, regardless of the input.

This was verified empirically:

```bash
$ afl-showmap -- ./bin/fuzz_parser < seed1  # 2 tuples
$ afl-showmap -- ./bin/fuzz_parser < seed2  # 2 tuples, same hash
```

Without differentiated coverage, afl-fuzz **cannot steer itself** toward new paths.
The two ways to fix it:

| Path | Mechanism | Cost |
|-----|-----------|-------|
| QEMU mode (`-Q`) | `afl-qemu-trace` emulates and instruments the binary | Compile patched QEMU (~40 min, GB of disk) + `qemu-user`, `meson`, `libglib2.0-dev`, `bison`, `flex` |
| **Manual instrumentation** ✅ | Mark each basic block with a `call __afl_trace` | No extra dependencies; the runtime already shipped in `afl-compiler-rt.o` |

We chose **manual instrumentation**: it achieves the same real coverage, without
sudo or heavy builds, and it is faithful to the project's spirit (everything by
hand, no dependencies).

---

## 3. How we instrumented the assembly

In `parse_http_request.asm` we defined a conditional macro:

```asm
%ifdef AFL_INSTRUMENTED
    extern __afl_trace
%macro AFL_EDGE 1
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push rbx
    mov rbx, rsp
    and rsp, -16          ; stack aligned to 16 for the call (SysV)
    mov edi, %1
    call __afl_trace
    mov rsp, rbx
    pop rbx
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
%endmacro
%else
%macro AFL_EDGE 1        ; production build: emits nothing
%endmacro
%endif
```

Each basic block of the router carries an `AFL_EDGE <id>` with a unique id (17
edges in total: entry, GET/POST, each route, and each branch of the topic
validator). `__afl_trace(id)` implements the **neverZero** counter over the
shared map:

```c
void __afl_trace(const u32 x) {
    PREV_LOC_T prev = __afl_prev_loc[0];
    __afl_prev_loc[0] = (x >> 1);
    u8 *p = &__afl_area_ptr[prev ^ x];
    // increment with overflow protection (never wraps back to 0)
    ...
}
```

Key properties:

- **Production untouched**: without `-DAFL_INSTRUMENTED`, `AFL_EDGE` expands to
  nothing. The production binary is byte-identical to an uninstrumented build.
- **Registers preserved**: the macro saves/restores all caller-saved registers
  (and `rbx`), so it does not alter the parser's semantics.
- **Stack always aligned**: `and rsp, -16` guarantees the SysV ABI of the `call`
  regardless of whether the edge sits in a prologue body or at a `call`-target
  entry.

---

## 4. How to build and verify coverage

```bash
# Build the instrumented harness (assembly + AFL runtime)
make fuzz-afl

# Verify that coverage is REAL (varies by input)
afl-showmap -o /tmp/map -- ./bin/fuzz_parser_afl < tests/corpus/get_live.txt
#   -> 3 tuples (before: 2 identical tuples for everything)

# No-crash smoke test (corpus + edge cases + random burst)
./tests/test_fuzz_smoke.sh
```

---

## 5. Real campaign

```bash
afl-fuzz -i tests/corpus -o tests/findings -V 300 -- ./bin/fuzz_parser_afl
```

Results (`tests/findings/default/fuzzer_stats`):

| Metric | Value |
|---------|-------|
| Duration | 300 s |
| Total executions | **2,712,732** |
| Speed | **9,042 exec/s** |
| Full queue cycles | 1,765 |
| Edges reached (of 17 basic blocks) | **15** |
| **Crashes** | **0** |
| Hangs | 0 |

---

## 6. Robustness + efficiency: the full picture

Fuzzing demonstrates **robustness** (0 crashes after hundreds of thousands of
guided mutations over the network entry point). **Efficiency** is demonstrated by
the concurrency benchmark (`tests/bench.go`), which in the CI environment gave:

| Metric | Value |
|---------|-------|
| Throughput | **27,558 req/s** |
| Messages/s (batch of 100) | **~2,755,800 msg/s** |
| Errors | 0 |

Together: an L7 router that withstands aggressive fuzzing without a single crash
and sustains ~2.7 million messages per second over local loopback.
