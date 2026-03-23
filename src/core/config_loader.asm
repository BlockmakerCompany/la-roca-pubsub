; -----------------------------------------------------------------------------
; Module: src/core/config_loader.asm
; Project: La Roca Micro-PubSub
; Responsibility: Parse environment variables to override default geometry.
;                 Acts as the primary provisioner for the engine's RAM globals.
; -----------------------------------------------------------------------------
%include "config.inc"

extern get_env
extern atoi
extern rt_msg_size
extern rt_max_messages

section .data
    env_msg_size db "ROCK_MSG_SIZE", 0
    env_max_msgs db "ROCK_MAX_MSGS", 0

section .text
    global load_engine_config

; -----------------------------------------------------------------------------
; load_engine_config: Scans the environment array (envp) for engine settings.
; Input: RSI = envp pointer (passed from the Linux Kernel stack via main.asm)
; -----------------------------------------------------------------------------
load_engine_config:
    ; Preserve the envp pointer (RSI) on the stack as it's needed for
    ; subsequent searches within the same execution frame.
    push rsi

    ; =========================================================================
    ; 1. SEARCH FOR ROCK_MSG_SIZE
    ; =========================================================================
    lea rdi, [rel env_msg_size] ; Key to search for
    ; RSI is already the pointer to the environment array
    call get_env

    test rax, rax
    jz .load_max                ; If not found, skip (preserves default 256)

    mov rdi, rax                ; RDI = Pointer to the value string (e.g., "1024")
    call atoi                   ; Convert ASCII to Integer
    mov [rt_msg_size], rax      ; Overwrite RAM global with environment value

.load_max:
    ; Restore original envp pointer to search for the next variable
    pop rsi
    push rsi                    ; Re-save it for the final cleanup

    ; =========================================================================
    ; 2. SEARCH FOR ROCK_MAX_MSGS
    ; =========================================================================
    lea rdi, [rel env_max_msgs] ; Key to search for
    ; RSI is restored as the environment array pointer
    call get_env

    test rax, rax
    jz .done                    ; If not found, skip (preserves default count)

    mov rdi, rax                ; RDI = Pointer to value string
    call atoi
    mov [rt_max_messages], rax  ; Overwrite RAM global with environment value

.done:
    pop rsi                     ; Final stack cleanup
    ret