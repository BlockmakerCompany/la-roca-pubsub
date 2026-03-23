; -----------------------------------------------------------------------------
; Module: src/core/globals.asm
; Project: La Roca Micro-PubSub
; Responsibility: Single Source of Truth for engine state and configuration.
;                 Holds default geometries, io_uring state, and boot metrics.
; -----------------------------------------------------------------------------

section .data
    global rt_msg_size
    global rt_max_messages
    global MAX_TOPICS
    global boot_time            ; Used for uptime metrics calculation

    ; Default Geometry & Engine Limits
    rt_msg_size         dq 256
    rt_max_messages     dq 262143       ; Default max messages (ensures ~64MB file size fallback)
    MAX_TOPICS          dq 8
    boot_time           dq 0            ; Populated dynamically during _start (boot time)

    ; io_uring global state (Asynchronous DMA)
    global worker_uring_sq_ptr
    global worker_uring_sq_tail
    global worker_uring_fd

    worker_uring_sq_ptr     dq 0
    worker_uring_sq_tail    dq 0
    worker_uring_fd         dq 0

section .text
    global log_event

; -----------------------------------------------------------------------------
; log_event: Fast STDOUT logging utility.
; Input: RSI = Pointer to message buffer, RDX = Message length
; -----------------------------------------------------------------------------
log_event:
    mov rax, 1                  ; sys_write
    mov rdi, 1                  ; File descriptor: STDOUT
    syscall
    ret