# Document snapshots

Browse mode requests its accessibility data asynchronously. `WebBuffer.build()` returns immediately. A document
owns one `AXWalkRunner` with one executing collection and one replaceable pending collection. Repeated refresh
requests share the current collection. Each caller keeps its completion and checks whether its intent is current.
A refresh requested during a continuation waits for that pass and then collects from the root.
Dirty notifications arriving during collection remain due for a subsequent refresh. An edge search requests at
most one extra collection for its command, so an infinite feed cannot turn one heading key into endless scrolling.

`WebBufferCollection` captures an immutable `AXSnapshot` on the worker. Attributes, action names, labels and
window/ancestor stubs cross the boundary as checked `Sendable` values. The collection has a two-second cooperative
deadline, 6,000-element and 24,000-AX-query caps, a depth cap and cycle detection. Attribute counts and retained
strings are bounded too. A native AX call already in progress cannot be interrupted; cancellation never waits
for it on main, and the runner rejects its result again at delivery.

Main interprets the captured attributes using the existing object factory, app overlays, profile labels and
speech presentation rules. `AXSnapshot.with` provides a synchronous thread-local read scope: attributes missing
from the snapshot remain missing, and uncaptured parameter queries or writes cannot fall through to live AX.
The scope is restored on return or throw and is never held across suspension. Opaque provider objects are omitted;
attributed descriptions retain their plain text. Password fields exclude value-bearing attributes.

Local layout has a 100 ms cooperative deadline. It publishes text, lines, segments, containers and accessibility
metadata in one replacement. The model reports loading, complete, partial, unavailable or cancelled separately.
Deadline, node, query, depth, cycle, provider-failure and backoff stops all remain incomplete. An empty successful
collection is distinct from a failed collection with no content.

During a same-page refresh, commands can continue reading the previous publication. A failed refresh with no
usable content retains that publication, marks it incomplete and leaves it due for retry. At replacement, the document
anchors the current caret by its line text and offset. It does not restore the position from request time.
`BufferTextInfo` and its copies retain the publication their offsets describe. Say All uses that copy for speech
and stop positions. Across a refresh it moves the live caret only when it can match the spoken line.

At the end of a partial page, the next collection starts at the saved frontier. The worker checks the page address
and collects the remaining elements under the same per-pass limits. Main appends their text using the merged
snapshot, preserving the published prefix and its offsets. A failed continuation leaves the cached page partial
and due for refresh. Say All can move to a newer publication when the text it has read is still an exact prefix.
A refresh of a long page can collect several passes before publication to reach the reader's position.

A URL change clears the old publication and advances the document generation. The worker also checks for a URL
change during collection, and publication checks the captured address against the requesting document. Leaving the document, retiring it or handing control to VoiceOver cancels collection
and deferred actions. Callbacks additionally check the document generation, current interceptor, latest key
intent and reading position before moving or speaking. A burst of keys cannot become a delayed burst of moves.

Page loading, focus tracking, manual refresh, missing quick-navigation targets, scroll-for-more consume asynchronous results. Kindle retains its existing page-turn policy and only waits for build completion. Loading timers discover replacement roots on a separate bounded worker and
apply app root policies only to that captured window. Partial documents keep the existing partial-page announcement. New spoken wording and paged-reading policy changes are deferred.

`buildForInspection()` is an explicit synchronous path for the command-line plugin inspector. Interactive reader
code must use `build(completion:)`. This change does not move every AX operation out of browse commands: native
focus/actions, navigation metadata, WebKit structural search and selection bridges retain their existing owners. The keyboard's
150 ms script-decision timeout and replay rules are unchanged.

`WebBufferTests` holds workers and main delivery independently, checks coalescing and stale generations, preserves
the caret moved during refresh, compares control presentation with existing object rules, and checks snapshot
scope isolation and actual collector stops. Existing recorded-page tests wait for publication before checking
navigation. Live validation still needs Safari and Chromium pages, focus/browse transitions, long-page boundaries,
Back/Forward, VoiceOver handover, and Kindle page turns where available. A passing build does not establish speech
quality or the behavior of those applications.

The 6,000-element cap applies to each pass. This combines the worker collection from issue 119 with the long-page
continuation added for issue 227.
