#!/bin/sh
# Builds the cfgmgr32.dll shim (64-bit, for steam.exe) — see bustype.c.
set -e; cd "$(dirname "$0")"
python3 gen.py cfgmgr32.spec
x86_64-w64-mingw32-gcc -shared -O2 -Wall -o cfgmgr32.dll bustype.c thunks.c exports.def -static-libgcc
ls -la cfgmgr32.dll
