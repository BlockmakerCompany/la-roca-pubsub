; -----------------------------------------------------------------------------
; Module: src/routers/handle_mpub.asm
; Project: La Roca Micro-PubSub
; Responsibility: Parse HTTP POST, extract routing key, split \n delimited
;                 messages, and execute batch publication into the Ring Buffer.
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
    ; Allocate 32 bytes on stack:
    ; [rbp-16] : 16 bytes for Topic Name
    ; [rbp-24] : 8 bytes for Key Pointer
    ; [rbp-32] : 8 bytes for Key Size
    sub rsp, 32

    push r12
    push r13
    push r14
    push r15
    push rbx

    mov r12, rdi                ; R12 = Client Socket FD
    mov r13, rsi                ; R13 = Request Buffer Pointer
    mov r14, rdx                ; R14 = Total Bytes Read

    ; Default Key State (No Key)
    xor rax, rax
    mov qword [rbp - 24], rax   ; Key Ptr = 0
    mov qword [rbp - 32], rax   ; Key Size = 0

    ; =========================================================================
    ; 1. EXTRACT & NULL-PAD TOPIC NAME
    ; =========================================================================
    lea rsi, [r13 + 11]         ; Skip "POST /mpub/"
    lea rdi, [rbp - 16]

    xor rax, rax
    mov qword [rdi], rax        ; Zero-out local name buffer
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
    call registry_find
    test rax, rax
    jnz .found_it

    TRACE "Topic not found. Attempting auto-creation (MPUB)..."
    lea rdi, [rbp - 16]
    call create_new_topic
    test rax, rax
    jz .send_400

.found_it:
    mov r15, rax                ; R15 = Topic Mmap Base Pointer

    ; =========================================================================
    ; 3. LOCATE HTTP BODY & HEADERS
    ; =========================================================================
    mov rcx, r14
    mov rdi, r13
    mov eax, 0x0A0D0A0D         ; "\r\n\r\n"

.search_body:
    cmp dword [rdi], eax
    je .found_body
    inc rdi
    dec rcx
    jnz .search_body
    jmp .send_400               ; Body delimiter not found

.found_body:
    add rdi, 4                  ; Skip delimiter
    mov rbx, rdi                ; RBX = Pointer to Body Start

    mov rdx, rdi
    sub rdx, r13
    mov rcx, r14
    sub rcx, rdx                ; RCX = Total Body Length

    ; =========================================================================
    ; 3.5 EXTRACT ROUTING KEY (Scan Headers for X-Roca-Key:)
    ; =========================================================================
    push rcx                    ; Save Body Length across key search
    push rbx                    ; Save Body Pointer across key search

    mov rdi, r13                ; Start scanning from the beginning
    mov r9, rbx
    sub r9, r13                 ; R9 = Length of Headers
    sub r9, 11                  ; Safe margin
    jle .key_search_done

.scan_key:
    cmp dword [rdi], 0x6F522D58   ; "X-Ro"
    jne .next_char
    cmp dword [rdi+4], 0x4B2D6163 ; "ca-K"
    jne .next_char
    mov eax, dword [rdi+8]
    and eax, 0x00FFFFFF
    cmp eax, 0x003A7965           ; "ey:"
    jne .next_char

    ; Key Found!
    lea rsi, [rdi + 11]
    cmp byte [rsi], ' '
    jne .find_key_end
    inc rsi                       ; Skip space

.find_key_end:
    mov rdi, rsi
.key_end_loop:
    cmp byte [rdi], 0x0D
    je .calc_key_len
    cmp byte [rdi], 0x0A
    je .calc_key_len
    inc rdi
    jmp .key_end_loop

.calc_key_len:
    mov qword [rbp - 24], rsi   ; Store Key Ptr in stack
    mov rdx, rdi
    sub rdx, rsi
    mov qword [rbp - 32], rdx   ; Store Key Size in stack
    jmp .key_search_done

.next_char:
    inc rdi
    dec r9
    jnz .scan_key

.key_search_done:
    pop rbx                     ; Restore Body Pointer
    pop rcx                     ; Restore Body Length

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

    mov r9, r8                  ; R9 = Actual payload length
    mov al, byte [rbx + r8 - 1]
    cmp al, 13                  ; Check for '\r' (CR) at end of line
    jne .do_publish
    dec r9                      ; Strip '\r' if found
    jz .skip_empty

.do_publish:
    ; --- STATE PRESERVATION SHIELD (FIXED) ---
    push r15                    ; Save Mmap Pointer
    push rbx                    ; Save current payload pointer position
    push rcx                    ; Save remaining body length
    push r8                     ; Save line length (including newline)

    ; Setup 5-Parameter ABI for publish_message
    mov rdi, r15                ; Mmap Base Pointer
    mov rsi, [rbp - 24]         ; Key Pointer
    mov rdx, [rbp - 32]         ; Key Size
    mov rcx, rbx                ; Payload Pointer (Start of line)
    mov r8,  r9                 ; Payload Size (Without CRLF)

    call publish_message

    pop r8
    pop rcx
    pop rbx
    pop r15
    ; -----------------------------------------

    cmp rax, 0
    jl .send_500                ; Critical error (Buffer Full / Bad Geometry)

.skip_empty:
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
    ; No need to push/pop here as the loop is ending, but we must set ABI
    mov rdi, r15
    mov rsi, [rbp - 24]
    mov rdx, [rbp - 32]
    mov rcx, rbx
    mov r8, r9
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
    add rsp, 32                 ; Clear local stack variables
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret