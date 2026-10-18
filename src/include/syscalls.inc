; -----------------------------------------------------------------------------
; Module: src/include/syscalls.inc
; Project: La Roca Micro-PubSub
; Responsibility: Zero-cost System V AMD64 ABI syscall macros.
;                 Replaces repetitive `mov rax, N` blocks with compile-time
;                 expansion — no runtime abstraction, no stack traffic.
; -----------------------------------------------------------------------------
;
; REGISTER SAFETY (The Sacred ABI):
;   - The Linux x86_64 syscall ABI clobbers RCX and R11 (the kernel saves
;     RIP/RFLAGS there) and returns the result in RAX.
;   - These macros ONLY write RAX and the argument registers they are handed
;     (RDI, RSI, RDX, R10, R8, R9). They never touch R12-R15, RBX or RBP.
;   - CALLER CONTRACT: treat RAX, RCX, R11 and any argument register you pass
;     as destroyed after the macro. Preserve them yourself if you need them.
;   - Do NOT pass register arguments aliased out of ABI order (a value living
;     in RDX must be the 3rd argument, not the 4th). Label arguments are
;     expanded to their ADDRESS; equ constants to their numeric value.
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
; SYSCALL num [, rdi] [, rsi] [, rdx] [, r10] [, r8] [, r9]
; Generic wrapper. `num` may be a literal or a SYS_* %define.
; -----------------------------------------------------------------------------
%macro SYSCALL 1-7
    %if %0 > 1
        mov rdi, %2
    %endif
    %if %0 > 2
        mov rsi, %3
    %endif
    %if %0 > 3
        mov rdx, %4
    %endif
    %if %0 > 4
        mov r10, %5
    %endif
    %if %0 > 5
        mov r8,  %6
    %endif
    %if %0 > 6
        mov r9,  %7
    %endif
    mov rax, %1
    syscall
%endmacro

; --- Convenience wrappers for the hot syscalls ---

; DO_SYS_READ fd, buf, len
%macro DO_SYS_READ 3
    SYSCALL SYS_READ, %1, %2, %3
%endmacro

; DO_SYS_WRITE fd, buf, len
%macro DO_SYS_WRITE 3
    SYSCALL SYS_WRITE, %1, %2, %3
%endmacro

; DO_SYS_CLOSE fd
%macro DO_SYS_CLOSE 1
    SYSCALL SYS_CLOSE, %1
%endmacro

; DO_SYS_EPOLL_WAIT epfd, events, maxevents, timeout
%macro DO_SYS_EPOLL_WAIT 4
    SYSCALL SYS_EPOLL_WAIT, %1, %2, %3, %4
%endmacro

; DO_SYS_MMAP addr, length, prot, flags, fd, offset
%macro DO_SYS_MMAP 6
    SYSCALL SYS_MMAP, %1, %2, %3, %4, %5, %6
%endmacro
