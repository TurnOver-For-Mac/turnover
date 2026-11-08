#!/bin/sh
# Builds the NVDA stand-in, 64- and 32-bit. Needs MinGW: brew install mingw-w64
set -e
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -shared -O2 -Wall -Wextra -o nvdaControllerClient64.dll nvdabridge.c nvdabridge.def -lws2_32 -static-libgcc -Wl,--enable-stdcall-fixup
i686-w64-mingw32-gcc   -shared -O2 -Wall -Wextra -o nvdaControllerClient32.dll nvdabridge.c nvdabridge.def -lws2_32 -static-libgcc -Wl,--enable-stdcall-fixup
echo "built $(pwd)/nvdaControllerClient64.dll and nvdaControllerClient32.dll"
