#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Proves the keeper (docs/PLUGIN-SCRIPTS-PLAN.md, "The keeper"; 15 Nov 2026) with a throwaway app, before the real app is built.
#
#   Tools/check-trust-keeper.sh <turnover-trust-keeper program> <signing identity> <work folder>
#
# The throwaway app, com.turnover.keepercheck, is built around the real keeper program only (never a copy of the reader): the
# same program is its host (run with --client check) and its XPC service, com.turnover.keepercheck.trust-keeper, signed as
# build.sh signs the real one, with the App Sandbox entitlement. Then:
#   (a) signed with the build's identity, the check must say ok;
#   (b) a copy whose outside is signed again ad hoc, the service inside left alone, must be refused;
#   (c) a copy whose host is signed with another identifier by the build's identity must be refused.
# (b) and (c) run the program as the attacker (--client check-as-stranger): a client that connects to the keeper without the
# team check of its own and without a requirement on the keeper, so that it is the keeper's own check that says no. The ordinary
# client refuses itself when it has no team, before the keeper is asked anything, which proves nothing about the keeper.
# Exit status: 0 all three as they should be; 2 (b) or (c) was answered, so the keeper answers a stranger (build.sh stops);
# 1 anything else: (a) failed, or a check could not be run (build.sh warns that scripts cannot be approved in this build).
# The throwaway apps are removed afterwards. Never run on its own with the real app's folder as the work folder.
set -u
KEEPER="${1:-}"; IDENTITY="${2:-}"; WORK="${3:-}"
[ -x "$KEEPER" ] && [ -n "$IDENTITY" ] && [ -n "$WORK" ] || { echo "usage: $0 <turnover-trust-keeper> <signing identity> <work folder>" >&2; exit 1; }
[ "$IDENTITY" != "-" ] || { echo "check-trust-keeper: an ad hoc build has no team, so the keeper answers nobody; nothing to prove" >&2; exit 1; }
HOSTID="com.turnover.keepercheck"
DIR="$WORK/keepercheck"
rm -rf "$DIR"; mkdir -p "$DIR" || exit 1
trap 'rm -rf "$DIR"' EXIT
# A hung check must never hang the build.
to() { perl -e 'alarm shift; exec @ARGV' "$@"; }
quiet() { "$@" 2>&1 | grep -v "replacing existing signature" || true; }

ENT="$DIR/keeper.entitlements"
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST

# make_app <folder>: Check.app with the keeper program as host and as service, both signed with the build's identity.
make_app() {
  local app="$1/Check.app" xpc="$1/Check.app/Contents/XPCServices/TurnOverTrustKeeper.xpc"
  mkdir -p "$app/Contents/MacOS" "$xpc/Contents/MacOS" || return 1
  local info="$app/Contents/Info.plist" xinfo="$xpc/Contents/Info.plist" pb=/usr/libexec/PlistBuddy
  $pb -c "Add :CFBundleIdentifier string $HOSTID" -c "Add :CFBundleName string KeeperCheck" -c "Add :CFBundleExecutable string keepercheck" \
      -c "Add :CFBundlePackageType string APPL" -c "Add :CFBundleVersion string 1" -c "Add :CFBundleShortVersionString string 1.0" \
      -c "Add :CFBundleInfoDictionaryVersion string 6.0" -c "Add :LSUIElement bool true" "$info" >/dev/null || return 1
  $pb -c "Add :CFBundleIdentifier string $HOSTID.trust-keeper" -c "Add :CFBundleName string TurnOverTrustKeeper" -c "Add :CFBundleExecutable string turnover-trust-keeper" \
      -c "Add :CFBundlePackageType string XPC!" -c "Add :CFBundleVersion string 1" -c "Add :CFBundleShortVersionString string 1.0" \
      -c "Add :CFBundleInfoDictionaryVersion string 6.0" -c "Add :XPCService dict" -c "Add :XPCService:ServiceType string Application" "$xinfo" >/dev/null || return 1
  cp "$KEEPER" "$app/Contents/MacOS/keepercheck" && cp "$KEEPER" "$xpc/Contents/MacOS/turnover-trust-keeper" || return 1
  quiet to 60 codesign --force --timestamp=none --options runtime --entitlements "$ENT" --sign "$IDENTITY" --identifier "$HOSTID.trust-keeper" "$xpc"
  quiet to 60 codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier "$HOSTID" "$app"
  codesign --verify --deep --strict "$app" 2>/dev/null
}

# run_check <app> [mode]: what the host says, and its exit status in $STATUS. The mode is check, or check-as-stranger.
run_check() {
  OUT=$(to 30 "$1/Contents/MacOS/keepercheck" --client "${2:-check}" 2>&1); STATUS=$?
  echo "    $OUT (exit $STATUS)"
}

echo "check-trust-keeper: a throwaway app around the keeper program, signed with this build's identity"
make_app "$DIR/genuine" || { echo "check-trust-keeper: the throwaway app could not be made or signed" >&2; exit 1; }
RESULT=0

echo "  (a) the app's own host:"
run_check "$DIR/genuine/Check.app"
if [ $STATUS -ne 0 ]; then echo "check-trust-keeper: the keeper did not answer its own app" >&2; RESULT=1; fi

echo "  (b) a copy whose outside is signed again ad hoc, the service inside untouched:"
mkdir -p "$DIR/adhoc" && ditto "$DIR/genuine/Check.app" "$DIR/adhoc/Check.app" || exit 1
quiet to 60 codesign --force --timestamp=none --sign - "$DIR/adhoc/Check.app"
run_check "$DIR/adhoc/Check.app" check-as-stranger
if [ $STATUS -eq 0 ]; then echo "check-trust-keeper: THE KEEPER ANSWERED AN AD HOC COPY OF THE APP" >&2; exit 2; fi
if [ $STATUS -ne 3 ]; then echo "check-trust-keeper: (b) gave neither an answer nor a refusal (exit $STATUS); it could not be judged" >&2; RESULT=1; fi

echo "  (c) a copy whose host is signed with another identifier by the same identity:"
mkdir -p "$DIR/other" && ditto "$DIR/genuine/Check.app" "$DIR/other/Check.app" || exit 1
quiet to 60 codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier "$HOSTID.other" "$DIR/other/Check.app"
run_check "$DIR/other/Check.app" check-as-stranger
if [ $STATUS -eq 0 ]; then echo "check-trust-keeper: THE KEEPER ANSWERED A PROGRAM WITH ANOTHER IDENTIFIER" >&2; exit 2; fi
if [ $STATUS -ne 3 ]; then echo "check-trust-keeper: (c) gave neither an answer nor a refusal (exit $STATUS); it could not be judged" >&2; RESULT=1; fi

[ $RESULT -eq 0 ] && echo "check-trust-keeper: the keeper answers its own app and refuses a stranger"
exit $RESULT
