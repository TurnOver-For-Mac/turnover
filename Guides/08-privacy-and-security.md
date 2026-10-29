# Privacy and security

A screen reader has to see everything on your Mac and hear every key, so it asks for macOS's most powerful
permissions. This page says what each is for, what never leaves your Mac, and how you can check for yourself.

## The permissions, and why

- **Accessibility:** to read apps, windows and controls, and to move and press them for you. Every screen reader
  needs it.
- **Input Monitoring:** to hear TurnOver's keys (VO keys, the TurnOver layer, quick navigation). TurnOver looks at a
  key to see whether it is one of its commands; anything else goes straight on to the app.
- **Screen Recording:** only for screen recognition and describing a picture, when you ask. Both run on your Mac.
- **Automation (asked once, for one app at a time):** for example Keynote, to read a slide while a show plays.
- **Audio (CoExist):** to keep VoiceOver's sound quiet while TurnOver reads. A small separate program,
  voiceover-quiet, mutes VoiceOver's sound and throws it away: nothing is recorded, saved or sent, and no other
  app's sound is touched.

TurnOver does not ask for Full Disk Access.

The optional Safari Page Reader extension has separate website-access permissions in Safari. It changes limited
accessibility attributes locally, without reading text-field contents, sending a page tree or making network
requests. It does not click consent buttons, move focus or fill forms. Safari lets you choose which sites it uses.

## What leaves your Mac

TurnOver connects to one place by itself: **its update site**, `doll-eye.github.io/turnover-updates`, to check for a
new build. Nothing about you or what you do is sent: it only fetches that file.

Everything else happens on your Mac:

- Speech, including the natural say all voice, is made on your Mac.
- Screen recognition and picture descriptions use Apple's on-device recognition and model.
- Game speech listens only on this Mac (it accepts nothing from the network), and never speaks over Apple's apps or a
  browser. Reading Steam's Big Picture is off until you turn it on, because it makes Steam open a debugging port on
  this Mac while it runs; turning it off, or uninstalling TurnOver, removes that again.

Things you choose to send, and see before they go:

- **Send feedback** saves a report on your Desktop and opens TurnOver's problem form on GitHub in your browser. You
  write the report yourself, and attach the file only if you choose to; TurnOver never sends anything on its own.
  Reports on GitHub are public.
- **Ask for this app to be tuned** opens the request form on GitHub, filled in with how the app is built (kinds of
  item and counts, never what is in it), for you to post.

### Check it yourself

You don't have to take our word for it. Install a firewall that shows every connection, such as LuLu (free, from
objective-see.org) or Little Snitch, and use TurnOver as usual. You will see TurnOver contact its update site, and
nothing else.

## What TurnOver keeps

TurnOver keeps a log on your Mac, in your Library folder: Application Support, TurnOver, logs. Logs older than 30
days are deleted.

- The log records what TurnOver did: the app, the kind of item, the command a key ran.
- It never records what you type. A typed key is written as "a typed key", never the key itself.
- It doesn't record the words you were reading. Where a name, a page or a message would appear, the log keeps only
  how many characters it had.

The log is plain text: you are welcome to open it and read it.

A feedback report holds these logs. "Send a report with what TurnOver said" also includes what TurnOver said aloud in
the last 15 minutes, which can be the text of an email or page you were reading; "Send a report without what
TurnOver said" leaves it out. Either way the report is a file on your Desktop: you decide whether to attach it, and
since GitHub reports are public, choose the one without what TurnOver said if anything private was on screen.

## Who can talk to TurnOver

TurnOver's own helpers (its Settings window, the Command Control Period helper, the plugin tool, Windy) reach it
through a private channel in TurnOver's own folder. Before anything is read, macOS checks that the program on the other
end is signed by TurnOver's developer; any other program is turned away and the refusal is logged. A copy you build
yourself without a developer certificate accepts only the programs inside its own app. Like any app's, TurnOver's
settings file can be changed by programs running as you; a script you give a key to asks you before it first runs.

## Apps that speak through TurnOver

An app can ask TurnOver to speak for it (a game, for example), through a port on this Mac only. TurnOver works out
for itself which program is asking (from the Mac's own records, not from what the app says), and the first time asks
you, by name, whether you trust it. An app you allow is heard only while it is the app in front, and it can do nothing
but speak: no settings, no keys. Settings, Apps that speak through TurnOver, lists them and changes your answer.

## Passwords and security prompts

With CoExist on (it is unless you turn it off), VoiceOver stays running alongside TurnOver, and everything to do with
security is VoiceOver's:

- **Password fields, in any app or web page:** when one has the keyboard (macOS's secure typing is on, or TurnOver
  lands in one), TurnOver steps aside completely. It doesn't read the field and doesn't take your keys; VoiceOver is
  heard. TurnOver comes back when you leave it.
- **Typing into a password field is never spoken or logged** by TurnOver, even where an app hides that the keyboard
  is in one.
- **macOS's own prompts** (an administrator password, the keychain, Touch ID, "Allow" questions): the same,
  VoiceOver's from the moment they open until they close.

So Apple's own reader is the one with you whenever you type a password or approve something, and TurnOver never
sees it. With CoExist off, TurnOver still never speaks or logs what you type into a password field.

## When we get something wrong

We'll say so here and in What's new.

- **18 October 2026:** in Kindle's Amazon sign-in, TurnOver read the password aloud as it was typed, because the page
  told TurnOver the keyboard was somewhere other than the password field. It was found the same day and fixed for
  every app: typing into a password field is never spoken or logged, wherever the app says the keyboard is. It
  needed an app that hides where the keyboard is, as Kindle's sign-in does; Kindle support was new that day, so we
  know of no released build where it happened.

## Questions

Ask on TurnOver's GitHub page (github.com/TurnOver-For-Mac/turnover), from the TurnOver menu, Send feedback. Something that
could expose what a person reads or types is best reported privately, through the repository's Security tab.
