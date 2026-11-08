#!/bin/sh
# Builds the WindowsTTS stand-in, 64- and 32-bit. Needs MinGW: brew install mingw-w64
set -e
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -shared -O2 -Wall -Wextra -o WindowsTTS64.dll windowstts.c windowstts.def -lws2_32 -static-libgcc -Wl,--enable-stdcall-fixup
i686-w64-mingw32-gcc   -shared -O2 -Wall -Wextra -o WindowsTTS32.dll windowstts.c windowstts.def -lws2_32 -static-libgcc -Wl,--enable-stdcall-fixup
echo "built $(pwd)/WindowsTTS64.dll and WindowsTTS32.dll"
