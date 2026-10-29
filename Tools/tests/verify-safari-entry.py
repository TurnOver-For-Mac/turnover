# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify the actual Foundation extension entry point, rather than a dylib-only header assumption."""
import re
import subprocess
import sys


def output(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.PIPE)


def require(condition):
    if not condition:
        raise ValueError("unexpected extension executable entry point")


def verify(path):
    architectures = output("lipo", "-archs", path).split()
    require(architectures)
    for arch in architectures:
        header = output("otool", "-arch", arch, "-hv", path)
        require(re.search(r"\bMH_MAGIC_64\s+.*\bEXECUTE\b", header))
        commands = output("otool", "-arch", arch, "-l", path)
        blocks = re.split(r"Load command \d+", commands)
        text = [block for block in blocks if re.search(r"^\s*segname __TEXT$", block, re.M)]
        main = [block for block in blocks if re.search(r"^\s*cmd LC_MAIN$", block, re.M)]
        require(len(text) == 1 and len(main) == 1)
        vm = re.search(r"^\s*vmaddr (0x[0-9a-fA-F]+)$", text[0], re.M)
        offset = re.search(r"^\s*fileoff (\d+)$", text[0], re.M)
        entry = re.search(r"^\s*entryoff (\d+)$", main[0], re.M)
        require(vm and offset and entry)
        imports = output("otool", "-arch", arch, "-Iv", path)
        stubs = imports.split("Indirect symbols for (__TEXT,__stubs)", 1)
        require(len(stubs) == 2)
        stubs = stubs[1].split("Indirect symbols for", 1)[0]
        addresses = re.findall(r"^0x([0-9a-fA-F]+)\s+\d+\s+_NSExtensionMain$", stubs, re.M)
        require(len(addresses) == 1)
        require(int(addresses[0], 16) - int(vm[1], 16) + int(offset[1]) == int(entry[1]))
    return architectures


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("one executable is required")
        architectures = verify(sys.argv[1])
    except (OSError, subprocess.CalledProcessError, ValueError):
        raise SystemExit("STOP: Page Reader must enter Foundation's NSExtensionMain in every executable slice; not installing")
    print("Page Reader Foundation entry verified: " + ", ".join(architectures))
