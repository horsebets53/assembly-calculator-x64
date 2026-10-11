#!/usr/bin/env bash
#
# Regression tests for the assembly calculator.
#
# Usage: tests/test_calculator.sh [path-to-calculator]
# The binary is built automatically when it is missing.

set -u

cd "$(dirname "$0")/.."

BIN="${1:-./calculator}"

if [ ! -x "$BIN" ]; then
    echo "Building $BIN ..."
    ./build.sh > /dev/null || { echo "Build failed." >&2; exit 1; }
fi

PASS=0
FAIL=0

# run <input-with-\n-escapes> -> calculator output with the prompts removed
# Skipped input (empty lines) leaves two prompts back to back on one line,
# hence the repeat in the substitution.
run() {
    printf '%b' "$1" | "$BIN" 2>&1 | sed 's/^\(> \)\+//' | sed '/^[[:space:]]*$/d'
}

check() {
    local name="$1" input="$2" expected="$3" actual
    actual="$(run "$input")"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
        printf 'ok   %-42s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %-42s\n' "$name"
        printf '     input:    %q\n' "$input"
        printf '     expected: %s\n' "$expected"
        printf '     actual:   %s\n' "$actual"
    fi
}

echo "== arithmetic =="
check "addition"              '2+2\n'                  'Result: 4.000000'
check "precedence"            '3+4*2\n'                'Result: 11.000000'
check "parentheses"           '(1+2)*3\n'              'Result: 9.000000'
check "division"              '10/4\n'                 'Result: 2.500000'
check "subtraction is left-assoc"  '2-3-4\n'           'Result: -5.000000'
check "division is left-assoc"     '8/4/2\n'           'Result: 1.000000'
check "mixed precedence"      '2*3+4*5\n'              'Result: 26.000000'
check "nested parentheses"    '2*(3+4)/(1+1)\n'        'Result: 7.000000'
check "unary minus"           '-5+3\n'                 'Result: -2.000000'
check "unary after operator"  '5*-2\n'                 'Result: -10.000000'
check "double unary minus"    '2--3\n'                 'Result: 5.000000'
check "triple negation"       '-(-(-3))\n'             'Result: -3.000000'
check "fractional numbers"    '1.5*2\n'                'Result: 3.000000'
check "scientific notation"   '1e3+1\n'                'Result: 1001.000000'
check "whitespace and tabs"   "  7 \t* 6  \n"          'Result: 42.000000'
check "division by zero"      '1/0\n'                  'Result: inf'

echo "== error handling =="
check "invalid character"     '2&a\n'                  "Error: Invalid character '&' found."
check "unknown operator"      '2^3\n'                  "Error: Invalid character '^' found."
check "malformed number"      '.\n'                    'Error: Invalid number.'
check "unclosed parenthesis"  '2*(3+4\n'               'Error: Unbalanced parentheses.'
check "extra parenthesis"     '2+3)\n'                 'Error: Unbalanced parentheses.'
check "nested unclosed paren" '((1+2)*3\n'             'Error: Unbalanced parentheses.'
check "missing right operand" '5+\n'                   'Error: Invalid expression (check for missing or extra operands).'
check "missing left operand"  '*5\n'                   'Error: Invalid expression (check for missing or extra operands).'
check "two operands in a row" '2 2\n'                  'Error: Invalid expression (check for missing or extra operands).'
check "empty parentheses"     '()\n'                   'Error: Invalid expression (check for missing or extra operands).'
check "too many tokens"       "$(python3 -c 'print("1+"*40+"1")' 2>/dev/null || printf '1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1\n')\n" \
                                                        'Error: Expression is too long (max 64 tokens).'

echo "== input handling =="
check "empty line is ignored" '\n2+2\n'                'Result: 4.000000'
check "several expressions"   '1+1\n2*3\n'             'Result: 2.000000
Result: 6.000000'
check "error then recovery"   '2&a\n2+2\n'             "Error: Invalid character '&' found.
Result: 4.000000"
check "no newline at EOF"     '3*7'                    'Result: 21.000000'
check "over-long line is dropped, session continues" \
      "$(python3 -c 'print("9"*300)' 2>/dev/null || printf '%0.s9' $(seq 1 300))\n1+1\n" \
                                                        'Error: Input line is too long (max 254 characters).
Result: 2.000000'

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
