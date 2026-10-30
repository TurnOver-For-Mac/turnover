#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the compact app index and check record categories and local links."""
from pathlib import Path
import re
import sys
from urllib.parse import quote, unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
APPS = ROOT / 'Sources' / 'Apps'
DESTINATION = APPS / 'README.md'
SUPPORT = ('Works', 'Partial', 'Blocked', 'Not assessed')
EFFORT = ('None', 'Settings or plugin', 'Module', 'Workaround', 'No route known')
FIELDS = ('Bundle id', 'Support', 'Effort', 'Being worked on', 'Checked')


def records():
    result = []
    bundles = set()
    for path in sorted(APPS.glob('*/STATUS.md')):
        lines = path.read_text(encoding='utf-8').splitlines()
        titles = [line[2:].strip() for line in lines if line.startswith('# ')]
        if len(titles) != 1 or not titles[0]:
            raise ValueError(f'{path.relative_to(ROOT)}: expected one app title')
        headings = [line[3:].strip() for line in lines if line.startswith('## ')]
        if headings != ['Findings', 'Evidence']:
            raise ValueError(f'{path.relative_to(ROOT)}: use Findings and Evidence headings')
        fields = {}
        for line in lines[:next(i for i, line in enumerate(lines) if line.startswith('## '))]:
            if line.startswith('- ') and ':' in line:
                key, value = line[2:].split(':', 1)
                if key.strip() in fields:
                    raise ValueError(f'{path.relative_to(ROOT)}: duplicate field {key.strip()}')
                fields[key.strip()] = value.strip()
        if set(fields) != set(FIELDS):
            raise ValueError(f'{path.relative_to(ROOT)}: expected fields {", ".join(FIELDS)}')
        if fields['Support'] not in SUPPORT or (fields['Effort'] and fields['Effort'] not in EFFORT):
            raise ValueError(f'{path.relative_to(ROOT)}: invalid Support or Effort category')
        if any(not fields[key] for key in FIELDS if key != 'Effort'):
            raise ValueError(f'{path.relative_to(ROOT)}: only Effort may be blank; use Unclaimed for unassigned work')
        if fields['Bundle id'] in bundles:
            raise ValueError(f'{path.relative_to(ROOT)}: duplicate bundle id')
        bundles.add(fields['Bundle id'])
        result.append((titles[0], quote(path.relative_to(APPS).as_posix(), safe='/'), fields))
    if not result:
        raise ValueError('No app records found')
    return result


def check_links():
    for path in sorted(APPS.rglob('*.md')):
        for raw in re.findall(r'\[[^\]]+\]\(([^)]+)\)', path.read_text(encoding='utf-8')):
            target = raw.strip().removeprefix('<').removesuffix('>')
            url = urlsplit(target)
            if url.scheme in ('http', 'https', 'mailto') or not url.path:
                continue
            if url.scheme or url.netloc or url.path.startswith('/'):
                raise ValueError(f'{path.relative_to(ROOT)}: use a portable relative link: {target}')
            resolved = (path.parent / unquote(url.path)).resolve()
            if not resolved.is_relative_to(ROOT) or not resolved.exists():
                raise ValueError(f'{path.relative_to(ROOT)}: broken local link: {target}')


def index(entries):
    out = ['# App records', '',
           'Generated from each app’s STATUS.md. Only the recorded tasks and setups are assessed; the presence of a folder is not evidence of support.', '',
           '## Reading the records', '',
           '**Support:** Works means the named tasks worked in the recorded setup; Partial means useful tasks have known gaps; Blocked means the stated task has no usable tested route; Not assessed means no relevant assessment is recorded. Blocked is not proof of impossibility.', '',
           '**Effort:** None means no app-specific adaptation; Settings or plugin means configuration is sufficient; Module means app-specific code; Workaround means an indirect route; No route known means no usable approach has been demonstrated. Blank effort remains unassessed. These are categories, not time estimates.', '',
           '**Being worked on** records a current person and issue, or Unclaimed; it creates no permanent ownership. AI assistance and historical work are described in the evidence. VoiceOver on/off is a test condition, not a limit on TurnOver’s intended support.', '',
           'Assess support by checking the named tasks and recording the app/macOS versions, reader build, keyboard style and VoiceOver state. Use public sample content for saved evidence.', '',
           'Shared implementations: [Media](Media/README.md), [Chat](Chat/README.md), [Panes](Panes/README.md), [Games](Games/README.md). They are not separate app support grades.', '',
           'Regenerate with `python3 Tools/build-app-index.py` from the repository root; check records, local links and stale output with `--check`.', '']
    for support in SUPPORT:
        out.extend([f'## {support}', ''])
        group = sorted((entry for entry in entries if entry[2]['Support'] == support), key=lambda entry: entry[0].casefold())
        if not group:
            out.append('No entries recorded in this category.')
        for title, link, fields in group:
            out.append(f'- [{title}]({link}) — Effort: {fields["Effort"] or "not assessed"}; being worked on: {fields["Being worked on"]}.')
        out.append('')
    return '\n'.join(out)


def main():
    if sys.argv[1:] not in ([], ['--check']):
        raise ValueError('Usage: python3 Tools/build-app-index.py [--check]')
    entries = records()
    body = index(entries)
    if sys.argv[1:] == ['--check']:
        if not DESTINATION.exists() or DESTINATION.read_text(encoding='utf-8') != body:
            raise ValueError('App index is stale; run python3 Tools/build-app-index.py')
        check_links()
        print(f'App index, categories and local links checked: {len(entries)} records.')
    else:
        DESTINATION.write_text(body, encoding='utf-8')
        check_links()
        print(f'Generated app index: {len(entries)} records.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(str(error)) from error
