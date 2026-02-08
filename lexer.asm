; ============================================================================
;                        		Assembly Calculator
;                               Part 1: LEXER MODULE
; ============================================================================

option casemap:none

INCLUDE common.inc      ; CORRECTED: No quotes around the filename

; --- Imports needed by this module ---
EXTERN printf:PROC
EXTERN strtod:PROC
EXTERN error_str_ptr:QWORD, err_max_tokens_ptr:QWORD

; --- Exports for other modules ---
PUBLIC tokenize, print_tokens, tokens_array
PUBLIC TOKEN_NUMBER, TOKEN_PLUS, TOKEN_MINUS, TOKEN_MUL, TOKEN_DIV
PUBLIC TOKEN_UNARY_MINUS, TOKEN_LPAREN, TOKEN_RPAREN, MAX_TOKENS

.DATA
    tok_num_str     DB  'TOKEN_NUMBER(value=%f)', 10, 0
    tok_plus_str    DB  'TOKEN_PLUS', 10, 0
    tok_minus_str   DB  'TOKEN_MINUS', 10, 0
    tok_mul_str     DB  'TOKEN_MUL', 10, 0
    tok_div_str     DB  'TOKEN_DIV', 10, 0
    tok_uminus_str  DB  'TOKEN_UNARY_MINUS', 10, 0
    tok_lparen_str  DB  'TOKEN_LPAREN', 10, 0
    tok_rparen_str  DB  'TOKEN_RPAREN', 10, 0
    tok_unknown_str DB  'TOKEN_UNKNOWN', 10, 0

    TOKEN_NULL          EQU 0
    TOKEN_NUMBER        EQU 1
    TOKEN_PLUS          EQU 2
    TOKEN_MINUS         EQU 3
    TOKEN_MUL           EQU 4
    TOKEN_DIV           EQU 5
    TOKEN_UNARY_MINUS   EQU 6
    TOKEN_LPAREN        EQU 7
    TOKEN_RPAREN        EQU 8
    
    MAX_TOKENS          EQU 64

.DATA?
    tokens_array Token MAX_TOKENS DUP(<>)

.CODE

print_tokens PROC
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdi
    mov     r13, rsi
    xor     r14, r14
    mov     rbx, r12

pt_loop:
    cmp     r14, r13
    jge     pt_end

    mov     rax, [rbx].Token.tok_type

    lea     rdi, tok_unknown_str
    cmp     rax, TOKEN_NUMBER
    je      pt_print_num
    cmp     rax, TOKEN_PLUS
    je      pt_print_plus
    cmp     rax, TOKEN_MINUS
    je      pt_print_minus
    cmp     rax, TOKEN_MUL
    je      pt_print_mul
    cmp     rax, TOKEN_DIV
    je      pt_print_div
    cmp     rax, TOKEN_UNARY_MINUS
    je      pt_print_uminus
    cmp     rax, TOKEN_LPAREN
    je      pt_print_lparen
    cmp     rax, TOKEN_RPAREN
    je      pt_print_rparen
    jmp     pt_do_print_zero

pt_print_num:
    lea     rdi, tok_num_str
    movsd   xmm0, [rbx].Token.tok_value
    mov     eax, 1
    jmp     pt_do_print

pt_print_plus:
    lea     rdi, tok_plus_str
    jmp     pt_do_print_zero
pt_print_minus:
    lea     rdi, tok_minus_str
    jmp     pt_do_print_zero
pt_print_mul:
    lea     rdi, tok_mul_str
    jmp     pt_do_print_zero
pt_print_div:
    lea     rdi, tok_div_str
    jmp     pt_do_print_zero
pt_print_uminus:
    lea     rdi, tok_uminus_str
    jmp     pt_do_print_zero
pt_print_lparen:
    lea     rdi, tok_lparen_str
    jmp     pt_do_print_zero
pt_print_rparen:
    lea     rdi, tok_rparen_str

pt_do_print_zero:
    xor     eax, eax
pt_do_print:
    call    printf

    add     rbx, SIZEOF Token
    inc     r14
    jmp     pt_loop

pt_end:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rsp, rbp
    pop     rbp
    ret
print_tokens ENDP

tokenize PROC
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14
    push    r15
    
    mov     r12, rdi
    mov     r13, rsi
    xor     rax, rax
    xor     r14, r14

tok_main_loop:
    movzx   r15, byte ptr [r12]
    cmp     r15b, 0
    je      tok_end
    cmp     r15b, 10
    je      tok_end
    cmp     r15b, 13
    je      tok_end
    cmp     r15b, ' '
    je      tok_next_char
    cmp     r15b, 9
    je      tok_next_char

    cmp     rax, MAX_TOKENS
    jge     tok_error_max_tokens

    cmp     r15b, '0'
    jl      tok_not_a_digit
    cmp     r15b, '9'
    jle     tok_parse_number
tok_not_a_digit:
    cmp     r15b, '.'
    je      tok_parse_number

    cmp     r15b, '+'
    je      tok_is_plus
    cmp     r15b, '*'
    je      tok_is_mul
    cmp     r15b, '/'
    je      tok_is_div
    cmp     r15b, '('
    je      tok_is_lparen
    cmp     r15b, ')'
    je      tok_is_rparen
    cmp     r15b, '-'
    je      tok_is_minus
    
    lea     rdi, error_str_ptr
    mov     rdi, [rdi]
    mov     rsi, r15
    xor     rax, rax
    call    printf
    mov     rax, -1
    jmp     tok_end

tok_parse_number:
    sub     rsp, 32
    mov     [rsp], rax

    mov     rdi, r12
    lea     rsi, [rsp+16]
    call    strtod

    mov     r12, [rsp+16]
    mov     rax, [rsp]
    add     rsp, 32

    mov     [r13].Token.tok_type, TOKEN_NUMBER
    movsd   [r13].Token.tok_value, xmm0
    
    inc     rax
    add     r13, SIZEOF Token
    mov     r14, 1
    jmp     tok_main_loop

tok_is_plus:
    mov     [r13].Token.tok_type, TOKEN_PLUS
    jmp     tok_add_binary_op
tok_is_mul:
    mov     [r13].Token.tok_type, TOKEN_MUL
    jmp     tok_add_binary_op
tok_is_div:
    mov     [r13].Token.tok_type, TOKEN_DIV
    jmp     tok_add_binary_op

tok_is_minus:
    cmp     r14, 0
    je      tok_is_unary_minus
    mov     [r13].Token.tok_type, TOKEN_MINUS
    jmp     tok_add_binary_op

tok_is_unary_minus:
    mov     [r13].Token.tok_type, TOKEN_UNARY_MINUS
    jmp     tok_add_unary_op
tok_is_lparen:
    mov     [r13].Token.tok_type, TOKEN_LPAREN
    jmp     tok_add_unary_op

tok_is_rparen:
    mov     [r13].Token.tok_type, TOKEN_RPAREN
    inc     rax
    add     r13, SIZEOF Token
    mov     r14, 1
    jmp     tok_next_char

tok_add_binary_op:
    inc     rax
    add     r13, SIZEOF Token
    mov     r14, 0
    jmp     tok_next_char

tok_add_unary_op:
    inc     rax
    add     r13, SIZEOF Token
    mov     r14, 0

tok_next_char:
    inc     r12
    jmp     tok_main_loop

tok_error_max_tokens:
    lea     rdi, err_max_tokens_ptr
    mov     rdi, [rdi]
    xor     rax, rax
    call    printf
    mov     rax, -1

tok_end:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    mov     rsp, rbp
    pop     rbp
    ret
tokenize ENDP

END