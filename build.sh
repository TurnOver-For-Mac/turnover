#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build TurnOver and the probe harness, wrap the reader in an app bundle, sign it
# with the Apple Development identity (so the Accessibility grant survives
# rebuilds), install it to /Applications and relaunch it.
#
# Read the newest file in ~/Library/Application Support/TurnOver/logs/ afterwards.
#
# Builds outside the project directory: extended attributes on files in the
# source folder (from a synced folder, for one) make codesign refuse bundles.
set -e
cd "$(dirname "$0")"

BUILD="${TURNOVER_BUILD:-$HOME/Library/Developer/TurnOver/build}"
# Developer ID when there is one, as the published builds: Accessibility and Input Monitoring are kept for every
# account on the Mac, one entry per app, tied to the signature. A development copy signed differently and a tester
# account's published copy took that entry from each other, and macOS kept asking both (5 Oct 2026).
DEVID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
# No Developer ID: an Apple Development certificate if there is one, otherwise ad hoc ("-"), so anyone can build.
[ -n "$DEVID" ] || DEVID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)
IDENTITY="${TURNOVER_IDENTITY:-${DEVID:--}}"
# One app, named "TurnOver". The marker is checked in every slice of the core below (code review, 16 Oct 2026).
APPNAME="TurnOver"
SWIFTFLAGS=""
BUNDLEID="com.turnover.reader"; FEEDURL="https://doll-eye.github.io/turnover-updates/appcast.xml"; MARKER="TURNOVER-EDITION-BETA"
APP="$BUILD/$APPNAME.app"
INSTALL="/Applications/$APPNAME.app"
# Signing asks Apple's time server for a timestamp; with the network down it fails and leaves the app unsigned, and
# macOS then no longer trusts TurnOver with Accessibility (6 Oct 2026: a Mac was left with no speech). A local build
# signs without the timestamp when the server cannot be reached; a published build is signed again, with one.
sign() {
  local out
  out=$(codesign "$@" 2>&1)
  if echo "$out" | grep -q "timestamp"; then
    echo "codesign: no timestamp server; signing without one" >&2
    out=$(codesign --timestamp=none "$@" 2>&1)
  fi
  echo "$out" | grep -v "replacing existing signature" || true
}

if ! xcodebuild -version >/dev/null 2>&1; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]; then
      DEVELOPER_DIR="$candidate/Contents/Developer"; export DEVELOPER_DIR; break
    fi
  done
fi

mkdir -p "$BUILD"
# A failed compile must not install yesterday's binary.
# (Every product, the Settings app and the test runners too: a stale one of those installed or ran as if new. From an
# outside audit, pull request 13, 26 Oct 2026.)
for f in turnover turnover-probe turnover-plugin turnover-key turnover-settings turnover-tests turnover-coretest libTurnOverCore.dylib; do
  rm -f "$BUILD/release/$f"
done
# The recipes and official listings, built into the program (make-embedded.py).
python3 make-embedded.py || { echo "STOP: make-embedded.py failed"; exit 1; }
# The compiler's own exit status decides, not only whether the files exist: a build that failed after a product was
# written went on to install (the same audit).
set +e
# The compiler lists the translatable strings as it goes (Package.swift's translatable), for the catalog.
export TURNOVER_STRINGS="$BUILD/strings"
swift build -c release --scratch-path "$BUILD" $SWIFTFLAGS 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\]'
BUILD_STATUS=${PIPESTATUS[0]}
set -e
[ "$BUILD_STATUS" -eq 0 ] || { echo "build failed"; exit "$BUILD_STATUS"; }
[ -x "$BUILD/release/turnover" ] && [ -x "$BUILD/release/turnover-key" ] && [ -f "$BUILD/release/libTurnOverCore.dylib" ] || { echo "build failed"; exit 1; }
# The unit tests (Sources/TurnOverTests): a failing test stops the install (8 Oct 2026). TURNOVER_SKIP_TESTS=1 to skip.
if [ "$TURNOVER_SKIP_TESTS" != 1 ]; then
  "$BUILD/release/turnover-tests" || { echo "build.sh: tests failed; not installing"; exit 1; }
  bash Tools/tests/braille-thread-test.sh
fi

# TURNOVER_UNIVERSAL=1 (for release builds): an Intel build as well, merged with the Apple Silicon one, so the app runs on both.
BIN="$BUILD/release"
if [ "$TURNOVER_UNIVERSAL" = 1 ]; then
  X86="$BUILD-x86_64"
  for f in turnover turnover-probe turnover-plugin turnover-key turnover-settings turnover-tests turnover-coretest libTurnOverCore.dylib; do
    rm -f "$X86/release/$f"
  done
  set +e
  swift build -c release --scratch-path "$X86" --triple x86_64-apple-macosx14.0 $SWIFTFLAGS 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\]'
  X86_BUILD_STATUS=${PIPESTATUS[0]}
  set -e
  [ "$X86_BUILD_STATUS" -eq 0 ] || { echo "Intel build failed"; exit "$X86_BUILD_STATUS"; }
  [ -x "$X86/release/turnover" ] && [ -x "$X86/release/turnover-key" ] && [ -f "$X86/release/libTurnOverCore.dylib" ] || { echo "Intel build failed"; exit 1; }
  BIN="$BUILD/universal"
  rm -rf "$BIN"; mkdir -p "$BIN"
  for f in turnover turnover-plugin turnover-key turnover-settings libTurnOverCore.dylib; do
    lipo -create "$BUILD/release/$f" "$X86/release/$f" -output "$BIN/$f"
  done
  echo "Universal: $(lipo -archs "$BIN/turnover")"
fi
# Every slice carries the marker (an Intel slice once built without the right flags would have shipped as it was).
for arch in $(lipo -archs "$BIN/libTurnOverCore.dylib"); do
  strings -arch "$arch" "$BIN/libTurnOverCore.dylib" | grep -q "^$MARKER$" || { echo "STOP: the $arch slice of the core has no $MARKER"; exit 1; }
done

# TurnOver's helper programs: Steam speech (14 Oct 2026), Trackpad gestures and VoiceOver quiet, in Helpers/. Each
# built, its self-test run, carried in the bundle and signed with TurnOver. A release build stops without them.
HELPERSRC="$(cd "$(dirname "$0")" && pwd)/Helpers"
HELPERBINS=()
for H in steam-speech trackpad-gestures voiceover-quiet; do
  SRC="$HELPERSRC/$H"
  if [ ! -f "$SRC/Package.swift" ]; then
    [ "$TURNOVER_UNIVERSAL" = 1 ] && { echo "STOP: $SRC is missing: a build for testers needs it"; exit 1; }
    echo "build.sh: WARNING: $SRC is missing; built without $H"; continue
  fi
  SB="$BUILD-$H"   # beside the main build, so two checkouts never share a helper's build
  rm -f "$SB/release/$H"
  swift build -c release --package-path "$SRC" --scratch-path "$SB" 2>&1 | grep -E "error:" || true
  { [ -x "$SB/release/$H" ] && "$SB/release/$H" --self-test; } || { echo "build.sh: $H failed to build or its self-test failed; not installing"; exit 1; }
  BINH="$SB/release/$H"
  if [ "$TURNOVER_UNIVERSAL" = 1 ]; then
    rm -f "$SB-x86_64/release/$H"
    # The helper's own lowest macOS: voiceover-quiet needs 14.2 (process taps), which TurnOver checks before starting it.
    MINOS=$(grep -o 'macOS("[0-9.]*")' "$SRC/Package.swift" | grep -o '[0-9.]*' | head -1); MINOS=${MINOS:-14.0}
    swift build -c release --package-path "$SRC" --scratch-path "$SB-x86_64" --triple x86_64-apple-macosx$MINOS 2>&1 | grep -E "error:" || true
    [ -x "$SB-x86_64/release/$H" ] || { echo "Intel build of $H failed"; exit 1; }
    lipo -create "$SB/release/$H" "$SB-x86_64/release/$H" -output "$SB/$H-universal"
    BINH="$SB/$H-universal"
  fi
  HELPERBINS+=("$H:$BINH")
done

# New strings into Resources/Localizable.xcstrings, untranslated until someone translates them (make-strings.py):
# TurnOver's own and its helpers' (Steam speech's words are said too), so after the helpers are built.
python3 make-strings.py sync "$TURNOVER_STRINGS" || { echo "STOP: make-strings.py sync failed"; exit 1; }

# The probe: sign in place.
sign --force --sign "$IDENTITY" --identifier com.turnover.probe "$BUILD/release/turnover-probe"

