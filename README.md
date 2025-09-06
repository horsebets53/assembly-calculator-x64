# Assembly Calculator

A cross-platform console calculator written from scratch in x86-64 assembly using MASM/UASM syntax. This project demonstrates a low-level implementation of classic expression parsing and evaluation algorithms, as well as the construction of a modular architecture in assembly.

## Features

- **Basic Arithmetic Operations:** Addition (`+`), subtraction (`-`), multiplication (`*`), division (`/`).
- **Operator Precedence:** Correctly handles the order of operations (multiplication and division are performed before addition and subtraction).
- **Parentheses Support:** Allows overriding the order of operations using parentheses.
- **Unary Minus:** Supports negative numbers and expressions like `5 * -2`.
- **Floating-Point Numbers:** All calculations are performed with 64-bit double-precision numbers using SSE2 instructions.
- **Cross-Platform:** The code compiles on Linux and can be easily adapted for Windows due to its use of the standard C library (libc/MSVCRT).

## Architecture

The project features a clean, modular architecture that separates responsibilities between components:

1.  **`lexer.asm` (Lexer):** Responsible for lexical analysis. It converts the input string into a sequence of tokens (numbers, operators, parentheses).
2.  **`parser` (Parser, in `calculator.asm`):** Responsible for syntax analysis. It uses the **Shunting-yard algorithm** to convert the token sequence into Reverse Polish Notation (RPN), respecting operator precedence and parentheses.
3.  **`evaluator.asm` (Evaluator):** Evaluates the expression represented in RPN using a stack-based calculator.
4.  **`calculator.asm` (Main Module):** Orchestrates the entire process: gets user input, calls the modules in sequence, and prints the final result.
5.  **`common.inc`:** A common header file containing the `Token` structure definition.

## Building and Running

**Prerequisites:**
- `UASM` assembler (version 2.57+)
- `GCC` compiler (for linking)

**Build Instructions:**

The repository includes a `build.sh` script for convenience.

1.  Make the script executable:
    ```bash
    chmod +x build.sh
    ```
2.  Run the script:
    ```bash
    ./build.sh
    ```
    This will automatically assemble all modules and link them into a single executable named `calculator`.

**Manual Build:**
```bash
# 1. Assemble all modules
uasm -elf64 lexer.asm
uasm -elf64 evaluator.asm
uasm -elf64 calculator.asm

# 2. Link the object files using GCC
gcc -no-pie calculator.o lexer.o evaluator.o -o calculator -lm
```

**Running:**
```bash
./calculator
```
