# Plugins people can build on: the plan (16 Nov 2026)

The maintainer's decisions of 16 Nov 2026: TurnOver's plugins are to be at least as capable as NVDA's add-ons, with
the power granted as named abilities the person hears and approves one by one, never as one unrestricted kind; and
a converter is to bring NVDA add-ons across as well as they can be brought. Telling the person plainly what a
plugin may do is the centre of the design: it is what TurnOver does better than NVDA.

This builds on docs/PLUGIN-SCRIPTS-PLAN.md (the sandboxed host, approval, the keeper). The facts about real add-ons
are in the study of twelve add-ons made the same day (kept outside the repository; its conclusions are below).

## What the study found

- NVDA's store does not review code. A person checks once that a submitter owns the repository; after that the
  checks are automatic (manifest, versions, a virus scan) and a SHA-256 stops later changes. So "approved for
  NVDA" says who published a file and that it has not changed. It does not say the code is safe.
- The store publishes one combined list (`https://addonStore.nvaccess.org/en/all/latest.json`) with, for each
  add-on, its id, version, download address, SHA-256, source address, channel and licence.
- All twelve add-ons were GPL. A converted plugin is a derived work: it keeps the author, the licence and where it
  came from.
- Of twelve: three convert in part today (app modules, whose selectors must be remade from the Mac app), two more
  need scripts that work in every app, and seven cannot come across as written (speech drivers, remote access,
  OCR, Windows-only apps).
- What scripts lack, in order of need: options TurnOver shows itself; every-app scripts; tones of a chosen pitch;
  reading the selection and lines of the focused item and moving the caret; a list to choose from and a prompt
  for text; hearing what TurnOver says; reading the clipboard.

## Stage A: the converter (`turnover-plugin convert`)

1. Input: an add-on id from the store, or a `.nvda-addon` file or folder the person already has.
2. From the store: fetch the combined list, find the id (stable channel unless asked), download the file, and
   refuse it unless its SHA-256 matches the list. This is the tool's own request to NVDA's store; TurnOver the
   screen reader still connects only to its update site.
3. Read, never run: unpack, read `manifest.ini`, and read the Python as text with Python's own `ast` module
   (`/usr/bin/python3`, run with `-I`, on a small script of ours that only parses). No add-on code is executed.
4. Work out what the add-on is and uses: global plugin, app module or driver; the apps it names; each script with
   its description, gesture and category; each event; the NVDA modules and calls it uses; whether it draws
   windows, keeps settings, touches files, the network or other programs.
5. Write a draft plugin: `manifest.json` (name, version, author, licence, `convertedFrom` with the id, version,
   SHA-256 and source address), commands from the scripts with their descriptions and keys translated where a
   Mac key exists, `main.js` with a handler for each script and event holding the mechanical translation where
   the mapping is exact and otherwise the original Python as a comment under a line that says a person must
   write it, and the abilities the original's behaviour needs and no others.
6. Write `CONVERSION.md` in the draft: what carried over, what needs a person, what can never come across and
   why, in plain sentences; and the licence notice.
7. Nothing new is injected: the abilities are derived from the original alone and recorded in `convertedFrom`.
   `turnover-plugin check` on a converted plugin reports, as an error, any ability or app in the manifest that
   the record does not have, so a later hand or AI edit that reaches further is seen. The draft then meets
   TurnOver's own approval like any other plugin.
8. An add-on that cannot come across at all still gets its report, and no plugin.

## Stage B: what scripts must gain (each a named ability with its own approval sentence)

- `everywhere`: a script whose `apps` is `["*"]`. Never in the forbidden apps; in the closed apps it reads and
  speaks only. Its commands' keys work in every app.
- Options: declared in the manifest (a switch, a choice, text, a number), shown and changed in TurnOver's own
  menu, read by the script, with an event when one changes. No ability: they are the person's own settings.
- `turnover.choose(title, items)` and `turnover.ask(prompt)`: TurnOver's own list and text prompt; the script
  gets the answer. Under `say`.
- `turnover.tone(hertz, milliseconds)`: under `say`, within limits.
- Text: the selection, the line and the whole text of an item, and moving the caret. Reading under `read`,
  moving under `edit`. Never in a secure field.
- `hearSpeech`: an event with what TurnOver says in the plugin's apps.
- `clipboardRead`: reading the clipboard, said plainly at approval.
- Later, one at a time, each with its own decision: the internet to named hosts, and files in a folder the person
  chooses.

Stage A is built first because it was asked for first. It lands add-ons on what scripts can do today and names,
in each report, which stage B piece would carry the rest.

## Who looks after a plugin (decided 16 Nov 2026)

A plugin's author is responsible for it, and TurnOver makes that visible.
- The manifest gains `support`: a web address or an email for reporting a problem. Needed for the library; a
  converted add-on's is the converter's, with the creator named beside it.
- Each plugin in the Plugins menu gets "Report a problem with this plugin": it says who looks after it and copies
  the address with the plugin's name and version and TurnOver's build.
- TurnOver's own problem report lists the plugins that were on.
- One menu item turns every plugin off until TurnOver starts again, so a person can tell whether a fault is
  TurnOver's or a plugin's.
- The library can mark a plugin as unmaintained and let someone else take it over.
- CONTRIBUTING.md says what belongs in the core and what is a plugin.
