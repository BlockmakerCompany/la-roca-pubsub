; -----------------------------------------------------------------------------
; Module: src/routers/parse_http_request.asm
; Project: La Roca Micro-PubSub
; Responsibility: Pure L7 HTTP parser. No syscalls, no handlers, no side effects.
;                 This is the AFL++ fuzzing target — it links standalone into a
;                 C harness with ZERO engine dependencies.
; -----------------------------------------------------------------------------
; Uses bitmasking for O(1) URI prefix matching. The route codes are shared with
; route_api.asm via config.inc (ROUTE_* constants).
; -----------------------------------------------------------------------------
%include "config.inc"

section .text
    global parse_http_request

; -----------------------------------------------------------------------------
; parse_http_request: Pure L7 router.
; C calling convention: RDI = Buffer Pointer, RSI = Total Bytes Read.
; Output: RAX = Route code (see ROUTE_* constants in config.inc).
; -----------------------------------------------------------------------------
parse_http_request:
    push rbp
    mov rbp, rsp

    ; Identify HTTP Method (First 4 bytes)
    mov eax, dword [rdi]
    cmp eax, 0x20544547         ; 'GET ' (Little Endian)
    je .p_get
    cmp eax, 0x54534F50         ; 'POST' (Little Endian)
    je .p_post
    jmp .p_not_handled

.p_get:
    ; Load the first 8 bytes following 'GET ' for fast prefix masking
    mov rax, qword [rdi + 4]

    ; Check for "/live " (6 bytes: / l i v e [space])
    mov r8, rax
    mov r9, 0x0000FFFFFFFFFFFF  ; 48-bit mask
    and r8, r9
    mov r9, 0x206576696C2F      ; '/live '
    cmp r8, r9
    je .p_live

    ; Check for "/stats " (7 bytes: / s t a t s [space])
    mov r8, rax
    mov r9, 0x00FFFFFFFFFFFFFF  ; 56-bit mask
    and r8, r9
    mov r9, 0x2073746174732F    ; '/stats '
    cmp r8, r9
    je .p_stats

    ; --- TOPIC-BASED GET ROUTES ---
    ; Check for "/sub/" (Prefix: 5 bytes)
    mov r8, rax
    mov r9, 0x000000FFFFFFFFFF  ; 40-bit mask
    and r8, r9
    mov r9, 0x2F6275732F        ; '/sub/'
    cmp r8, r9
    jne .p_check_batch
    mov r8, 9                   ; Offset: 4 (GET) + 5 (/sub/)
    call .p_validate_topic
    test rax, rax
    jz .p_bad_topic
    jmp .p_sub

.p_check_batch:
    ; Check for "/batch/" (Prefix: 7 bytes)
    mov r8, rax
    mov r9, 0x00FFFFFFFFFFFFFF  ; 56-bit mask
    and r8, r9
    mov r9, 0x2F68637461622F    ; '/batch/'
    cmp r8, r9
    jne .p_not_handled
    mov r8, 11                  ; Offset: 4 (GET) + 7 (/batch/)
    call .p_validate_topic
    test rax, rax
    jz .p_bad_topic
    jmp .p_batch

.p_post:
    ; Load the first 8 bytes following 'POST '
    mov rax, qword [rdi + 5]

    ; Check for "/pub/" (Prefix: 5 bytes)
    mov r8, rax
    mov r9, 0x000000FFFFFFFFFF  ; 40-bit mask
    and r8, r9
    mov r9, 0x2F6275702F        ; '/pub/'
    cmp r8, r9
    jne .p_check_mpub
    mov r8, 10                  ; Offset: 5 (POST) + 5 (/pub/)
    call .p_validate_topic
    test rax, rax
    jz .p_bad_topic
    jmp .p_pub

.p_check_mpub:
    ; Check for "/mpub/" (Prefix: 6 bytes)
    mov r8, rax
    mov r9, 0x0000FFFFFFFFFFFF  ; 48-bit mask
    and r8, r9
    mov r9, 0x2F6275706D2F      ; '/mpub/'
    cmp r8, r9
    jne .p_not_handled
    mov r8, 11                  ; Offset: 5 (POST) + 6 (/mpub/)
    call .p_validate_topic
    test rax, rax
    jz .p_bad_topic
    jmp .p_mpub

; --- Route code returns ---
.p_not_handled:
    mov rax, ROUTE_NOT_HANDLED
    jmp .p_exit
.p_live:
    mov rax, ROUTE_LIVE
    jmp .p_exit
.p_stats:
    mov rax, ROUTE_STATS
    jmp .p_exit
.p_sub:
    mov rax, ROUTE_SUB
    jmp .p_exit
.p_batch:
    mov rax, ROUTE_BATCH
    jmp .p_exit
.p_pub:
    mov rax, ROUTE_PUB
    jmp .p_exit
.p_mpub:
    mov rax, ROUTE_MPUB
    jmp .p_exit
.p_bad_topic:
    mov rax, ROUTE_BAD_TOPIC
    jmp .p_exit

; -----------------------------------------------------------------------------
; .p_validate_topic: Security Boundary (pure, no syscalls).
; Input: RDI = Buffer pointer, R8 = offset of topic start
; Output: RAX = 1 (valid) / 0 (invalid)
; -----------------------------------------------------------------------------
.p_validate_topic:
    push rdi
    add rdi, r8
    xor rcx, rcx
.p_v_loop:
    mov al, [rdi + rcx]
    cmp al, '/'
    je .p_v_done
    cmp al, ' '
    je .p_v_done

    inc rcx
    cmp rcx, 16                 ; Max 16 bytes
    jg .p_v_fail
    jmp .p_v_loop

.p_v_done:
    test rcx, rcx
    jz .p_v_fail
    mov rax, 1
    jmp .p_v_exit
.p_v_fail:
    xor rax, rax
.p_v_exit:
    pop rdi
    ret

.p_exit:
    pop rbp
    ret
