# Plan: the flat view (27 Oct 2026; a Codex critique the same day is folded in)

One engine that turns a window area into a list TurnOver can read and act on, instead of a hand-made view per app.

## Why

Three apps are read today through views written by hand: `ChatView` (Messages, WhatsApp, Discord), `MediaView`
(Music, Podcasts, TV) and `AppStoreView`. Each reads the window's tree into its own list of items, keeps the
elements it found, and acts on them later. Each has had the same bugs in turn, found by firefighting:

- The element kept is stale: rows are reused as the list scrolls, so a press meant for WhatsApp got another app's
  Get (6 Oct); "73.2% loaded" was read long after Outlook installed (14 Oct).
- The list is of a page the app has since replaced: the App Store's search results arrive in stages (11 items,
  then 24, then 36 within two seconds), and Return looked for rows the screen no longer had (27 Oct).
- Acting needs the item on screen and the system's hit test to agree, and each view scrolls its own way (the
  scroll bar's value by binary search, AXScrollToVisible, AXNextContentSibling); the search results page's container
  has no frame, so every row counted as off screen (27 Oct).
- The app's own tree changes shape (a card over the window, a page of its own, the Updates page's nameless rows), and
  each view has a branch for each shape.

Oliver, 27 Oct: "we need something more robust that flattens these sorts of interfaces", "more robust rather than
firefighting in little areas".

Browse mode is the nearest thing TurnOver has: `WebBuffer` is a flat list of a page. It is not the model to copy
wholesale, though: it keeps the page's elements in its segments, builds on the main thread with a two-second
deadline, and activates the kept element first with a live-text fallback (`WebBuffer.swift:25`, `:98`;
`BrowseModeActivation.swift:70`). What the flat view takes from it is the shape of the experience (one list, the
arrows, the place kept across rebuilds), not its code.

## What it is

`FlatView`: for one area of a window (the page, the sidebar, a transcript), a list of items in reading order. The
engine does three things, each specified apart: discover, resolve, act. An app module owns the area through an
adapter (Swift), fed by a recipe where lines are enough.

### The item

```
Item
  key        how the item is found again (below); never an AXUIElement
  label      what is said: name, then the pieces the verbosity list allows. Separate from the key: labels carry
             previews, times, delivery status, remaining time, which change (ChatView.swift:313, MediaView.swift:543)
  kind       heading, text, button, row, link, field, card, section
  section    which shelf or section it belongs to, for Left and Right and for "shelf, 3 of 12"
  acts       the policy for Return and Space, decided by the adapter, not by the element's advertised actions:
             the App Store's tile reports AXPress as success and opens nothing; opening is a click on the icon
             away from the offer button (AppStoreView.swift:855)
```

### The key, and when it is not enough

Identity is per app, declared by the adapter, in this order:

1. **An identifier that carries the record**: Music's `shelfItem.HorizontalLockup[id=ra.68…]` names the item
   (`MediaView.swift:37`). The adapter says which identifier patterns are record ids; the rest are widget types
   (WhatsApp's every bubble is `WAMessageBubbleTableViewCell`, `ChatView.swift:11`) and never identify.
2. **A name the adapter declares stable**, scoped to the area and the page: the app's name on a Store tile (the
   first named descendant that is not artwork or the offer button, `AppStoreView.swift:227`); a conversation's
   contact name, not its preview.
