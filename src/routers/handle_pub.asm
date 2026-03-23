; -----------------------------------------------------------------------------
; Module: src/routers/handle_pub.asm
; Project: La Roca Micro-PubSub
; Responsibility: Parse HTTP POST, Auto-Create topic if missing, and Publish
;                 a single message into the Ring Buffer.
; -----------------------------------------------------------------------------
%include "config.inc"

extern registry_find
extern create_new_topic    ; Required for dynamic on-the-fly provisioning
extern publish_message

section .data
    res_pub_ok      db "HTTP/1.1 200 OK", 13, 10
                    db "Content-Length: 0", 13, 10, 13, 10
    res_pub_ok_len  equ $ - res_pub_ok

    res_pub_400     db "HTTP/1.1 400 Bad Request", 13, 10
                    db "Content-Length: 0", 13, 10, 13, 10
    res_pub_400_len equ $ - res_pub_400

    res_pub_500     db "HTTP/1.1 500 Internal Server Error", 13, 10
                    db "Content-Length: 0", 13, 10, 13, 10
    res_pub_500_len equ $ - res_pub_500

section .text
    global handle_pub

; -----------------------------------------------------------------------------
; handle_pub: Processes /pub/[topic] requests.
; Input: RDI = Socket FD, RSI = Buffer Pointer, RDX = Total Bytes Read
; -----------------------------------------------------------------------------
handle_pub:
    push rbp
    mov rbp, rsp
    sub rsp, 16                 ; Local Buffer: 16-byte stack space for Topic Name

    push r12
    push r13
    push r14
    push r15

    mov r12, rdi                ; r12 = Socket FD
    mov r13, rsi                ; r13 = Request Buffer Pointer
    mov r14, rdx                ; r14 = Bytes Read

    ; =========================================================================
    ; 1. EXTRACT & NULL-PAD TOPIC NAME
    ; =========================================================================
    ; Offset 10 skips "POST /pub/"
    lea rsi, [r13 + 10]
    lea rdi, [rbp - 16]

    ; Clear local name buffer (Zero-fill)
    xor rax, rax
    mov qword [rdi], rax
    mov qword [rdi + 8], rax

    mov rcx, 16
.extract_name:
    mov al, byte [rsi]
    cmp al, ' '
    je .lookup_topic
    cmp al, '/'
    je .lookup_topic
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jnz .extract_name

    ; =========================================================================
    ; 2. REGISTRY LOOKUP & AUTO-PROVISIONING
    ; =========================================================================
.lookup_topic:
    lea rdi, [rbp - 16]         ; RDI = Pointer to parsed topic name
    call registry_find
    test rax, rax
    jnz .found_it               ; If exists, proceed to publishing flow

    ; --- Lazy Loading: Topic missing in RAM, attempt dynamic creation ---
    TRACE "Topic not found in registry. Attempting auto-creation..."
    lea rdi, [rbp - 16]
    call create_new_topic       ; Handles file creation, mmap, and registry insertion
    test rax, rax
    jz .send_400                ; Fail if name is invalid or disk error occurs

.found_it:
    mov r15, rax                ; r15 = Mmap Base Pointer (from registry or creator)

    ; =========================================================================
    ; 3. LOCATE HTTP BODY (Search for double CRLF)
    ; =========================================================================
    mov rcx, r14
    mov rdi, r13
    mov eax, 0x0A0D0A0D         ; Little-Endian "\r\n\r\n"

.search_body:
    cmp dword [rdi], eax
    je .found_body
    inc rdi
    dec rcx
    jnz .search_body
    jmp .send_400               ; Body start not found

.found_body:
    add rdi, 4                  ; Skip the delimiter
    mov rsi, rdi                ; RSI = Payload Pointer
    mov rdx, rdi
    sub rdx, r13
    mov rcx, r14
    sub rcx, rdx
    mov rdx, rcx                ; RDX = Actual Payload Length

    ; =========================================================================
    ; 4. INJECT INTO ENGINE (Atomic Write)
    ; =========================================================================
    mov rdi, r15                ; RDI = Mmap Base Pointer
    ; RSI and RDX are already pre-loaded with payload and length
    call publish_message
    cmp rax, 0
    jl .send_500                ; Fail if buffer is full or mmap is corrupted

    ; =========================================================================
    ; 5. HTTP RESPONSE DISPATCH
    ; =========================================================================
.send_200:
    mov rax, SYS_WRITE
    mov rdi, r12
    lea rsi, [rel res_pub_ok]
    mov rdx, res_pub_ok_len
    syscall
    jmp .exit

.send_400:
    mov rax, SYS_WRITE
    mov rdi, r12
    lea rsi, [rel res_pub_400]
    mov rdx, res_pub_400_len
    syscall
    jmp .exit

.send_500:
    mov rax, SYS_WRITE
    mov rdi, r12
    lea rsi, [rel res_pub_500]
    mov rdx, res_pub_500_len
    syscall

.exit:
    pop r15
    pop r14
    pop r13
    pop r12
    add rsp, 16                 ; Reclaim local name buffer
    pop rbp
    ret