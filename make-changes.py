#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CHANGELOG.md, the record of every published build, made into the site's "What's new" page and into one build's
update notes for Sparkle. The release tooling runs it on publish.
  make-changes.py page CHANGELOG.md changes.html [build]   (with a build: nothing newer than it is shown)
  make-changes.py notes CHANGELOG.md <build> notes.md     (the section for that build; nothing if there is none)
  make-changes.py try CHANGELOG.md new-to-try.json        (each build's "### New to try" list, for the app)

A build's section may have "### New to try" (new things for testers to try: features, apps, settings) and
"### Fixed" (everything else); a section with neither is all one list."""
import html, re, sys

def sections(text):
    out, title, body = [], None, []
    for line in text.splitlines():
        if line.startswith("## "):
            if title: out.append((title, body))
            title, body = line[3:].strip(), []
        elif title is not None: body.append(line)
    if title: out.append((title, body))
    return out

mode, src = sys.argv[1], open(sys.argv[2], encoding="utf-8").read()
if mode == "try":
    import json
    out = []
    for title, body in sections(src):
        m = re.search(r"\bbuild (\d+)\b", title)
        # Each item with its continuation lines (they were cut at the first line, 12 Oct 2026); bold marks dropped.
        lists, where = {"new to try": [], "what to test": []}, None
        for l in body:
            if l.startswith("### "): where = l[4:].strip().lower(); where = where if where in lists else None; continue
            if where is None: continue
            if l.startswith("- "): lists[where].append(l[2:].strip())
            elif l.startswith("  ") and lists[where]: lists[where][-1] += " " + l.strip()
        clean = lambda xs: [x.replace("**", "") for x in xs]
        if m and lists["new to try"]:
            out.append({"build": int(m.group(1)), "items": clean(lists["new to try"]), "tests": clean(lists["what to test"])})
    open(sys.argv[3], "w", encoding="utf-8").write(json.dumps(out, ensure_ascii=False, indent=1))
    sys.exit(0)
if mode == "notes":
    build, dest = sys.argv[3], sys.argv[4]
    for title, body in sections(src):
        if re.search(rf"\bbuild {re.escape(build)}\b", title):
            open(dest, "w", encoding="utf-8").write(f"# TurnOver {title}\n\n" + "\n".join(body).strip() + "\n")
    sys.exit(0)

# Only what has been published (6 Nov 2026; staged by hand for 22.5 on 1 Nov, when the changelog already held build
# 23): given the build being published, a section for a newer build, or one marked "in progress", is left out.
published = float(sys.argv[4]) if len(sys.argv) > 4 else None
def released(title):
    if "in progress" in title.lower(): return False
    m = re.search(r"\bbuild (\d+(?:\.\d+)?)\b", title)
    return published is None or not m or float(m.group(1)) <= published
intro = src.split("## ", 1)[0].splitlines()
intro = " ".join(l for l in intro if l and not l.startswith("#"))
parts = [f"<h1>What's new in TurnOver</h1>", f"<p>{html.escape(intro)}</p>"]
for title, body in sections(src):
    if not released(title): continue
    parts.append(f"<h2>{html.escape(title)}</h2>")
    items = []
    def flush():
        if items: parts.append("<ul>\n" + "\n".join(f"<li>{html.escape(i)}</li>" for i in items) + "\n</ul>"); items.clear()
    for l in body:
        if l.startswith("### "): flush(); parts.append(f"<h3>{html.escape(l[4:].strip())}</h3>")
        elif l.startswith("- "): items.append(l[2:].strip())
        # A bullet's continuation lines, as "try" reads them: the page cut each item at its first line (staged by
        # hand for 22.5 on 1 Nov 2026; made durable for build 23, 6 Nov 2026).
        elif l.startswith("  ") and items: items[-1] += " " + l.strip()
    flush()
page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow"><title>What's new in TurnOver</title>
<style>body{{font:1rem/1.5 -apple-system,system-ui,sans-serif;max-width:46rem;margin:0 auto;padding:1rem;color:#111;background:#fff}}
@media (prefers-color-scheme:dark){{body{{color:#eee;background:#111}}a{{color:#8ab4ff}}}}</style></head>
<body><main>
{chr(10).join(parts)}
<p><a href=".">Back to the download page</a></p>
</main></body></html>
"""
open(sys.argv[3], "w", encoding="utf-8").write(page)
