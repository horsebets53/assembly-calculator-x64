#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

MODULES="lexer evaluator calculator"
TARGET=calculator

if [ "${1:-}" = "clean" ]; then
    echo "Cleaning..."
    rm -f $TARGET $(for m in $MODULES; do echo "$m.o"; done)
    exit 0
fi

for tool in uasm gcc; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "Error: '$tool' was not found in PATH." >&2
        echo "Install UASM (https://github.com/Terraspace/UASM) and GCC, then retry." >&2
        exit 1
    fi
done

echo "Assembling modules..."
for m in $MODULES; do
    uasm -elf64 "$m.asm"
done

echo "Linking..."
# -z noexecstack: the assembler emits no .note.GNU-stack section, so without it
# the linker would mark the stack executable (and warn about it).
gcc -no-pie -z noexecstack $(for m in $MODULES; do echo "$m.o"; done) -o $TARGET -lm

echo "Build successful! Run with ./$TARGET"
