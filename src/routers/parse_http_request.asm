; -----------------------------------------------------------------------------
; Module: src/routers/parse_http_request.asm
; Project: La Roca Micro-PubSub
; Responsibility: Pure L7 HTTP parser. No syscalls, no handlers, no side effects.
;                 This is the AFL++ fuzzing target — it links standalone into a
;                 C harness with ZERO engine dependencies.
; -----------------------------------------------------------------------------
; Uses bitmasking for O(1) URI prefix matching. The route codes are shared with
; route_api.asm via config.inc (ROUTE_* constants).
; -----------------------------------------------------------------------------
%include "config.inc"

; -----------------------------------------------------------------------------
; Optional AFL++ edge instrumentation (fuzzing only).
;
;   Default build (no -DAFL_INSTRUMENTED): AFL_EDGE expands to NOTHING, so the
;   production binary is byte-identical to an uninstrumented build.
;
;   Fuzz build (nasm -DAFL_INSTRUMENTED): each AFL_EDGE marks a unique
;   control-flow edge in the shared AFL map via __afl_trace (which implements
;   the neverZero counter). This gives afl-fuzz REAL coverage of the hand-written
;   assembly, with no QEMU mode (-Q) and no afl-qemu-trace dependency.
; -----------------------------------------------------------------------------
%ifdef AFL_INSTRUMENTED
    extern __afl_trace

; AFL_EDGE id — record a control-flow edge in the AFL coverage map.
; Preserves every register (saves all caller-saved regs + rbx) and guarantees
; a 16-byte aligned stack for the __afl_trace call regardless of the alignment
; at the call site (works both in a prologue body and at a `call`-target entry).
%macro AFL_EDGE 1
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov edi, %1
    call __afl_trace
    mov rsp, rbx
    pop rbx
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
%endmacro
%else
%macro AFL_EDGE 1
%endmacro
%endif

section .text
    global parse_http_request

; -----------------------------------------------------------------------------
; parse_http_request: Pure L7 router.
; C calling convention: RDI = Buffer Pointer, RSI = Total Bytes Read.
; Output: RAX = Route code (see ROUTE_* constants in config.inc).
; -----------------------------------------------------------------------------
parse_http_request:
    push rbp
    mov rbp, rsp
    AFL_EDGE 0x0001

    ; Identify HTTP Method (First 4 bytes)
    mov eax, dword [rdi]
    cmp eax, 0x20544547         ; 'GET ' (Little Endian)
    je .p_get
    cmp eax, 0x54534F50         ; 'POST' (Little Endian)
    je .p_post
    jmp .p_not_handled

.p_get:
    AFL_EDGE 0x0002
    ; Load the first 8 bytes following 'GET ' for fast prefix masking
    mov rax, qword [rdi + 4]

    ; Check for "/live " (6 bytes: / l i v e [space])
    mov r8, rax
    mov r9, 0x0000FFFFFFFFFFFF  ; 48-bit mask
    and r8, r9
    mov r9, 0x206576696C2F      ; '/live '
    cmp r8, r9
    je .p_live

    ; Check for "/stats " (7 bytes: / s t a t s [space])
    mov r8, rax
    mov r9, 0x00FFFFFFFFFFFFFF  ; 56-bit mask
    and r8, r9
    mov r9, 0x2073746174732F    ; '/stats '
    cmp r8, r9
    je .p_stats

    ; --- TOPIC-BASED GET ROUTES ---
    ; Check for "/sub/" (Prefix: 5 bytes)
    mov r8, rax
    mov r9, 0x000000FFFFFFFFFF  ; 40-bit mask
    and r8, r9
    mov r9, 0x2F6275732F        ; '/sub/'
    cmp r8, r9
    jne .p_check_batch
    mov r8, 9                   ; Offset: 4 (GET) + 5 (/sub/)
    call .p_validate_topic
    test rax, rax
    jz .p_bad_topic
    jmp .p_sub

