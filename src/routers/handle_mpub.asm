; -----------------------------------------------------------------------------
; Module: src/routers/handle_mpub.asm
; Project: La Roca Micro-PubSub
; Responsibility: Parse HTTP POST, extract multiple \n delimited messages,
;                 and execute batch publication into the Ring Buffer.
; -----------------------------------------------------------------------------
%include "config.inc"

extern registry_find
extern create_new_topic
extern publish_message

section .data
    res_mpub_ok      db "HTTP/1.1 200 OK", 13, 10
                     db "Content-Length: 0", 13, 10, 13, 10
    res_mpub_ok_len  equ $ - res_mpub_ok

    res_mpub_400     db "HTTP/1.1 400 Bad Request", 13, 10
                     db "Content-Length: 0", 13, 10, 13, 10
    res_mpub_400_len equ $ - res_mpub_400

    res_mpub_500     db "HTTP/1.1 500 Internal Server Error", 13, 10
                     db "Content-Length: 0", 13, 10, 13, 10
    res_mpub_500_len equ $ - res_mpub_500

section .text
    global handle_mpub

; -----------------------------------------------------------------------------
; handle_mpub: Processes /mpub/[topic] with a newline-delimited body.
; Input: RDI = Client Socket FD, RSI = Buffer Pointer, RDX = Bytes Read
; -----------------------------------------------------------------------------
handle_mpub:
    push rbp
    mov rbp, rsp
    sub rsp, 16                 ; Local Stack Buffer: 16 bytes for Topic Name

    push r12
    push r13
    push r14
    push r15
    push rbx

    mov r12, rdi                ; R12 = Client Socket FD
    mov r13, rsi                ; R13 = Request Buffer Pointer
    mov r14, rdx                ; R14 = Total Bytes Read

    ; =========================================================================
    ; 1. EXTRACT & NULL-PAD TOPIC NAME
    ; =========================================================================
    ; Offset 11 skips "POST /mpub/"
    lea rsi, [r13 + 11]
    lea rdi, [rbp - 16]

    xor rax, rax
    mov qword [rdi], rax        ; Zero-out the local name buffer
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
    lea rdi, [rbp - 16]
    call registry_find          ; Search for topic metadata
    test rax, rax
    jnz .found_it

    TRACE "Topic not found. Attempting auto-creation (MPUB)..."
    lea rdi, [rbp - 16]
    call create_new_topic       ; Lazy-load topic if missing (Enforces Disk Authority)
    test rax, rax
    jz .send_400

.found_it:
    mov r15, rax                ; R15 = Topic Mmap Base Pointer

    ; =========================================================================
    ; 3. LOCATE HTTP BODY (Double CRLF Search)
    ; =========================================================================
    mov rcx, r14
    mov rdi, r13
    mov eax, 0x0A0D0A0D         ; Little-Endian representation of "\r\n\r\n"

.search_body:
    cmp dword [rdi], eax
    je .found_body
    inc rdi
    dec rcx
    jnz .search_body
    jmp .send_400               ; Body delimiter not found

.found_body:
    add rdi, 4
    mov rbx, rdi                ; RBX = Pointer to Body Start

    mov rdx, rdi
    sub rdx, r13
    mov rcx, r14
    sub rcx, rdx                ; RCX = Body Length (Total - Header)

    ; =========================================================================
    ; 4. THE HOT LOOP: BATCH INGESTION (\n delimiter)
    ; =========================================================================
.parse_messages:
    test rcx, rcx
    jle .send_200               ; Finished processing all bytes

    mov rsi, rbx                ; Current line start
    mov rdx, rcx                ; Remaining bytes in body
    xor r8, r8                  ; Current line length counter

.find_newline:
    test rdx, rdx
    jz .inject_last             ; End of buffer reached without a final newline

    mov al, byte [rsi]
    cmp al, 10                  ; Check for '\n' (LF)
    je .process_line
    inc rsi
    inc r8
    dec rdx
    jmp .find_newline

.process_line:
    test r8, r8
    jz .skip_empty              ; Ignore empty lines (double newlines)

    mov r9, r8                  ; R9 = Actual payload length to inject
    mov al, byte [rbx + r8 - 1]
    cmp al, 13                  ; Check for '\r' (CR) at end of line
    jne .do_publish
    dec r9                      ; Strip '\r' if found
    jz .skip_empty

.do_publish:
    mov rdi, r15                ; RDI = Mmap Base Pointer
    mov rsi, rbx                ; RSI = Payload Pointer (Body segment)
    mov rdx, r9                 ; RDX = Payload Length (sanitized)

    ; --- STATE PRESERVATION SHIELD (System V ABI Compliance) ---
    ; Preserve loop-sensitive registers on the stack.
    ; 4 registers * 8 bytes = 32 bytes (keeps 16-byte stack alignment).
    push r15
    push rbx
    push rcx
    push r8

    call publish_message        ; Atomic injection into Ring Buffer

    pop r8
    pop rcx
    pop rbx
    pop r15
    ; -----------------------------------------------------------

    cmp rax, 0
    jl .send_500                ; Critical error (e.g., Ring Buffer full)

.skip_empty:
    ; Advance pointers and decrement total body counter
    lea rbx, [rbx + r8 + 1]     ; Move RBX past the message and the '\n'
    sub rcx, r8
    dec rcx
    jmp .parse_messages

.inject_last:
    test r8, r8
    jz .send_200

    mov r9, r8
    mov al, byte [rbx + r8 - 1]
    cmp al, 13
    jne .do_publish_last
    dec r9
    jz .send_200

.do_publish_last:
    mov rdi, r15
    mov rsi, rbx
    mov rdx, r9
    call publish_message
    jmp .send_200

    ; =========================================================================
    ; 5. RESPOND & EXIT
    ; =========================================================================
.send_200:
    mov rax, SYS_WRITE
    mov rdi, r12
    lea rsi, [rel res_mpub_ok]
    mov rdx, res_mpub_ok_len
    syscall
    jmp .exit

.send_400:
    mov rax, SYS_WRITE
    mov rdi, r12
    lea rsi, [rel res_mpub_400]
    mov rdx, res_mpub_400_len
    syscall
    jmp .exit

.send_500:
    mov rax, SYS_WRITE
    mov rdi, r12
    lea rsi, [rel res_mpub_500]
    mov rdx, res_mpub_500_len
    syscall

.exit:
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    add rsp, 16                 ; Clear local topic name buffer
    pop rbp
    ret