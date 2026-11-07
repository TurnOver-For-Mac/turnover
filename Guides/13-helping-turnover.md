# Helping TurnOver read your apps

You know better than anyone how an app should sound. There are a few ways to help TurnOver read one better, from a
minute's work to building a fix with your own AI assistant. Start wherever suits you; each one helps.

With the app in front, open the TurnOver menu (Command Control Comma, then M), then This app, then
**Help improve this app**.

## Tell us what's wrong

Choose **Tell us what's wrong**. A short form opens in your browser, already filled in with the app, your TurnOver
build and how the app is built: the kinds of item it has, never what's in them. You add what you did and what you
heard, then submit it. Nothing to install; you need a free GitHub account.

## Fix the item you're on

On a button or a line that reads badly:

- With VoiceOver keys, press **VO-Slash**.
- With any keys, choose **Fix the item I'm on** in Help improve this app, or This app, then Change the item I'm on.

A short list opens:

- **Label this item**: type a name, and it's called that from now on.
- **Give this item a key**: press a key, and it presses, focuses or reads the item.
- **Read this when it changes**: for a status line or a counter that changes silently.
- **Don't announce this**: for something that chatters.
- **Undo the last change**, and **My changes for this app**, to take one away.

Each change works straight away, and is kept on your Mac for that app.

## Share your fix

In the same list, choose **Share my changes on GitHub**. TurnOver copies your changes and opens a short form. Paste
them where it asks, read them through to check they hold nothing private, and submit. If the project accepts them,
they come with the next TurnOver, for everyone who uses that app.

**Save my changes as a file** puts them in a zip on your Desktop instead, to send to someone.

## Build a fix with your AI

Some apps need more than a label or a key: what to read after Return, or how to move through a list that doesn't
report anything. That's an app's **module**, a little code for that one app. Your own AI assistant can write it with
you, one step at a time, while you decide how it should sound.

Choose **Build it with Claude Code** (or Codex, or Gemini CLI, if you have them). Your assistant opens with a
description of the app and TurnOver's brief for AI contributors, asks you what goes wrong, and checks with you
before anything is sent. You need Xcode, Apple's free tool for building apps (a large download), and a free GitHub
account; your assistant helps you set them up.

While you try your fix, it installs as **TurnOver Developer**, beside TurnOver. The TurnOver menu then offers
**Switch to your developer build** and **Switch to the published TurnOver**, so you can go back and forth.
Command Control Period starts and stops whichever you used last.

**Build it myself** opens the same description of the app, and the guide to writing a module.

## Ask for a building block

Now and then an app needs something new from TurnOver itself. Choose **Ask for a building block**: a short form
opens, already filled in. Say what the app needs; you don't need to know how to build it.

## What stays safe

Fixes are data, not code: TurnOver checks every one as it loads it, and a fix can't reach the internet, read another
app, or change your settings. Modules are reviewed by the project before they're accepted, and nothing in TurnOver's
core changes without that review. Nothing you share includes what you read or type unless you paste it yourself, so
read what you send.

Thank you.
