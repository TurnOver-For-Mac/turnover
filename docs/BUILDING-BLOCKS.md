# Building blocks

A building block is something in TurnOver's core that app modules build on. A module teaches TurnOver one app; a
building block is what a module needs when the app can't be fixed from inside its own folder. For example, a hook
`AppModule` doesn't have yet, a kind of control TurnOver doesn't read, or a change to how focus, speech or keys work.
[MODULE-GUIDE.md](../MODULE-GUIDE.md) is the guide to writing modules; this page is about the blocks under them.

Blocks are asked for, not just added, because they change shared code: what every app hears. They are reviewed more
closely than modules, tried by ear on more than the app that asked, and land between releases, never on a release day.

## Asking for one

Open an issue with the **A building block** form (label: `building block`). It asks for:

- the app;
- what the module needs;
- what you tried and why it wasn't enough;
- what it would let the module do.

You don't need to know how to build it, and the request doesn't have to name the solution. "The list never takes the
focus, so the module can't tell when its selection changes" is a good request.

## What happens next

1. **Triage**, within a few days. The request gets one of these answers:
   - **It's already there**, with where to find it.
   - **It's a module fix after all**, with how to do it in the app's folder.
   - **A building block**, kept open with a short plan.
   - **Not now**, with the reason.
2. **Building it.** Whoever builds it, the person who asked or a maintainer, opens a pull request that says
   `Building block for #N`. The pull request:
   - names the block, in a few words, as it will appear in the list below;
   - adds a test, and a dated comment that says which app needed it and why;
   - is tried by ear on the app that asked, and on one app that already worked, to show nothing else changed.
3. **Delivered.** When it merges, the block is added to the list below, the issue is closed with the build it will
   ship in, and the person who asked is told. Their module can use it from that build on.

If a request sits for a week without an answer, say so on the issue; it hasn't been forgotten on purpose.

## Blocks already there

Before asking, check what modules can already use:

- **The `AppModule` hooks** (`Sources/Core/AppModule.swift`): keys, events, object classes, focus redirection,
  browse-mode roots, say all past the end, hints, grids, announcements, the app's own TurnOver menu section.
  [MODULE-GUIDE.md](../MODULE-GUIDE.md) describes them.
- **Shared implementations** for whole kinds of app, which a module can join instead of starting from nothing:
  - Media, for Music, TV and Podcasts;
  - Chat, for Messages, WhatsApp and Discord;
  - Panes;
  - Games;
  - Catalog search;
  - Google's browser editors.

  They are listed at the top of [Sources/Apps/README.md](../Sources/Apps/README.md).
- **The parts made for plugins** (`Sources/Core/Plugins/TurnOverParts.swift`, October 2026): pane focus reports, hold
  lists, names from nearby text and others. Plugins are parked, but the parts are in the core and modules can use
  them.

## Delivered

Newest first. Each line: the block, the issue that asked for it, the build it first shipped in.

| Block | Asked for in | First in build |
|---|---|---|
| (none yet through this process) | | |
