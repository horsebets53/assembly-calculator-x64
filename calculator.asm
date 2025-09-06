; ============================================================================
;                        		Assembly Calculator
;                               Part 2: MAIN MODULE
; ============================================================================

option casemap:none

INCLUDE common.inc

; --- Imports from C library ---
EXTERN printf:PROC
EXTERN fgets:PROC
EXTERN fflush:PROC
EXTERN stdin:QWORD
EXTERN stdout:QWORD

; --- Imports from our lexer module ---
EXTERN tokenize:PROC
EXTERN print_tokens:PROC
EXTERN tokens_array:BYTE            
EXTERN TOKEN_NUMBER:ABS
EXTERN TOKEN_PLUS:ABS
EXTERN TOKEN_MINUS:ABS
EXTERN TOKEN_MUL:ABS
EXTERN TOKEN_DIV:ABS
EXTERN TOKEN_UNARY_MINUS:ABS
EXTERN TOKEN_LPAREN:ABS
EXTERN TOKEN_RPAREN:ABS

; --- Imports from evaluator module ---
EXTERN evaluate_rpn:PROC
EXTERN rpn_queue:PROC

; --- Global error strings needed by the lexer ---
PUBLIC error_str_ptr, err_max_tokens_ptr

.DATA
    prompt          DB  '> ', 0
    format_lf       DB  10, 0
    error_str       DB  'Error: Invalid character ''%c'' found.', 10, 0
    err_max_tokens  DB  'Error: Expression is too long (max 64 tokens).', 10, 0
    
    error_str_ptr       DQ error_str
    err_max_tokens_ptr  DQ err_max_tokens
    
    debug_rpn       DB  'RPN Output:', 10, 0
    result_str      DB  'Result: %f', 10, 0
    eval_error_str  DB  'Error: Invalid expression (check for missing operands or division by zero)', 10, 0

.DATA?
    input_buffer    BYTE 256 DUP(?)
    op_stack        Token 64 DUP(<>)
    op_stack_top    QWORD ?

.CODE

; ----------------------------------------------------------------------------
; get_precedence - Returns precedence of an operator
; Input: RAX = token type
; Output: RAX = precedence (0, 1, 2, or 3)
; ----------------------------------------------------------------------------
get_precedence PROC
    cmp     rax, TOKEN_PLUS
    jne     gp_check_minus
    mov     rax, 1
    ret
    
gp_check_minus:
    cmp     rax, TOKEN_MINUS
    jne     gp_check_mul
    mov     rax, 1
    ret
    
gp_check_mul:
    cmp     rax, TOKEN_MUL
    jne     gp_check_div
    mov     rax, 2
    ret
    
gp_check_div:
    cmp     rax, TOKEN_DIV
    jne     gp_check_unary
    mov     rax, 2
    ret
    
gp_check_unary:
    cmp     rax, TOKEN_UNARY_MINUS
    jne     gp_zero
    mov     rax, 3
    ret
    
gp_zero:
    xor     rax, rax
    ret
get_precedence ENDP

; ----------------------------------------------------------------------------
; op_stack_push - Push token onto operator stack
; Input: RBX = pointer to Token to push
; Preserves: All registers except RAX
; ----------------------------------------------------------------------------
op_stack_push PROC
    push    rdx
    
    mov     rax, [op_stack_top]
    imul    rax, SIZEOF Token
    lea     rdx, op_stack
    add     rdx, rax
    
    ; Copy token type
    mov     rax, [rbx].Token.tok_type
    mov     [rdx].Token.tok_type, rax
    
    ; Copy token value
    movsd   xmm0, [rbx].Token.tok_value
    movsd   [rdx].Token.tok_value, xmm0
    
    inc     qword ptr [op_stack_top]
    
    pop     rdx
    ret
op_stack_push ENDP

; ----------------------------------------------------------------------------
; op_stack_pop - Pop token from operator stack to output
; Input: R15 = current output index
; Output: R15 = incremented output index
; Preserves: All other registers
; ----------------------------------------------------------------------------
op_stack_pop PROC
    push    rax
    push    rdx
    push    rcx
    
    mov     rax, [op_stack_top]
    test    rax, rax
    jz      osp_done                    ; Stack empty
    
    ; Get stack top
    dec     qword ptr [op_stack_top]
    mov     rax, [op_stack_top]
    imul    rax, SIZEOF Token
    lea     rdx, op_stack
    add     rdx, rax
    
    ; Copy to output
    mov     rax, r15
    imul    rax, SIZEOF Token
    lea     rcx, rpn_queue
    add     rcx, rax
    
    mov     rax, [rdx].Token.tok_type
    mov     [rcx].Token.tok_type, rax
    movsd   xmm0, [rdx].Token.tok_value
    movsd   [rcx].Token.tok_value, xmm0
    
    inc     r15
    
osp_done:
    pop     rcx
    pop     rdx
    pop     rax
    ret
op_stack_pop ENDP

; ----------------------------------------------------------------------------
; op_stack_peek - Look at top of operator stack without popping
; Output: RAX = token type (0 if empty)
; Preserves: All other registers
; ----------------------------------------------------------------------------
op_stack_peek PROC
    push    rdx
    
    mov     rax, [op_stack_top]
    test    rax, rax
    jz      osp_empty
    
    dec     rax
    imul    rax, SIZEOF Token
    lea     rdx, op_stack
    add     rdx, rax
    
    mov     rax, [rdx].Token.tok_type
    pop     rdx
    ret
    
osp_empty:
    xor     rax, rax
    pop     rdx
    ret
op_stack_peek ENDP

