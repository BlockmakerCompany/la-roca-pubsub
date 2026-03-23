; -----------------------------------------------------------------------------
; Module: src/main.asm
; Project: La Roca Micro-PubSub
; Responsibility: System entry point (_start). Orchestrates engine hydration,
;                 environment parsing, and the Epoll-based TCP Reactor loop.
; -----------------------------------------------------------------------------
%include "core/config.inc"

extern vfs_init
extern init_topics
extern route_api
extern boot_time            ; Defined in globals.asm (Uptime tracking)
extern load_engine_config   ; Parses envp for dynamic geometry

section .data
    msg_boot        db "La Roca Micro-PubSub starting on port 8080...", 10, 0
    msg_boot_l      equ $ - msg_boot

    msg_err_sock    db "FATAL: Could not bind socket.", 10, 0
    msg_err_sock_l  equ $ - msg_err_sock

    ; --- Socket Address Structure (sockaddr_in) ---
    sockaddr        dw 2            ; sin_family: AF_INET (IPv4)
                    dw 0x901F       ; sin_port: 8080 (Big-Endian/Network Byte Order)
                    dd 0            ; sin_addr: INADDR_ANY (0.0.0.0)
                    dq 0            ; Padding to 16 bytes

    MAX_EVENTS      equ 1024        ; Max events per epoll_wait cycle

section .bss
    server_fd       resq 1          ; Master listening socket
    epoll_fd        resq 1          ; Epoll instance file descriptor
    http_buffer     resb 4096       ; Shared buffer for raw HTTP ingestion
    epoll_events    resb MAX_EVENTS * 16 ; Array of struct epoll_event
    ep_event        resb 16         ; Single epoll_event struct for CTL ops

section .text
    global _start

; -----------------------------------------------------------------------------
; _start: Execution begins here.
; -----------------------------------------------------------------------------
_start:
    ; =========================================================================
    ; 0. CAPTURE ENGINE GENESIS (Boot Timestamp)
    ; =========================================================================
    mov rax, 201                ; sys_time (Returns Unix Epoch in RAX)
    xor rdi, rdi                ; rdi = NULL
    syscall
    mov [boot_time], rax        ; Hydrate global boot_time for uptime metrics

    ; =========================================================================
    ; 0.5. ENVIRONMENT PARSING (Dynamic Geometry via envp)
    ; =========================================================================
    ; At entry, the Linux Kernel initializes the stack as follows:
    ; [rsp]                  = argc
    ; [rsp + 8]              = argv[0]
    ; [rsp + 8 + argc*8]     = NULL (End of argv)
    ; [rsp + 8 + argc*8 + 8] = envp[0] <--- The Environment Pointer starts here!

    mov rdi, [rsp]                 ; RDI = argc
    lea rsi, [rsp + 8 + rdi*8 + 8] ; RSI = Pointer to the envp array
    call load_engine_config        ; Parse envp and overwrite defaults in globals.asm

    ; =========================================================================
    ; 1. CONSOLE INITIALIZATION
    ; =========================================================================
    mov rax, 1                  ; sys_write
    mov rdi, 1                  ; STDOUT
    lea rsi, [msg_boot]
    mov rdx, msg_boot_l
    syscall

    ; =========================================================================
    ; 2. STORAGE & ENGINE HYDRATION
    ; =========================================================================
    ; vfs_init and init_topics now use the geometry loaded from envp
    call vfs_init               ; Ensure /topics directory exists
    call init_topics            ; Scan disk for existing topics (Disk Authority)

    ; =========================================================================
    ; 3. NETWORK STACK INITIALIZATION (TCP)
    ; =========================================================================
    ; Create Socket: AF_INET (2), SOCK_STREAM (1), IPPROTO_TCP (6)
    mov rax, 41                 ; sys_socket
    mov rdi, 2
    mov rsi, 1
    mov rdx, 6
    syscall
    cmp rax, 0
    jl .fatal_error
    mov [server_fd], rax

    ; Set Socket Option: SO_REUSEADDR (Avoid "Address already in use" on restarts)
    mov rax, 54                 ; sys_setsockopt
    mov rdi, [server_fd]
    mov rsi, 1                  ; SOL_SOCKET
    mov rdx, 2                  ; SO_REUSEADDR
    push qword 1                ; Option value: 1 (Enabled)
    mov r10, rsp
    mov r8, 4                   ; Size of int
    syscall
    pop rcx                     ; Restore stack

    ; Bind Socket to 0.0.0.0:8080
    mov rax, 49                 ; sys_bind
    mov rdi, [server_fd]
    lea rsi, [sockaddr]
    mov rdx, 16
    syscall
    cmp rax, 0
    jl .fatal_error

    ; Start Listening
    mov rax, 50                 ; sys_listen
    mov rdi, [server_fd]
    mov rsi, 4096               ; Backlog size
    syscall

    ; =========================================================================
    ; 4. EVENT REACTOR SETUP (Epoll)
    ; =========================================================================
    mov rax, 291                ; sys_epoll_create1
    xor rdi, rdi
    syscall
    mov [epoll_fd], rax

    ; Register the listening socket in the epoll instance
    mov dword [ep_event], 1     ; EPOLLIN (Standard Read Event)
    mov rax, [server_fd]
    mov qword [ep_event + 4], rax

    mov rax, 233                ; sys_epoll_ctl
    mov rdi, [epoll_fd]
    mov rsi, 1                  ; EPOLL_CTL_ADD
    mov rdx, [server_fd]
    lea r10, [ep_event]
    syscall

    ; =========================================================================
    ; 5. MAIN REACTOR LOOP
    ; =========================================================================
