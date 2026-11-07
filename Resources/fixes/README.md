# Fixes that come with TurnOver

Each folder here is a fix someone made with TurnOver's fix list (VO-Slash with VoiceOver keys, or This app, Change
the item I'm on, in the TurnOver menu: label an item, give it a key, read it when it
changes, keep it quiet), shared with Share my changes on GitHub, and accepted by the project. `build.sh` copies this
folder into TurnOver.app, and TurnOver loads every fix in it for everyone, before each person's own changes.

A folder holds the two files TurnOver writes: `manifest.json` and `profile.json` (the plugin format,
[PLUGIN-GUIDE.md](../../PLUGIN-GUIDE.md)). To add one from a Share a fix issue:

1. Make a folder named for the app, such as `fix-com-example-app`, and put the two files in it.
2. Give the manifest an `id` matching the folder, a plain `name` and `description`, and the sharer as `author`.
3. Check it: `turnover-plugin check Resources/fixes/<folder>`, then `./build.sh`, and try the app by ear.

These are data, not code: TurnOver checks every rule as it loads them, and refuses what no plugin may do.
