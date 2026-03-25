; -----------------------------------------------------------------------------
; Module: src/routers/handle_pub.asm
; Project: La Roca Micro-PubSub
; Responsibility: Parse HTTP POST, Auto-Create topic if missing, extract custom
;                 routing keys (X-Roca-Key), and Publish to the Ring Buffer.
; -----------------------------------------------------------------------------
%include "config.inc"

extern registry_find
extern create_new_topic
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
    mov r14, rdx                ; r14 = Total Bytes Read

    ; =========================================================================
    ; 1. EXTRACT & NULL-PAD TOPIC NAME
    ; =========================================================================
    lea rsi, [r13 + 10]         ; Skip "POST /pub/"
    lea rdi, [rbp - 16]

    xor rax, rax                ; Zero-fill local name buffer
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
    lea rdi, [rbp - 16]         ; Pointer to parsed topic name
    call registry_find
    test rax, rax
    jnz .found_it

    TRACE "Topic not found in registry. Attempting auto-creation..."
    lea rdi, [rbp - 16]
    call create_new_topic
    test rax, rax
    jz .send_400                ; Fail if invalid name or disk error

.found_it:
    mov r15, rax                ; r15 = Mmap Base Pointer

    ; =========================================================================
    ; 3. LOCATE HTTP BODY (Search for \r\n\r\n)
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
    add rdi, 4                  ; Skip the delimiter (\r\n\r\n)
    mov rcx, rdi                ; RCX = Payload Pointer (For Publisher)
    mov r8, r14
    sub rdi, r13
    sub r8, rdi                 ; R8 = Payload Size (For Publisher)

    ; =========================================================================
    ; 4. EXTRACT ROUTING KEY (Scan for X-Roca-Key:)
    ; =========================================================================
    xor rsi, rsi                ; Default: Key Ptr = 0
    xor rdx, rdx                ; Default: Key Size = 0

    mov rdi, r13                ; Start scanning from the beginning of HTTP request
    mov r9, rcx
    sub r9, r13                 ; R9 = Length of Headers
    sub r9, 11                  ; Safe margin to avoid out-of-bounds reading
    jle .do_publish             ; If headers are too short, skip key search

.scan_key:
    ; Fast 32-bit chunk comparisons for "X-Roca-Key:"
    cmp dword [rdi], 0x6F522D58   ; "X-Ro" (Little Endian)
    jne .next_char
    cmp dword [rdi+4], 0x4B2D6163 ; "ca-K" (Little Endian)
    jne .next_char

    mov eax, dword [rdi+8]
    and eax, 0x00FFFFFF           ; Mask out the 4th byte
    cmp eax, 0x003A7965           ; "ey:" (Little Endian)
    jne .next_char

    ; We found "X-Roca-Key:"!
    lea rsi, [rdi + 11]           ; Start of the Key value
    cmp byte [rsi], ' '           ; Optional space after colon
    jne .find_key_end
    inc rsi                       ; Skip space

.find_key_end:
    mov rdi, rsi                  ; Use RDI to scan for the end of the line
.key_end_loop:
    cmp byte [rdi], 0x0D          ; '\r'
    je .calc_key_len
    cmp byte [rdi], 0x0A          ; '\n'
    je .calc_key_len
    inc rdi
    jmp .key_end_loop

.calc_key_len:
    mov rdx, rdi
    sub rdx, rsi                  ; RDX = Key Size
    jmp .do_publish

.next_char:
    inc rdi
    dec r9
    jnz .scan_key

    ; =========================================================================
    ; 5. INJECT INTO ENGINE (New 5-Parameter ABI)
    ; =========================================================================
.do_publish:
    ; At this point, registers are perfectly aligned for publish_message:
    ; RDI = Mmap Base Pointer
    ; RSI = Key Pointer (or 0)
    ; RDX = Key Size (or 0)
    ; RCX = Payload Pointer
    ; R8  = Payload Size
    mov rdi, r15
    call publish_message

    cmp rax, 0
    jl .send_500                ; Negative RAX means Buffer Full or Geometry Error

    ; =========================================================================
    ; 6. HTTP RESPONSE DISPATCH
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