; ============================================================================
;                        		Assembly Calculator
;                               Part 2: MAIN MODULE
; ============================================================================

option casemap:none

INCLUDE common.inc
INCLUDE runtime.inc

; --- Imports from C library ---
EXTERN printf:PROC
EXTERN fgets:PROC
EXTERN fflush:PROC
EXTERN stdin:QWORD
EXTERN stdout:QWORD

; --- Imports from our lexer module ---
EXTERN tokenize:PROC
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
EXTERN rpn_queue:QWORD

; --- Global error strings needed by the lexer ---
PUBLIC error_str_ptr, err_max_tokens_ptr, err_bad_number_ptr

; --- Limits ---
INPUT_BUFFER_SIZE   EQU 256
OP_STACK_SIZE       EQU 64

.DATA
    prompt          DB  '> ', 0
    format_lf       DB  10, 0
    error_str       DB  'Error: Invalid character ''%c'' found.', 10, 0
    err_max_tokens  DB  'Error: Expression is too long (max 64 tokens).', 10, 0
    err_bad_number  DB  'Error: Invalid number.', 10, 0
    
    error_str_ptr       DQ error_str
    err_max_tokens_ptr  DQ err_max_tokens
    err_bad_number_ptr  DQ err_bad_number
    
    result_str      DB  'Result: %f', 10, 0
    eval_error_str  DB  'Error: Invalid expression (check for missing or extra operands).', 10, 0
    syntax_error_str DB 'Error: Unbalanced parentheses.', 10, 0
    err_line_too_long DB 'Error: Input line is too long (max 254 characters).', 10, 0

.DATA?
    input_buffer    BYTE INPUT_BUFFER_SIZE DUP(?)
    op_stack        Token OP_STACK_SIZE DUP(<>)
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
; Output: RAX = 1 on success, 0 if the stack is full
; Preserves: All registers except RAX
; ----------------------------------------------------------------------------
op_stack_push PROC
    push    rdx
    
    mov     rax, [op_stack_top]
    cmp     rax, OP_STACK_SIZE
    jge     osp_push_full
    
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
    
    mov     eax, 1
    pop     rdx
    ret

osp_push_full:
    xor     eax, eax
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
; Output: RAX = count of tokens in rpn_queue, or -1 on a syntax error
; ----------------------------------------------------------------------------
parse_to_rpn PROC
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8                      ; five saves leave RSP 8 mod 16; calls
                                        ; need it 16-byte aligned (SysV ABI)
    
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
    test    rax, rax
    jz      parse_error                 ; Operator stack full
    jmp     parse_next

handle_rparen:
    ; Pop until left paren
rparen_loop:
    call    op_stack_peek
    test    rax, rax
    jz      parse_error                 ; ')' without a matching '('
    
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
    call    get_precedence
    mov     r10, rax                    ; r10 = current precedence

operator_loop:
    call    op_stack_peek
    test    rax, rax
    jz      operator_push               ; Stack empty
    
    cmp     rax, TOKEN_LPAREN
    je      operator_push               ; Don't pop left paren
    
    ; Get stack top precedence
    ; get_precedence only clobbers RAX; no saves or alignment changes needed.
    call    get_precedence
    mov     r11, rax                    ; r11 = stack precedence
    
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
    test    rax, rax
    jz      parse_error                 ; Operator stack full

parse_next:
    inc     r14
    jmp     parse_loop

parse_flush_stack:
    ; Pop all remaining operators
flush_loop:
    mov     rax, [op_stack_top]
    test    rax, rax
    jz      parse_done
    
    ; Anything left must be an operator; a '(' here means it was never closed
    call    op_stack_peek
    cmp     rax, TOKEN_LPAREN
    je      parse_error
    
    call    op_stack_pop
    jmp     flush_loop

parse_done:
    mov     rax, r15                    ; Return output count
    jmp     parse_epilogue

parse_error:
    mov     rax, -1                     ; Syntax error

parse_epilogue:
    lea     rsp, [rbp-40]               ; drop the alignment pad, then restores
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
parse_to_rpn ENDP

