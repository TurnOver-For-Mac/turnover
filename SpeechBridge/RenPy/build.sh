#!/bin/sh
# Builds sbsay.exe, the Ren'Py self-voicing helper. Needs MinGW: brew install mingw-w64
set -e
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -mwindows -o sbsay.exe sbsay.c -lws2_32 -lshell32 -static-libgcc
echo "built $(pwd)/sbsay.exe"
