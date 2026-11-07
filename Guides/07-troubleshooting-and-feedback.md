# Troubleshooting and feedback

## TurnOver stops answering

VoiceOver comes back by itself within a few seconds, and your keys work again; if TurnOver is still stuck, it
restarts itself. **Command Control Period** stops or starts it from anywhere.

## No sound at all

If even VoiceOver is silent, macOS's sound service may have stopped. In Terminal, run this and type your password:

```
sudo killall coreaudiod
```

Or restart the Mac. Then press Command Control Period to start TurnOver.

## Force quit, spoken

Command Option Escape lists the running apps: choose one, then force quit it, ask it to quit, or cancel.

## Sending feedback

- The moment something goes wrong: **Command Control Comma, J** marks it, and you carry on.
- When you're ready: the TurnOver menu, Send feedback. A report is saved to your Desktop, and TurnOver's problem form
  opens on GitHub with your build and Mac filled in. Say in a sentence what you were doing and what you expected, and
  drag the report in if you like. Reports on GitHub are public: choose the report without what TurnOver said if
  anything private was on screen.
- To help with an app: switch to it, then the TurnOver menu, This app, Help improve this app. Tell us what's wrong
  opens the form on GitHub, filled in with how the app is built (never what's in it). There's more in
  [Helping TurnOver read your apps](helping-turnover.html).
- You need a free GitHub account to post. TurnOver is a spare-time project: every report is read, but replies may
  take a while.

## Removing TurnOver

The TurnOver menu, About and updates, Uninstall TurnOver: the app only (your settings kept), or everything
(settings, logs, permissions and login items), which also turns VoiceOver on and removes anything an earlier TurnOver put into VoiceOver's settings.
