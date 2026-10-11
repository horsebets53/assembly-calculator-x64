; Win64/UCRT boundary for the platform-independent calculator core.
; Assemble only for Windows: uasm -win64 -D__WINDOWS__ windows.asm
option casemap:none
option prologue:none
option epilogue:none

EXTERN calculator_main:PROC
EXTERN __acrt_iob_func:PROC
EXTERN printf:PROC, strtod:PROC, fgets:PROC, fflush:PROC
PUBLIC stdin, stdout, main
PUBLIC win_printf, win_strtod, win_fgets, win_fflush

.DATA?
    stdin   QWORD ?
    stdout  QWORD ?

.CODE
; Windows CRT calls this with the native Win64 ABI. The private core preserves
; RBX/RBP/R12-R15 and does not touch XMM6-XMM15, but may clobber RDI/RSI.
; Save those two additional Windows nonvolatile registers here.
main PROC FRAME
    push    rdi
    .pushreg rdi
    push    rsi
    .pushreg rsi
    sub     rsp, 40                     ; 32-byte home space + alignment
    .allocstack 40
    .endprolog

    xor     ecx, ecx                    ; UCRT stdin = __acrt_iob_func(0)
    call    __acrt_iob_func
    mov     [stdin], rax
    mov     ecx, 1                      ; UCRT stdout = __acrt_iob_func(1)
    call    __acrt_iob_func
    mov     [stdout], rax
    call    calculator_main

    add     rsp, 40
    pop     rsi
    pop     rdi
    ret
main ENDP

; Supports the formats used by this project: a string, a string + integer,
; or a string + one double. For variadic Win64 calls the double must occupy
; BOTH XMM1 and RDX, since it is argument #2 (not XMM0 as in SysV).
win_printf PROC FRAME
    sub     rsp, 40
    .allocstack 40
    .endprolog
    mov     rcx, rdi
    mov     rdx, rsi
    test    al, al
    jz      printf_ready
    movq    rdx, xmm0
    movaps  xmm1, xmm0
printf_ready:
    call    printf
    add     rsp, 40
    ret
win_printf ENDP

win_strtod PROC FRAME
    sub     rsp, 40
    .allocstack 40
    .endprolog
    mov     rcx, rdi
    mov     rdx, rsi
    call    strtod
    add     rsp, 40
    ret
win_strtod ENDP

win_fgets PROC FRAME
    sub     rsp, 40
    .allocstack 40
    .endprolog
    mov     r8, rdx                     ; FILE * before RDX is overwritten
    mov     rcx, rdi
    mov     edx, esi
    call    fgets
    add     rsp, 40
    ret
win_fgets ENDP

win_fflush PROC FRAME
    sub     rsp, 40
    .allocstack 40
    .endprolog
    mov     rcx, rdi
    call    fflush
    add     rsp, 40
    ret
win_fflush ENDP
END
