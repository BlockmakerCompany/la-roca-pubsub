; -----------------------------------------------------------------------------
; Module: src/core/config.inc
; Project: La Roca Micro-PubSub
; Responsibility: System-wide macros, syscall definitions, and constants.
; -----------------------------------------------------------------------------

; Logger Levels
%define LOG_INFO  0
%define LOG_WARN  1
%define LOG_ERROR 2

; Epoll Constants
%define EPOLLIN 1
%define EPOLL_CTL_ADD 1

; Common Syscalls (x86_64)
%define SYS_READ      0
%define SYS_WRITE     1
%define SYS_OPEN      2
%define SYS_CLOSE     3
%define SYS_LSEEK     8
%define SYS_MMAP      9
%define SYS_MSYNC     26
%define SYS_SOCKET    41
%define SYS_ACCEPT    43
%define SYS_BIND      49
%define SYS_LISTEN    50
%define SYS_SETSOCKOPT 54
%define SYS_EXIT      60
%define SYS_FTRUNCATE 77
%define SYS_MKDIR     83

%define SYS_EPOLL_WAIT  232
%define SYS_EPOLL_CTL   233
%define SYS_EPOLL_CREATE1 291

; =============================================================================
; MACRO: TRACE
; Zero-side-effect logging tool for debugging.
; Preserves all volatile registers modified by syscalls.
; Note: NASM syntax requires no leading spaces before %macro.
; =============================================================================
%macro TRACE 1
    section .data
        %%msg db "[TRACE] ", %1, 10, 0
        %%len equ $ - %%msg
    section .text
        push rax
        push rdi
        push rsi
        push rdx
        push rcx
        push r11
        mov rax, SYS_WRITE  ; syscall: sys_write
        mov rdi, 1          ; file descriptor: STDOUT
        lea rsi, [%%msg]
        mov rdx, %%len
        syscall
        pop r11
        pop rcx
        pop rdx
        pop rsi
        pop rdi
        pop rax
%endmacro