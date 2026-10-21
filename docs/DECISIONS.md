# Decisions

The choices that are settled, so they are not argued again in every issue, and the things that are parked, so nobody
fixes code that is not live. Each has a date and a reason. To reopen one, open a Discussion and say what has changed.

## Settled

- **VoiceOver stays on** (16 Oct 2026). TurnOver reads the apps it is given; VoiceOver is silenced there by a sound
  tap and keeps passwords, macOS's own prompts and every other app. A blind person is never without speech, and
  TurnOver can concentrate on the apps where it reads better. The README says the rest under Where TurnOver stands.
- **The keys follow the reader they are named after** (15 Oct 2026). VoiceOver keys do what VoiceOver's do; NVDA keys
  what NVDA's do; JAWS keys what JAWS's do. Where a key clashes with a Mac shortcut, the Mac shortcut wins. A change
  that alters what an existing key does needs a very good reason (CONTRIBUTING.md, Keep what works).
- **Settings live in the Settings window; the menu holds actions** (21 Oct 2026, NVDA's shape). The menu is This
  app, Settings, Keys, Tools, Help, Support TurnOver, Quit; Command Control M opens it. A new setting gets a control in
  the window, never a menu item.
- **TurnOver's own features live on one layer** (Command Control Comma, then a letter) in every style, so a user
  learns one new thing at a time; new direct keys are rare.
- **App rules go in app modules, not shared code** (PATTERNS.md). A rule that helps one app can silently break
  another; shared code (focus, the lookup, the hand-over, the watchdog, the buffer) changes only with a reason that
  names the apps it was checked in.
- **Design borrowed, code not** (NOTICE.md). The object model and app modules are NVDA's design; the keys are
  VoiceOver's and NVDA's; no code from either is in the tree.
- **Plugins are data** (20 Oct 2026). Reading rules, labels and keys for an app, written as files; no scripts run
  from a plugin. The toolkit's sandboxed scripts are not built (docs/PLUGIN-TOOLKIT-PLAN.md).
- **Feedback through GitHub** (20 Oct 2026): the issue forms, not email.
- **Main takes pull requests only** (21 Oct 2026), the maintainer's included, with the build check green. The
  publish script opens one for each sync from the maintainer's tree, and refuses to run over a contributor's merged
  work until it has been ported.

## Parked

Kept in the tree, not live. Each file says so at the top.

- **Speech parity** (SpeechParity.swift): following VoiceOver's rate, volume and pitch. Off since 20 Oct 2026; not
  reliable. Kept for a better attempt.
- **Narrator keys** (Config.swift, Resources/keymaps/narrator.json): the style exists, its table is empty, and K does
  not offer it.
- **The plugin maker's tool** (`turnover-plugin`, the TurnOverPlugin target): not built into the product.
- **An app explorer and fixture comparison** (docs/APP-RECIPES-PLAN.md): planned, not built.

## Open

Fair questions without a ruling yet; Discussions is the place.

- Whether TurnOver should ever aim to stand on its own without VoiceOver.
- Narrator keys: worth building, or two Windows styles are enough.
