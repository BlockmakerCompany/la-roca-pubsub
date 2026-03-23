; -----------------------------------------------------------------------------
; Module: src/core/subscriber.asm
; Project: La Roca Micro-PubSub
; Responsibility: Wait-Free Message Consumption from Shared Memory.
;                 Handles O(1) offset mapping and safe payload extraction.
; -----------------------------------------------------------------------------
%include "config.inc"

extern rt_msg_size
extern rt_max_messages

section .text
    global consume_message

; -----------------------------------------------------------------------------
; consume_message: Reads a message from the Ring Buffer.
; Input: RDI = Mmap Base Pointer (DIRECT RAM Source)
;        RSI = Expected Sequence
;        RDX = Dest Buffer Ptr
;        RCX = Dest Buffer Size
; Output: RAX = Bytes copied, or 0 if message is not ready/not found.
; -----------------------------------------------------------------------------
consume_message:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15

    ; 1. Save Arguments
    mov r8, rdi         ; R8 = Base Pointer (mmap)
    mov r13, rsi        ; R13 = Expected Sequence
    mov r14, rdx        ; R14 = Dest Buffer Ptr
    mov r15, rcx        ; R15 = Dest Buffer Capacity

    ; 2. Check Tail (Global Sequence Counter)
    mov rax, qword [r8] ; Read Tail from Header (Offset 0)

    TRACE "Consumer: Checking Tail sequence vs Expected..."

    cmp r13, rax
    jge .not_ready      ; If requested sequence >= current tail, it doesn't exist yet

    ; 3. O(1) Offset Calculation
    ; Offset = 256 + ((Seq % Max) * MsgSize)
    mov rax, r13
    xor rdx, rdx
    mov rbx, [rt_max_messages]
    div rbx             ; RDX = Seq % Max

    mov rax, rdx
    mov rbx, [rt_msg_size]
    mul rbx             ; RAX = (Seq % Max) * MsgSize
    add rax, 256        ; RAX = Final Relative Offset

    lea r9, [r8 + rax]  ; R9 = Absolute physical address of the slot

    ; 4. Status Validation
    mov al, byte [r9]
    TRACE "Consumer: Checking Slot Status Byte..."
    cmp al, 2           ; 2 = READY (Finished writing by the Publisher)
    jne .not_ready

    lfence              ; Memory Barrier: Ensure status is read before payload

    ; 5. Sequence Validation (Wrap-around guard)
    mov rbx, qword [r9 + 1]
    cmp rbx, r13
    jne .not_ready

    ; 6. Copy Payload (Zero-Copy extraction to user socket buffer)
    TRACE "Consumer: Success! Copying payload to user buffer..."
    lea rsi, [r9 + 9]   ; Source: Skip Status(1) + Seq(8)
    mov rdi, r14        ; Dest buffer

    ; Calculate copy size: min(UserBufferCapacity, MsgSize - 9)
    mov rcx, r15        ; RCX = Dest Capacity
    mov rbx, [rt_msg_size]
    sub rbx, 9          ; RBX = Actual Payload Size
    js .not_ready       ; Guard: If msg_size < 9, something is very wrong

    cmp rcx, rbx
    cmovg rcx, rbx      ; Truncate if user buffer is smaller than payload

    ; --- CRITICAL FIX ---
    ; rep movsb uses RCX as a counter and decrements it to 0.
    ; We must save the value to return the actual number of bytes copied.
    mov r11, rcx        ; Save count in R11 (non-volatile within this scope)

    cld                 ; Ensure forward copy
    rep movsb           ; Fast hardware-accelerated memory copy (RCX becomes 0)

    mov rax, r11        ; RAX = Correct number of bytes copied
    jmp .exit

.not_ready:
    TRACE "Consumer: Message not ready or sequence empty."
    xor rax, rax        ; Return 0 bytes (Handler will send 404/Empty)

.exit:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret