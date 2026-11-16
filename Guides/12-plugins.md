# Plugins

A plugin teaches TurnOver an app: what to call its controls, which keys do what, what to read when something
changes, and what to keep quiet. Plugins are written as data, not code: a folder with a manifest and a few JSON
files. That means no programming, nothing a plugin can do behind your back, and anyone can read one before
installing it.

## Using one

- **Fixes that come with TurnOver**: ones people shared and the project accepted. They're simply there, and listed in
  the plugins menu as "comes with TurnOver".
- **The plugin library** (the TurnOver menu, Tools, Plugins, Plugin library) is paused for now.
- **Install from a folder or the clipboard**, in the same menu, for one someone sent you.
- **Reload plugins** after editing one.

## Making one

1. Switch to the app, then the TurnOver menu, Tools, Plugins.
2. Choose **Write a plugin for this app yourself**: TurnOver makes a starter folder with the guide, a snapshot of the
   app's window and its menus, so you can see what the app calls things.
3. Or choose **Make a plugin with** an AI: TurnOver gives it the window's labels, text and menus and its own log, with
   your typing and speech left out, and the AI writes the first draft. You read and change it.
4. Edit the files, then **Install my plugin from its folder**. Reload after each change.

The format is in [the plugin guide](https://github.com/TurnOver-For-Mac/turnover/blob/main/PLUGIN-GUIDE.md): what a
manifest holds, how a rule names a control, how a key is given a command, and the checker that finds mistakes.

## Sharing one

The quickest way is a fix made in TurnOver itself (VO-Slash with VoiceOver keys, or This app, Change the item I'm on):
choose **Share my changes on GitHub** in its list. TurnOver copies the fix and opens a short form. Fixes the project
accepts come with TurnOver for everyone. [Helping TurnOver read your apps](helping-turnover.html) has the steps.

The plugin library is paused for now (since October 2026): shared fixes reach people with TurnOver itself instead.

## What a plugin can't do

Run code, reach the internet, read anything in an app it doesn't name, or change TurnOver's settings. Those limits
are the point: a screen reader sees everything on your screen, and a plugin shouldn't widen that.
