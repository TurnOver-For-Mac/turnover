#!/bin/sh
# Builds the SpVoice stand-in, 64- and 32-bit. Needs MinGW: brew install mingw-w64
set -e
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -shared -O2 -Wall -Wextra -o SpVoiceBridge64.dll spvoice.c spvoice.def -lws2_32 -lole32 -luuid -static-libgcc
i686-w64-mingw32-gcc   -shared -O2 -Wall -Wextra -o SpVoiceBridge32.dll spvoice.c spvoice.def -lws2_32 -lole32 -luuid -static-libgcc
echo "built $(pwd)/SpVoiceBridge64.dll and SpVoiceBridge32.dll"
