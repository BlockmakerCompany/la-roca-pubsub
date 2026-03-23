; -----------------------------------------------------------------------------
; Module: src/routers/handle_live.asm
; Project: La Roca Micro-PubSub
; Responsibility: Fast Layer 7 (L7) health-check response for Load Balancers,
;                 Kubernetes Liveness Probes, and Orchestrators.
; -----------------------------------------------------------------------------
%include "config.inc"

section .data
    res_200     db "HTTP/1.1 200 OK", 13, 10
                db "Content-Length: 2", 13, 10
                db "Content-Type: text/plain", 13, 10, 13, 10
                db "OK"
    res_200_len equ $ - res_200

section .text
    global handle_live

; -----------------------------------------------------------------------------
; handle_live: Sends a static 200 OK response to verify engine availability.
; Input: RDI = Client Socket File Descriptor (FD)
; -----------------------------------------------------------------------------
handle_live:
    mov rax, SYS_WRITE          ; Use the macro/define from config.inc
    ; RDI is already pre-loaded with the Socket FD from the main loop
    lea rsi, [rel res_200]      ; Relative addressing for position-independent safety
    mov rdx, res_200_len        ; Total length of the HTTP packet
    syscall
    ret