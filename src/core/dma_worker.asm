; -----------------------------------------------------------------------------
; Module: src/core/dma_worker.asm
; Project: La Roca Micro-PubSub
; Responsibility: Asynchronous DMA persistence using io_uring.
;                 Monitors the Ring Buffer and flushes memory to NVMe.
;                 Updates Head Sequence to release backpressure.
; -----------------------------------------------------------------------------
%include "config.inc"

; Refactored: Removed 'extern get_topic_ptr' in favor of direct pointer passing
extern rt_msg_size
extern rt_max_messages
extern worker_uring_sq_ptr
extern worker_uring_sq_tail
extern worker_uring_fd

section .text
    global submit_dma_batch

; -----------------------------------------------------------------------------
; submit_dma_batch: Prepares an io_uring SQE to write a memory block to disk.
; Input:
;   RDI = Mmap Base Pointer (DIRECT RAM Source)
;   RSI = File Descriptor of the Topic Log (Opened with O_DIRECT)
;   RDX = Start Sequence (Head)
;   RCX = Batch Size (Number of messages to flush)
; Output:
;   RAX = 0 on success, negative error code on failure
; -----------------------------------------------------------------------------
submit_dma_batch:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15

    ; 1. Load arguments directly into working registers
    mov r8, rdi                 ; R8  = Mmap Base Pointer (RAM Source)
    mov r13, rsi                ; R13 = Topic File Descriptor
    mov r14, rdx                ; R14 = Start Sequence
    mov r15, rcx                ; R15 = Batch Size

    ; =========================================================================
    ; 🧮 CALCULATE MEMORY (RAM) AND FILE (DISK) OFFSETS
    ; Both must be identically aligned for O_DIRECT DMA to succeed.
    ; =========================================================================
    mov rax, r14
    xor rdx, rdx
    mov rbx, [rt_max_messages]
    div rbx                     ; RDX = Sequence % Max_Messages

    mov rax, rdx
    mov rbx, [rt_msg_size]
    mul rbx                     ; RAX = Offset relative to data segment

    ; Add Header Offset (256 bytes) to both RAM and Disk targets
    add rax, 256

    lea r9, [r8 + rax]          ; R9  = Source Memory Address (RAM)
    mov r10, rax                ; R10 = Target File Offset (Disk)

    ; Calculate total payload size: Batch Size * Message Size
    mov rax, r15
    mov rbx, [rt_msg_size]
    mul rbx
    mov r11, rax                ; R11 = Total bytes to flush

    ; =========================================================================
    ; 🚀 BUILD io_uring SUBMISSION QUEUE ENTRY (SQE)
    ; =========================================================================
    ; Retrieve current SQ tail to locate the next available SQE slot
    mov rax, [worker_uring_sq_tail]
    mov rbx, [rax]              ; RBX = Current tail index

    ; Mask the index (Assumes SQ size is a power of 2, e.g., 64)
    and rbx, 63

    ; Each SQE is exactly 64 bytes. Calculate memory offset: SQ_PTR + (index * 64)
    mov rcx, [worker_uring_sq_ptr]
    shl rbx, 6                  ; RBX *= 64
    add rcx, rbx                ; RCX = Pointer to the active SQE struct

    ; Clear the 64-byte SQE instantly using AVX/YMM vectorized registers
    vxorps ymm0, ymm0, ymm0
    vmovups [rcx], ymm0
    vmovups [rcx + 32], ymm0

    ; Populate SQE fields for IORING_OP_WRITE (Opcode 2)
    mov byte [rcx + 0], 2       ; sqe->opcode = IORING_OP_WRITE
    mov dword [rcx + 4], r13d   ; sqe->fd = Target Topic FD
    mov qword [rcx + 8], r10    ; sqe->off = Target File Offset (Disk)
    mov qword [rcx + 16], r9    ; sqe->addr = Source Memory Address (RAM)
    mov dword [rcx + 24], r11d  ; sqe->len = Total bytes to write

    ; Inject the Start Sequence as user_data for future completion tracking
    mov qword [rcx + 32], r14   ; sqe->user_data = Start Sequence

    ; =========================================================================
    ; 🔔 NOTIFY THE KERNEL (sys_io_uring_enter)
    ; =========================================================================
    ; Increment the tail atomically (make it visible to the kernel)
    mov rax, [worker_uring_sq_tail]
    lock add dword [rax], 1
    sfence                      ; Enforce memory barrier before syscall

    ; Syscall 426: sys_io_uring_enter (x86_64 architecture)
    mov rax, 426
    mov rdi, [worker_uring_fd]  ; ring_fd
    mov rsi, 1                  ; to_submit = 1
    xor rdx, rdx                ; min_complete = 0 (Asynchronous: do not block!)
    xor r10, r10                ; flags = 0
    xor r8, r8                  ; sigmask = NULL
    syscall

    cmp rax, 0
    jl .err_syscall             ; Branch if kernel rejected the submission (e.g., -EBUSY)

    xor rax, rax                ; Return 0 (Success)
    jmp .exit

.err_syscall:
    ; RAX currently holds the negative error code directly from the kernel
    jmp .exit

.exit:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret