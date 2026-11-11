# Document adapter boundary

Shared events, browse mode and editing code call `DocumentAdapters`; the built-in registration supplies the
Google editor adapter from `Sources/Apps/GoogleDocs`. Browser app modules continue to own native browser UI.

This first change delegates to the existing `GoogleDocs.swift` implementation unchanged. Recognition, the global
100 ms timer and announcement baseline, the three-second support check, private speech, limits and key decisions
are retained. The full 12 Oct 2026 observations remain beside the original code. Return still calls typed-character
echo, and forward Delete retains the ordinary editing path.

Background polling belongs to a follow-up under issue 119. Return and forward Delete pass-through require a
separate issue and change. Those follow-ups should test query/fragment identity, invalid reply cleanup, and
recovery after menus or window switches without a focus event.

Verification uses the custom test harness and `./build.sh --no-install`. The unchanged Google implementation can
also be compared byte-for-byte with main. Speech and browser/editor trials must be reported separately from
automated checks.
