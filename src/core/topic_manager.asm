; -----------------------------------------------------------------------------
; Module: src/core/topic_manager.asm
; Project: La Roca Micro-PubSub
; Responsibility: High-level Topic lifecycle and Startup Scanning.
;                 Auto-discovers existing topic files on boot to enforce
;                 Disk Authority and immutable geometry.
; -----------------------------------------------------------------------------
%include "config.inc"

extern create_new_topic

section .data
    topics_dir      db "topics", 0

section .bss
    dir_fd          resq 1              ; Directory File Descriptor
    dents_buf       resb 4096           ; Buffer for linux_dirent64 structs
    temp_name_buf   resb 16             ; 16-byte null-padded topic name buffer

section .text
    global init_topics

; -----------------------------------------------------------------------------
; init_topics: Scans the /topics directory and registers existing logs.
; -----------------------------------------------------------------------------
init_topics:
    push rbp
    mov rbp, rsp
    push r12
    push r13

    ; =========================================================================
    ; 1. DIRECTORY PROVISIONING
    ; =========================================================================
    ; Ensure the "topics" directory exists (sys_mkdir)
    mov rax, SYS_MKDIR
    lea rdi, [topics_dir]
    mov rsi, 0755o              ; Permissions: rwxr-xr-x
    syscall

    ; =========================================================================
    ; 2. DIRECTORY SCANNING (O_DIRECTORY)
    ; =========================================================================
    mov rax, SYS_OPEN
    lea rdi, [topics_dir]
    mov rsi, 0x10000            ; O_DIRECTORY flag (Prevents opening non-directories)
    syscall
    js .exit                    ; Jump to exit if sys_open fails
    mov [dir_fd], rax

.scan:
    ; Syscall 217: sys_getdents64 (Get directory entries)
    mov rax, 217
    mov rdi, [dir_fd]
    lea rsi, [dents_buf]
    mov rdx, 4096               ; Read up to 4KB of directory entries
    syscall

    test rax, rax               ; If RAX <= 0, we reached EOF or an error occurred
    jle .close

    mov r12, rax                ; R12 = Total bytes read into dents_buf
    xor r13, r13                ; R13 = Current offset within dents_buf

.loop:
    ; linux_dirent64 structure offset math:
    ; d_name starts at offset 19 (8 ino + 8 off + 2 reclen + 1 type)
    lea rdx, [dents_buf + r13 + 19]

    ; Ignore relative path indicators ('.' and '..')
    cmp byte [rdx], '.'
    je .next

    ; Register the discovered file into the engine
    call _reg_from_scan

.next:
    ; d_reclen (record length) is a 16-bit integer at offset 16
    movzx rax, word [dents_buf + r13 + 16]
    add r13, rax                ; Advance to the next linux_dirent64 struct

    cmp r13, r12                ; Have we processed all bytes in the buffer?
    jl .loop
    jmp .scan                   ; Fetch the next batch from the kernel

.close:
    mov rax, SYS_CLOSE
    mov rdi, [dir_fd]
    syscall
.exit:
    pop r13
    pop r12
    leave
    ret

; -----------------------------------------------------------------------------
; _reg_from_scan: Parses the filename, strips ".log", and mounts the topic.
; Input: RDX = Pointer to null-terminated filename from getdents64
; -----------------------------------------------------------------------------
_reg_from_scan:
    ; Zero out the 16-byte temporary name buffer using 64-bit moves
    lea rdi, [temp_name_buf]
    xor rax, rax
    mov [rdi], rax
    mov [rdi + 8], rax

    mov rsi, rdx                ; RSI = Source filename

.copy_char:
    lodsb                       ; Load byte from [RSI] into AL
    cmp al, '.'                 ; Stop copying if we hit the extension dot
    je .dispatch
    test al, al                 ; Stop copying if we hit the null terminator
    jz .dispatch
    stosb                       ; Store AL into [RDI]
    jmp .copy_char

.dispatch:
    lea rdi, [temp_name_buf]
    ; create_new_topic will read the file, enforce Disk Authority, and map it
    call create_new_topic
    ret