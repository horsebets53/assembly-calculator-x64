[Русская версия](README.ru.md)

# Assembly Calculator

A cross-platform console calculator written from scratch in x86-64 assembly using MASM/UASM syntax. This project demonstrates a low-level implementation of classic expression parsing and evaluation algorithms, as well as the construction of a modular architecture in assembly.

![Image](untitled.png)

## Features

- **Basic Arithmetic Operations:** Addition (`+`), subtraction (`-`), multiplication (`*`), division (`/`).
- **Operator Precedence:** Correctly handles the order of operations (multiplication and division are performed before addition and subtraction).
- **Parentheses Support:** Allows overriding the order of operations using parentheses.
- **Unary Minus:** Supports negative numbers and expressions like `5 * -2`.
- **Floating-Point Numbers:** All calculations are performed with 64-bit double-precision numbers using SSE2 instructions.
- **Division by Zero:** Returns `inf` in accordance with the IEEE 754 standard.
- **Error Reporting:** Invalid characters, malformed numbers, unbalanced parentheses, missing operands and over-long expressions are all reported instead of producing a wrong result silently.
- **Cross-Platform:** Builds on Linux (ELF64/libc) and native Windows x64 (PE/COFF, MSYS2 UCRT64 GCC), without WSL.

## Architecture

The project features a clean, modular architecture that separates responsibilities between components:

1.  **`lexer.asm` (Lexer):** Responsible for lexical analysis. It converts the input string into a sequence of tokens (numbers, operators, parentheses).
2.  **`parser` (Parser, in `calculator.asm`):** Responsible for syntax analysis. It uses the **Shunting-yard algorithm** to convert the token sequence into Reverse Polish Notation (RPN), respecting operator precedence and parentheses.
3.  **`evaluator.asm` (Evaluator):** Evaluates the expression represented in RPN using a stack-based calculator.
4.  **`calculator.asm` (Main Module):** Orchestrates the entire process: gets user input, calls the modules in sequence, and prints the final result.
5.  **`common.inc`:** A common header file containing the `Token` structure definition.
6.  **`runtime.inc` / `windows.asm`:** Platform-specific CRT call dispatch and the Windows x64/UCRT adapter. The assembly core keeps a private SysV-style register convention on both platforms; its routines are not a Windows C ABI. The adapter handles native `main`, preserved registers, shadow space, variadic floating arguments and UCRT standard streams.

## Building and Running

### Linux

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

    To remove the build artifacts run `./build.sh clean`.

**Manual Build:**
```bash
# 1. Assemble all modules
uasm -elf64 lexer.asm
uasm -elf64 evaluator.asm
uasm -elf64 calculator.asm

# 2. Link the object files using GCC
#    -z noexecstack keeps the stack non-executable (UASM emits no .note.GNU-stack)
gcc -no-pie -z noexecstack calculator.o lexer.o evaluator.o -o calculator -lm
```

**Running:**
```bash
./calculator
```

### Windows x64 (no WSL)

Required:
- **UASM x64 2.57+** (`uasm.exe`), available from [UASM](https://github.com/Terraspace/UASM).
- **MSYS2 UCRT64 GCC**, normally `C:\msys64\ucrt64\bin\gcc.exe`.
  If needed, install it from the **MSYS2 UCRT64** terminal:
  ```bash
  pacman -S --needed mingw-w64-ucrt-x86_64-gcc
  ```

Open **Command Prompt (`cmd.exe`)** in this repository and run:

```bat
set "UASM=C:\Tools\UASM\uasm.exe"
build.bat
calculator.exe
```

Replace the example UASM path with your actual location. If `uasm.exe` is
already in `PATH`, omit the `set` command. The script uses
`C:\msys64\ucrt64\bin\gcc.exe` by default; override it if necessary:

```bat
set "GCC=D:\msys64\ucrt64\bin\gcc.exe"
build.bat
```

Use **UCRT64**, not MSYS `/usr/bin/gcc`, 32-bit MinGW or legacy MSVCRT GCC.
Run `build.bat clean` to remove Windows build artifacts. In PowerShell,
use `$env:UASM = 'C:\Tools\UASM\uasm.exe'` and `.\build.bat`.

Manual equivalent, in `cmd.exe` with both tools in `PATH`:

```bat
uasm -win64 -D__WINDOWS__ -Folexer.obj lexer.asm
uasm -win64 -D__WINDOWS__ -Foevaluator.obj evaluator.asm
uasm -win64 -D__WINDOWS__ -Focalculator.obj calculator.asm
uasm -win64 -D__WINDOWS__ -Fowindows.obj windows.asm
gcc calculator.obj lexer.obj evaluator.obj windows.obj -Wl,--nxcompat,--dynamicbase -o calculator.exe
```

Keep `-D__WINDOWS__` on **all** Windows assembly commands and include
`windows.obj` when linking. Merely changing `-elf64` to `-win64` is not enough.

**Limits:** an expression may contain up to 64 tokens and an input line up to 254 characters.

## Testing

Python 3 is required **only for tests**, not to build or run the calculator.
The shared suite checks 49 cases: arithmetic, invalid input, recovery, token
and line limits, CRLF and EOF. Nonzero exit codes, stderr and timeouts fail a test.

```bash
# Linux (the shell entry point builds the default binary if missing)
./tests/test_calculator.sh
# Or, after building:
python3 tests/test_calculator.py ./calculator
```

```bat
rem Native Windows, after build.bat
py tests\test_calculator.py .\calculator.exe
```

For a configured 64-bit Wine installation:

```bash
WINEDEBUG=-all python3 tests/test_calculator.py ./calculator.exe --runner wine64
```

**Validation:** Linux/UASM+GCC and Windows PE/UCRT cross-linking with
`zig cc -target x86_64-windows-gnu`, followed by execution under Wine 8.0,
each passed all 49 cases. This is not a native Windows/MSYS2 GCC test; run the
command above on Windows to verify your exact toolchain. No CI workflow is required.