3. **Nothing**: the item is readable but not actable by identity. Its sibling path and its position in the list
   recover a reading position only. Return on such an item refuses with a reason ("two items are called Episode;
   say which") rather than guessing: a hit test only proves that the row found occupies the point, never that it is
   the item that was read, so ambiguity must be refused before the click, not caught after it.

Where names repeat in an area (a list of "Episode"), the label gains the position ("Episode, 4 of 9") so the person
can tell them apart, and the key includes the position within the section at the time of reading, marked unstable.

### Discover

The area is read in waves, off the main thread, each wave with a deadline and a cap, and the result published as a
checked, `Sendable` snapshot with a generation (window, page, request) that is compared before anything is said or
done with it. A main-actor `Task` does not leave main (`AGENTS.md:38`); the worker is a serial queue owned by the
view, one per area, with cancellation on a page change. An accessibility call already blocked is not interrupted by a
deadline: the per-call messaging timeout (0.3 s) bounds each, `AXHealth` rests an app that misbehaves, and the wave's
deadline bounds the sum.

Virtualised areas are the hard part and the reason the views exist. The engine must do what they do, as named
operations the adapter can tune, not as a whole-tree snapshot that would drop what an earlier wave found:

- **Materialise**: shelves that do not exist until scrolled are reached by `AXNextContentSibling` and by revealing
  empty sections (`AppStoreView.swift:171`, `:217`); Media scrolls and merges newly exposed shelves with the ones
  already read (`MediaView.swift:286`, `:668`).
- **Merge**: a new wave's items are merged into the list by key; items whose key is gone are dropped; the end of the
  area is known only when the last content sibling is reached, not when a wave runs out.
- **Settle**: after a page change the area is read again at 0.7 s and 1.5 s (the App Store's `settleResults`,
  27 Oct); a changed list is merged and the place kept by key, else by label, else by index.
- **Scroll hint**: where the item was on the scroll bar when read (`MediaView.swift:862`), kept with the key, so an
  item that has no live row can be brought back before it is looked for: resolve cannot find a row that does not
  exist yet, so reveal comes first where the hint says the item is off screen.

### Resolve

An item asked to act is found again, now: by its record id if it has one, else by its stable name among the rows
of its area on screen, after the scroll hint and `AXScrollToVisible` (on the item or its section; the scroll bar's
value only where neither exists, as the App Store's binary search does today) have brought it on screen. Then the
click point is chosen as the views choose it (the icon, else the left edge, never inside the offer button's bounds,
never under the floating toolbar, `AppStoreView.swift:305`, `:870`), and the system's hit test under that point must
name the resolved row and not an offer button, with up to a second for the app to agree (27 Oct). On any doubt
TurnOver says what it found and does nothing.

### Act

By the adapter's policy: the element's own action (`AXPress`, a custom action by name such as Podcasts' Play),
else the click, the pointer put back after. What happens next is watched by the adapter (a page change, a title
change, a download starting), each with its own wait; there is no universal "nothing changed" message, since the
views' own waits run to several seconds for navigation, downloads and playback.

### Knowing when to rebuild

The notifications the handler receives are not enough on their own: `AXCreated` and `AXRowCountChanged` are only
logged today, and `AXLayoutChanged` and `AXLoadComplete` only dirty the web interceptor
(`AXHandlerNotifications.swift:119`, `:134`); value and title changes reach the focus and the plugin watches, not a
view. The engine gets an invalidation path of its own: the area's element observed for those notifications, scoped
to the area and coalesced (one rebuild per 200 ms at most), with the subscription's failure logged and a fallback
of a freshness check every two seconds while the area is the one being read, and an on-demand check before every
act. Same-count row reuse, preview and progress changes are caught by the freshness check's merge, not by a notice.

## What a recipe says, and what stays in Swift

`Recipes.swift` reads a `view` of kind `chat` with the parts' identifiers; `media` is a kind marker with no schema
yet (`Recipes.swift:11`, `:54`). A `flat` kind would name the areas, their roots, the item and section patterns,
the record-id patterns and the settle times. The action policy, the label rules (badges in order, artwork and
status suppressed, text blocks split from links) and the waits are Swift, in the adapter: a selector language rich
enough to say them is a bigger design than the engine and is not attempted. Recipes stay what the 8 Oct plan made
them: parameters for Swift views, now for one view.

## The behaviour contract

Nothing moves until the behaviours each view has today are listed and ticked off one by one. The critique's list is
the start of it, by file and line:

- App Store: card overlays without a sidebar, alternate roots, standalone error pages, page-title fallbacks
  (`AppStoreView.swift:74`, `:117`); carousel discovery both ways, empty-section materialisation, boundary and End
  loading, keys queued during loading (`:171`, `:395`, `:676`, `:728`); search, the sidebar tabs and the account,
  the focus returned to results after a search, Back restoring the place (`:572`, `:801`, `:1020`); the product,
  search, update and card labels, text split from links, badge order, screenshots suppressed, live offer wording,
  shelf announcements and hints (`:442`, `:534`, `:606`); Return against Space, product-top Return, purchase
  confirmation, download progress without accidental cancel, Delete to cancel, repeated-Open suppression, progress
  and completion announcements, Get to Install (`:40`, `:843`, `:941`).
- Media: the four areas including the player and toolbar, the selected sidebar landing, empty areas skipped, shelf
  positions and hints (`MediaView.swift:55`, `:795`); the prior page hidden, scrolling to the top first, shelf
  merging, content-sibling traversal, boundary loading, End (`:183`, `:245`, `:286`, `:426`, `:728`); headers split
  into text and buttons, episode labels, artwork and junk suppressed, lazy library-row labels, first-column letters
  (`:384`, `:456`, `:494`, `:534`, `:598`, `:780`); Return plays, Shift-Return opens, custom Play, table selection
  plus a real Return, Space's player toggle with a real-key fallback, playback verified, now playing (`:851`, `:896`,
  `:928`, `:990`); search focus, Back and menu fallbacks, the opened item restored, the video player's keys handed
  over (`:713`, `:961`, `:1015`).
- Chat: the composer kept while the lists are TurnOver's, entry on the selected conversation and the newest message,
  the four parts cycled, focus and braille released on exit (`ChatView.swift:343`, `:366`, `:383`); search results
  over the chats, Archived, Starred and Calls, section headings, Discord's descendants (`:185`, `:222`, `:292`);
  loading at both ends, older messages, exhaustion remembered, stable numbering, selected state, hints (`:402`,
  `:452`, `:519`); descendant activation, the conversation's title verified with a selection retry before the box
  (26 Oct), delayed refocus, section fallback, sheet Back and Close (`:118`, `:543`); custom-action menus,
  AXShowMenu, Tapback, the latest-nine commands (`:619`, `:685`, `:716`); new-message polling and its suppressions
  (`:735`). The transcript's own logic stays, and its tie to the list it reads from is part of the contract.

## Order of work

1. The contract above, completed by reading each view once more; the identity rules per app; the worker lifecycle;
   the adapter protocol. A document, reviewed before code.
2. `FlatView` discover and resolve, with tests. Recorded windows (`AXFixtures`) test labels and keys but not
   safety: replay records actions and returns success, and the shim does not intercept hit testing
   (`AXFixtures.swift:359`, `AXReplayShim.c:90`). Tests of transitions, recycling, delay and cancellation need a
   fake tree that changes between waves, in `TurnOverCoreTest`, and installed-app checks in the daily pass.
3. One App Store area (the search results page) behind the existing controller: `AppStoreView` keeps its keys and
   waits, and asks the engine for that page's list and resolution. Proven there, the Discover page, then the rest.
4. Media's page area, then its sidebar; the chat conversations list; the transcript last and apart.
5. Only then the views' own building and scrolling code goes. Issue 117 (splitting the two big views) is not closed
   by this plan; it is closed when the code is gone, and may still be worth doing first if the engine takes long.

No afternoons are promised: each step is a pull request with the contract's ticks in its description.

## Risks

- Rows with no record id and repeated names: resolution refuses, reading says the position. Acceptable; the
  alternative is a wrong click.
- Waves cost accessibility calls while the app is busy: the per-call timeout, the wave deadline and `AXHealth`
  bound it; the log's `took` warnings are the measure (issue 119).
- New code under three apps: step 3 proves it on the hardest app behind its own controller before anything moves.

## Decisions wanted

- Go ahead with step 1 (the contract and the adapter protocol) now, or finish issue 117's split first and let the
  engine come after.
- Whether a flattened area says what it is on entry ("results, 36 items") so the keys are explained, as browse mode
  says "browse mode".

## Measured on the App Store, 27 Oct 2026 (evening), with the first engine behind the `flatView` switch

- The results list lists sixteen rows; the rest come as content siblings both ways, with groups that are not rows
  (stories, spacers) between them, so a chain that stops at the first non-row sees nothing. Walked both ways,
  skipping up to twenty non-rows, a "water" search gives 160 to 200 rows.
- A row's name is answered blank intermittently while the Store loads: the same four rows read blank at once, at
  50 ms and at 200 ms, had their names at 500 ms, and were blank again at 1.5 s. Blank is not "nameless": a wave
  that reads blank must leave the row out and count itself incomplete; a known row must never be replaced by a
  blank reading of itself; keys learned are kept.
- The full label (subtitle, stars, price) costs about 36 ms a row through the Store's tree; two hundred rows took
  seven seconds a wave. The wave reads the name and the button only; the rest is for when the item is spoken.
- The Store's hit test under a row lags the page it shows by up to a second after a search.

The engine as left tonight: waves off main (0.3 s, then a second of materialising), merge by key, settle waves at
0.7 and 1.5 s, a light freshness look every 3 s that triggers a full wave only when new rows are listed, resolve by
key both ways with scroll-to-visible and the hit test agreeing. Reading the results works; opening a row reached
by Return still fails more often than it should, because the find at the moment of the key sees the Store blank.
Next: a find that retries over a second until the row answers, and the click made within the same breath.

### What the evening settled (27 Oct 2026, late)

The engine as written cannot open a result reliably, and the reason is the Store, not the engine. A second
measurement over three seconds, ten rows (five listed, five reached as siblings): all blank at once; at 300 ms
seven of the ten answered their names, listed and sibling rows alike; at 700 ms and 1.5 s none; at 3 s two. The
answers come in bursts, whether or not the row is on screen: the Store's accessibility server answers while it is
idle and blanks while it is busy loading (images, the network), and busy is most of the time just after a search.
A blank is never a fact. (The first reading, that only rows on screen answer, was wrong: it was the bursts.)

So the robust shape is patience and memory, not a different walk:

- **Keys by position.** On a results page the order is fixed once loaded, so an item's key is its position among
  the rows (`.position(n)`), which is readable even when the name is not; the name is attached the first time it
  is answered and kept. The merge adds names to positions and never removes a name for a blank.
- **Reads that wait for an answer.** Every read of a name retries over up to a second (every 100 ms) until the Store
  answers; a wave that still has blanks after that is incomplete and the next wave fills them. The old view's
  `confirmed` did the same by scrolling and waiting up to two seconds; this is the same patience without the scroll.
- **One breath to act.** Resolve walks to the position, waits for the name, confirms it is the one that was read,
  scrolls it into view, hit tests, clicks, all within the same burst where possible, and gives up with a reason
  after two seconds rather than clicking blind.

That is the design to take to step 2; the measurements above are its tests. The code behind the `flatView` switch
stays as the first cut, off for everyone, and reads a results page well enough to show the shape.

### The second cut, same evening: positions and patience

Rewritten the same night around positions: `walkStructure` numbers the rows (listed, then the content siblings
back to the top and on to the end, non-rows skipped, a walk that doesn't reach the top discarded), `learnNames` asks
for the names around the cursor on its own queue, every 300 ms for up to ten seconds, and keeps what answers;
`resolve` scrolls the row at the position into view, waits for its name, confirms it is the one read, re-counts the
rows if it stays blank, and makes the hit test agree, asking the row under the point for its name until it answers.
Seen working in pieces: 13 rows named within a round, "row 7" said then its name as it came, the row at position 7
found and its name confirmed, the hit test agreeing after the name was waited for. Not yet working as a whole: the
tie to `AppStoreView`'s own life (buildPage, ensureCurrent, waitForNewPage, settleResults, a stale `loading` flag)
left the page empty or restarted under Return in one run out of two, each time a different way. The engine is
sound; its host is not. Next: the results page gets a host of its own (a small AppStoreResults controller with the
keys, the waits and the flat view, and nothing of the old page machinery), and AppStoreView hands over to it on a
results page and takes back on leaving. Switch off again; the code stays on main, inert.

### VoiceOver as a buffer (27 Oct 2026, late; Oliver's idea: "if we have to use VoiceOver as a kind of buffer")

Measured with VoiceOver on beside TurnOver and driven by script (its AppleScript dictionary: `vo cursor`, `text
under cursor`, `last phrase`, `move`; `tell application "VoiceOver"`), the switch "Allow VoiceOver to be controlled
with AppleScript" on:

- Scripted `move` commands are accepted but slow (0.5 to 4 s each) and `text under cursor` stays missing after them.
  Synthetic VO keys (Control Option Right through System Events) move the cursor in about 150 ms and `text under
  cursor` answers: 36 of 36 window parts named right after a search, where our wire gave blanks.
- With VoiceOver's speech muted (VO Shift S) every read is empty: the read API follows what VoiceOver speaks. A
  silent route would need VoiceOver's own volume at zero or an audio device of its own; not tried, and VoiceOver's
  volume setting persists, so it is not a thing to flip in a probe.
- Reaching the rows needs VoiceOver's interaction model (VO Shift Down twice from the page's group); inside a row
  the parts answered ("74", "Artwork", "Water Daily Intake Tracker, …, zero stars"), and then seventeen of twenty
  steps on answered blank: VoiceOver too is starved by the Store at that moment, or its cursor was bumping at the
  row's end; not settled tonight.

Verdict for now: VoiceOver's wire does answer where ours doesn't, at 150 ms a step and only while VoiceOver is
audibly speaking, and only along VoiceOver's own navigation. Usable as a last resort for a single question ("what
is this row called", "press it") rather than for reading a page; and only with the swap off and VoiceOver silent by
some means that keeps its reads alive. Parked behind the engine's own patience, which got names within a round on
the good runs tonight without VoiceOver at all.

### The third cut, 27 Oct 2026, night: the screen is the truth, and the Store's screen lies too

Opening a row kept failing under the second cut, so the ground was tested point by point:

- **AXScrollToVisible** on a row or its list returns success and moves nothing. Only the scroll bar's value moves the
  page (the nearest scroll area above the list).
- **AXFrame** of a row is a row out after a reflow: the point at a row's icon, hit tested, names another row.
- **The hit test** (`AXUIElementCopyElementAtPosition`) matches what the Store draws: checked against two screenshots.
  A scan of the visible area every 60 by 40 points is about 340 hit tests in 300 to 550 ms, and a click at a scanned
  point not on the offer button opened the product page (HiWater, from a standalone probe).
- **The list's children** are every result, but a result the Store hasn't drawn answers blank: its title is an
  invalid element until the cell is on screen. The names "answering in bursts" were cells scrolling into view.
- **The scroll offset carries over:** a new search ("hydration") opened 7300 points down, where the last page was,
  so rows 1 to 12 were above the screen and blank.
- **Cell reuse without a refresh.** After a scroll, the hit test and the tree name Discover-page apps (Pages, Weather
  Dock, ClassicWeather, Apple Arcade, a STORY tile) where the pixels show water results; a click at "STORY" opened
  Water Meter: IoT Platform. Screenshots also show two titles drawn in one tile ("Water Sort Color Puzzle" over
  "Paint Expert"). `AXEnhancedUserInterface` was already on. So on this Store (macOS 27.2) neither the tree, the
  frames nor the hit test can be trusted to match the pixels after a scroll; only the pixels can.

So `FlatScreen.swift` (behind the same switch) reads the page from the screen: to the top, a hit-test scan, the tiles
in reading order as the items, a screen down and a new scan when the person moves past the last tile, and Return
clicks the point a fresh scan finds for the tile. Reading and moving across screens work (5 tiles a screen, 0.4 s a
scan); opening still opens whatever the Store has really drawn there, which can be another app.

**Where this leaves the App Store.** The accessibility layer of this results page does not describe the screen.
Two honest routes remain: read the pixels (Vision text recognition on a window capture: needs Screen Recording,
a big ask for a screen reader), or leave the results page alone and give the person the catalog directly (the
public iTunes search API for the term they typed, a plain list, Return opening the product page by id through
`macappstore://apps.apple.com/app/id…`), which is what Codex suggested the same evening. The second is cheap,
reliable and private enough (the search term goes to Apple either way). Oliver's call.

### The catalog, 28 Oct 2026: Music and Podcasts too

The App Store's catalog route (Catalog.swift, behind the same switch) now answers Music and Podcasts searches as
well: Music lists three artists, twelve albums and thirty songs; Podcasts forty shows; each app follows its own
scheme (`music://`, `podcasts://`) from any page, measured. The arrows, Home, End, Return and Escape are the list's
while the search field keeps the focus (the letters stay the field's); Return on the same term opens the item.
TV is left out: Apple TV+ shows are not in the public catalog ("severance" found nothing), and its page reads well
enough. Music's own search page also reads well through MediaView ("Top Results, 6 items, Radiohead, Artist"), so
there the catalog is a choice, not a rescue; Oliver is comparing.
