# Reports for Apple, 28 October 2026

Measured on macOS 27.2 (26B118), MacBook, with TurnOver (an open-source third-party screen reader) and
standalone probes against the accessibility API. All seven were filed through Feedback Assistant in the early hours of 28 October 2026 (the FB numbers are on each
heading); the email about the announcements went to accessibility@apple.com the same night. Area in brackets.

---

## 1. App Store: the accessibility tree names recycled cells after a scroll (macOS, App Store) — filed FB25345215

**Title:** App Store search results: accessibility names and hit tests describe recycled cells, not what is drawn

**Description:**
On the search results page, after the page has scrolled, the accessibility elements for the result tiles describe
other content than the screen shows.

Steps:
1. Open the App Store, search for "water".
2. Set the results scroll area's vertical scroll bar AXValue to 0.4 (AXScrollToVisible does nothing, see a separate
   report).
3. Call AXUIElementCopyElementAtPosition on points across the visible area and read each hit's enclosing result
   tile (identifier contains "shelfItem…ContentSearchResultCollectionViewCell") and its title.

Result: the hit tests name tiles from the Discover page (Pages: Create Documents, Weather Dock, ClassicWeather,
Apple Arcade, a STORY tile) while the screen shows water results. A synthetic click at the point named "STORY"
opened the product page of "Water Meter: IoT Platform". Screenshots taken at the same time show two titles drawn in
one tile ("Water Sort Color Puzzle" over "Paint Expert", "ibisPaint" over "Water Sort").

Expected: the accessibility tree and hit testing describe what is drawn; a reused collection view cell updates its
accessibility title, description and identifier when it is rebound.

Impact: a screen reader cannot open a search result reliably; automation and UI tests have the same problem.

---

## 2. App Store: AXScrollToVisible is accepted and does nothing (macOS, App Store) — filed FB25345221

**Title:** App Store: AXScrollToVisible on a result row or the results list returns success but does not scroll

**Description:**
Steps: search for "water"; take a result row (AXGroup, identifier containing ContentSearchResultCollectionViewCell)
whose frame is below the window; perform AXScrollToVisible on it, then on its parent AXList
(AppStore.search.result).

Result: both return kAXErrorSuccess; the page does not move; the row's AXFrame is unchanged. Only writing the
scroll area's vertical scroll bar AXValue moves the page.

Expected: AXScrollToVisible brings the element into view, as in AppKit.

---

## 3. App Store: results that are not yet drawn have no accessible title (macOS, App Store) — filed FB25345234

**Title:** App Store search results: undrawn result cells return invalid elements for their title until scrolled on screen

**Description:**
The results AXList lists every result as a child, but a child whose cell has not been drawn answers
kAXErrorInvalidUIElement for the title and description of its inner group until it scrolls into view. The children
are readable in bursts as cells are realised.

Also: a new search opens at the previous page's scroll offset. A search for "hydration" after "water" opened with the
results list's frame at y = -7300 points, so its first rows were above the window and unreadable.

Expected: the children of a list expose their titles whether drawn or not (as AppKit table views do), or the list
exposes only the realised rows and AXVisibleRows / row count; a new search starts at the top.

---

## 4. App Store: a row's frame lags the layout by one row (macOS, App Store) — filed FB25345239

**Title:** App Store search results: AXFrame of a result row is stale by one row after a reflow

**Description:**
Steps: search for "water"; wait for the results to settle; read AXFrame of row 6; hit test (AXUIElementCopyElementAtPosition)
at the centre of that frame's icon area.

Result: the hit test names the row before it. The frames catch up after a further scroll. A click at the frame's
point opens the wrong app.

Expected: AXFrame reflects the current layout.

---

## 5. VoiceOver: a setting to silence "VoiceOver on" and "VoiceOver off" (macOS, Accessibility) — filed FB25345243

**Title:** VoiceOver: please add a setting to suppress the "VoiceOver on" and "VoiceOver off" announcements

**Description:**
People who use another screen reader alongside VoiceOver switch VoiceOver on and off per app, many times an hour,
with its shortcut. Each switch speaks "VoiceOver on" or "VoiceOver off" (SCRWorkspace.quickStart / quickStop).
There is no setting under VoiceOver Utility > Verbosity > Announcements, or anywhere else, to turn these two
announcements off. Please add one, or honour the Announcements verbosity level for them.

---

## 6. Third-party screen readers: a supported way to get the responsiveness VoiceOver gets (Developer Technologies & SDKs, Accessibility) — filed FB25345255

**Title:** Request: a documented entitlement or API for assistive technology so third-party screen readers' accessibility requests are served as VoiceOver's are

