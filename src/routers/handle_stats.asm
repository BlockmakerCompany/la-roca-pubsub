; -----------------------------------------------------------------------------
; Module: src/routers/handle_stats.asm
; Project: La Roca Micro-PubSub
; Responsibility: Generate dynamic L7 engine metrics in JSON format.
;                 Calculates uptime, active topics, and configured geometry.
; -----------------------------------------------------------------------------
%include "config.inc"

extern rt_msg_size
extern rt_max_messages
extern boot_time                ; Populated during _start in main.asm
extern registry_get_count       ; Exported from topic_registry.asm

section .data
    res_200_head    db "HTTP/1.1 200 OK", 13, 10
                    db "Content-Type: application/json", 13, 10
                    db "Content-Length: "
    res_200_head_l  equ $ - res_200_head
    res_crlf        db 13, 10, 13, 10

    ; --- JSON Serialization Fragments ---
    json_p1         db '{"status":"ok","engine":"lock-free","uptime_seconds":'
    json_p1_l       equ $ - json_p1
    json_p2         db ',"active_topics":'
    json_p2_l       equ $ - json_p2
    json_p3         db ',"msg_size_bytes":'
    json_p3_l       equ $ - json_p3
    json_p4         db ',"max_msgs_per_topic":'
    json_p4_l       equ $ - json_p4
    json_p5         db '}', 10
    json_p5_l       equ $ - json_p5

section .bss
    stats_body_buf  resb 1024       ; Buffer for JSON payload
    stats_http_buf  resb 2048       ; Buffer for full HTTP packet

section .text
    global handle_stats

; -----------------------------------------------------------------------------
; handle_stats: Processes /stats requests and returns engine telemetry.
; Input: RDI = Client Socket FD
; -----------------------------------------------------------------------------
handle_stats:
    push rbp
    mov rbp, rsp
    push r12
    push r13

    mov r12, rdi                ; r12 = Client Socket FD

    ; =========================================================================
    ; 1. TELEMETRY DATA GATHERING
    ; =========================================================================

    ; Calculate Uptime: delta = current_time - boot_time
    mov rax, 201                ; sys_time (syscall 201 on x86_64)
    xor rdi, rdi
    syscall
    sub rax, [boot_time]
    mov r8, rax                 ; r8 = Uptime in seconds

    ; Fetch topic count from the registry
    call registry_get_count
    mov r9, rax                 ; r9 = Active Topics

    ; =========================================================================
    ; 2. JSON BODY ASSEMBLY
    ; =========================================================================
    lea rdi, [stats_body_buf]

    ; --- "uptime_seconds": [R8] ---
    lea rsi, [json_p1]
    mov rcx, json_p1_l
    rep movsb
    mov rax, r8
    call append_number

    ; --- "active_topics": [R9] ---
    lea rsi, [json_p2]
    mov rcx, json_p2_l
    rep movsb
    mov rax, r9
    call append_number

    ; --- "msg_size_bytes": [rt_msg_size] ---
    lea rsi, [json_p3]
    mov rcx, json_p3_l
    rep movsb
    mov rax, [rt_msg_size]
    call append_number

    ; --- "max_msgs_per_topic": [rt_max_messages] ---
    lea rsi, [json_p4]
    mov rcx, json_p4_l
    rep movsb
    mov rax, [rt_max_messages]
    call append_number

    ; --- JSON Closure ---
    lea rsi, [json_p5]
    mov rcx, json_p5_l
    rep movsb

    ; Calculate total JSON body length
    mov r13, rdi
    lea rax, [stats_body_buf]
    sub r13, rax                ; r13 = Total JSON Payload Length

    ; =========================================================================
    ; 3. HTTP RESPONSE ASSEMBLY
    ; =========================================================================
    lea rdi, [stats_http_buf]

    ; Copy Status Line and Header Start
    lea rsi, [res_200_head]
    mov rcx, res_200_head_l
    rep movsb

    ; Append Content-Length value
    mov rax, r13
    call append_number

    ; Append double CRLF (Header/Body delimiter)
    lea rsi, [res_crlf]
    mov rcx, 4
    rep movsb

    ; Append the actual JSON body
    lea rsi, [stats_body_buf]
    mov rcx, r13
    rep movsb

    ; =========================================================================
    ; 4. TRANSMISSION
    ; =========================================================================
    mov rdx, rdi
    lea rsi, [stats_http_buf]
    sub rdx, rsi                ; rdx = Total HTTP packet size

    mov rax, SYS_WRITE
    mov rdi, r12                ; Restore Socket FD
    syscall

    pop r13
    pop r12
    pop rbp
    ret

; -----------------------------------------------------------------------------
; append_number: itoa utility for manual buffer concatenation.
; Input:  RAX = Integer to convert
;         RDI = Pointer to destination buffer (updated after write)
; -----------------------------------------------------------------------------
append_number:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    mov rbx, 10
    lea r8, [rsp - 32]          ; Use stack space for temporal itoa storage
    mov r9, r8
.itoa_loop:
    xor rdx, rdx
    div rbx
    add dl, '0'
    dec r8
    mov byte [r8], dl
    test rax, rax
    jnz .itoa_loop

    ; Copy converted ASCII string to final RDI buffer
    mov rsi, r8
    mov rcx, r9
    sub rcx, r8
    rep movsb

    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret