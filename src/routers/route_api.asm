; -----------------------------------------------------------------------------
; Module: src/routers/route_api.asm
; Project: La Roca Micro-PubSub
; Responsibility: Zero-allocation HTTP routing + Security Length Validation.
;                 Utilizes bitmasking for O(1) URI prefix matching.
; -----------------------------------------------------------------------------
%include "config.inc"

extern handle_live
extern handle_stats
extern handle_pub
extern handle_sub
extern handle_batch
extern handle_mpub

section .data
    res_400_bad_topic db "HTTP/1.1 400 Bad Request", 13, 10
                      db "Content-Length: 26", 13, 10, 13, 10
                      db "Error: Topic name too long"
    res_400_len       equ $ - res_400_bad_topic

    ; GENERIC 400 RESPONSE FOR UNSUPPORTED VERBS OR MALFORMED URIS
    res_400_generic   db "HTTP/1.1 400 Bad Request", 13, 10
                      db "Content-Length: 0", 13, 10, 13, 10
    res_400_gen_len   equ $ - res_400_generic

section .text
    global route_api

; -----------------------------------------------------------------------------
; route_api: Main HTTP entry point.
; Input: RDI = Socket FD, RSI = Buffer Pointer, RDX = Total Bytes Read
; -----------------------------------------------------------------------------
route_api:
    push rbp
    mov rbp, rsp

    ; Identify HTTP Method (First 4 bytes)
    mov eax, dword [rsi]
    cmp eax, 0x20544547         ; 'GET ' (Little Endian)
    je .route_get
    cmp eax, 0x54534F50         ; 'POST' (Little Endian)
    je .route_post
    jmp .not_handled            ; If not GET/POST, reject politely

.route_get:
    ; Load the first 8 bytes following 'GET ' for fast prefix masking
    mov rax, qword [rsi + 4]

    ; Check for "/live " (6 bytes: / l i v e [space])
    mov r8, rax
    mov r9, 0x0000FFFFFFFFFFFF  ; 48-bit mask
    and r8, r9
    mov r9, 0x206576696C2F      ; '/live '
    cmp r8, r9
    je .call_live

    ; Check for "/stats " (7 bytes: / s t a t s [space])
    mov r8, rax
    mov r9, 0x00FFFFFFFFFFFFFF  ; 56-bit mask
    and r8, r9
    mov r9, 0x2073746174732F    ; '/stats '
    cmp r8, r9
    je .call_stats

    ; --- TOPIC-BASED GET ROUTES ---
    ; Check for "/sub/" (Prefix: 5 bytes)
    mov r8, rax
    mov r9, 0x000000FFFFFFFFFF  ; 40-bit mask
    and r8, r9
    mov r9, 0x2F6275732F        ; '/sub/'
    cmp r8, r9
    jne .check_batch
    mov r8, 9                   ; Offset: 4 (GET) + 5 (/sub/)
    call .validate_topic_len
    test rax, rax
    jz .send_400_error
    jmp .call_sub

.check_batch:
    ; Check for "/batch/" (Prefix: 7 bytes)
    mov r8, rax
    mov r9, 0x00FFFFFFFFFFFFFF  ; 56-bit mask
    and r8, r9
    mov r9, 0x2F68637461622F    ; '/batch/'
    cmp r8, r9
    jne .not_handled
    mov r8, 11                  ; Offset: 4 (GET) + 7 (/batch/)
    call .validate_topic_len
    test rax, rax
    jz .send_400_error
    jmp .call_batch

.route_post:
    ; Load the first 8 bytes following 'POST '
    mov rax, qword [rsi + 5]

    ; Check for "/pub/" (Prefix: 5 bytes)
    mov r8, rax
    mov r9, 0x000000FFFFFFFFFF  ; 40-bit mask
    and r8, r9
    mov r9, 0x2F6275702F        ; '/pub/'
    cmp r8, r9
    jne .check_mpub
    mov r8, 10                  ; Offset: 5 (POST) + 5 (/pub/)
    call .validate_topic_len
    test rax, rax
    jz .send_400_error
    jmp .call_pub

.check_mpub:
    ; Check for "/mpub/" (Prefix: 6 bytes)
    mov r8, rax
    mov r9, 0x0000FFFFFFFFFFFF  ; 48-bit mask
    and r8, r9
    mov r9, 0x2F6275706D2F      ; '/mpub/'
    cmp r8, r9
    jne .not_handled
    mov r8, 11                  ; Offset: 5 (POST) + 6 (/mpub/)
    call .validate_topic_len
    test rax, rax
    jz .send_400_error
    jmp .call_mpub

; -----------------------------------------------------------------------------
; .validate_topic_len: Security Boundary
; -----------------------------------------------------------------------------
.validate_topic_len:
    push rsi
    add rsi, r8
    xor rcx, rcx
.v_loop:
    mov al, [rsi + rcx]
    cmp al, '/'
    je .v_done
    cmp al, ' '
    je .v_done

    inc rcx
    cmp rcx, 16                 ; Max 16 bytes
    jg .v_fail
    jmp .v_loop

.v_done:
    test rcx, rcx
    jz .v_fail
    mov rax, 1
    jmp .v_exit
.v_fail:
    xor rax, rax
.v_exit:
    pop rsi
    ret

; -----------------------------------------------------------------------------
; DISPATCH HANDLERS
; -----------------------------------------------------------------------------
.send_400_error:
    mov rax, SYS_WRITE
    lea rsi, [rel res_400_bad_topic]
    mov rdx, res_400_len
    syscall
    jmp .handled

.call_live:
    call handle_live
    jmp .handled
.call_stats:
    call handle_stats
    jmp .handled
.call_sub:
    call handle_sub
    jmp .handled
.call_pub:
    call handle_pub
    jmp .handled
.call_batch:
    call handle_batch
    jmp .handled
.call_mpub:
    call handle_mpub
    jmp .handled

.not_handled:
    ; --- ELEGANT HTTP 400 FALLBACK ---
    ; Send HTTP 400 Bad Request for unsupported verbs or malformed URIs
    ; instead of closing the socket abruptly. This ensures HTTP/1.1 compliance.
    mov rax, SYS_WRITE
    lea rsi, [rel res_400_generic]
    mov rdx, res_400_gen_len
    syscall                     ; Write "400 Bad Request" to the socket
    jmp .handled                ; Finalize cleanly

.handled:
    mov rax, 1
.exit:
    pop rbp
    ret