# The reader: assemble the bundle.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/turnover" "$APP/Contents/MacOS/turnover"
for hb in "${HELPERBINS[@]}"; do mkdir -p "$APP/Contents/Helpers"; cp "${hb#*:}" "$APP/Contents/Helpers/${hb%%:*}"; done
cp NOTICE.md "$APP/Contents/Resources/NOTICE.md"
# The built-in app recipes (docs/APP-RECIPES-PLAN.md): one JSON file per app.
# Built into the program now (make-embedded.py, run before the build): no readable folder in the app (18 Oct 2026).
rm -rf "$APP/Contents/Resources/recipes"
# TurnOver's own sound set (make-sounds.py writes it; 17 Oct 2026).
rm -rf "$APP/Contents/Resources/Sounds"; cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"
# The guide inside the app, made from the guides (Guides/*.md, 18 Oct 2026).
python3 make-guides.py --text "Resources/TurnOver Guide.txt"
cp "Resources/TurnOver Guide.txt" "$APP/Contents/Resources/TurnOver Guide.txt"
# The plugin maker's tool and its guide (PLUGIN-GUIDE.md), for people and their AIs (17 Oct 2026), and the plugin
# format's schemas, for editors and AIs.
cp "$BIN/turnover-plugin" "$APP/Contents/MacOS/turnover-plugin"
cp PLUGIN-GUIDE.md "$APP/Contents/Resources/PLUGIN-GUIDE.md"
rm -rf "$APP/Contents/Resources/plugin-schema"; cp -R Resources/plugin-schema "$APP/Contents/Resources/plugin-schema"
# Left by older builds: the beta guide (the guides replaced it) and the listings (built into the program now,
# make-embedded.py).
rm -rf "$APP/Contents/Resources/official" "$APP/Contents/Resources/TurnOver Beta Guide.txt"
# Each build's "New to try" list from CHANGELOG.md, for the app to announce after an update.
python3 make-changes.py try CHANGELOG.md "$APP/Contents/Resources/new-to-try.json"
# The core is a dynamic library (add-ons link it); the executable looks for it in Contents/Frameworks.
cp "$BIN/libTurnOverCore.dylib" "$APP/Contents/Frameworks/libTurnOverCore.dylib"
# Sparkle (updates): its framework already holds both architectures.
SPARKLE="$BUILD/release/Sparkle.framework"
[ -d "$SPARKLE" ] || { echo "Sparkle.framework missing from the build"; exit 1; }
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLEID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEEDURL" "$APP/Contents/Info.plist"
if [ "$APPNAME" != "TurnOver" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APPNAME" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APPNAME" "$APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APPNAME" "$APP/Contents/Info.plist"
fi
# A build not stripped for release is a developer's build: only it honours the developer switches (Edition.isDevBuild).
[ "$TURNOVER_STRIP" = 1 ] || /usr/libexec/PlistBuddy -c "Add :TODevBuild bool true" "$APP/Contents/Info.plist"
# A development build (installed here) takes no updates: a published build would replace the work in progress.
[ "$1" = "--no-install" ] || /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# TurnOver Key (Command+Control+Period starts and quits TurnOver): a login-item helper inside the bundle.
# TurnOver Settings: the settings in a window, an app of its own inside TurnOver.app (18 Oct 2026).
SETAPP="$APP/Contents/Applications/TurnOver Settings.app"
rm -rf "$SETAPP"; mkdir -p "$SETAPP/Contents/MacOS"
cp "$BIN/turnover-settings" "$SETAPP/Contents/MacOS/turnover-settings"
cp Resources/TurnOverSettings-Info.plist "$SETAPP/Contents/Info.plist"
printf 'APPL????' > "$SETAPP/Contents/PkgInfo"
KEYAPP="$APP/Contents/Library/LoginItems/TurnOver Key.app"
mkdir -p "$KEYAPP/Contents/MacOS"
cp "$BIN/turnover-key" "$KEYAPP/Contents/MacOS/turnover-key"
cp Resources/TurnOverKey-Info.plist "$KEYAPP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :TOReaderID string $BUNDLEID" "$KEYAPP/Contents/Info.plist"   # the reader this helper starts
printf 'APPL????' > "$KEYAPP/Contents/PkgInfo"
# The translations, as <language>.lproj in each of the three apps: macOS picks the person's language, and English
# where there is none (make-strings.py).
python3 make-strings.py compile "$APP/Contents/Resources" "$SETAPP/Contents/Resources" "$KEYAPP/Contents/Resources" || { echo "STOP: make-strings.py compile failed"; exit 1; }
# TURNOVER_STRIP=1 (for release builds): stripped before it is signed, to keep it small. Swift keeps
# class names, which its runtime needs. The unstripped programs are
# kept privately, by their UUID, to read crash reports: atos -o <copy> -l <load address> <addresses>.
if [ "$TURNOVER_STRIP" = 1 ]; then
  KEYEXE="$KEYAPP/Contents/MacOS/turnover-key"
  for f in "$APP/Contents/MacOS/turnover" "$APP/Contents/MacOS/turnover-plugin" "$APP/Contents/Frameworks/libTurnOverCore.dylib" "$KEYEXE"; do
    [ -f "$f" ] || { echo "STOP: $f is missing, nothing stripped"; exit 1; }
    uuid=$(dwarfdump --uuid "$f" | awk '{print $2}' | head -1)
    mkdir -p "$HOME/Library/Developer/TurnOver/symbols/$uuid"
    cp "$f" "$HOME/Library/Developer/TurnOver/symbols/$uuid/"
  done
  strip "$APP/Contents/MacOS/turnover" "$KEYEXE" || { echo "STOP: strip failed"; exit 1; }
  [ -f "$APP/Contents/MacOS/turnover-plugin" ] && { strip "$APP/Contents/MacOS/turnover-plugin" || { echo "STOP: strip failed"; exit 1; }; }
  strip -x "$APP/Contents/Frameworks/libTurnOverCore.dylib" || { echo "STOP: strip failed on the core library"; exit 1; }   # keeps what the programs link against
  echo "Stripped: $(nm "$APP/Contents/MacOS/turnover" 2>/dev/null | wc -l | tr -d ' ') names left in turnover; unstripped copies in ~/Library/Developer/TurnOver/symbols"
fi
sign --force --sign "$IDENTITY" --identifier com.turnover.key "$KEYAPP"
sign --force --sign "$IDENTITY" --identifier com.turnover.settings "$SETAPP"
# Sparkle inside out, as its documentation sets out (a published build is signed again for distribution).
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for f in "$SPK/XPCServices/Installer.xpc" "$SPK/XPCServices/Downloader.xpc" "$SPK/Autoupdate" "$SPK/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  sign --force --sign "$IDENTITY" --preserve-metadata=entitlements "$f"
done
sign --force --sign "$IDENTITY" --identifier com.turnover.core "$APP/Contents/Frameworks/libTurnOverCore.dylib"
[ -f "$APP/Contents/MacOS/turnover-plugin" ] && sign --force --sign "$IDENTITY" --identifier com.turnover.plugin-tool "$APP/Contents/MacOS/turnover-plugin"
for h in steam-speech trackpad-gestures voiceover-quiet; do [ -f "$APP/Contents/Helpers/$h" ] && sign --force --sign "$IDENTITY" --identifier "com.turnover.$h" "$APP/Contents/Helpers/$h"; done
sign --force --sign "$IDENTITY" --identifier "$BUNDLEID" "$APP"

# Never install a TurnOver macOS will not trust: it would come up with no permissions and no speech.
if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
  echo "build.sh: TurnOver.app is not properly signed; not installing" >&2
  exit 1
fi

if [ "$1" != "--no-install" ]; then
  # A restart, not a quit: TurnOver leaves VoiceOver as it is (it turns VoiceOver on when it really goes).
  mkdir -p "$HOME/Library/Application Support/TurnOver" && touch "$HOME/Library/Application Support/TurnOver/restarting"
  # Never replace a working TurnOver with a broken bundle: on 8 Oct 2026 an install left no executable, and no screen
  # reader at all until VoiceOver was started by hand.
  if [ ! -x "$APP/Contents/MacOS/turnover" ] || ! codesign --verify "$APP" >/dev/null 2>&1; then
    echo "the new bundle is incomplete or unsigned; the installed TurnOver is untouched"; exit 1
  fi
  pkill -x turnover 2>/dev/null || true
  # TurnOver Key: launchd names it by its bundle identifier, not its executable. TurnOver starts the new one.
  pkill -x turnover-key 2>/dev/null || true
  # A Settings window left open from the copy being replaced: the new TurnOver turns it away (its signature is checked
  # against files no longer there) and it shows TurnOver as off until reopened (issue 77; again on 25 Oct 2026).
  pkill -x turnover-settings 2>/dev/null || true
  pkill -f "com.turnover.key" 2>/dev/null || true
  pkill -x turnover 2>/dev/null || true
  sleep 0.5
  rm -rf "$INSTALL"
  ditto "$APP" "$INSTALL"
  # Launch Services can still think the just-replaced bundle has no executable ("cannot be opened because its
  # executable is missing", twice on 8 Oct 2026, with the file plainly there): try by path, then again a moment later.
  sleep 1
  open -g "$INSTALL" || true
  i=0; while [ $i -lt 10 ] && ! pgrep -x turnover >/dev/null; do sleep 0.5; i=$((i+1)); done
  if ! pgrep -x turnover >/dev/null; then sleep 2; open -g -a "$INSTALL" || true; fi
  # If it isn't running a few seconds later, bring VoiceOver back so the user is never left without speech.
  i=0; while [ $i -lt 10 ] && ! pgrep -x turnover >/dev/null; do sleep 0.5; i=$((i+1)); done
  if ! pgrep -x turnover >/dev/null; then echo "TurnOver did not start; starting VoiceOver"; open -a VoiceOver; fi
  sleep 2
  LOG=$(ls -t "$HOME/Library/Application Support/TurnOver/logs/turnover-"*.log 2>/dev/null | head -1)
  echo "Installed and launched: $INSTALL"
  echo "Log: $LOG"
fi
