# ⚡ Register Topology Map — La Roca Micro-PubSub

In a zero-libc kernel, losing register state across a `syscall` or `call` means a
segfault. This document is the canonical reference for which registers hold what,
and what each instruction boundary is allowed to destroy. Any `.asm` module that
violates these pins will corrupt the hot loop.

---

## Pinned Registers (NEVER use for temporary math)

| Register | Purpose | Lifetime |
|----------|---------|----------|
| `R12` | `mmap` base pointer of the active topic | Pinned while a topic is in scope |
| `R13` | Global sequence counter address / loop bookkeeping | Pinned while the reactor loops |
| `RBP` / `RSP` | Stack frame boundaries | Always |

`R12` is the physical base of the memory-mapped topic file. Every O(1) offset
calculation (`256 + (seq % max) * msg_size`) derives from it. If a subroutine
needs scratch registers, it MUST push/pop `R12` first — never repurpose it.

`R13` carries the address of the global sequence counter used by `lock xadd`.
Do not use `R13` for intermediate math inside the publish/consume path.

## Volatile Registers (assume destroyed after any `syscall`)

`RAX`, `RCX`, `RDX`, `RSI`, `RDI`, `R8`–`R11`.

- `RCX` and `R11` are **always** clobbered by the kernel (RIP/RFLAGS save slots).
- The Linux x86_64 syscall ABI uses `RAX, RDI, RSI, RDX, R10, R8, R9` for args.
- After any `syscall`, `RAX` holds the return value.

If the `/mpub` loop counter or a payload pointer lives in one of these registers,
`push`/`pop` it around the syscall. The `syscalls.inc` macros do NOT preserve any
register — they are zero-cost by design.

## Callee-Saved Registers (preserved across `call`)

`RBX`, `RBP`, `R12`–`R15`.

Any subroutine that uses these MUST restore them before `ret`. The handlers
(`handle_pub`, `handle_sub`, `handle_batch`, `handle_mpub`) all follow the same
prologue/epilogue pattern: push in the order used, pop in reverse.

## Stack Alignment

Before executing a `call`, `RSP` MUST be 16-byte aligned. This protects kernel
transitions and any interaction with external C-like structures (even though we
don't link `libc`). When a handler does an odd number of pushes before a `call`,
insert a compensating `sub rsp, 8` / `add rsp, 8` pair — see `handle_batch.asm`.

## The Syscall Macros

`src/include/syscalls.inc` defines zero-cost compile-time wrappers (`SYSCALL`,
`DO_SYS_WRITE`, `DO_SYS_READ`, `DO_SYS_CLOSE`, `DO_SYS_EPOLL_WAIT`,
`DO_SYS_MMAP`). They expand to plain `mov` + `syscall` and write ONLY `RAX` and
the argument registers they are handed. They never touch `R12`-`R15`, `RBX`, or
`RBP`.

Caller contract: treat `RAX`, `RCX`, `R11` and any argument register you pass as
destroyed after the macro. Do not pass register arguments aliased out of ABI
order.