.p_check_batch:
    AFL_EDGE 0x0005
    ; Check for "/batch/" (Prefix: 7 bytes)
    mov r8, rax
    mov r9, 0x00FFFFFFFFFFFFFF  ; 56-bit mask
    and r8, r9
    mov r9, 0x2F68637461622F    ; '/batch/'
    cmp r8, r9
    jne .p_not_handled
    mov r8, 11                  ; Offset: 4 (GET) + 7 (/batch/)
    call .p_validate_topic
    test rax, rax
    jz .p_bad_topic
    jmp .p_batch

.p_post:
    AFL_EDGE 0x0003
    ; Load the first 8 bytes following 'POST '
    mov rax, qword [rdi + 5]

    ; Check for "/pub/" (Prefix: 5 bytes)
    mov r8, rax
    mov r9, 0x000000FFFFFFFFFF  ; 40-bit mask
    and r8, r9
    mov r9, 0x2F6275702F        ; '/pub/'
    cmp r8, r9
    jne .p_check_mpub
    mov r8, 10                  ; Offset: 5 (POST) + 5 (/pub/)
    call .p_validate_topic
    test rax, rax
    jz .p_bad_topic
    jmp .p_pub

.p_check_mpub:
    AFL_EDGE 0x0006
    ; Check for "/mpub/" (Prefix: 6 bytes)
    mov r8, rax
    mov r9, 0x0000FFFFFFFFFFFF  ; 48-bit mask
    and r8, r9
    mov r9, 0x2F6275706D2F      ; '/mpub/'
    cmp r8, r9
    jne .p_not_handled
    mov r8, 11                  ; Offset: 5 (POST) + 6 (/mpub/)
    call .p_validate_topic
    test rax, rax
    jz .p_bad_topic
    jmp .p_mpub

; --- Route code returns ---
.p_not_handled:
    AFL_EDGE 0x0004
    mov rax, ROUTE_NOT_HANDLED
    jmp .p_exit
.p_live:
    AFL_EDGE 0x0007
    mov rax, ROUTE_LIVE
    jmp .p_exit
.p_stats:
    AFL_EDGE 0x0008
    mov rax, ROUTE_STATS
    jmp .p_exit
.p_sub:
    AFL_EDGE 0x0009
    mov rax, ROUTE_SUB
    jmp .p_exit
.p_batch:
    AFL_EDGE 0x000a
    mov rax, ROUTE_BATCH
    jmp .p_exit
.p_pub:
    AFL_EDGE 0x000b
    mov rax, ROUTE_PUB
    jmp .p_exit
.p_mpub:
    AFL_EDGE 0x000c
    mov rax, ROUTE_MPUB
    jmp .p_exit
.p_bad_topic:
    AFL_EDGE 0x000d
    mov rax, ROUTE_BAD_TOPIC
    jmp .p_exit

; -----------------------------------------------------------------------------
; .p_validate_topic: Security Boundary (pure, no syscalls).
; Input: RDI = Buffer pointer, R8 = offset of topic start
; Output: RAX = 1 (valid) / 0 (invalid)
; -----------------------------------------------------------------------------
.p_validate_topic:
    AFL_EDGE 0x000e
    push rdi
    add rdi, r8
    xor rcx, rcx
.p_v_loop:
    AFL_EDGE 0x000f
    mov al, [rdi + rcx]
    cmp al, '/'
    je .p_v_done
    cmp al, ' '
    je .p_v_done

    inc rcx
    cmp rcx, 16                 ; Max 16 bytes
    jg .p_v_fail
    jmp .p_v_loop

.p_v_done:
    AFL_EDGE 0x0010
    test rcx, rcx
    jz .p_v_fail
    mov rax, 1
    jmp .p_v_exit
.p_v_fail:
    AFL_EDGE 0x0011
    xor rax, rax
.p_v_exit:
    pop rdi
    ret

.p_exit:
    pop rbp
    ret
