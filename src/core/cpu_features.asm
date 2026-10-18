; -----------------------------------------------------------------------------
; Module: src/core/cpu_features.asm
; Project: La Roca Micro-PubSub
; Responsibility: CPUID/XGETBV-based CPU feature detection. Sets the global
;                 avx2_supported flag so hot loops can pick SIMD vs scalar path.
; -----------------------------------------------------------------------------
%include "config.inc"

extern avx2_supported

section .text
    global detect_cpu_features

; -----------------------------------------------------------------------------
; detect_cpu_features: Sets avx2_supported = 1 if CPU + OS support AVX2.
; Clobbers volatile registers only (RAX, RBX, RCX, RDX).
; -----------------------------------------------------------------------------
detect_cpu_features:
    push rbx                    ; CPUID clobbers RBX
    push rcx
    push rdx

    mov byte [avx2_supported], 0

    ; --- 1. CPUID leaf 1: require AVX (ECX bit 28) + OSXSAVE (ECX bit 27) ---
    mov eax, 1
    cpuid
    mov edx, ecx
    and edx, 0x18000000         ; (1 << 28) | (1 << 27)
    cmp edx, 0x18000000
    jne .done

    ; --- 2. XGETBV(0): XCR0 must have SSE + AVX state enabled (bits 1:2) ---
    xor ecx, ecx
    xgetbv                      ; EDX:EAX = XCR0
    and eax, 0x6                ; XCR0.SSE (bit 1) | XCR0.AVX (bit 2)
    cmp eax, 0x6
    jne .done

    ; --- 3. CPUID leaf 7 subleaf 0: require AVX2 (EBX bit 5) ---
    mov eax, 7
    xor ecx, ecx
    cpuid
    test ebx, 0x20              ; AVX2
    jz .done

    mov byte [avx2_supported], 1

.done:
    pop rdx
    pop rcx
    pop rbx
    ret
