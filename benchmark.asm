; ============================================================================
;                        Benchmark for stack_pop
; ============================================================================
; This file is a benchmark to measure the performance of stack_pop.
; It repeatedly calls stack_push and stack_pop in a loop.
;
; Note: This file requires uasm to build, which is not available in the current
; environment. It serves as a documentation of the intended benchmark.

option casemap:none

INCLUDE common.inc

EXTERN stack_push:PROC
EXTERN stack_pop:PROC
EXTERN printf:PROC
EXTERN exit:PROC

.DATA
    test_val    REAL8   1.2345
    fmt_str     DB      "Benchmark done.", 10, 0

.CODE

main PROC
    sub     rsp, 40                     ; Shadow space + alignment

    ; Setup loop counter
    mov     rcx, 100000000              ; 100 million iterations

bench_loop:
    push    rcx                         ; Save counter (rcx is volatile)

    ; Push a value
    movsd   xmm0, [test_val]
    call    stack_push

    ; Pop the value (this is what we are measuring)
    call    stack_pop

    pop     rcx                         ; Restore counter
    dec     rcx
    jnz     bench_loop

    ; Print completion
    lea     rcx, fmt_str
    call    printf

    xor     ecx, ecx
    call    exit
main ENDP

END
