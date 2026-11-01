# Plan: making new apps cheap (agreed 8 Oct 2026, for the week of 12 Oct)

The aim: most apps need a recipe, not code; a tool writes the first draft of the recipe; and the generic layer
gets better for every app at once. Recipes are also the first kind of plugin.

## 1. App recipes (first)

ChatView (Messages, WhatsApp) and MediaView (Music, Podcasts, TV) already work from a `Spec`: the identifiers of
the parts and a few switches. Lift those specs into a loadable file, one per app, and add the common Mac shapes:

- chat: message box, transcript, conversations, sections, search, "sent" wording
- media: sidebar, shelves, player, toolbar
- sidebar + list + detail (Mail-like, Notes-like): the three parts and what Tab and Shift Tab do
- search with results: the field and the results list
- extras any recipe can carry: Tab stops to add or skip, names for nameless controls (today's Profiles labels),
  a hint per part

Format: JSON or a plist, read from ~/Library/Application Support/TurnOver/recipes/<bundle id>.json, and the built-in
ones from the app bundle. The TurnOver menu's Applications list shows every recipe found. A recipe with an error is
reported by name, never silently ignored. Keep the Swift views; the recipe only parameterises them.

Done when: Messages, WhatsApp, Music, Podcasts and TV run from recipes with no change in behaviour (the daily pass
and the fixture tests say so), and one new app (Notes or Reminders) works from a recipe alone.

## 2. The app explorer (second)

`turnover-coretest --explore <bundle id>`: records every window (the recorder from 8 Oct), then reports in plain words:
the text areas and fields with their identifiers; lists, tables and outlines with row counts; the search field;
the toolbar; which parts are empty until scrolled; which known pattern it matches (PATTERNS.md: Catalyst,
Electron page, Office ribbon, nameless groups). Then it proposes a recipe file, marked "draft", to be tried and
corrected. Output: a report text file and a recipe, in a folder named after the app.

Done when: the explorer run on Notes proposes a recipe that works after at most small edits.

## 3. The generic layer, for every app at once (ongoing)

This is what the daily passes already do, one fix at a time (groupItems, the focus rules, nameless groups,
late-loading lists). The new part: after each generic fix, run the generic reading over every recorded window
(Tests/Fixtures) and compare with the last run, so a fix for Mail that changes Finder's reading is seen before it
ships. A test, `generic reading unchanged`, with a per-fixture expected file.

## 4. Plugins, by the same road

- Recipes are plugins without code: a file, shareable, no signing question. First.
- Then signed code plugins (PLUGIN-GUIDE.md, turnover-plugin): a recipe may name a plugin for the parts it can't
  describe. Signing requirement before any plugin loads (team review, item 11).
- A tester who writes a recipe for their app gets it into the built-in set with their name on it.

## Order and time

Recipes: 2–3 days. Explorer: 1 day. Generic-reading comparison: half a day. Plugin signing: half a day.

## Progress

- 8 Oct 2026: the recipe layer is in (Sources/TurnOverCore/Recipes.swift): `Recipe` (kind, bundle, name,
  a `chat` section), `RecipeMatch` (roles, identifier prefix/suffix/equals/empty, "any"), `Recipes.load` from the
  app's Resources/recipes and ~/Library/Application Support/TurnOver/recipes (user files override by bundle),
  problems reported by file name with the reason. Messages and WhatsApp run from Resources/recipes/*.json; the
  Swift specs are gone. Tests: the built-in recipes decode and match as the code did; a broken file is reported and
  the rest load. Next: the media shape, then sidebar + list + detail, then the menu's Applications list from recipes.
- 8 Oct 2026, later: after the code review, a recipe is the `view` section of a plugin's profile.json (one format,
  one loader, one folder, one checker, one guide section); matches are the profile's `ElementMatch`, which gained
  `roles` and `any`. TurnOver's own recipes stay as files in Resources/recipes (bundle, name, view). The user
  recipes folder and recipe.json are gone before anyone learnt them. The installer says what a plugin's keys can
  do to the app and asks again for one that can quit, delete or send. The app modules moved into TurnOverCore
  (then Sources/TurnOverCore/Modules; since 30 October 2026, Sources/Apps with registration in Sources/System/BuiltInModules.swift), so turnover-coretest and the tests see them. Plugins in the beta are one switch,
  Edition.pluginsInBeta, still off.
- 8 Oct 2026: the third shape, `panes` (PanesView): named parts with a match each, Tab and Shift Tab round
  them, TurnOver 1 to 9 to one, TurnOver Shift W says where. Notes is the built-in example. This is the shape
  for Steam, Bambu Studio, PrusaSlicer and most Mac apps; profiles' labels and keys cover what the shape doesn't.
