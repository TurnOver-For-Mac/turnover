#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
# Compile the exact executable-owned output extension against the freshly built
# production core. Never launch the TurnOver app or touch reader/settings state.
BUILD="${1:?pass the build scratch directory}"
BIN="$BUILD/release"
# SwiftPM uses the checkout identity for package-scoped test hooks.
PACKAGE_ID=$(python3 -c 'import pathlib, re; print(re.sub(r"[^a-z0-9_]", "_", pathlib.Path.cwd().name.lower()))')
MODULEMAPS="$BUILD/out/Intermediates.noindex/GeneratedModuleMaps"
if [ -f "$MODULEMAPS/TurnOverBraille.modulemap" ]; then
    BRAILLE_MAP="$MODULEMAPS/TurnOverBraille.modulemap"
    OBJC_MAP="$MODULEMAPS/TurnOverObjC.modulemap"
else
    BRAILLE_MAP="$BIN/TurnOverBraille.build/module.modulemap"
    OBJC_MAP="$BIN/TurnOverObjC.build/module.modulemap"
fi
TESTDIR=$(mktemp -d "${TMPDIR:-/tmp}/turnover-mode-wiring.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
compile() {
    xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library -package-name "$PACKAGE_ID" \
        -I "$BIN/Modules" -I "$BIN" \
        -Xcc "-fmodule-map-file=$BRAILLE_MAP" -Xcc "-fmodule-map-file=$OBJC_MAP" \
        -I Sources/TurnOverBraille/include -I Sources/TurnOverObjC/include \
        -L "$BIN" -lTurnOverCore -Xlinker -rpath -Xlinker "$BIN" \
        "$1" "$2" Tools/tests/mode-wiring/Harness.swift -o "$TESTDIR/mode-wiring"
}
EXTENSION=Sources/TurnOver/LeadWatcherModeSpeech.swift
TAP=Sources/TurnOver/VoiceOverTap.swift
compile "$EXTENSION" "$TAP"
"$TESTDIR/mode-wiring"
# Prove these regression tests fail if either production reader output is
# disconnected, or the getter returns the pre-probe confirmation again.
python3 - "$TESTDIR" <<'PYTHON'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
source = Path('Sources/TurnOver/LeadWatcherModeSpeech.swift').read_text()
for name, old, new in [
    ('no-turnover', 'Speech.speakMessage(text)', '/* disconnected */'),
    ('no-voiceover', 'VoiceOverSpeak.sayToVoiceOver(text, current:', 'discardVoiceOver(text, current:')
]:
    assert source.count(old) == 1
    mutant = source.replace(old, new)
    if name == 'no-voiceover':
        mutant += '\n@MainActor private func discardVoiceOver(_ text: String, current: @escaping @MainActor () -> Bool) {}\n'
    (folder / (name + '.swift')).write_text(mutant)
tap = Path('Sources/TurnOver/VoiceOverTap.swift').read_text()
old = '        if let announcementTestDriver { announcementTestDriver() }'
assert tap.count(old) == 1
tap = tap.replace(old, '        let staleValue = confirmation.value(pid: pid, wanted: wantedSilent, now: now)\n' + old)
old = '        return confirmation.value(pid: pid, wanted: wantedSilent, now: now)'
assert tap.count(old) == 1
tap = tap.replace(old, '        return staleValue')
(folder / 'stale-confirmation.swift').write_text(tap)
PYTHON
for mutant in no-turnover no-voiceover stale-confirmation; do
    if [ "$mutant" = stale-confirmation ]; then
        compile "$EXTENSION" "$TESTDIR/$mutant.swift"
    else
        compile "$TESTDIR/$mutant.swift" "$TAP"
    fi
    if "$TESTDIR/mode-wiring" > "$TESTDIR/$mutant.log" 2>&1; then
        echo "mode wiring: mutation survived: $mutant"
        exit 1
    fi
    if ! grep -Eq '^mode wiring: [1-9][0-9]* failed$' "$TESTDIR/$mutant.log"; then
        cat "$TESTDIR/$mutant.log"
        echo "mode wiring: mutation did not fail through a regression assertion: $mutant"
        exit 1
    fi
    echo "mode wiring: rejected mutation $mutant"
done
