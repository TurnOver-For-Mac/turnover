#!/bin/sh
# Builds the SapiBridge voice (64- and 32-bit) and the sapitest programs.
# Needs MinGW: brew install mingw-w64
set -e
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -shared -O2 -Wall -Wextra -o SapiBridge64.dll sapibridge.c sapibridge.def -lws2_32 -lole32 -luuid -static-libgcc
i686-w64-mingw32-gcc   -shared -O2 -Wall -Wextra -o SapiBridge32.dll sapibridge.c sapibridge.def -lws2_32 -lole32 -luuid -static-libgcc
x86_64-w64-mingw32-gcc -O2 -Wall -o sapitest64.exe sapitest.c -lole32 -static-libgcc
i686-w64-mingw32-gcc   -O2 -Wall -o sapitest32.exe sapitest.c -lole32 -static-libgcc
echo "built $(pwd)/SapiBridge64.dll SapiBridge32.dll sapitest64.exe sapitest32.exe"
