; -----------------------------------------------------------------------------
; Module: src/core/publisher.asm
; Project: La Roca Micro-PubSub
; Responsibility: Lock-Free Message Injection with Configurable Key Geometry.
; -----------------------------------------------------------------------------
%include "config.inc"

extern rt_msg_size
extern rt_max_messages
extern rt_key_size              ; NEW: Global configuration for key size

section .text
    global publish_message

; -----------------------------------------------------------------------------
; publish_message: Injects a message and its routing key into the Ring Buffer.
; System V AMD64 ABI Input:
;   RDI = Mmap Base Pointer (DIRECT RAM Target)
;   RSI = Key Pointer (Can be 0 if no key)
;   RDX = Key Size (Actual length provided by user)
;   RCX = Payload Pointer
;   R8  = Payload Size
; Output: RAX = Assigned Sequence ID, or negative error code on failure.
; -----------------------------------------------------------------------------
publish_message:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; 1. Save Arguments into Non-Volatile Registers
    mov r15, rdi        ; R15 = Mmap Base Pointer
    mov r12, rsi        ; R12 = Key Pointer
    mov rbx, rdx        ; RBX = Key Size (Provided)
    mov r14, rcx        ; R14 = Payload Pointer
    mov r13, r8         ; R13 = Payload Size

    ; =========================================================================
    ; ⚡ LOCK-FREE SEQUENCE CLAIM
    ; =========================================================================
    mov rax, 1
    lock xadd qword [r15], rax  ; Atomic increment at offset 0
    mov r11, rax                ; R11 = Our Unique Sequence ID

    ; =========================================================================
    ; 🛑 BACKPRESSURE CHECK (Is Buffer Full?)
    ; =========================================================================
    mov rcx, qword [r15 + 8]    ; Read Head Sequence from Header (if implemented)
    mov rax, r11
    sub rax, rcx
    cmp rax, [rt_max_messages]
    jge .err_buffer_full

    ; =========================================================================
    ; 🧮 O(1) OFFSET CALCULATION
    ; Offset = 256 + ((Sequence % Max) * MsgSize)
    ; =========================================================================
    mov rax, r11
    xor rdx, rdx
    mov rcx, [rt_max_messages]
    div rcx                     ; RDX = Sequence % Max

    mov rax, rdx
    mov rcx, [rt_msg_size]
    mul rcx                     ; RAX = Index * MsgSize
    add rax, 256                ; RAX = Final Offset (past the 256B file header)

    lea r10, [r15 + rax]        ; R10 = Absolute physical address of the slot

    ; =========================================================================
    ; 💾 MEMORY INJECTION (Dynamic Geometry)
    ; Layout: [Status:1][Seq:8][Key:rt_key_size][Payload:N]
    ; =========================================================================

    ; Step 1 & 2: Mark WRITING (1) and write Sequence
    mov byte [r10], 1
    mov qword [r10 + 1], r11

    ; Step 3: Inject Key (Offset: +9)
    lea rdi, [r10 + 9]          ; Destination = Slot + 9
    mov rsi, r12                ; Source = Key Ptr
    mov rcx, rbx                ; Size = Provided Key Size

    ; Truncate key if user provided one larger than the configured limit
    mov rax, [rt_key_size]
    cmp rcx, rax
    cmovg rcx, rax              ; rcx = min(provided_size, rt_key_size)

    ; Copy Key if exists
    test rsi, rsi
    jz .skip_key
    test rcx, rcx
    jz .skip_key
    cld
    rep movsb
.skip_key:

    ; Step 4: Inject Payload (Offset: +9 + rt_key_size)
    mov rax, [rt_key_size]
    lea rdi, [r10 + 9 + rax]    ; Destination = Slot + 9 + KeySize
    mov rsi, r14                ; Source = Payload Ptr
    mov rcx, r13                ; Size = Provided Payload Size

    ; Calculate maximum available space for payload
    mov rax, [rt_msg_size]
    sub rax, 9                  ; Subtract Status & Seq
    sub rax, [rt_key_size]      ; Subtract Key space
    js .err_invalid_geometry    ; Guard: If math goes negative, geometry is broken

    ; Truncate payload if it exceeds available space
    cmp rcx, rax
    cmovg rcx, rax

    ; Copy Payload
    test rsi, rsi
    jz .commit
    test rcx, rcx
    jz .commit
    cld
    rep movsb

.commit:
    ; =========================================================================
    ; ✅ COMMIT MESSAGE (Memory Barrier)
    ; =========================================================================
    sfence                      ; Ensure writes flush to memory before status change
    mov byte [r10], 2           ; Status = READY (2)

    TRACE "Publisher: Message and Key committed successfully."
    mov rax, r11                ; Return Sequence ID
    jmp .exit

.err_buffer_full:
    TRACE "Publisher: WARNING - Buffer Full."
    mov rax, -2
    jmp .exit

.err_invalid_geometry:
    TRACE "Publisher: ERROR - MsgSize too small for configured KeySize."
    mov rax, -3

.exit:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret