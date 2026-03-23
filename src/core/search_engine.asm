; -----------------------------------------------------------------------------
; Module: src/core/search_engine.asm
; Project: La Roca Micro-PubSub
; Responsibility: Read-Only Binary Search (O(log N)) for Topic Registry.
; -----------------------------------------------------------------------------
%include "config.inc"

; --- External Registry Data ---
extern topic_registry
extern topic_count

section .text
    global registry_find
    global registry_find_lower_bound
    global compare_keys

    ENTRY_SIZE equ 24           ; 16 bytes (Name) + 8 bytes (Pointer)
    KEY_SIZE   equ 16           ; 16 bytes static string

; -----------------------------------------------------------------------------
; registry_find_lower_bound: Finds the first index where RegistryKey >= SearchKey.
; Input:  RDI = Pointer to 16-byte null-padded target name
; Output: RAX = Index (Candidate)
; -----------------------------------------------------------------------------
registry_find_lower_bound:
    push rbp
    mov rbp, rsp
    push rbx
    push r12                    ; Preserve R12 to maintain System V ABI compliance
    push r13
    push r14

    mov r13, rdi
    mov r11, [topic_count]

    xor r10, r10
    mov r14, r11
    dec r11

    test r14, r14
    jz .lb_done

.lb_loop:
    cmp r10, r11
    jg .lb_done

    ; Calculate Midpoint
    mov rax, r10
    add rax, r11
    shr rax, 1
    mov r9, rax

    ; --- STATIC OFFSET CALCULATION ---
    imul rax, ENTRY_SIZE
    lea r12, [topic_registry + rax]

    lea rdi, [r12]
    mov rsi, r13
    call compare_keys

    ; Binary Search Decision Tree
    ja .go_right

    mov r14, r9
    test r9, r9
    jz .lb_done
    mov r11, r9
    dec r11
    jmp .lb_loop

.go_right:
    mov r10, r9
    inc r10
    jmp .lb_loop

.lb_done:
    mov rax, r14
    pop r14
    pop r13
    pop r12                     ; Restore R12 intact for the caller
    pop rbx
    leave
    ret

; -----------------------------------------------------------------------------
; registry_find: Exact match lookup. Returns Mmap Pointer.
; Input:  RDI = Pointer to 16-byte null-padded target name
; Output: RAX = 64-bit Mmap Pointer (or 0 if not found)
; -----------------------------------------------------------------------------
registry_find:
    push rbp
    mov rbp, rsp
    push rsi
    push rdi

    call registry_find_lower_bound
    mov r9, rax                 ; R9 = Lower Bound Index

    pop rdi                     ; RDI = Search Key (Restored)

    cmp r9, [topic_count]
    jae .not_found              ; If Index >= Count, the key doesn't exist

    ; --- STATIC OFFSET CALCULATION (Using R8 to avoid clobbering R12) ---
    mov rax, r9
    imul rax, ENTRY_SIZE
    lea r8, [topic_registry + rax]

    push rdi
    mov rsi, rdi                ; RSI = Search Key
    lea rdi, [r8]               ; RDI = Registry Key
    call compare_keys
    pop rdi
    jne .not_found              ; Keys didn't match exactly

    ; Found! Extract the Mmap pointer located 16 bytes after the start of the slot
    mov rax, [r8 + KEY_SIZE]
    jmp .exit

.not_found:
    xor rax, rax                ; Return 0 (NULL)
.exit:
    leave
    ret

; -----------------------------------------------------------------------------
; compare_keys: Static string comparator (16 bytes).
; Input: RDI = Dest String, RSI = Source String
; -----------------------------------------------------------------------------
compare_keys:
    push rcx
    push rsi
    push rdi
    mov rcx, KEY_SIZE           ; Static key size = 16
    cld
    repe cmpsb                  ; Hardware-accelerated byte comparison: [RSI] - [RDI]
    pop rdi
    pop rsi
    pop rcx
    ret