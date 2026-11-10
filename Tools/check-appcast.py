#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The update feed checked before it is pushed (6 Nov 2026; the 22.5 release did this by hand on 1 Nov 2026).

  Tools/check-appcast.py <site folder> <build> [--prune]

Every enclosure in appcast.xml must be a file in the site folder, the size the feed says, with an EdDSA signature,
and <build> must be the newest version. With --prune, a delta whose file is gone is taken out of the feed first:
generate_appcast keeps an older item's deltas after the archive they came from leaves the site (22.5's entry pointed
at TurnOver22.5-22.3.delta after build 23 went up). Each enclosure carries its own signature, so removing one
leaves the others valid. A missing full archive is never pruned: it stops the publish."""
import os, re, sys, urllib.parse

site, build = sys.argv[1], sys.argv[2]
prune = "--prune" in sys.argv[3:]
path = os.path.join(site, "appcast.xml")
xml = open(path, encoding="utf-8").read()

def filename(url): return urllib.parse.unquote(url.rsplit("/", 1)[-1])

if prune:
    pruned = []
    def drop(m):
        if not os.path.exists(os.path.join(site, filename(m.group(1)))):
            pruned.append(filename(m.group(1))); return ""
        return m.group(0)
    # Deltas sit inside <sparkle:deltas>; one enclosure each, self-closing.
    xml = re.sub(r'\s*<enclosure url="([^"]+\.delta)"[^>]*/>', drop, xml)
    xml = re.sub(r'\s*<sparkle:deltas>\s*</sparkle:deltas>', "", xml)
    if pruned:
        open(path, "w", encoding="utf-8").write(xml)
        print("pruned from the feed (files gone): " + ", ".join(pruned))

problems = []
versions = re.findall(r"<sparkle:version>([^<]+)</sparkle:version>", xml)
if not versions or versions[0] != build:
    problems.append(f"the newest version is {versions[0] if versions else 'none'}, not {build}")
for tag in re.findall(r"<enclosure [^>]*>", xml):
    url = re.search(r'url="([^"]+)"', tag); length = re.search(r'length="(\d+)"', tag)
    if not url: problems.append("an enclosure has no url"); continue
    f = os.path.join(site, filename(url.group(1)))
    if not os.path.exists(f): problems.append(f"{filename(url.group(1))}: in the feed, not on the site"); continue
    if not length or int(length.group(1)) != os.path.getsize(f): problems.append(f"{filename(url.group(1))}: its length in the feed isn't the file's")
    if "sparkle:edSignature=" not in tag: problems.append(f"{filename(url.group(1))}: no EdDSA signature")
if problems:
    print("STOP: the feed isn't right:\n  " + "\n  ".join(problems)); sys.exit(1)
print(f"feed checked: {len(re.findall(r'<enclosure ', xml))} enclosures, all on the site and signed; newest {build}")
