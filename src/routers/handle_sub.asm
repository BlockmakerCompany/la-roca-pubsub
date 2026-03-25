; -----------------------------------------------------------------------------
; Module: src/routers/handle_sub.asm
; Project: La Roca Micro-PubSub
; Responsibility: Parse HTTP GET, Lazy-Load Topic if missing, extract message
;                 AND its Routing Key, and build the HTTP response.
; -----------------------------------------------------------------------------
%include "config.inc"

extern registry_find
extern create_new_topic
extern consume_message
extern rt_key_size

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
    res_200_head_l  equ $ - res_200_head

    res_key_head    db "X-Roca-Key: "
    res_key_head_l  equ $ - res_key_head

    res_crlf        db 13, 10
    res_len_head    db "Content-Length: "
    res_len_head_l  equ $ - res_len_head

section .bss
    sub_payload_buf resb 8192       ; Internal buffer for payload
    sub_key_buf     resb 256        ; Internal buffer for routing key
    http_out_buf    resb 16384      ; Increased buffer for HTTP response

section .text
    global handle_sub

; -----------------------------------------------------------------------------
; handle_sub: Processes /sub/[topic]/[sequence] requests.
; Input: RDI = Client Socket FD, RSI = Request Buffer Pointer
; -----------------------------------------------------------------------------
handle_sub:
    push rbp
    mov rbp, rsp
    sub rsp, 16                 ; Local Stack Buffer: Topic Name

    push r12
    push r13
    push r14
    push r15
    push rbx

    mov r12, rdi                ; Client Socket FD
    mov r13, rsi                ; Request Buffer Pointer

    ; =========================================================================
    ; 1. EXTRACT TOPIC NAME
    ; =========================================================================
    lea rsi, [r13 + 9]          ; Skip "GET /sub/"
    lea rdi, [rbp - 16]

    xor rax, rax
    mov qword [rdi], rax
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

    cmp byte [rsi], '/'
    jne .send_400

    ; =========================================================================
    ; 2. REGISTRY LOOKUP & LAZY LOAD
    ; =========================================================================
.do_lookup:
    push rsi
    lea rdi, [rbp - 16]
    call registry_find
    pop rsi
    test rax, rax
    jnz .found_it

    push rsi
    lea rdi, [rbp - 16]
    call create_new_topic
    pop rsi
    test rax, rax
    jz .send_400

.found_it:
    mov r14, rax                ; r14 = Topic Mmap Base Pointer

    ; =========================================================================
    ; 3. EXTRACT SEQUENCE NUMBER
    ; =========================================================================
    inc rsi                     ; Skip '/'
    mov al, byte [rsi]
    cmp al, ' '
    je .send_400

    xor r15, r15                ; Sequence accumulator

.parse_seq:
    movzx rax, byte [rsi]
    cmp al, ' '
    je .do_consume
    cmp al, '0'
    jb .send_400
    cmp al, '9'
    ja .send_400
    sub al, '0'
    imul r15, 10
    add r15, rax
    inc rsi
    jmp .parse_seq

    ; =========================================================================
    ; 4. WAIT-FREE CONSUMPTION (With Key Extraction)
    ; =========================================================================
.do_consume:
    ; Clean the Key Buffer first
    lea rdi, [sub_key_buf]
    mov rcx, 32                 ; Clear 256 bytes (32 * 8)
    xor rax, rax
    rep stosq

    ; Setup ABI parameters
    mov rdi, r14                ; Mmap Base Pointer
    mov rsi, r15                ; Requested Sequence ID
    lea rdx, [sub_payload_buf]  ; Payload Buffer
    mov rcx, 8192               ; Payload Capacity
    lea r8, [sub_key_buf]       ; Key Buffer (NEW)
    call consume_message

    cmp rax, 0
    jl .send_500
    je .send_404

    mov r15, rax                ; r15 = Actual bytes read (Payload Length)

    ; =========================================================================
    ; 5. BUILD DYNAMIC HTTP RESPONSE
    ; =========================================================================
    lea rdi, [http_out_buf]     ; Dest for HTTP Packet

    ; Copy Response Header Start
    lea rsi, [rel res_200_head]
    mov rcx, res_200_head_l
    rep movsb

    ; --- INJECT CUSTOM KEY HEADER (If exists) ---
    cmp qword [rt_key_size], 0
    jle .skip_key_header        ; No key configured

    cmp byte [sub_key_buf], 0
    je .skip_key_header         ; Key is empty

    ; Copy "X-Roca-Key: "
    lea rsi, [rel res_key_head]
    mov rcx, res_key_head_l
    rep movsb

    ; Copy the actual key (until null-terminator or rt_key_size)
    lea rsi, [sub_key_buf]
    mov rcx, [rt_key_size]
.copy_key_loop:
    lodsb
    test al, al                 ; Check for null-terminator
    jz .finish_key
    stosb                       ; Write to HTTP packet
    dec rcx
    jnz .copy_key_loop
.finish_key:

    ; Add CRLF after key header
    mov word [rdi], 0x0A0D
    add rdi, 2

.skip_key_header:
    ; --- INJECT CONTENT-LENGTH ---
    lea rsi, [rel res_len_head]
    mov rcx, res_len_head_l
    rep movsb

    ; Convert Content-Length to ASCII
    mov rax, r15
    mov r8, 10
    lea r9, [http_out_buf + 2048]
    mov r10, r9
.itoa_loop:
    xor rdx, rdx
    div r8
    add dl, '0'
    dec r9
    mov byte [r9], dl
    test rax, rax
    jnz .itoa_loop

    ; Copy ASCII length
    mov rsi, r9
    mov rcx, r10
    sub rcx, r9
    rep movsb

    ; Finalize HTTP Headers (Double CRLF: \r\n\r\n)
    mov dword [rdi], 0x0A0D0A0D
    add rdi, 4

    ; Copy the extracted Payload
    lea rsi, [sub_payload_buf]
    mov rcx, r15
    rep movsb

    ; =========================================================================
    ; 6. TRANSMISSION & CLEANUP
    ; =========================================================================
    mov rdx, rdi
    lea rsi, [http_out_buf]
    sub rdx, rsi                ; Total HTTP packet size

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
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    add rsp, 16                 ; Reclaim local stack
    pop rbp
    ret