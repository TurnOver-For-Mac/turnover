#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Every local link in a site folder's pages leads somewhere (6 Nov 2026; for 22.5 the check was by hand, and the
domain's home page linked to TurnOver-Beta-Guide.txt, which no longer existed).

  Tools/check-site-links.py <site folder> [<site folder> ...]

Links to other sites, mailto: and the page's own top are not followed. A link to page.html#part needs an element
with id="part" there."""
import html.parser, os, sys, urllib.parse

class Links(html.parser.HTMLParser):
    def __init__(self): super().__init__(); self.links, self.ids = [], set()
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a: self.ids.add(a["id"])
        if tag == "a" and a.get("name"): self.ids.add(a["name"])
        for key in ("href", "src"):
            if a.get(key): self.links.append(a[key])

def parse(path):
    p = Links(); p.feed(open(path, encoding="utf-8", errors="replace").read()); return p

problems, checked = [], 0
for root in sys.argv[1:]:
    pages = {}
    for d, _, files in os.walk(root):
        if ".git" in d.split(os.sep): continue
        for f in files:
            if f.endswith(".html"): pages[os.path.join(d, f)] = None
    for page in pages:
        for link in parse(page).links:
            u = urllib.parse.urlsplit(link)
            if u.scheme or u.netloc or link.startswith(("mailto:", "#top")) or link == "#": continue
            target = os.path.normpath(os.path.join(os.path.dirname(page), urllib.parse.unquote(u.path))) if u.path else page
            if os.path.isdir(target): target = os.path.join(target, "index.html")
            checked += 1
            if not os.path.exists(target): problems.append(f"{os.path.relpath(page, root)}: {link} leads nowhere"); continue
            if u.fragment and target.endswith(".html") and u.fragment not in parse(target).ids:
                problems.append(f"{os.path.relpath(page, root)}: {link}: no such part")
if problems:
    print("STOP: links that lead nowhere:\n  " + "\n  ".join(problems)); sys.exit(1)
print(f"site links checked: {checked}, all lead somewhere")
