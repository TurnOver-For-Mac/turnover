#!/bin/sh
# Builds SAAPI64.dll. Needs a MinGW cross-compiler:
#   Mac:   brew install mingw-w64
#   Linux: apt install mingw-w64
set -e
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -shared -O2 -Wall -Wextra -o SAAPI64.dll saapi64.c saapi64.def -lws2_32 -static-libgcc
echo "built $(pwd)/SAAPI64.dll"
x86_64-w64-mingw32-objdump -p SAAPI64.dll | sed -n '/Export Address Table/,/^$/p' | grep -E 'SA_' || true