**Description:**
A third-party screen reader uses the public AXUIElement API with Accessibility and Input Monitoring granted by the
user. When an app is busy, its requests time out, while VoiceOver's are answered at once.

Measurement (App Store, 27 Oct 2026): immediately after Return in the search field, reading the sidebar took 11
accessibility calls and 2002 ms in them; the app then stopped answering for about 3 s. VoiceOver reads the same
page during the same seconds. On the results page, a scan of the visible area by hit test takes 300 to 550 ms for
340 calls; a row's name answers only when its cell is drawn.

Request: a documented way for user-authorised assistive technology to receive the same service level as VoiceOver,
through an entitlement granted with the existing user consent, or an API that lets an assistive process declare
itself. Without it, every third-party reader is built on timeouts and retries.

---

## 7. Secure input: let user-authorised assistive technology see key events in password fields (Developer Technologies & SDKs, Accessibility) — filed FB25345265

**Title:** Request: a supported way for assistive technology to keep receiving key events while secure input is on

**Description:**
With a password field focused, macOS turns on secure input and the event tap of a third-party screen reader no
longer sees any key. VoiceOver keeps working there. For TurnOver the arrow keys die in a password field: the user
cannot leave the field with the reader's own keys, only with Tab, and cannot review what the field holds (its length)
as the reader does elsewhere. Typed characters are never spoken or logged by the reader.

Request: a documented path (entitlement or API, with user consent) that lets assistive technology receive key
events for navigation while secure input is on, as VoiceOver does.

---

## 8. The umbrella: a supported assistive technology platform on macOS (Developer Technologies & SDKs, Accessibility Framework, Suggestion) — filed FB25345326

**Title:** Request: a declared assistive technology role on macOS, with the services a third-party screen reader needs

**Description:**
I write TurnOver, an open-source screen reader for the Mac that people run alongside VoiceOver. On macOS, VoiceOver
is part of the system and a third-party screen reader is an ordinary app with the Accessibility and Input Monitoring
permissions. Windows and Android each have a declared role for assistive technology, with the privileges that role
needs; macOS has none. Every one of the problems below comes from that gap. This is a request for one thing, a
declared assistive technology process (an entitlement or a registration, granted with the user's existing consent),
and for the services that process needs. The individual bugs are filed separately (FB25345215, FB25345221,
FB25345234, FB25345239, FB25345243, FB25345255, FB25345265); this report is the platform request they add up to.

1. Service level. Accessibility requests from the declared process served while an app is busy, as VoiceOver's are.
   Measured: after Return in the App Store's search field, 11 requests took 2002 ms and the app then answered nothing
   for about 3 s, while VoiceOver read the same page in the same seconds (FB25345255).

2. A bulk tree read. One call that returns a subtree with the attributes asked for, instead of one IPC round trip per
   element per attribute. One arrow press on a Store page costs 264 calls; a web page costs thousands. This single API
   would do more for third-party reader performance than anything else.

3. Reliable notifications. Registration that does not fail silently (TurnOver's log records "0 of 24 notifications
   registered" for a process and retries), and a notification when a virtualised list realises its rows, so a reader
   knows when titles become readable (FB25345234).

4. A supported key hook. Ordered, consumable key events for the declared process, delivered while secure input is on
   (password fields, FB25345265), in the login window and on the lock screen, where VoiceOver works and a third-party
   reader cannot. Today the only route is a CGEvent tap, which secure input blinds.

5. System dialogs and the login window. The declared process allowed to run and read there, including the
   permission prompts that at present take only a physical key.

6. Speech. The system's premium and Siri voices available to the declared process through the public speech API,
   and a priority audio route with correct ducking.

7. Braille. Access to the braille display drivers VoiceOver uses, so each reader need not write its own.

8. Screen reading. Window capture for on-device text recognition for the declared process without the full Screen
   Recording grant, scoped to the front window.

9. Apple's own apps. A conformance bar: the accessibility tree matches the screen, and standard actions do what
   they say. On macOS 27.2 the App Store's search results name recycled cells after a scroll, AXScrollToVisible is a
   no-op, undrawn rows have no title and frames lag the layout (FB25345215, FB25345221, FB25345234, FB25345239).

10. A channel. An accessibility developer contact or a lab slot for assistive technology developers, so requests
    like this can be discussed with the engineers who own the framework.

Why it matters: blind Mac users who want a Windows-style reader, or any reader that is not VoiceOver, have no
first-class option, and every third-party attempt is built on timeouts, retries and workarounds. A declared role
would let the platform support them instead.
