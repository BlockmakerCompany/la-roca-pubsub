; -----------------------------------------------------------------------------
; Module: src/routers/route_api.asm
; Project: La Roca Micro-PubSub
; Responsibility: Network-facing HTTP dispatcher. Delegates pure parsing to
;                 parse_http_request (src/routers/parse_http_request.asm) and
;                 dispatches to the concrete route handlers.
; -----------------------------------------------------------------------------
%include "config.inc"

extern handle_live
extern handle_stats
extern handle_pub
extern handle_sub
extern handle_batch
extern handle_mpub
extern parse_http_request

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
; route_api: Main HTTP entry point (network-facing dispatcher).
; Input: RDI = Socket FD, RSI = Buffer Pointer, RDX = Total Bytes Read
; -----------------------------------------------------------------------------
route_api:
    push rbp
    mov rbp, rsp
    push r12
    push r13

    mov r12, rdi                ; r12 = Client Socket FD
    mov r13, rsi                ; r13 = Request Buffer Pointer

    ; Parse the request (pure, no side effects) via the C-ABI entry point
    mov rdi, r13                ; 1st arg = buffer pointer
    mov rsi, rdx                ; 2nd arg = bytes read (unused by parser today)
    call parse_http_request

    ; Dispatch to handlers based on the route code in RAX
    cmp rax, ROUTE_LIVE
    je .call_live
    cmp rax, ROUTE_STATS
    je .call_stats
    cmp rax, ROUTE_SUB
    je .call_sub
    cmp rax, ROUTE_BATCH
    je .call_batch
    cmp rax, ROUTE_PUB
    je .call_pub
    cmp rax, ROUTE_MPUB
    je .call_mpub
    cmp rax, ROUTE_BAD_TOPIC
    je .send_400_error
    jmp .not_handled            ; ROUTE_NOT_HANDLED (0) or unknown

; -----------------------------------------------------------------------------
; DISPATCH HANDLERS
; -----------------------------------------------------------------------------
.send_400_error:
    mov rdi, r12
    DO_SYS_WRITE rdi, res_400_bad_topic, res_400_len
    jmp .handled

.call_live:
    mov rdi, r12
    mov rsi, r13
    call handle_live
    jmp .handled
.call_stats:
    mov rdi, r12
    mov rsi, r13
    call handle_stats
    jmp .handled
.call_sub:
    mov rdi, r12
    mov rsi, r13
    call handle_sub
    jmp .handled
.call_pub:
    mov rdi, r12
    mov rsi, r13
    call handle_pub
    jmp .handled
.call_batch:
    mov rdi, r12
    mov rsi, r13
    call handle_batch
    jmp .handled
.call_mpub:
    mov rdi, r12
    mov rsi, r13
    call handle_mpub
    jmp .handled

.not_handled:
    ; --- ELEGANT HTTP 400 FALLBACK ---
    ; Send HTTP 400 Bad Request for unsupported verbs or malformed URIs
    ; instead of closing the socket abruptly. This ensures HTTP/1.1 compliance.
    mov rdi, r12
    DO_SYS_WRITE rdi, res_400_generic, res_400_gen_len
    jmp .handled                ; Finalize cleanly

.handled:
    mov rax, 1
    pop r13
    pop r12
    pop rbp
    ret
