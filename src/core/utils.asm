; -----------------------------------------------------------------------------
; Module: src/core/utils.asm
; Project: La Roca Micro-PubSub
; Responsibility: Low-level string utilities and Linux environment parsing.
;                 Provides OS-agnostic (libc-free) string-to-int and
;                 environment lookup capabilities.
; -----------------------------------------------------------------------------

section .text
    global get_env
    global atoi

; -----------------------------------------------------------------------------
; get_env: Searches for the value of a specific environment variable.
; Input:  RDI = Pointer to Key Name string (e.g., "ROCK_MSG_SIZE")
;         RSI = Pointer to envp array (Environment pointers from the stack)
; Output: RAX = Pointer to the value string (segment after '=') or 0 if NULL.
; -----------------------------------------------------------------------------
get_env:
    push rbp
    mov rbp, rsp
    push rbx                    ; Callee-saved register preservation
    push r12
    push r13

    mov r12, rdi                ; r12 = Target Key string pointer
    mov r13, rsi                ; r13 = Current envp array index pointer

.loop_env:
    mov rbx, [r13]              ; Dereference r13 to get the pointer to "KEY=VALUE"
    test rbx, rbx               ; If pointer is NULL, we've reached the end of envp
    jz .not_found

    mov rdi, r12                ; Reset RDI to our target Key
    mov rsi, rbx                ; Set RSI to the start of the current env string
.compare:
    mov al, [rdi]               ; Load byte from target Key
    mov dl, [rsi]               ; Load byte from current env string
    test al, al                 ; If we hit the end of our target Key (\0)...
    jz .check_equal             ; ...verify if the env string has an '='
    cmp al, dl
    jne .next_env               ; Mismatch: jump to the next environment string
    inc rdi
    inc rsi
    jmp .compare

.check_equal:
    cmp byte [rsi], '='         ; Key matched perfectly; must be followed by '='
    je .found
.next_env:
    add r13, 8                  ; Advance to the next 64-bit pointer in the array
    jmp .loop_env

.found:
    inc rsi                     ; Skip the '=' character
    mov rax, rsi                ; Return the pointer to the beginning of the Value
    jmp .exit

.not_found:
    xor rax, rax                ; Return NULL
.exit:
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; -----------------------------------------------------------------------------
; atoi: Converts a null-terminated ASCII string to a 64-bit unsigned integer.
; Input:  RDI = Pointer to null-terminated ASCII string.
; Output: RAX = Resulting 64-bit integer value.
; -----------------------------------------------------------------------------
atoi:
    xor rax, rax                ; Clear accumulator (result = 0)
.loop:
    movzx rdx, byte [rdi]       ; Load current character
    test dl, dl                 ; Check for null terminator
    jz .done
    cmp dl, '0'                 ; Validation: must be >= '0'
    jl .done
    cmp dl, '9'                 ; Validation: must be <= '9'
    jg .done

    sub dl, '0'                 ; Convert ASCII byte to literal integer
    imul rax, 10                ; result = result * 10
    add rax, rdx                ; result = result + current_digit

    inc rdi                     ; Advance string pointer
    jmp .loop
.done:
    ret