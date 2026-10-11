#!/usr/bin/env bash
# Compatibility entry point; the shared suite also runs on native Windows.
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -eq 0 ] && [ ! -x ./calculator ]; then
    ./build.sh
fi
exec python3 tests/test_calculator.py "$@"
