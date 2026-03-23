; -----------------------------------------------------------------------------
; Module: src/core/publisher.asm
; Project: La Roca Micro-PubSub
; Responsibility: Lock-Free Message Injection into Shared Memory Ring Buffer.
; -----------------------------------------------------------------------------
%include "config.inc"

; Refactored: Removed 'extern get_topic_ptr' in favor of direct pointer passing
extern rt_msg_size
extern rt_max_messages

section .text
    global publish_message

; -----------------------------------------------------------------------------
; publish_message: Injects a message into the Ring Buffer.
; Input: RDI = Mmap Base Pointer (DIRECT RAM Target)
;        RSI = Payload Pointer
;        RDX = Payload Size
; Output: RAX = Assigned Sequence ID, or negative error code on failure.
; -----------------------------------------------------------------------------
publish_message:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15

    ; 1. Save Arguments into Non-Volatile Registers
    mov r15, rdi        ; R15 = Mmap Base Pointer (DIRECT!)
    mov r13, rsi        ; R13 = Payload Pointer
    mov r14, rdx        ; R14 = Payload Size

    ; Direct injection: Bypass registry lookup, operate directly on the Mmap Base Pointer.

    ; =========================================================================
    ; ⚡ LOCK-FREE SEQUENCE CLAIM
    ; =========================================================================
    mov rax, 1
    lock xadd qword [r15], rax  ; Atomic sequence increment in the mmap header (offset 0)

    ; RAX now contains the UNIQUE Sequence ID assigned to this thread/request.
    mov r11, rax        ; R11 = Our Sequence ID

    ; =========================================================================
    ; 🛑 BACKPRESSURE CHECK (Is Buffer Full?)
    ; =========================================================================
    mov rcx, qword [r15 + 8]    ; Read Head Sequence from the mmap Header
    mov rbx, r11                ; Current Tail
    sub rbx, rcx                ; Delta between Tail and Head
    cmp rbx, [rt_max_messages]
    jge .err_buffer_full

    ; =========================================================================
    ; 🧮 O(1) OFFSET CALCULATION
    ; Offset = 256 + ((Sequence % Max) * MsgSize)
    ; =========================================================================
    mov rax, r11
    xor rdx, rdx
    mov rbx, [rt_max_messages]
    div rbx                     ; RDX = Sequence % Max_Messages

    mov rax, rdx
    mov rbx, [rt_msg_size]
    mul rbx                     ; RAX = Index * MsgSize
    add rax, 256                ; Add the Header offset (256 bytes)

    lea rdi, [r15 + rax]        ; RDI = Physical address of the slot within the mmap
    mov r10, rdi                ; R10 = Save slot start address for the final commit phase

    ; =========================================================================
    ; 💾 MEMORY INJECTION (Zero-Copy)
    ; =========================================================================
    ; Slot Layout: [Status:1 byte][Seq:8 bytes][Payload:N bytes]

    ; Step 1: Mark status as WRITING (1) to block fast-reading consumers
    mov byte [rdi], 1

    ; Step 2: Write the Sequence ID (8 bytes)
    mov qword [rdi + 1], r11

    ; Step 3: Copy the payload
    lea rdi, [rdi + 9]          ; Destination = Slot start + 9
    mov rsi, r13                ; Source = User buffer
    mov rcx, r14                ; Requested payload size

    ; Safety check: Does the payload fit in the slot?
    mov rbx, [rt_msg_size]
    sub rbx, 9
    cmp rcx, rbx
    cmovg rcx, rbx              ; Truncate if it exceeds maximum capacity

    cld
    rep movsb                   ; Hardware-accelerated memory copy

    ; =========================================================================
    ; ✅ COMMIT MESSAGE (Memory Barrier)
    ; =========================================================================
    sfence                      ; Ensure write visibility across all CPU cores

    ; Final step: Change Status to READY (2)
    mov byte [r10], 2

    TRACE "Publisher: Message committed to named topic."

    mov rax, r11                ; Return the assigned Sequence ID (Success)
    jmp .exit

.err_buffer_full:
    TRACE "Publisher: WARNING - Buffer Full."
    mov rax, -2                 ; Backpressure error code

.exit:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret