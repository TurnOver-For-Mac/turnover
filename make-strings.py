#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""TurnOver's words in other languages (23 Oct 2026). Resources/Localizable.xcstrings is Apple's String Catalog: every
string the code marks with String(localized:) (and SwiftUI's Text), in English, with each language's translation
beside it. A string with no translation is spoken in English, so a language can be added a little at a time.

    python3 make-strings.py sync <folder>          the compiler's lists of strings (build.sh's TURNOVER_STRINGS, one
                                                    folder per target) into the catalog: new strings appear there,
                                                    untranslated, and strings no longer used are marked stale
    python3 make-strings.py compile <folder> ...    each Resources/*.xcstrings compiled into <folder>/<language>.lproj,
                                                    for an app's Contents/Resources

build.sh runs both. Translating is editing the catalog: in Xcode, or as JSON (a "tr" entry beside "en"). A new language
needs no code."""
import glob, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(HERE, "Resources", "Localizable.xcstrings")


def sync(folder):
    lists = sorted(glob.glob(os.path.join(folder, "**", "*.stringsdata"), recursive=True))
    # A source file since deleted or renamed leaves its list behind (the compiler only writes what it compiles):
    # dropped, so its strings are marked stale rather than kept alive.
    kept = []
    for path in lists:
        try:
            source = json.load(open(path, encoding="utf-8")).get("source", "")
        except (OSError, ValueError):
            source = ""
        if source and os.path.exists(source):
            kept.append(path)
        else:
            os.remove(path)
    # No lists at all is a build without TURNOVER_STRINGS, not code without strings: syncing then would mark every
    # string stale.
    if not kept:
        sys.exit(f"make-strings.py: no .stringsdata under {folder}; the catalog is left as it is")
    subprocess.run(["xcrun", "xcstringstool", "sync", CATALOG, "--stringsdata", *kept], check=True)


def compile_into(folders):
    with tempfile.TemporaryDirectory() as out:
        for catalog in sorted(glob.glob(os.path.join(HERE, "Resources", "*.xcstrings"))):
            # The translations only. English stays where it is written (the code, Info.plist): an en.lproj made from
            # InfoPlist.xcstrings gave its keys as the English permission prompts (25 Oct 2026).
            data = json.load(open(catalog, encoding="utf-8"))
            source = data.get("sourceLanguage", "en")
            languages = sorted({l for e in data.get("strings", {}).values() for l in e.get("localizations", {})} - {source})
            if not languages:
                continue
            subprocess.run(["xcrun", "xcstringstool", "compile", catalog, "--output-directory", out,
                            *[a for l in languages for a in ("--language", l)]], check=True)
        for folder in folders:
            for lproj in sorted(glob.glob(os.path.join(out, "*.lproj"))):
                target = os.path.join(folder, os.path.basename(lproj))
                shutil.rmtree(target, ignore_errors=True)
                shutil.copytree(lproj, target)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "sync":
        sync(sys.argv[2])
    elif len(sys.argv) >= 3 and sys.argv[1] == "compile":
        compile_into(sys.argv[2:])
    else:
        sys.exit(__doc__)
