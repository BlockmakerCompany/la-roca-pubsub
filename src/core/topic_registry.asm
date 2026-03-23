; -----------------------------------------------------------------------------
; Module: src/core/topic_registry.asm
; Project: La Roca Micro-PubSub
; Responsibility: Maintains an alphabetically sorted array of active topics.
;                 O(N) Insertion using hardware-accelerated memory shifting.
; -----------------------------------------------------------------------------
%include "config.inc"

section .bss
    global topic_registry
    global topic_count

    MAX_TOPICS      equ 1024
    ENTRY_SIZE      equ 24      ; 16 bytes (Name) + 8 bytes (Mmap Pointer)
    REGISTRY_SIZE   equ 24576   ; 1024 * 24 bytes (Fits perfectly in L1 Cache!)

    topic_registry  resb REGISTRY_SIZE
    topic_count     resq 1

section .text
    global registry_insert
    global get_topic_ptr
    global registry_get_count   ; Exported for router metrics and testing

; -----------------------------------------------------------------------------
; registry_get_count: Returns the current number of active topics.
; Output: RAX = Current topic count
; -----------------------------------------------------------------------------
registry_get_count:
    mov rax, [topic_count]
    ret

; -----------------------------------------------------------------------------
; registry_insert: Inserts a new topic maintaining ASCENDING alphabetical order.
; Input:  RDI = Pointer to 16-byte null-padded topic name
;         RSI = 64-bit Mmap Pointer
; Output: RAX = 1 (Success), 0 (Registry Full or Topic Already Exists)
; -----------------------------------------------------------------------------
registry_insert:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13

    mov r12, rdi                ; R12 = New Topic Name Ptr
    mov r13, rsi                ; R13 = Mmap Ptr

    mov r8, [topic_count]
    cmp r8, MAX_TOPICS
    jae .err                    ; Capacity check: Abort if registry is full

    ; =========================================================================
    ; 1. LINEAR SEARCH FOR INSERTION POINT
    ; =========================================================================
    lea rbx, [topic_registry]
    xor r9, r9                  ; R9 = Current Index Counter

.find_pos:
    cmp r9, r8
    je .do_insert               ; Reached the end of active entries, append it.

    ; Lexicographical Compare (16 bytes)
    mov rdi, rbx                ; Dest = Current Registry Key
    mov rsi, r12                ; Src  = New Key to insert
    mov rcx, 16                 ; Key length limit
    cld
    repe cmpsb
    je .err                     ; Exact match -> Topic already exists!

    ; --- LEXICOGRAPHICAL BOUNDARY FOUND ---
    ; If New Key < Registry Key, we found our insertion index.
    jb .shift_needed

    ; Otherwise, advance to the next entry
    add rbx, ENTRY_SIZE
    inc r9
    jmp .find_pos

    ; =========================================================================
    ; 2. SHIFT ARRAY RIGHT TO MAKE ROOM (The Overlapping Memory Pattern)
    ; =========================================================================
.shift_needed:
    ; Calculate Source Tail (End of current active registry)
    mov rax, r8
    dec rax
    imul rax, ENTRY_SIZE
    lea rsi, [topic_registry + rax + ENTRY_SIZE - 8]

    ; Calculate Destination Tail (Shifted by 1 slot)
    mov rax, r8
    imul rax, ENTRY_SIZE
    lea rdi, [topic_registry + rax + ENTRY_SIZE - 8]

    ; Calculate how many QWORDs (8-byte chunks) to move
    mov rcx, r8
    sub rcx, r9                 ; Number of entries to shift
    imul rcx, 3                 ; Multiply by 3 (24 bytes per entry / 8 bytes)

    ; Perform backwards overlapping memory copy (memmove equivalent)
    std                         ; Set Direction Flag to decrement
    rep movsq                   ; Shift QWORDs from high to low memory
    cld                         ; Restore Direction Flag immediately

    ; =========================================================================
    ; 3. INSERT THE NEW TOPIC
    ; =========================================================================
.do_insert:
    ; Calculate physical address of the newly freed slot
    mov rax, r9
    imul rax, ENTRY_SIZE
    lea rdi, [topic_registry + rax]

    ; Copy the 16-byte Topic Name
    mov rsi, r12
    mov rcx, 2                  ; 2 QWORDs = 16 bytes
    cld
    rep movsq

    ; Write the 8-byte Mmap Pointer directly after the name
    mov [rdi], r13

    inc qword [topic_count]     ; Atomically increment the total count
    mov rax, 1                  ; Return 1 (Success)
    jmp .exit

.err:
    xor rax, rax                ; Return 0 (Failure)

.exit:
    pop r13
    pop r12
    pop rbx
    leave
    ret

; =============================================================================
; COMPATIBILITY LAYER FOR DMA_WORKER
; Retrieves a topic's Mmap pointer by its numerical index.
; Input: RDI = Topic Index
; Output: RDX = Mmap Pointer (or 0 if index out of bounds)
; =============================================================================
get_topic_ptr:
    cmp rdi, [topic_count]
    jae .not_found

    mov rax, rdi
    imul rax, ENTRY_SIZE

    lea rcx, [topic_registry]
    mov rdx, [rcx + rax + 16]   ; Read pointer (offset 16 bytes after the name)
    ret

.not_found:
    xor rdx, rdx
    ret