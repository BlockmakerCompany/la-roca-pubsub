; -----------------------------------------------------------------------------
; Module: src/core/subscriber.asm
; Project: La Roca Micro-PubSub
; Responsibility: Wait-Free Message Consumption with Dynamic Key Extraction.
; -----------------------------------------------------------------------------
%include "config.inc"

extern rt_msg_size
extern rt_max_messages
extern rt_key_size              ; NEW: Global configuration for key size

section .text
    global consume_message

; -----------------------------------------------------------------------------
; consume_message: Reads a message and its routing key from the Ring Buffer.
; Input: RDI = Mmap Base Pointer (DIRECT RAM Source)
;        RSI = Expected Sequence
;        RDX = Dest Payload Buffer Ptr
;        RCX = Dest Payload Buffer Size
;        R8  = Dest Key Buffer Ptr (NEW: Can be NULL if key is not needed)
; Output: RAX = Bytes copied, or 0 if message is not ready/not found.
; -----------------------------------------------------------------------------
consume_message:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15
    push rbx            ; Push RBX to preserve it across calls

    ; 1. Save Arguments (ABI Compliance Fix)
    mov r12, rdi        ; R12 = Base Pointer (mmap) - Changed from R8 to free up 5th argument!
    mov r13, rsi        ; R13 = Expected Sequence
    mov r14, rdx        ; R14 = Dest Payload Buffer Ptr
    mov r15, rcx        ; R15 = Dest Payload Capacity
    mov rbx, r8         ; RBX = Dest Key Buffer Ptr (From 5th parameter)

    ; 2. Check Tail (Global Sequence Counter)
    mov rax, qword [r12] ; Read Tail from Header (Offset 0)

    TRACE "Consumer: Checking Tail sequence vs Expected..."

    cmp r13, rax
    jge .not_ready      ; If requested sequence >= current tail, it doesn't exist yet

    ; 3. O(1) Offset Calculation
    ; Offset = 256 + ((Seq % Max) * MsgSize)
    mov rax, r13
    xor rdx, rdx
    mov rcx, [rt_max_messages]
    div rcx             ; RDX = Seq % Max

    mov rax, rdx
    mov rcx, [rt_msg_size]
    mul rcx             ; RAX = (Seq % Max) * MsgSize
    add rax, 256        ; RAX = Final Relative Offset

    lea r9, [r12 + rax] ; R9 = Absolute physical address of the slot

    ; 4. Status Validation
    mov al, byte [r9]
    TRACE "Consumer: Checking Slot Status Byte..."
    cmp al, 2           ; 2 = READY (Finished writing by the Publisher)
    jne .not_ready

    lfence              ; Memory Barrier: Ensure status is read before payload

    ; 5. Sequence Validation (Wrap-around guard)
    mov rcx, qword [r9 + 1]
    cmp rcx, r13
    jne .not_ready

    ; =========================================================================
    ; 6. EXTRACT ROUTING KEY (If buffer is provided)
    ; =========================================================================
    test rbx, rbx
    jz .extract_payload ; Skip key extraction if R8 was NULL

    TRACE "Consumer: Extracting routing key..."
    lea rsi, [r9 + 9]   ; Source: Slot + Status(1) + Seq(8)
    mov rdi, rbx        ; Dest: User Key Buffer
    mov rcx, [rt_key_size]
    test rcx, rcx
    jz .extract_payload ; Skip if KeySize is 0
    cld
    rep movsb

    ; =========================================================================
    ; 7. EXTRACT PAYLOAD (Zero-Copy to user socket buffer)
    ; =========================================================================
.extract_payload:
    TRACE "Consumer: Success! Copying payload to user buffer..."

    ; --- GEOMETRY UPDATE: Skip Status(1) + Seq(8) + Key(rt_key_size) ---
    mov rax, [rt_key_size]
    lea rsi, [r9 + 9 + rax] ; Source Pointer
    mov rdi, r14            ; Dest buffer

    ; Calculate maximum copy size: MsgSize - 9 - KeySize
    mov rcx, r15            ; RCX = Dest Capacity
    mov rax, [rt_msg_size]
    sub rax, 9              ; Subtract Status and Seq
    sub rax, [rt_key_size]  ; Subtract Key Size
    js .not_ready           ; Guard: If math is negative, geometry is broken

    cmp rcx, rax
    cmovg rcx, rax          ; Truncate if user buffer is smaller than payload

    ; Save count in R11 before rep movsb destroys RCX
    mov r11, rcx

    cld                     ; Ensure forward copy
    rep movsb               ; Fast hardware-accelerated memory copy (RCX becomes 0)

    mov rax, r11            ; RAX = Correct number of bytes copied
    jmp .exit

.not_ready:
    TRACE "Consumer: Message not ready or sequence empty."
    xor rax, rax            ; Return 0 bytes (Handler will send 404/Empty)

.exit:
    pop rbx             ; Restore preserved RBX
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret