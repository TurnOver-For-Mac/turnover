#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the app index and SwiftPM app-record exclusions; validate both together."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import re
import sys
from urllib.parse import quote, unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
APPS = ROOT / 'Sources' / 'Apps'
DESTINATION = APPS / 'README.md'
SUPPORT = ('Works', 'Partial', 'Blocked', 'Not assessed')
EFFORT = ('None', 'Settings or plugin', 'Module', 'Workaround', 'No route known')
FIELDS = ('Bundle id', 'Support', 'Effort', 'Being worked on', 'Checked')
UNKNOWN_BUNDLE = 'Not recorded'
MANIFEST = ROOT / 'Package.swift'
EXCLUDES_BEGIN = '// BEGIN GENERATED APP EXCLUDES (Tools/build-app-index.py)'
EXCLUDES_END = '// END GENERATED APP EXCLUDES'
NONPRODUCTION = {'Tests', 'Experiments', 'Fixtures'}
SOURCE_SUFFIXES = {'.swift', '.c', '.cc', '.cpp', '.cxx', '.m', '.mm', '.s', '.h', '.hh', '.hpp', '.hxx'}


def app_excludes():
    # Collapse sample trees so future files inside them cannot enter a reader target.
    # App production Swift files remain explicit in Package.swift; never generate that list.
    result = {'Apps/README.md'}
    for path in sorted(APPS.rglob('*')):
        relative = path.relative_to(APPS)
        if any(part.startswith('.') for part in relative.parts):
            continue  # SwiftPM ignores Finder metadata and hidden paths.
        sample = next((i for i, part in enumerate(relative.parts) if part in NONPRODUCTION), None)
        if sample is not None:
            result.add('Apps/' + '/'.join(relative.parts[:sample + 1]))
        elif path.is_file() and path.suffix != '.swift':
            if path.suffix.lower() in SOURCE_SUFFIXES:
                raise ValueError(f'{path.relative_to(ROOT)}: app production code must be Swift; place diagnostic samples under Tests, Experiments or Fixtures')
            result.add('Apps/' + relative.as_posix())
    if any(any(ord(c) < 32 for c in name) for name in result):
        raise ValueError('App record paths must not contain control characters')
    return sorted(result)


def manifest_with_excludes(original, paths):
    matches = []
    for marker in (EXCLUDES_BEGIN, EXCLUDES_END):
        found = list(re.finditer(r'(?m)^([ \t]*)' + re.escape(marker) + r'$', original))
        if len(found) != 1:
            raise ValueError(f'Package.swift: expected exactly one {marker} marker')
        matches.append(found[0])
    begin, end = matches
    if begin.end() >= end.start() or begin[1] != end[1]:
        raise ValueError('Package.swift: app exclusion markers must be ordered and equally indented')
    entries = '\n'.join(begin[1] + json.dumps(path, ensure_ascii=False) + ',' for path in paths)
    return original[:begin.end()] + '\n' + entries + '\n' + original[end.start():]



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
        # An old observation may lack identity metadata. Keep that uncertainty explicit;
        # known identifiers must still be unique so two records cannot silently diverge.
        if fields['Bundle id'] != UNKNOWN_BUNDLE:
            if fields['Bundle id'] in bundles:
                raise ValueError(f'{path.relative_to(ROOT)}: duplicate bundle id')
            bundles.add(fields['Bundle id'])
        result.append((titles[0], quote(path.relative_to(APPS).as_posix(), safe='/'), fields))
    if not result:
        raise ValueError('No app records found')
    return result


def check_links(generated_index):
    for path in sorted(set(APPS.rglob('*.md')) | {DESTINATION}):
        contents = generated_index if path == DESTINATION else path.read_text(encoding='utf-8')
        for raw in re.findall(r'\[[^\]]+\]\(([^)]+)\)', contents):
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
           '**Support:** Works means the named tasks worked in the recorded setup; Partial means useful tasks have known gaps; Blocked means the stated task has no usable tested route; Not assessed means there is no adequate evidence for the named tasks. Grades use the best recorded evidence; Checked gives its date and build, and a new build does not automatically reset them. Blocked is not proof of impossibility.', '',
           '**Effort:** None means no app-specific adaptation; Settings or plugin means configuration is sufficient; Module means app-specific code; Workaround means an indirect route; No route known means no usable approach has been demonstrated. Blank effort remains unassessed. These are categories, not time estimates.', '',
           '**Being worked on** records a current person and issue, or Unclaimed; it creates no permanent ownership. AI assistance and historical work are described in the evidence. VoiceOver on/off is a test condition, not a limit on TurnOver’s intended support.', '',
           'Records include dedicated modules, shared-code support and earlier app investigations. A recovered result keeps its original date and limits; a planned task is not a completed test. See [the evidence guide](../../docs/APP-TEST-HISTORY.md). Bundle id may be Not recorded until verified; never guess an identifier from an app name.', '',
           'Assess support by checking the named tasks and recording the app/macOS versions, reader build, keyboard style and VoiceOver state. Use public sample content for saved evidence.', '',
           'Shared implementations: [Media](Media/README.md), [Chat](Chat/README.md), [Panes](Panes/README.md), [Games](Games/README.md), [Catalog](Catalog/README.md), [Google browser editors](GoogleDocs/README.md). They are not separate app support grades.', '',
           'Run `python3 Tools/build-app-index.py` after editing app records or documentation. It updates this index and the generated app-record exclusions in Package.swift. `--check` validates records, local links and both outputs. Production Swift source entries remain explicit.', '']
    for support in SUPPORT:
        out.extend([f'## {support}', ''])
        group = sorted((entry for entry in entries if entry[2]['Support'] == support), key=lambda entry: entry[0].casefold())
        if not group:
            out.append('No entries recorded in this category.')
        for title, link, fields in group:
            out.append(f'- [{title}]({link}) — Effort: {fields["Effort"] or "not assessed"}; being worked on: {fields["Being worked on"]}.')
        out.append('')
    return '\n'.join(out)


def self_test():
    # Exercise the contributor command on a temporary repository, including stale
    # manifest output; checking SwiftPM describe alone misses unhandled-file warnings.
    with tempfile.TemporaryDirectory(prefix='turnover-app-index-') as directory:
        root = Path(directory)
        (root / 'Tools').mkdir()
        shutil.copy2(__file__, root / 'Tools/build-app-index.py')
        apps = root / 'Sources/Apps'
        for name in ('Media', 'Chat', 'Panes', 'Games', 'Catalog', 'GoogleDocs'):
            (apps / name).mkdir(parents=True)
            (apps / name / 'README.md').write_text('# Shared implementation\n')
        (root / 'docs').mkdir()
        (root / 'docs/APP-TEST-HISTORY.md').write_text('# Evidence\n')
        manifest = root / 'Package.swift'
        manifest.write_text('sources: ["Apps/Sample/Production.swift"],\nexclude: [\n    '
                            + EXCLUDES_BEGIN + '\n    ' + EXCLUDES_END + '\n]\n')
        original = manifest.read_text()
        sample = apps / 'Sample'
        sample.mkdir()
        status = ('# Sample\n\n- Bundle id: example.Sample\n- Support: Not assessed\n'
                  '- Effort: \n- Being worked on: Unclaimed\n- Checked: No evidence yet\n\n'
                  '## Findings\n\nNot checked.\n\n## Evidence\n\nNone.\n')
        (sample / 'STATUS.md').write_text(status)
        (sample / 'Production.swift').write_text('// Production file, explicitly listed.\n')
        def run(*args, succeeds=True, message=None):
            result = subprocess.run([sys.executable, str(root / 'Tools/build-app-index.py'), *args],
                                    capture_output=True, text=True, timeout=20)
            if (result.returncode == 0) != succeeds or (message and message not in result.stderr):
                raise AssertionError(result.stdout + result.stderr)
        run('--check', succeeds=False, message='App index is stale')
        run()
        run('--check')
        generated = manifest.read_text()
        (apps / '.DS_Store').write_bytes(b'Finder metadata')
        (sample / '.notes').mkdir()
        (sample / '.notes/local.txt').write_text('Ignored by SwiftPM.\n')
        run('--check')
        assert '"Apps/Sample/STATUS.md",' in generated
        assert generated.count('Apps/Sample/Production.swift') == 1
        assert manifest_with_excludes(original, []) == manifest_with_excludes(generated, [])
        run()
        assert manifest.read_text() == generated, 'generation must be idempotent'
        # A plain note changes only exclusions, so checking index freshness is insufficient.
        (sample / 'NOTES.md').write_text('# Notes\n')
        run('--check', succeeds=False, message='App record exclusions are stale')
        run()
        for name in NONPRODUCTION:
            (sample / name / 'Nested').mkdir(parents=True)
            (sample / name / 'Nested/Sample.swift').write_text('// Diagnostic sample.\n')
        run('--check', succeeds=False, message='App record exclusions are stale')
        run()
        generated = manifest.read_text()
        for name in NONPRODUCTION:
            assert f'"Apps/Sample/{name}",' in generated
            assert f'{name}/Nested' not in generated
        (sample / 'NOTES.md').unlink()
        run('--check', succeeds=False, message='App record exclusions are stale')
        run()
        assert 'NOTES.md' not in manifest.read_text()
        for suffix in ('.c', '.cc', '.cxx', '.s', '.S', '.C'):
            source = sample / ('Bridge' + suffix)
            source.write_text('// Must not be silently excluded.\n')
            run(succeeds=False, message='app production code must be Swift')
            source.unlink()
        before_index = (apps / 'README.md').read_bytes()
        before_manifest = manifest.read_bytes()
        (sample / 'STATUS.md').write_text(status + '[missing](missing.md)\n')
        run(succeeds=False, message='broken local link')
        assert (apps / 'README.md').read_bytes() == before_index
        assert manifest.read_bytes() == before_manifest
        (sample / 'STATUS.md').write_text(status)
        second = apps / 'Second'
        second.mkdir()
        (second / 'STATUS.md').write_text(status.replace('# Sample', '# Second').replace('example.Sample', 'example.Second'))
        run()
        (sample / 'STATUS.md').unlink()
        # Validate the next index, not links in the stale index that still names the removed record.
        run()
        run('--check')
        assert 'Sample/STATUS.md' not in (apps / 'README.md').read_text()
        assert 'Apps/Sample/STATUS.md' not in manifest.read_text()
        for damaged in (original.replace(EXCLUDES_BEGIN, ''), original + EXCLUDES_END + '\n',
                        EXCLUDES_END + '\n' + EXCLUDES_BEGIN + '\n'):
            manifest.write_text(damaged)
            run(succeeds=False, message='Package.swift:')
            assert manifest.read_text() == damaged
    print('app-index self-test: record and note additions/removal, excluded samples, idempotence, explicit production entries, invalid source, links and marker safeguards passed')


def main():
    if sys.argv[1:] == ['--self-test']:
        self_test()
        return
    if sys.argv[1:] not in ([], ['--check']):
        raise ValueError('Usage: python3 Tools/build-app-index.py [--check | --self-test]')
    entries = records()
    body = index(entries)
    manifest = manifest_with_excludes(MANIFEST.read_text(encoding='utf-8'), app_excludes())
    check_links(body)
    if sys.argv[1:] == ['--check']:
        if not DESTINATION.exists() or DESTINATION.read_text(encoding='utf-8') != body:
            raise ValueError('App index is stale; run python3 Tools/build-app-index.py')
        if MANIFEST.read_text(encoding='utf-8') != manifest:
            raise ValueError('App record exclusions are stale in Package.swift; run python3 Tools/build-app-index.py')
        print(f'App index, exclusions, categories and local links checked: {len(entries)} records.')
    else:
        DESTINATION.write_text(body, encoding='utf-8')
        MANIFEST.write_text(manifest, encoding='utf-8')
        print(f'Generated app index and exclusions: {len(entries)} records.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(str(error)) from error
