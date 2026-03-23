; -----------------------------------------------------------------------------
; Module: src/routers/handle_batch.asm
; Project: La Roca Micro-PubSub
; Responsibility: Parse HTTP GET, Lazy-Load Topic, and consume multiple
;                 messages sequentially in a single network round-trip.
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

    res_200_head    db "HTTP/1.1 200 OK", 13, 10
                    db "Content-Type: application/octet-stream", 13, 10
                    db "Content-Length: "
    res_200_head_l  equ $ - res_200_head

    res_crlf        db 13, 10, 13, 10

section .bss
    batch_payload_buf resb 65536  ; 64 KB Internal Collection Buffer
    http_out_buf      resb 65536  ; 64 KB HTTP Response Assembler

section .text
    global handle_batch

; -----------------------------------------------------------------------------
; handle_batch: Processes /batch/[topic]/[start_seq]/[count]
; Input: RDI = Client Socket FD, RSI = Pointer to HTTP Request Buffer
; -----------------------------------------------------------------------------
handle_batch:
    push rbp
    mov rbp, rsp
    sub rsp, 16                 ; Local space for topic name parsing

    push r12
    push r13
    push r14
    push r15
    push rbx

    mov r12, rdi                ; R12 = Client Socket FD
    mov r13, rsi                ; R13 = Request Buffer Pointer

    ; =========================================================================
    ; 1. EXTRACT TOPIC NAME
    ; =========================================================================
    ; Offset 11 skips "GET /batch/"
    lea rsi, [r13 + 11]
    lea rdi, [rbp - 16]

    xor rax, rax
    mov qword [rdi], rax        ; Clear local name buffer
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
    ; 2. REGISTRY LOOKUP & AUTO-PROVISIONING
    ; =========================================================================
.do_lookup:
    push rsi
    lea rdi, [rbp - 16]
    call registry_find          ; Search for topic in the sorted registry
    pop rsi
    test rax, rax
    jnz .found_it

    ; Lazy-Loading: Create topic if not found (Enforces Disk Authority)
    push rsi
    lea rdi, [rbp - 16]
    call create_new_topic
    pop rsi
    test rax, rax
    jz .send_400

.found_it:
    mov r14, rax                ; R14 = Topic Mmap Base Pointer

    ; =========================================================================
    ; 3. EXTRACT START SEQUENCE (ASCII to Integer)
    ; =========================================================================
    inc rsi                     ; Skip the '/'
    xor r15, r15                ; R15 = Start Sequence Accumulator
.parse_seq:
    movzx rax, byte [rsi]
    cmp al, '/'
    je .extract_batch_size
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
    ; 4. EXTRACT BATCH SIZE (ASCII to Integer)
    ; =========================================================================
.extract_batch_size:
    inc rsi                     ; Skip the '/'
    xor r13, r13                ; R13 = Batch Size Accumulator
.parse_size:
    movzx rax, byte [rsi]
    cmp al, ' '
    je .do_batch_consume
    cmp al, '0'
    jb .send_400
    cmp al, '9'
    ja .send_400
    sub al, '0'
    imul r13, 10
    add r13, rax
    inc rsi
    jmp .parse_size

    ; =========================================================================
    ; 5. THE HOT LOOP (Shielded Message Collector)
    ; =========================================================================
.do_batch_consume:
    xor rbx, rbx                ; RBX = Total Bytes Accumulated

.batch_loop:
    test r13, r13               ; Are there messages left in the batch?
    jz .build_response

    ; Buffer Overflow Protection: Check if we have enough space for at least 1KB
    mov rcx, 65536
    sub rcx, rbx
    cmp rcx, 1024
    jl .build_response

    ; --- TITANIUM SHIELD (ABI Compliance & State Protection) ---
    push r13                    ; Preserve Batch Count
    push r14                    ; Preserve Mmap Pointer
    push r15                    ; Preserve Current Sequence ID
    push rbx                    ; Preserve Accumulated Bytes
    sub rsp, 8                  ; Align Stack to 16-bytes (Strict System V ABI)

    mov rdi, r14                ; RDI = Mmap Base Pointer
    mov rsi, r15                ; RSI = Requested Sequence
    lea rdx, [rel batch_payload_buf]
    add rdx, rbx                ; Destination = Buffer + Current Offset
    ; RCX already contains the remaining buffer limit

    call consume_message        ; Wait-free read from Ring Buffer

    add rsp, 8                  ; Undo ABI stack alignment
    pop rbx
    pop r15
    pop r14
    pop r13
    ; ----------------------------------------------------------

    cmp rax, 0
    jle .build_response         ; If message not ready or empty, finalize the batch

    add rbx, rax                ; Update total read count

    ; Append newline ('\n') as a message separator for binary streams
    lea rdx, [rel batch_payload_buf]
    add rdx, rbx
    mov byte [rdx], 10
    inc rbx

    inc r15                     ; Increment to next Sequence ID
    dec r13                     ; Decrement remaining batch counter
    jmp .batch_loop

    ; =========================================================================
    ; 6. BUILD & SEND HTTP RESPONSE
    ; =========================================================================
.build_response:
    test rbx, rbx               ; If 0 bytes collected, no data found
    jz .send_404

    lea rdi, [rel http_out_buf]
    lea rsi, [rel res_200_head]
    mov rcx, res_200_head_l
    rep movsb                   ; Copy HTTP Header base

    ; Fast itoa: Convert RBX (Total Content-Length) to ASCII
    mov rax, rbx
    mov r8, 10
    lea r9, [rel http_out_buf]
    add r9, 1024                ; Temporal buffer for itoa
    mov r10, r9
.itoa_loop:
    xor rdx, rdx
    div r8
    add dl, '0'
    dec r9
    mov byte [r9], dl
    test rax, rax
    jnz .itoa_loop

    ; Copy ASCII length to HTTP response
    mov rsi, r9
    mov rcx, r10
    sub rcx, r9
    rep movsb

    ; Finalize Header with double CRLF
    lea rsi, [rel res_crlf]
    mov rcx, 4
    rep movsb

    ; Copy the entire batch payload
    lea rsi, [rel batch_payload_buf]
    mov rcx, rbx
    rep movsb

    ; Final Send: sys_write
    mov rdx, rdi
    lea rsi, [rel http_out_buf]
    sub rdx, rsi                ; RDX = Total HTTP packet size

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

.exit:
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    add rsp, 16                 ; Clear local topic name buffer
    pop rbp
    ret