#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

echo "Assembling modules..."
uasm -elf64 lexer.asm
uasm -elf64 evaluator.asm
uasm -elf64 calculator.asm

echo "Linking..."
gcc -no-pie calculator.o lexer.o evaluator.o -o calculator -lm

echo "Build successful! Run with ./calculator"
