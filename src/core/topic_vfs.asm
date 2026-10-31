; -----------------------------------------------------------------------------
; Module: src/core/topic_vfs.asm
; Project: La Roca Micro-PubSub
; Responsibility: Dynamic Auto-Provisioning & "Disk Authority" Memory Mapping.
;                 Handles file creation, geometry enforcement, and persistence.
; -----------------------------------------------------------------------------
%include "config.inc"

extern rt_msg_size
extern rt_max_messages
extern rt_key_size              ; NEW: Global configuration for key size
extern registry_insert

section .data
    dir_topics      db "topics", 0      ; Directory name for mkdir
    topics_slash    db "topics/", 0     ; Prefix for topic paths
    topic_ext       db ".log", 0        ; Standard topic file extension
    HEADER_SIZE     equ 256             ; Reserved space for metadata
    DIR_MODE        equ 0755o           ; Permissions: rwxr-xr-x

section .bss
    topic_path_buf  resb 128            ; Buffer to construct "topics/name.log"

section .text
    global vfs_init
    global create_new_topic
    global flush_topic
    global build_path_from_name

; -----------------------------------------------------------------------------
; vfs_init: Ensures the data directory exists.
; -----------------------------------------------------------------------------
vfs_init:
    push rbp
    mov rbp, rsp
    mov rax, SYS_MKDIR              ; syscall 83
    lea rdi, [rel dir_topics]
    mov rsi, DIR_MODE
    syscall
    pop rbp
    ret

; -----------------------------------------------------------------------------
; build_path_from_name: Constructs the full string "topics/[name].log"
; -----------------------------------------------------------------------------
build_path_from_name:
    lea rdi, [topic_path_buf]
    lea rsi, [topics_slash]
    mov rcx, 7                      ; Copy "topics/"
    cld
    rep movsb

    mov rsi, r12
    mov rcx, 16                     ; Copy the 16-byte topic name
.l1:
    lodsb
    test al, al
    jz .l2
    stosb
    loop .l1
.l2:
    lea rsi, [topic_ext]            ; Append ".log"
    mov rcx, 5
    rep movsb
    ret

; -----------------------------------------------------------------------------
; create_new_topic: Maps a topic file and enforces Disk Authority.
; Input:  RDI = Pointer to 16-byte null-padded topic name
; Output: RAX = Mmap Base Pointer (0 on failure)
;         RDX = Topic File Descriptor (0 on failure, kept open for sys_sendfile)
; -----------------------------------------------------------------------------
create_new_topic:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15

    mov r13, -1                 ; Sentinel: no FD opened yet (used by .fail)

    mov r12, rdi
    call build_path_from_name

    ; 1. OPEN (O_RDWR | O_CREAT)
    mov rax, SYS_OPEN
    lea rdi, [topic_path_buf]
    mov rsi, 66                     ; O_RDWR | O_CREAT
    mov rdx, 0644o
    syscall
    test rax, rax
    js .fail
    mov r13, rax

    ; 2. LSEEK to SEEK_END
    mov rax, SYS_LSEEK
    mov rdi, r13
    xor rsi, rsi
    mov rdx, 2                      ; SEEK_END
    syscall
    mov r15, rax                    ; R15 = Current file size

    ; 3. CHECK IF FILE ALREADY EXISTS
    test r15, r15
    jnz .map_existing

    ; --- PROVISIONING (For new files) ---
    mov rax, [rt_max_messages]
    mov rbx, [rt_msg_size]
    mul rbx
    add rax, HEADER_SIZE
    mov r15, rax

    mov rax, SYS_FTRUNCATE          ; Resize file
    mov rdi, r13
    mov rsi, r15
    syscall

    mov r14, 1                      ; Flag: New file
    jmp .do_mmap

.map_existing:
    xor r14, r14                    ; Flag: Existing file

.do_mmap:
    ; 4. MEMORY MAPPING
    mov rax, SYS_MMAP
    xor rdi, rdi
    mov rsi, r15
    mov rdx, 3                      ; PROT_READ | PROT_WRITE
    mov r10, 1                      ; MAP_SHARED
    mov r8, r13
    xor r9, r9
    syscall
    cmp rax, -1
    je .fail
    mov r15, rax                    ; R15 = Mmap Base Pointer

    ; 5. WRITE HEADER (Only for new files)
    test r14, r14
    jz .enforce_authority

    mov qword [r15 + 0], 0          ; Tail = 0
    mov rbx, [rt_msg_size]
    mov qword [r15 + 8], rbx        ; Tattoo MsgSize
    mov rbx, [rt_max_messages]
    mov qword [r15 + 16], rbx       ; Tattoo MaxMsgs

    ; --- NEW: Tattoo Key Size ---
    mov rbx, [rt_key_size]
    mov qword [r15 + 24], rbx       ; Offset 24: KeySize

.enforce_authority:
    ; =========================================================================
    ; 🛡️ DISK AUTHORITY ENFORCEMENT
    ; =========================================================================
    ; We synchronize RAM globals with the "Absolute Truth" from the disk header.
    mov rax, [r15 + 8]              ; Load true MsgSize from mmap
    mov [rt_msg_size], rax          ; Overwrite RAM global

    mov rax, [r15 + 16]             ; Load true MaxMsgs from mmap
    mov [rt_max_messages], rax      ; Overwrite RAM global

    ; --- NEW: Enforce Key Size ---
    mov rax, [r15 + 24]             ; Load true KeySize from mmap
    mov [rt_key_size], rax          ; Overwrite RAM global

.register:
    ; Keep the FD open for zero-copy sys_sendfile delivery.
    ; Register in engine (name, mmap base, fd)
    mov rdi, r12
    mov rsi, r15
    mov rdx, r13
    call registry_insert

    mov rax, r15                    ; RAX = Mmap Base (Success)
    mov rdx, r13                    ; RDX = Topic FD
    jmp .exit

.fail:
    ; Close the topic FD if it was opened before the failure, to avoid leaking
    ; a descriptor on every failed create_new_topic (the open happens before the
    ; mmap step that can still fail).
    cmp r13, -1
    je .fail_no_fd
    mov rax, SYS_CLOSE
    mov rdi, r13
    syscall
.fail_no_fd:
    xor rax, rax
    xor rdx, rdx
.exit:
    pop r15
    pop r14
    pop r13
    pop r12
    leave
    ret

; -----------------------------------------------------------------------------
; flush_topic: MSYNC based on tattooed metadata
; -----------------------------------------------------------------------------
flush_topic:
    mov rbx, [rdi + 8]
    mov rcx, [rdi + 16]
    mov rax, rbx
    mul rcx
    add rax, HEADER_SIZE
    mov rsi, rax
    mov rax, SYS_MSYNC
    mov rdx, 4
    syscall
    ret