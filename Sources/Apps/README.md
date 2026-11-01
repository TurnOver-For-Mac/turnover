# App records

Generated from each app’s STATUS.md. Only the recorded tasks and setups are assessed; the presence of a folder is not evidence of support.

## Reading the records

**Support:** Works means the named tasks worked in the recorded setup; Partial means useful tasks have known gaps; Blocked means the stated task has no usable tested route; Not assessed means there is no adequate evidence for the named tasks. Grades use the best recorded evidence; Checked gives its date and build, and a new build does not automatically reset them. Blocked is not proof of impossibility.

**Effort:** None means no app-specific adaptation; Settings or plugin means configuration is sufficient; Module means app-specific code; Workaround means an indirect route; No route known means no usable approach has been demonstrated. Blank effort remains unassessed. These are categories, not time estimates.

**Being worked on** records a current person and issue, or Unclaimed; it creates no permanent ownership. AI assistance and historical work are described in the evidence. VoiceOver on/off is a test condition, not a limit on TurnOver’s intended support.

Records include dedicated modules, shared-code support and earlier app investigations. A recovered result keeps its original date and limits; a planned task is not a completed test. See [the evidence guide](../../docs/APP-TEST-HISTORY.md). Bundle id may be Not recorded until verified; never guess an identifier from an app name.

Assess support by checking the named tasks and recording the app/macOS versions, reader build, keyboard style and VoiceOver state. Use public sample content for saved evidence.

Shared implementations: [Media](Media/README.md), [Chat](Chat/README.md), [Panes](Panes/README.md), [Games](Games/README.md), [Catalog](Catalog/README.md), [Google browser editors](GoogleDocs/README.md). They are not separate app support grades.

Run `python3 Tools/build-app-index.py` after editing app records or documentation. It updates this index and the generated app-record exclusions in Package.swift. `--check` validates records, local links and both outputs. Production Swift source entries remain explicit.

## Works

- [Activity Monitor](ActivityMonitor/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [Byword](Byword/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [Console](Console/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [Disk Utility](DiskUtility/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [iTerm2](iTerm2/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [REAPER](REAPER/STATUS.md) — Effort: Settings or plugin; being worked on: Unclaimed.
- [Terminal](Terminal/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Visual Studio Code](VSCode/STATUS.md) — Effort: None; being worked on: Unclaimed.

## Partial

- [App Store](AppStore/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Audacity](Audacity/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Audible](Audible/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [Bambu Studio](BambuStudio/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Books](Books/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Calendar](Calendar/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Contacts](Contacts/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Cyberduck](Cyberduck/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [Discord](Discord/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Finder](Finder/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Freeform](Freeform/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Home](Home/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [KeePassXC](KeePassXC/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [LibreOffice](LibreOffice/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [Messages](Messages/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Microsoft Excel](Excel/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Microsoft Word](Word/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [MuseScore Studio](MuseScore/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [OBS Studio](OBS/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Obsidian](Obsidian/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Passwords](Passwords/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [PDFsam Basic](PDFsam/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [Preview](Preview/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [QuickTime Player](QuickTime/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [Reminders](Reminders/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Script Editor](ScriptEditor/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [Shortcuts](Shortcuts/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Slack](Slack/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Spotify](Spotify/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Steam](Steam/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [System Settings](SystemSettings/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [TextEdit](TextEdit/STATUS.md) — Effort: Module; being worked on: Codex for Oliver, issue 212.
- [Ulysses](Ulysses/STATUS.md) — Effort: Module; being worked on: Codex for Oliver, issue 212.
- [Voice Memos](VoiceMemos/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [WhatsApp](WhatsApp/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Xcode](Xcode/STATUS.md) — Effort: None; being worked on: Unclaimed.

## Blocked

- [AppFlowy](AppFlowy/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Dropbox](Dropbox/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [iPhone Mirroring](iPhoneMirroring/STATUS.md) — Effort: No route known; being worked on: Unclaimed.
- [TV](TV/STATUS.md) — Effort: Module; being worked on: Unclaimed.

## Not assessed

- [Calculator](Calculator/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Claude](Claude/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Clock](Clock/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Dock](Dock/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [FaceTime](FaceTime/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Firefox](Firefox/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Games (Apple)](AppleGames/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [GarageBand](GarageBand/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Google Chrome](Chrome/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [IntelliJ IDEA](IntelliJIDEA/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Journal](Journal/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Keynote](Keynote/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Kindle](Kindle/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Libation](Libation/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [LocalSend](LocalSend/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Mail](Mail/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Maps](Maps/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Microsoft Edge](Edge/STATUS.md) — Effort: None; being worked on: Unclaimed.
- [Microsoft Outlook](Outlook/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Music](Music/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Notes](Notes/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Numbers](Numbers/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Pages](Pages/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Photos](Photos/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Podcasts](Podcasts/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Safari](Safari/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Spotlight](Spotlight/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Stocks](Stocks/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Thunderbird](Thunderbird/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Tips](Tips/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [TurnOver Settings](TurnOverSettings/STATUS.md) — Effort: Module; being worked on: Unclaimed.
- [Weather](Weather/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
- [Zoom](Zoom/STATUS.md) — Effort: not assessed; being worked on: Unclaimed.
