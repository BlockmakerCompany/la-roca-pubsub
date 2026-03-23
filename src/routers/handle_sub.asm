; -----------------------------------------------------------------------------
; Module: src/routers/handle_sub.asm
; Project: La Roca Micro-PubSub
; Responsibility: Parse HTTP GET, Lazy-Load Topic if missing, and execute
;                 Wait-Free consumption of a specific Sequence ID.
; -----------------------------------------------------------------------------
%include "config.inc"

extern registry_find
extern create_new_topic
extern consume_message

section .data
    res_400         db "HTTP/1.1 400 Bad Request", 13, 10
                    db "Content-Length: 0", 13, 10, 13, 10
    res_400_len     equ $ - res_400

    res_404         db "HTTP/1.1 404 Not Found", 13, 10
                    db "Content-Length: 0", 13, 10, 13, 10
    res_404_len     equ $ - res_404

    res_500         db "HTTP/1.1 500 Internal Error", 13, 10
                    db "Content-Length: 0", 13, 10, 13, 10
    res_500_len     equ $ - res_500

    res_200_head    db "HTTP/1.1 200 OK", 13, 10
                    db "Content-Type: application/octet-stream", 13, 10
                    db "Content-Length: "
    res_200_head_l  equ $ - res_200_head

    res_crlf        db 13, 10, 13, 10

section .bss
    sub_payload_buf resb 8192       ; Internal buffer for message extraction
    http_out_buf    resb 8192       ; Buffer for HTTP response assembly

section .text
    global handle_sub

; -----------------------------------------------------------------------------
; handle_sub: Processes /sub/[topic]/[sequence] requests.
; Input: RDI = Client Socket FD, RSI = Request Buffer Pointer
; -----------------------------------------------------------------------------
handle_sub:
    push rbp
    mov rbp, rsp
    sub rsp, 16                 ; Local Stack Buffer: 16 bytes for Topic Name

    push r12
    push r13
    push r14
    push r15

    mov r12, rdi                ; r12 = Client Socket FD
    mov r13, rsi                ; r13 = Request Buffer Pointer

    ; =========================================================================
    ; 1. EXTRACT TOPIC NAME
    ; =========================================================================
    ; Offset 9 skips "GET /sub/"
    lea rsi, [r13 + 9]
    lea rdi, [rbp - 16]

    xor rax, rax
    mov qword [rdi], rax        ; Zero-out the local name buffer
    mov qword [rdi + 8], rax

    mov rcx, 16
.extract_name:
    mov al, byte [rsi]
    cmp al, '/'
    je .do_lookup
    cmp al, ' '
    je .send_400

    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jnz .extract_name

    cmp byte [rsi], '/'         ; Topic name must be followed by a slash
    jne .send_400

    ; =========================================================================
    ; 2. REGISTRY LOOKUP & LAZY LOAD
    ; =========================================================================
.do_lookup:
    push rsi
    lea rdi, [rbp - 16]
    call registry_find          ; Search for the topic in the active registry
    pop rsi
    test rax, rax
    jnz .found_it

    ; Topic not in RAM: Try auto-loading from disk (Enforcing Disk Authority)
    push rsi
    lea rdi, [rbp - 16]
    call create_new_topic
    pop rsi
    test rax, rax
    jz .send_400                ; Fail if file creation/mapping error occurs

.found_it:
    mov r14, rax                ; r14 = Topic Mmap Base Pointer

    ; =========================================================================
    ; 3. EXTRACT SEQUENCE NUMBER (SHIELDED)
    ; =========================================================================
    inc rsi                     ; Skip the '/' character

    ; --- INPUT SANITIZATION ---
    mov al, byte [rsi]
    cmp al, ' '                 ; Is the sequence field empty?
    je .send_400                ; Yes -> Empty sequence -> 400 Bad Request
    ; --------------------------

    xor r15, r15                ; r15 = Sequence Number Accumulator

.parse_seq:
    movzx rax, byte [rsi]
    cmp al, ' '                 ; Check for space (end of URI)
    je .do_consume

    cmp al, '0'
    jb .send_400
    cmp al, '9'
    ja .send_400

    sub al, '0'                 ; ASCII to Integer conversion
    imul r15, 10
    add r15, rax
    inc rsi
    jmp .parse_seq

    ; =========================================================================
    ; 4. WAIT-FREE CONSUMPTION
    ; =========================================================================
.do_consume:
    mov rdi, r14                ; Mmap Base Pointer
    mov rsi, r15                ; Requested Sequence ID
    lea rdx, [sub_payload_buf]
    mov rcx, 8192               ; Target buffer capacity
    call consume_message

    cmp rax, 0
    jl .send_500                ; Negative return: Internal Error
    je .send_404                ; 0 return: Message not ready or sequence empty

    mov r15, rax                ; r15 = Actual bytes read from the Ring Buffer

    ; =========================================================================
    ; 5. BUILD HTTP RESPONSE
    ; =========================================================================
    lea rdi, [http_out_buf]

    ; Copy Response Header
    lea rsi, [rel res_200_head]
    mov rcx, res_200_head_l
    rep movsb

    ; Convert Content-Length to ASCII (itoa)
    mov rax, r15
    mov r8, 10                  ; Base 10 (Using R8 for ABI compliance)
    lea r9, [http_out_buf + 1024]
    mov r10, r9
.itoa_loop:
    xor rdx, rdx
    div r8
    add dl, '0'
    dec r9
    mov byte [r9], dl
    test rax, rax
    jnz .itoa_loop

    ; Copy ASCII length to the HTTP packet
    mov rsi, r9
    mov rcx, r10
    sub rcx, r9
    rep movsb

    ; Finalize Header (double CRLF)
    lea rsi, [rel res_crlf]
    mov rcx, 4
    rep movsb

    ; Copy the extracted message payload
    lea rsi, [sub_payload_buf]
    mov rcx, r15
    rep movsb

    ; =========================================================================
    ; 6. TRANSMISSION & CLEANUP
    ; =========================================================================
    mov rdx, rdi
    lea rsi, [http_out_buf]
    sub rdx, rsi                ; rdx = Total packet size

    mov rax, SYS_WRITE
    mov rdi, r12
    syscall
    jmp .exit

.send_400:
    mov rax, SYS_WRITE
    mov rdi, r12
    lea rsi, [rel res_400]
    mov rdx, res_400_len
    syscall
    jmp .exit

.send_404:
    mov rax, SYS_WRITE
    mov rdi, r12
    lea rsi, [rel res_404]
    mov rdx, res_404_len
    syscall
    jmp .exit

.send_500:
    mov rax, SYS_WRITE
    mov rdi, r12
    lea rsi, [rel res_500]
    mov rdx, res_500_len
    syscall

.exit:
    pop r15
    pop r14
    pop r13
    pop r12
    add rsp, 16                 ; Reclaim local name buffer
    pop rbp
    ret