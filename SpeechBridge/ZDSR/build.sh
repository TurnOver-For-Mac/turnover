#!/bin/sh
# Builds the ZDSR client stand-ins: ZDSRAPI_x64.dll (64-bit) and ZDSRAPI.dll (32-bit).
set -e; cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -shared -O2 -Wall -o ZDSRAPI_x64.dll zdsrapi.c zdsrapi.def -lws2_32 -static-libgcc
sed 's/^LIBRARY ZDSRAPI_x64/LIBRARY ZDSRAPI/' zdsrapi.def > zdsrapi32.def
i686-w64-mingw32-gcc -shared -O2 -Wall -o ZDSRAPI.dll zdsrapi.c zdsrapi32.def -lws2_32 -static-libgcc
rm -f zdsrapi32.def; ls -la ZDSRAPI_x64.dll ZDSRAPI.dll
