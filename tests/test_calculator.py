#!/usr/bin/env python3
r"""Black-box regression tests, using only Python's standard library.

Linux:   python3 tests/test_calculator.py ./calculator
Windows: py tests\test_calculator.py .\calculator.exe
Wine:    python3 tests/test_calculator.py ./calculator.exe --runner wine64

Each case checks stdout, stderr, exit status and a timeout. Text mode handles
both LF and Windows CRLF output. Set Wine environment variables externally.
"""

import argparse
from pathlib import Path
import re
import subprocess
import sys

INVALID = "Error: Invalid expression (check for missing or extra operands)."
PARENS = "Error: Unbalanced parentheses."
TOKENS = "Error: Expression is too long (max 64 tokens)."
LONG = "Error: Input line is too long (max 254 characters)."

CASES = [
    ("addition", "2+2\n", "Result: 4.000000"),
    ("precedence", "3+4*2\n", "Result: 11.000000"),
    ("parentheses", "(1+2)*3\n", "Result: 9.000000"),
    ("division", "10/4\n", "Result: 2.500000"),
    ("subtraction is left-assoc", "2-3-4\n", "Result: -5.000000"),
    ("division is left-assoc", "8/4/2\n", "Result: 1.000000"),
    ("mixed precedence", "2*3+4*5\n", "Result: 26.000000"),
    ("nested parentheses", "2*(3+4)/(1+1)\n", "Result: 7.000000"),
    ("unary minus", "-5+3\n", "Result: -2.000000"),
    ("unary after operator", "5*-2\n", "Result: -10.000000"),
    ("double unary minus", "2--3\n", "Result: 5.000000"),
    ("triple negation", "-(-(-3))\n", "Result: -3.000000"),
    ("fractional numbers", "1.5*2\n", "Result: 3.000000"),
    ("scientific notation", "1e3+1\n", "Result: 1001.000000"),
    ("whitespace and tabs", "  7 \t* 6  \n", "Result: 42.000000"),
    ("division by zero", "1/0\n", "Result: inf"),
    ("invalid character", "2&a\n", "Error: Invalid character '&' found."),
    ("unknown operator", "2^3\n", "Error: Invalid character '^' found."),
    ("malformed number", ".\n", "Error: Invalid number."),
    ("unclosed parenthesis", "2*(3+4\n", PARENS),
    ("extra parenthesis", "2+3)\n", PARENS),
    ("nested unclosed paren", "((1+2)*3\n", PARENS),
    ("missing right operand", "5+\n", INVALID),
    ("missing left operand", "*5\n", INVALID),
    ("two operands in a row", "2 2\n", INVALID),
    ("empty parentheses", "()\n", INVALID),
    ("too many tokens", "1+" * 40 + "1\n", TOKENS),
    ("empty line is ignored", "\n2+2\n", "Result: 4.000000"),
    ("several expressions", "1+1\n2*3\n", "Result: 2.000000\nResult: 6.000000"),
    ("error then recovery", "2&a\n2+2\n",
     "Error: Invalid character '&' found.\nResult: 4.000000"),
    ("no newline at EOF", "3*7", "Result: 21.000000"),
    ("over-long line and recovery", "9" * 300 + "\n1+1\n", LONG + "\nResult: 2.000000"),
    ("empty input", "", ""),
    ("only whitespace", " \t\n\n", ""),
    ("CRLF input", "1+2\r\n4/2\r\n", "Result: 3.000000\nResult: 2.000000"),
    ("leading decimal point", ".5+.25\n", "Result: 0.750000"),
    ("negative exponent", "1e-2*100\n", "Result: 1.000000"),
    ("64 tokens accepted", "-" * 63 + "1\n", "Result: -1.000000"),
    ("65 tokens rejected", "-" * 64 + "1\n", TOKENS),
    ("deep parentheses", "(" * 31 + "2" + ")" * 31 + "\n", "Result: 2.000000"),
    ("254 characters with newline", " " * 253 + "1\n", "Result: 1.000000"),
    ("254 characters at EOF", " " * 253 + "1", "Result: 1.000000"),
    ("255 characters rejected", " " * 254 + "1\n2\n", LONG + "\nResult: 2.000000"),
    ("long line at EOF", "9" * 300, LONG),
    ("drain multiple buffers", "9" * 1024 + "\n6*7\n", LONG + "\nResult: 42.000000"),
    ("parser error recovery", "(1+2\n4*5\n", PARENS + "\nResult: 20.000000"),
    ("evaluator error recovery", "1+\n4*5\n", INVALID + "\nResult: 20.000000"),
    ("lexer number error recovery", ".\n4*5\n", "Error: Invalid number.\nResult: 20.000000"),
    ("many expressions in one process", "1.25*8-3\n" * 200,
     "\n".join(["Result: 7.000000"] * 200)),
]


def normalize(output):
    output = re.sub(r"^(?:> )+", "", output, flags=re.MULTILINE)
    return "\n".join(line for line in output.splitlines() if line.strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", default="./calculator")
    parser.add_argument("--runner", help="optional executable, e.g. wine64")
    args = parser.parse_args()
    binary = Path(args.binary).resolve()
    if not binary.is_file():
        parser.error(f"binary not found: {binary}; build it first")
    command = ([args.runner] if args.runner else []) + [str(binary)]
    failed = 0
    for name, input_text, expected in CASES:
        try:
            result = subprocess.run(command, input=input_text, text=True,
                                    capture_output=True, timeout=30)
            actual = normalize(result.stdout)
            ok = result.returncode == 0 and not result.stderr and actual == expected
            if not ok:
                print(f"FAIL {name}\n  expected: {expected!r}\n  actual: {actual!r}"
                      f"\n  exit: {result.returncode}\n  stderr: {result.stderr!r}")
        except (OSError, subprocess.TimeoutExpired) as exc:
            print(f"FAIL {name}: {exc}")
            ok = False
        if ok:
            print(f"ok   {name}")
        else:
            failed += 1
    print(f"\npassed: {len(CASES) - failed}, failed: {failed}")
    return int(failed != 0)


if __name__ == "__main__":
    sys.exit(main())