; ----------------------------------------------------------------------------
; copy_token_to_output - Copy token to RPN output queue
; Input: RBX = pointer to source token, R15 = output index
; Output: R15 = incremented output index
; Preserves: All other registers
; ----------------------------------------------------------------------------
copy_token_to_output PROC
    push    rax
    push    rdx
    
    mov     rax, r15
    imul    rax, SIZEOF Token
    lea     rdx, rpn_queue
    add     rdx, rax
    
    mov     rax, [rbx].Token.tok_type
    mov     [rdx].Token.tok_type, rax
    movsd   xmm0, [rbx].Token.tok_value
    movsd   [rdx].Token.tok_value, xmm0
    
    inc     r15
    
    pop     rdx
    pop     rax
    ret
copy_token_to_output ENDP

; ----------------------------------------------------------------------------
; parse_to_rpn - Convert infix tokens to RPN using Shunting-yard algorithm
; Input: RDI = pointer to input tokens, RSI = token count
; Output: RAX = count of tokens in rpn_queue
; ----------------------------------------------------------------------------
parse_to_rpn PROC
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    
    ; Initialize
    mov     r12, rdi                    ; r12 = input tokens
    mov     r13, rsi                    ; r13 = token count
    xor     r14, r14                    ; r14 = input index
    xor     r15, r15                    ; r15 = output index
    mov     qword ptr [op_stack_top], 0
    
parse_loop:
    cmp     r14, r13
    jge     parse_flush_stack
    
    ; Get current token pointer
    mov     rax, r14
    imul    rax, SIZEOF Token
    add     rax, r12
    mov     rbx, rax                    ; rbx = current token pointer
    
    ; Get token type
    mov     rax, [rbx].Token.tok_type
    
    ; Process by type
    cmp     rax, TOKEN_NUMBER
    je      handle_number
    
    cmp     rax, TOKEN_LPAREN
    je      handle_lparen
    
    cmp     rax, TOKEN_RPAREN
    je      handle_rparen
    
    ; It's an operator
    jmp     handle_operator

handle_number:
    ; Copy number to output
    call    copy_token_to_output
    jmp     parse_next

handle_lparen:
    ; Push left paren to stack
    call    op_stack_push
    jmp     parse_next

handle_rparen:
    ; Pop until left paren
rparen_loop:
    call    op_stack_peek
    test    rax, rax
    jz      parse_next                  ; Stack empty
    
    cmp     rax, TOKEN_LPAREN
    je      rparen_found
    
    call    op_stack_pop
    jmp     rparen_loop

rparen_found:
    ; Remove left paren
    dec     qword ptr [op_stack_top]
    jmp     parse_next

handle_operator:
    ; Get current operator precedence
    mov     rax, [rbx].Token.tok_type
    push    rbx                         ; Save token pointer
    call    get_precedence
    mov     r10, rax                    ; r10 = current precedence
    pop     rbx                         ; Restore token pointer

operator_loop:
    call    op_stack_peek
    test    rax, rax
    jz      operator_push               ; Stack empty
    
    cmp     rax, TOKEN_LPAREN
    je      operator_push               ; Don't pop left paren
    
    ; Get stack top precedence
    push    rbx
    push    r10
    call    get_precedence
    mov     r11, rax                    ; r11 = stack precedence
    pop     r10
    pop     rbx
    
    ; Compare precedences
    mov     rax, [rbx].Token.tok_type
    cmp     rax, TOKEN_UNARY_MINUS
    je      check_right_assoc
    
    ; Left associative: pop if stack_prec >= current_prec
    cmp     r11, r10
    jl      operator_push
    jmp     pop_and_continue

check_right_assoc:
    ; Right associative: pop if stack_prec > current_prec
    cmp     r11, r10
    jle     operator_push

pop_and_continue:
    call    op_stack_pop
    jmp     operator_loop

operator_push:
    call    op_stack_push

parse_next:
    inc     r14
    jmp     parse_loop

parse_flush_stack:
    ; Pop all remaining operators
flush_loop:
    mov     rax, [op_stack_top]
    test    rax, rax
    jz      parse_done
    
    call    op_stack_pop
    jmp     flush_loop

parse_done:
    mov     rax, r15                    ; Return output count
    
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rsp, rbp
    pop     rbp
    ret
parse_to_rpn ENDP

main PROC PUBLIC
    push    rbp
    mov     rbp, rsp
    sub     rsp, 32

main_loop:
    lea     rdi, prompt
    xor     rax, rax
    call    printf

    mov     rdi, [stdout]
    call    fflush

    lea     rdi, input_buffer
    mov     rsi, 256
    mov     rdx, [stdin]
    call    fgets
    
    test    rax, rax
    jz      exit_program

    lea     rdi, input_buffer
    lea     rsi, tokens_array
    call    tokenize
    
    cmp     rax, -1
    je      main_loop
    
    ; Save token count
    mov     rbx, rax
    
    ; Convert to RPN
    lea     rdi, tokens_array
    mov     rsi, rbx
    call    parse_to_rpn
    
    ; Save RPN count
    mov     rbx, rax
    
    ; Evaluate RPN expression
    lea     rdi, rpn_queue
    mov     rsi, rbx
    call    evaluate_rpn
    
    ; Check for errors
    test    rax, rax
    jz      eval_error
    
    ; Print result
    lea     rdi, result_str
    mov     rax, 1                      ; printf needs RAX=1 for 1 float arg
    call    printf
    jmp     main_loop

eval_error:
    lea     rdi, eval_error_str
    xor     rax, rax
    call    printf
    jmp     main_loop

exit_program:
    xor     eax, eax
    add     rsp, 32
    mov     rsp, rbp
    pop     rbp
    ret
main ENDP

END