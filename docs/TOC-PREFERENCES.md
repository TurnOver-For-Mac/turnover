# TurnOver: every setting comes from VoiceOver

The rule (15 Oct 2026): in TurnOver there are no independent choices. VoiceOver Utility is where people set things;
TurnOver copies VoiceOver's export (the TurnOver menu, Copy VoiceOver settings) and every VoiceOver setting that
TurnOver has a capability for is applied one to one. Where TurnOver lacks the capability, that is work to do, listed
here.

The export is "VoiceOver Archive.voprefs" (VoiceOver Utility, File, Export Preferences…), a plain plist; its
`default` section holds the settings below (112 keys on one Mac). Names are VoiceOver's own, shortened.

Status: **copied** (done), **can copy** (TurnOver has the capability; the mapping to write), **needs capability**
(TurnOver must grow it first), **not for TurnOver** (VoiceOver-only, or the beta's).

## Speech (VoiceOver Utility, Speech)
| VoiceOver | TurnOver | Status |
|---|---|---|
| Voice (VoiceOverDefaultVoiceSelections: voiceId) | speech.voice | copied (Siri voices: nearest, said) |
| Rate, pitch, volume | speech.rate, pitch, volume | copied |
| Rotor voices (VoiceOverVoiceRotors), language voices | speech.languageVoices, languageRates | can copy |
| Punctuation level (per category; SCRPunctuationRepeatMode) | speech.symbolLevel | can copy (the level key sits per category; find it) |
| Repeated punctuation, repeated spaces (SCRRepeatedSpaces) | — | needs capability |
| Audio output device (SCRAudioOutputSelectorDeviceName) | speech.outputDevice | can copy |
| Audio ducking (AudioDuckingEnabled) | speech.ducking | can copy |
| Pronunciation list (custom.pronunciation.*) | — | needs capability (a dictionary, as NVDA's) |

## Verbosity
| VoiceOver | TurnOver | Status |
|---|---|---|
| Default verbosity (SCRVerbosityLevel: low, medium, high) | presentation.speakHints, reportObjectDescriptions | copied, roughly; a true three-level verbosity to build |
| Per-element verbosity (custom.verbosity.*: buttons, headings, links, lists…) | — | needs capability (TurnOver's words per role are fixed) |
| Typing echo (SCRTypingEchoFeedback) | keyboard.speakTypedCharacters, speakTypedWords | copied |
| Text attributes, misspelled words, link attributes, indentation levels | documentFormatting.* | can copy (map each level) |
| Instructions (SCRShouldOutputVOInstructions), help tags (SCROutputAXHelpTag) | presentation.speakHints, reportTooltips | can copy |
| Static text value updates (SCRVerbosity_StaticText_valueUpdate) | presentation.reportDynamicContentChanges | can copy |
| Announce Quick Nav type, system dialog reminder type | — | can copy (TurnOver has the reminder) |

## Navigation
| VoiceOver | TurnOver | Status |
|---|---|---|
| Cursor tracking (CursorTrackingEnabled, MToVO, VOToM) | general.focusFollowsCursor | can copy |
| Grouping behaviour (GroupingBehaviorGlobal), auto-drill containers | general.navigateByGroups | can copy |
| Skip redundant labels | — | needs capability (small) |
| Vertical and end-to-end wrapping | — | needs capability (small) |
| Keys for the VO modifier (SCRKeysToUseForVOModifier: Caps Lock, Control Option, both) | general.turnOverKey | can copy: important, the same key for both readers |

## Web
| VoiceOver | TurnOver | Status |
|---|---|---|
| Page loading behaviour (what's said on load), speak summary | browse mode on load | can copy |
| Single-letter Quick Nav (IndependentSingleLetterQuickNavEnabled), Left-Right Quick Nav | browse mode letters, arrow Quick Nav | can copy |
| Observe live regions | presentation.reportDynamicContentChanges | can copy |
| Don't speak table row and column indices | documentFormatting.tables | can copy |
| Image captions (UseImageCaption), image mapping level | describe image | can copy, partly |

## Commanders
| VoiceOver | TurnOver | Status |
|---|---|---|
| Keyboard Commander on/off and its modifier (SCRCKeyboardCommanderEnabled) | keyboard.optionCommander | can copy |
| Keyboard Commander assignments (custom.keyboard-commander.*: a letter → a VoiceOver command or a script) | keyboard commander table | can copy where TurnOver has the command; AppleScripts run as they are (wishlist 4a) |
| Numpad Commander (SCRNumPadCommanderEnabled) | keyboard.numpadCommander | can copy |
| Trackpad Commander (per trackpad) | gesture control | not for the Standard edition yet (beta) |
| Custom key bindings (custom.custom-keybindings.*, UseBuiltinCommandBindings) | keyboard.userGestures | can copy where the command exists |

## Braille
| VoiceOver | TurnOver | Status |
|---|---|---|
| Output and input tables, mirror tables, contracted, dots 7 and 8, word wrap, pan with cursor, alert timeout, auto-advance | braille.* | can copy (TurnOver's braille has most of these) |
| Braille verbosity (SCRBrailleVerbosityLevel) | braille verbosity | needs capability |
| Display input keys per display (custom.braille.*) | — | not for TurnOver (the display's own) |
| Braille window (visuals) | — | not for TurnOver |

## Sound and visuals
| VoiceOver | TurnOver | Status |
|---|---|---|
| Sounds on/off (mute sound toggle state) | sounds | can copy |
| Coding sounds (breakpoint, error, warning), line number verbosity | — | not for the Standard edition (Xcode is the beta's) |
| Caption window, braille window, cursor visuals, screen sharing settings | — | not for TurnOver |

## Hot spots and activities
| VoiceOver | TurnOver | Status |
|---|---|---|
| Hot spots (custom.hotspots.*) | — | needs capability (a hot spot is a saved element: TurnOver can find by match, as plugins do) |
| Activities (allProfiles): per-app settings | the tuned apps | not copied: TurnOver's app list takes their place; a per-app verbosity would need activities in TurnOver |

## Other
| VoiceOver | TurnOver | Status |
|---|---|---|
| Fast search, text checker rotor, rotor last positions, screen curtain | rotor, screen curtain | can copy the ones that are settings; positions are state, not settings |
| Allow AppleScript control | — | not for TurnOver |
| Welcome dialogue, login greeting | — | not for TurnOver |

## Order of work
1. The modifier key (Caps Lock or Control Option): same key for both readers.
2. Verbosity as three real levels, with per-element words.
3. Punctuation level, text attributes, misspellings, indentation.
4. Cursor tracking, grouping, web page loading, Quick Nav.
5. Commanders and custom key bindings (with scripts, wishlist 4a).
6. Braille settings.
7. Pronunciation dictionary; hot spots.

## TurnOver's own Settings, one by one (15 Oct: "everything in Settings is already defined in VoiceOver")

For each item in TurnOver Beta's Settings: the VoiceOver preference that defines it, and what the Standard edition (a smaller edition, parked; not built) does.
**From VoiceOver** = copied by the export, no item of its own. **Beta only** = the item goes (the feature is the
beta's). **No VoiceOver setting** = the maintainer to decide: keep as TurnOver's own item, or drop it and do what VoiceOver does.

### Speech
| TurnOver item | VoiceOver | Standard |
|---|---|---|
| Voice, Rate, Pitch, Volume | Speech: Voices | from VoiceOver (done) |
| Punctuation level | Speech: Punctuation | from VoiceOver |
| Language switching; Voices for other languages; Rate per language | Speech: Voices, one row per language | from VoiceOver |
| Where speech plays | Sound: output device | from VoiceOver |
| Lower other sounds while TurnOver speaks | Sound: audio ducking | from VoiceOver |
| Capitals; Say cap; Raise the pitch | none (VoiceOver has no capitals setting) | no VoiceOver setting |
| Speed; Kokoro natural voice; Read say all with Kokoro | none | beta only |
| Copy my VoiceOver settings | — | stays (it is the way in) |

### Keyboard
| TurnOver item | VoiceOver | Standard |
|---|---|---|
| TurnOver key (Caps Lock, Control Option) | General: keys to use as the VoiceOver modifier | from VoiceOver |
| Typing echo; Characters; Words | Verbosity: Text, typing echo | from VoiceOver (done) |
| Groups, Mac style | Navigation: grouping behaviour | from VoiceOver |
| Moving the cursor moves the keyboard focus | Navigation: keyboard focus follows VoiceOver cursor | from VoiceOver |
| Keypad commands, Mac style | Commanders: NumPad | from VoiceOver |
| Keyboard style; Keyboard layout; Groups, Windows style; Keypad commands, Windows style | none (NVDA's) | beta only |
| Command keys (speak modifier keys) | none | no VoiceOver setting |
| New line on Return | none | no VoiceOver setting |

### Braille
| TurnOver item | VoiceOver | Standard |
|---|---|---|
| Braille table; Other languages | Braille: output and input tables, mirror tables | from VoiceOver |
| Typing on the braille keyboard | Braille: input, contracted or not | from VoiceOver |
| Keep words whole | Braille: word wrap | from VoiceOver |
| Selection with dots 7 and 8 | Braille: show dots 7 and 8 | from VoiceOver |
| Show the word at the cursor uncontracted | Braille: translation, uncontracted word at cursor | from VoiceOver |
| Messages; Messages on the display; How long | Braille: alert messages, seconds | from VoiceOver |
| Bluetooth displays | Braille: displays | from VoiceOver |
| Show the cursor; Blink; Blink rate; Shape | Braille: cursor settings | from VoiceOver where VoiceOver has them |
| Speak braille typing | Verbosity: typing echo (shared) | from VoiceOver |
| Stop speech while panning | none | no VoiceOver setting |

### Documents (formatting)
| TurnOver item | VoiceOver | Standard |
|---|---|---|
| Bold, italic and the like; Font name; Font size; Fonts | Verbosity: text attributes level | from VoiceOver |
| Heading level | Verbosity: headings | from VoiceOver |
| Tables; Cell coordinates; Row and column headers | Web: table row and column indices; headers | from VoiceOver |

### Item details (presentation)
| TurnOver item | VoiceOver | Standard |
|---|---|---|
| Heading, link and button: when to say them | Verbosity: per-element | from VoiceOver |
| Help text of items | Verbosity: speak help tags | from VoiceOver |
| Hints after a pause | Verbosity: instructions for using the item | from VoiceOver |
| Each item's keyboard shortcut | none | no VoiceOver setting |
| Position, such as 3 of 10 | none (VoiceOver always says it) | no VoiceOver setting |
| Say which plugin an app has | none | beta only |

### Web pages (browse mode)
| TurnOver item | VoiceOver | Standard |
|---|---|---|
| Read the page automatically when it loads | Web: page loading, speak the page | from VoiceOver |
| Links and buttons in the line, as on screen | Web: navigate by DOM or group | from VoiceOver |
| Name undescribed pictures by their file name | Web: images, image mapping | from VoiceOver |
| Punctuation level | Speech: punctuation | from VoiceOver |
| Quick keys go round the page | Navigation: cursor wrapping | from VoiceOver |
| Focus mode when a field takes the focus | none (VoiceOver has no modes) | no VoiceOver setting |
| Maximum line length | none | no VoiceOver setting |

### General and the rest
| TurnOver item | VoiceOver | Standard |
|---|---|---|
| Sounds as I move and press | Sound: sounds on or off | from VoiceOver |
| Read new text as it appears | Web: observe live regions; Verbosity: value updates | from VoiceOver |
| Read the whole result as it opens | Verbosity: speak all static text in sheets | from VoiceOver |
| Screen Curtain while TurnOver reads | VoiceOver's screen curtain | from VoiceOver |
| Games; Gesture haptics; Screen recognition; Edition | none | beta only (Edition stays on a development Mac) |
| Hand-over (chimes or words) | none | no VoiceOver setting |
| Notifications from other apps | none | no VoiceOver setting |
| Starting (what TurnOver says as it starts) | General: login greeting | from VoiceOver, possibly |
| Open TurnOver at login; Show TurnOver in the menu bar | none (app housekeeping) | no VoiceOver setting |
