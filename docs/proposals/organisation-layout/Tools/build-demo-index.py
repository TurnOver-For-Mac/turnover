"""Generate this demo's compact app index from its STATUS.md records."""

from pathlib import Path
from urllib.parse import quote
import sys

root = Path(__file__).resolve().parent.parent
support_values = ('Works', 'Partial', 'Blocked', 'Not assessed')
effort_values = ('None', 'Settings or plugin', 'Module', 'Workaround', 'No route known')
entries = []
for status in (root / 'Sources' / 'Apps').glob('*/STATUS.md'):
    lines = status.read_text(encoding='utf-8').splitlines()
    title = next(line[2:] for line in lines if line.startswith('# '))
    metadata = lines[:next((i for i, line in enumerate(lines) if line.startswith('## ')), len(lines))]
    fields = {}
    for line in metadata:
        if line.startswith('- ') and ':' in line:
            key, value = line[2:].split(':', 1)
            fields[key.strip()] = value.strip()
    for field in ('Support', 'Effort', 'Being worked on'):
        if field not in fields:
            raise SystemExit(f'{status}: missing {field}')
    if fields['Support'] not in support_values:
        raise SystemExit(f'{status}: invalid Support category')
    if fields['Effort'] and fields['Effort'] not in effort_values:
        raise SystemExit(f'{status}: invalid Effort category')
    if not fields['Being worked on']:
        raise SystemExit(f'{status}: use Unclaimed when no work is claimed')
    link = quote(status.relative_to(root).as_posix(), safe='/')
    entries.append((title, link, fields))

output = ['# Apps', '',
          'Generated from STATUS.md. These are qualified demo records, not fresh assessments. [Grade definitions](CONTRIBUTING.md) · [Start](README.md)', '']
for support in support_values:
    output.extend([f'## {support}', ''])
    group = sorted((entry for entry in entries if entry[2]['Support'] == support), key=lambda entry: entry[0].casefold())
    if not group:
        output.append('No entries recorded in this category.')
    for title, link, fields in group:
        effort = fields['Effort'] or 'not assessed'
        output.append(f'- [{title}]({link}) — Effort: {effort}; being worked on: {fields["Being worked on"]}.')
    output.append('')
body = '\n'.join(output)
destination = root / 'APPS.md'
if sys.argv[1:] == ['--check']:
    if destination.read_text(encoding='utf-8') != body:
        raise SystemExit('App index is out of date; regenerate it.')
    print(f'Index matches all {len(entries)} app/group records and category values.')
elif not sys.argv[1:]:
    destination.write_text(body, encoding='utf-8')
    print(f'Generated {len(entries)} entries in {len(body.splitlines())} lines.')
else:
    raise SystemExit('Usage: python3 build-demo-index.py [--check]')
