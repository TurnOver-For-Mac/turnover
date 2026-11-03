#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Keep extracted app implementations out of shared reading code.

Apps still compile in TurnOverCore, so Swift cannot enforce this direction yet.
Opt an app into this check after its shared behavior has been extracted. System
registration and the edition's supported-app inventory remain assembly concerns.
"""
import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
ISOLATED_APPS = {"Word": "com.microsoft.Word"}
TOKENS = re.compile(r'//[^\n]*|/\*.*?\*/|""".*?"""|"(?:\\.|[^"\\])*"|\b[A-Za-z_]\w*\b', re.S)


def code_tokens(source):
    return [token for token in TOKENS.finditer(source) if not token[0].startswith(("//", "/*"))]


def app_types(folder, prefix):
    names = set()
    for path in folder.glob("*.swift"):
        tokens = code_tokens(path.read_text())
        for first, second in zip(tokens, tokens[1:]):
            if first[0] in {"class", "struct", "enum", "protocol", "typealias"} and second[0].startswith(prefix):
                names.add(second[0])
    return names


def violations(source, path, names, bundle):
    found = []
    for token in code_tokens(source):
        value = token[0]
        if value in names or (value == f'"{bundle}"' and path != Path("Sources/Core/Edition.swift")):
            line = source.count("\n", 0, token.start()) + 1
            found.append(f"{path}:{line}: app implementation reference {value}; use an app/object hook")
    return found


def self_test():
    path = Path("Sources/Core/Text/EditableText.swift")
    names = {"WordAppModule", "WordTableCell"}
    bundle = "com.microsoft.Word"
    assert violations("WordTableCell.cell(of: element)", path, names, bundle)
    assert violations('if bundle == "com.microsoft.Word" {}', path, names, bundle)
    assert not violations("appModule.isTableCellText(element)", path, names, bundle)
    assert not violations('// WordTableCell\n/* WordAppModule */\n"WordAppModule"', path, names, bundle)
    assert not violations('"com.microsoft.Word"', Path("Sources/Core/Edition.swift"), names, bundle)
    assert violations('WordAppModule.self', Path("Sources/Core/Edition.swift"), names, bundle)
    assert violations('/* preceding comment */\nWordAppModule.self', path, names, bundle)[0].startswith(f"{path}:2:")
    print("app boundary self-tests: 7 passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    errors = []
    for app, bundle in ISOLATED_APPS.items():
        names = app_types(ROOT / "Sources/Apps" / app, app)
        if not names:
            errors.append(f"{app}: no app implementation types found")
        for folder in ("Core", "Views"):
            for path in sorted((ROOT / "Sources" / folder).rglob("*.swift")):
                errors.extend(violations(path.read_text(), path.relative_to(ROOT), names, bundle))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("app boundaries: Word implementation stays in Apps; shared code uses hooks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
