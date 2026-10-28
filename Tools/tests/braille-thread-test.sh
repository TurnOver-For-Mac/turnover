#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
# Keep the executable temporary even when a test fails. No app is launched and no real display is opened.
TESTBIN=$(mktemp "${TMPDIR:-/tmp}/turnover-braille-test.XXXXXX")
trap 'rm -f "$TESTBIN"' EXIT
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
    -I Sources/TurnOverBraille/include Sources/TurnOverBraille/TOAppleBraille.m Tools/tests/braille-thread-test.m \
    -framework Foundation -framework IOKit -framework IOBluetooth -o "$TESTBIN"
"$TESTBIN"