.event_loop:
    mov rax, 232                ; sys_epoll_wait
    mov rdi, [epoll_fd]
    lea rsi, [epoll_events]
    mov rdx, MAX_EVENTS
    mov r10, -1                 ; Infinite timeout (Wait for events)
    syscall

    mov r12, rax                ; r12 = Number of triggered events
    xor r13, r13                ; r13 = Current event index

.process_events:
    cmp r13, r12
    jge .event_loop             ; Cycle back to wait once batch is processed

    ; Calculate pointer to current event: rbx = events + (index * 16)
    mov rax, r13
    shl rax, 4                  ; Each struct is 16 bytes (2^4)
    lea rbx, [epoll_events + rax]
    mov r14, qword [rbx + 4]    ; Extract the File Descriptor from data.fd

    ; Check if the event is a new connection on the master socket
    mov rax, [server_fd]
    cmp r14, rax
    je .handle_accept           ; Handle incoming connection
    jmp .handle_client          ; Handle data from existing client

.handle_accept:
    mov rax, 43                 ; sys_accept
    mov rdi, [server_fd]
    xor rsi, rsi                ; We don't need client addr info for now
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .next_event
    mov r15, rax                ; r15 = New Client FD

    ; Add New Client to Epoll (Wait-Free/Non-Blocking mode encouraged)
    mov dword [ep_event], 1     ; EPOLLIN
    mov qword [ep_event + 4], r15
    mov rax, 233                ; sys_epoll_ctl
    mov rdi, [epoll_fd]
    mov rsi, 1                  ; EPOLL_CTL_ADD
    mov rdx, r15
    lea r10, [ep_event]
    syscall
    jmp .next_event

.handle_client:
    ; Read raw HTTP request into shared buffer
    mov rax, 0                  ; sys_read
    mov rdi, r14
    lea rsi, [http_buffer]
    mov rdx, 4096
    syscall
    cmp rax, 0
    jle .close_client           ; Close if EOF (0) or error (-1)

    ; Dispatch to Routing API
    mov rdi, r14                ; rdi = FD
    lea rsi, [http_buffer]      ; rsi = Request Pointer
    mov rdx, rax                ; rdx = Bytes Read
    call route_api

.close_client:
    mov rax, 3                  ; sys_close
    mov rdi, r14
    syscall

.next_event:
    inc r13                     ; Advance to next event in batch
    jmp .process_events

.fatal_error:
    ; Print error and exit with code 1
    mov rax, 1
    mov rdi, 1
    lea rsi, [msg_err_sock]
    mov rdx, msg_err_sock_l
    syscall
    mov rax, 60                 ; sys_exit
    mov rdi, 1
    syscall