; ----------------------------------------------------------------------------
; line_is_complete - Check whether input_buffer holds a whole line
; Output: RAX = 1 if the line is complete, 0 if fgets filled the buffer and
;         stopped in the middle of the line.
; A line without a trailing newline is complete when it ended at end of file,
; which is the normal case for piped input such as: printf '2+2' | ./calculator
; Clobbers: RAX, RCX, RDI
; ----------------------------------------------------------------------------
line_is_complete PROC
    push    rdi
    push    rcx

    ; strlen(input_buffer) - fgets always NUL-terminates what it reads
    lea     rdi, input_buffer
    mov     rcx, INPUT_BUFFER_SIZE
    xor     eax, eax
    cld
    repne   scasb                       ; RDI = input_buffer + strlen + 1

    lea     rax, input_buffer
    sub     rdi, rax
    dec     rdi                         ; RDI = strlen

    cmp     rdi, INPUT_BUFFER_SIZE-1
    jb      lic_done                    ; buffer not full: line ended at EOF

    ; The buffer is full, so the line is complete only if it ends with '\n'
    lea     rax, input_buffer
    cmp     byte ptr [rax+rdi-1], 10
    je      lic_done

    xor     eax, eax                    ; truncated line
    pop     rcx
    pop     rdi
    ret

lic_done:
    mov     eax, 1
    pop     rcx
    pop     rdi
    ret
line_is_complete ENDP

; ----------------------------------------------------------------------------
; read_line - Print the prompt and read one whole line into input_buffer
; Output: RAX = 1 on success, 0 on end of file
;         Over-long lines are reported and skipped, they never reach the parser.
; ----------------------------------------------------------------------------
read_line PROC
    push    rbp
    mov     rbp, rsp                    ; frame keeps RSP 16-byte aligned

rl_prompt:
    lea     rdi, prompt
    xor     eax, eax
    CRT_CALL printf

    mov     rdi, [stdout]
    CRT_CALL fflush

rl_read:
    lea     rdi, input_buffer
    mov     rsi, INPUT_BUFFER_SIZE
    mov     rdx, [stdin]
    CRT_CALL fgets

    test    rax, rax
    jz      rl_eof                      ; end of file

    call    line_is_complete
    test    rax, rax
    jnz     rl_done                     ; whole line is in the buffer

    ; The line did not fit: report it and drop the remainder, otherwise the
    ; tail would be silently evaluated as a second, unrelated expression.
    lea     rdi, err_line_too_long
    xor     eax, eax
    CRT_CALL printf
rl_drain:
    lea     rdi, input_buffer
    mov     rsi, INPUT_BUFFER_SIZE
    mov     rdx, [stdin]
    CRT_CALL fgets
    test    rax, rax
    jz      rl_eof
    call    line_is_complete
    test    rax, rax
    jz      rl_drain
    jmp     rl_prompt                   ; discarded: ask for the next line

rl_done:
    mov     eax, 1
    pop     rbp
    ret

rl_eof:
    xor     eax, eax
    pop     rbp
    ret
read_line ENDP

IFDEF __WINDOWS__
calculator_main PROC PUBLIC
ELSE
main PROC PUBLIC
ENDIF
    push    rbp
    mov     rbp, rsp
    push    rbx                         ; RBX/R12 are callee-saved: the C run
    push    r12                         ; time expects them back unchanged
    sub     rsp, 16                     ; keep RSP 16-byte aligned for calls

main_loop:
    call    read_line
    test    rax, rax
    jz      exit_program                ; end of file (or line discarded)

    lea     rdi, input_buffer
    lea     rsi, tokens_array
    call    tokenize
    
    cmp     rax, -1
    je      main_loop                   ; lexer already reported the error
    
    ; Save token count
    mov     rbx, rax
    test    rbx, rbx
    jz      main_loop                   ; empty line: nothing to evaluate
    
    ; Convert to RPN
    lea     rdi, tokens_array
    mov     rsi, rbx
    call    parse_to_rpn
    
    cmp     rax, -1
    je      syntax_error
    
    ; Save RPN count
    mov     r12, rax
    
    ; Evaluate RPN expression
    lea     rdi, rpn_queue
    mov     rsi, r12
    call    evaluate_rpn
    
    ; Check for errors
    test    rax, rax
    jz      eval_error
    
    ; Print result
    lea     rdi, result_str
    mov     eax, 1                      ; printf needs AL=1 for 1 float arg
    CRT_CALL printf
    jmp     main_loop

syntax_error:
    lea     rdi, syntax_error_str
    xor     eax, eax
    CRT_CALL printf
    jmp     main_loop

eval_error:
    lea     rdi, eval_error_str
    xor     eax, eax
    CRT_CALL printf
    jmp     main_loop

exit_program:
    xor     eax, eax
    lea     rsp, [rbp-16]
    pop     r12
    pop     rbx
    pop     rbp
    ret
IFDEF __WINDOWS__
calculator_main ENDP
ELSE
main ENDP
ENDIF

END