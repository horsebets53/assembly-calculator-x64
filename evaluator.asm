; ============================================================================
;                        		Assembly Calculator
;                               Part 3: EVALUATOR MODULE
; ============================================================================

option casemap:none

INCLUDE common.inc

; --- Imports from lexer module ---
EXTERN TOKEN_NUMBER:ABS
EXTERN TOKEN_PLUS:ABS
EXTERN TOKEN_MINUS:ABS
EXTERN TOKEN_MUL:ABS
EXTERN TOKEN_DIV:ABS
EXTERN TOKEN_UNARY_MINUS:ABS
EXTERN MAX_TOKENS:ABS

; --- Exports for other modules ---
PUBLIC evaluate_rpn
PUBLIC rpn_queue

; --- Constants ---
MAX_STACK_SIZE      EQU 64

.DATA?
    rpn_queue           Token 64 DUP(<>)
    operand_stack       REAL8 MAX_STACK_SIZE DUP(?)
    operand_stack_pointer QWORD ?

.CODE

; ----------------------------------------------------------------------------
; stack_push - Push value onto operand stack
; Input: XMM0 = value to push
; Output: RAX = 1 on success, 0 on stack overflow
; ----------------------------------------------------------------------------
stack_push PROC
    mov     rax, [operand_stack_pointer]
    cmp     rax, MAX_STACK_SIZE
    jge     sp_overflow
    
    ; Push value
    imul    rax, 8                      ; REAL8 = 8 bytes
    lea     rdx, operand_stack
    add     rdx, rax
    movsd   [rdx], xmm0
    
    inc     qword ptr [operand_stack_pointer]
    mov     rax, 1
    ret
    
sp_overflow:
    xor     rax, rax
    ret
stack_push ENDP

; ----------------------------------------------------------------------------
; stack_pop - Pop value from operand stack
; Output: XMM0 = popped value, RAX = 1 on success, 0 on underflow
; ----------------------------------------------------------------------------
stack_pop PROC
    mov     rax, [operand_stack_pointer]
    test    rax, rax
    jz      sp_underflow
    
    ; Pop value
    dec     qword ptr [operand_stack_pointer]
    mov     rax, [operand_stack_pointer]
    imul    rax, 8
    lea     rdx, operand_stack
    add     rdx, rax
    movsd   xmm0, [rdx]
    
    mov     rax, 1
    ret
    
sp_underflow:
    xor     rax, rax
    xorpd   xmm0, xmm0
    ret
stack_pop ENDP

; ----------------------------------------------------------------------------
; evaluate_rpn - Evaluate RPN expression
; Input: RDI = pointer to RPN tokens, RSI = token count
; Output: XMM0 = result, RAX = 1 on success, 0 on error
; ----------------------------------------------------------------------------
evaluate_rpn PROC
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    
    ; Initialize
    mov     r12, rdi                    ; r12 = token array
    mov     r13, rsi                    ; r13 = token count
    xor     r14, r14                    ; r14 = current index
    mov     qword ptr [operand_stack_pointer], 0
    mov     rbx, r12                    ; rbx = current token pointer
    
eval_loop:
    cmp     r14, r13
    jge     eval_finish
    
    ; Get current token
    ; rbx is updated at end of loop (strength reduction)
    
    mov     rax, [rbx].Token.tok_type
    
    ; Process based on type
    cmp     rax, TOKEN_NUMBER
    je      eval_number
    
    cmp     rax, TOKEN_PLUS
    je      eval_plus
    
    cmp     rax, TOKEN_MINUS
    je      eval_minus
    
    cmp     rax, TOKEN_MUL
    je      eval_mul
    
    cmp     rax, TOKEN_DIV
    je      eval_div
    
    cmp     rax, TOKEN_UNARY_MINUS
    je      eval_unary_minus
    
    ; Unknown token, skip
    jmp     eval_next

eval_number:
    ; Push number onto stack
    movsd   xmm0, [rbx].Token.tok_value
    call    stack_push
    test    rax, rax
    jz      eval_error                  ; Stack overflow
    jmp     eval_next

eval_plus:
    ; Pop two operands and add
    call    stack_pop
    test    rax, rax
    jz      eval_error                  ; Underflow
    movsd   xmm1, xmm0                  ; Second operand
    
    call    stack_pop
    test    rax, rax
    jz      eval_error                  ; Underflow
    
    addsd   xmm0, xmm1                  ; xmm0 = first + second
    
    call    stack_push
    test    rax, rax
    jz      eval_error
    jmp     eval_next

eval_minus:
    ; Pop two operands and subtract
    call    stack_pop
    test    rax, rax
    jz      eval_error
    movsd   xmm1, xmm0                  ; Second operand
    
    call    stack_pop
    test    rax, rax
    jz      eval_error
    
    subsd   xmm0, xmm1                  ; xmm0 = first - second
    
    call    stack_push
    test    rax, rax
    jz      eval_error
    jmp     eval_next

eval_mul:
    ; Pop two operands and multiply
    call    stack_pop
    test    rax, rax
    jz      eval_error
    movsd   xmm1, xmm0                  ; Second operand
    
    call    stack_pop
    test    rax, rax
    jz      eval_error
    
    mulsd   xmm0, xmm1                  ; xmm0 = first * second
    
    call    stack_push
    test    rax, rax
    jz      eval_error
    jmp     eval_next

eval_div:
    ; Pop two operands and divide
    call    stack_pop
    test    rax, rax
    jz      eval_error
    movsd   xmm1, xmm0                  ; Second operand (divisor)
    
    call    stack_pop
    test    rax, rax
    jz      eval_error
    
    divsd   xmm0, xmm1                  ; xmm0 = first / second
    
    call    stack_push
    test    rax, rax
    jz      eval_error
    jmp     eval_next

eval_unary_minus:
    ; Pop one operand and negate
    call    stack_pop
    test    rax, rax
    jz      eval_error
    
    ; Negate by XORing the sign bit
    mov     rax, 8000000000000000h      ; Sign bit mask
    push    rax
    movsd   [rsp], xmm0
    xor     [rsp], rax
    movsd   xmm0, [rsp]
    add     rsp, 8
    
    call    stack_push
    test    rax, rax
    jz      eval_error
    jmp     eval_next

eval_next:
    add     rbx, SIZEOF Token
    inc     r14
    jmp     eval_loop

eval_finish:
    ; Check that exactly one value remains on stack
    mov     rax, [operand_stack_pointer]
    cmp     rax, 1
    jne     eval_error
    
    ; Pop final result
    call    stack_pop
    ; Result is already in XMM0, RAX = 1
    jmp     eval_done

eval_error:
    xor     rax, rax                    ; Error flag
    xorpd   xmm0, xmm0                  ; Clear result

eval_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rsp, rbp
    pop     rbp
    ret
evaluate_rpn ENDP

END