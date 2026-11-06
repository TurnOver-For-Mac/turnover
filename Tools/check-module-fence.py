#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The fence around TurnOver's core (6 Nov 2026, Oliver: contributors' AIs build app modules "whilst keeping the core
locked down and safe").

  Tools/check-module-fence.py <base ref> [--outside]

Lists what a branch changes since <base ref> and says whether all of it is app-module work:
- anything under Sources/Apps/<App>/ (the module, its record, tests, experiments);
- Sources/Apps/README.md (the generated index);
- tests and recorded windows (Sources/TurnOverTests/, Tests/Fixtures/): they run in the build, never ship in the app;
- in Package.swift, only lines naming files under Apps/ (coreSources and the generated exclusions);
- in Sources/System/BuiltInModules.swift, only `h.register(...)` lines;
- in Resources/Localizable.xcstrings, only added strings (the build adds a module's new words).
Anything else is the core. With --outside (the pull request is from someone outside the project), touching the core
fails the check, so the pull request can't merge until a maintainer has looked; without it, the list is only reported.
A contributor who needs the core asks for a building block (docs/BUILDING-BLOCKS.md)."""
import re, subprocess, sys

base = sys.argv[1]
outside = "--outside" in sys.argv[2:]

def git(*args): return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout
files = [f for f in git("diff", "--name-only", f"{base}...HEAD").splitlines() if f]

def changed_lines(path):
    out = git("diff", "-U0", f"{base}...HEAD", "--", path)
    return [l[1:] for l in out.splitlines() if l[:1] in "+-" and not l.startswith(("+++", "---"))], \
           [l[1:] for l in out.splitlines() if l.startswith("-") and not l.startswith("---")]

apps, core = set(), []
for f in files:
    m = re.match(r"Sources/Apps/([^/]+)/", f)
    if m: apps.add(m.group(1)); continue
    if f == "Sources/Apps/README.md": continue
    if f.startswith(("Sources/TurnOverTests/", "Tests/Fixtures/")): continue
    if f == "Package.swift":
        lines, _ = changed_lines(f)
        if all(re.search(r'"Apps/[^"]+"', l) or not l.strip() for l in lines): continue
    if f == "Sources/System/BuiltInModules.swift":
        lines, _ = changed_lines(f)
        if all("h.register(" in l or not l.strip() for l in lines): continue
    if f == "Resources/Localizable.xcstrings":
        _, removed = changed_lines(f)
        if not [l for l in removed if l.strip()]: continue
    core.append(f)

print(f"App folders changed: {', '.join(sorted(apps)) or 'none'}")
if not core:
    print("Inside the fence: only app-module work."); sys.exit(0)
print("Outside the fence (TurnOver's core):\n  " + "\n  ".join(core))
if outside:
    print("\nThis pull request changes TurnOver's core, so a maintainer looks at it before it can merge. If a module "
          "needs something from the core, the A building block issue form asks for it (docs/BUILDING-BLOCKS.md). A "
          "maintainer who has reviewed the change approves it with the label core approved.")
    sys.exit(1)
