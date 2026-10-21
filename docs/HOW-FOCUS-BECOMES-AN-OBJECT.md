# How an app's focus becomes an object

The other half of the story in [HOW-A-KEY-BECOMES-SPEECH.md](HOW-A-KEY-BECOMES-SPEECH.md): how a change inside an
application (the focus moved, a row was selected, the caret moved) becomes something TurnOver speaks.

The design is NVDA's, on macOS's accessibility API: an observer per application turns notifications into events;
each event is for an object; the object, its app module and the global plugins get the event in turn, and the
object's class decides what is said.

## 1. Watching an application

[AXHandler.swift](Sources/TurnOverCore/AXHandler.swift) is the handler for the accessibility API. When an app comes
forward, the observe method in [AXHandlerApplications.swift](Sources/TurnOverCore/AXHandlerApplications.swift)
creates an AXObserver for its process, sets the messaging timeout to one second so a hung app cannot hold TurnOver,
switches on the enhanced interface that makes WebKit and Chromium build their accessibility trees, and signs up for
the handler's list of notifications. An app still starting refuses them all, so the sign-up is retried as it
settles; a slow app is signed up off the main thread. The log says observing pid N.

The notification method in [AXHandlerNotifications.swift](Sources/TurnOverCore/AXHandlerNotifications.swift) is
where each notification is sorted. The ones that matter most:

- **focused element changed**: the focus rules (section 2), then the event.
- **selected text changed**: a caret event for the focus.
- **value changed**: spoken only for the focus object; everything else is noise (AutoSave labels, scroll bars).
- **selected rows or children changed**, **selected cells changed**: a selection event for the row or cell.
- **menu opened, closed, item selected**: menu events.
- **window created, sheet created, row count changed, layout changed, live region changed**: each its own case.

None of this speaks. The handler decides what the event is; the objects decide what to say.

## 2. Which element is the focus

Applications report the wrong focus often enough that there is a file for it:
[FocusChanges.swift](Sources/TurnOverCore/FocusChanges.swift). Each special case is a named rule, tried in order,
with a verdict: ignore (not the focus; say nothing), follow (the focus is really this other element; start the
rules again with it), go (this element, on to the next rule) or done (the rule has handled it). The present method
at the end makes the objects for the focus and its ancestors and queues the gainFocus event, with focusEntered events
for ancestors that are new (a window, a group, a table the focus just entered).

The result is kept in [API.swift](Sources/TurnOverCore/API.swift): focusObject is the current focus, focusAncestors
its chain up to the window, caretObject the object whose text the caret is in, focusPid the process it belongs to.
Scripts ask API for these; nothing else reaches into the handler.

## 3. From element to object

ObjectFactory.make, at the bottom of [TurnOverObject.swift](Sources/TurnOverCore/TurnOverObject.swift), turns a raw
accessibility element into a TurnOverObject:

- **The role** comes from the AX role and subrole through the from method in
  [ControlTypes.swift](Sources/TurnOverCore/ControlTypes.swift): AXOutline is a treeView, AXTable a table, AXTextArea
  editableText, and so on. Speech names roles from this one list, so an app's oddity is corrected here or in its
  module, never by special-casing the spoken word.
- **The class** is chosen by the app module first (objectClass, section 4), then by role and subrole: an editable
  text field becomes EditableText ([EditableText.swift](Sources/TurnOverCore/EditableText.swift)), a list or table a
  SelectableList ([SelectableList.swift](Sources/TurnOverCore/SelectableList.swift)), a dialog a Dialog
  ([Dialog.swift](Sources/TurnOverCore/Dialog.swift)). The class carries the scripts and the event handlers.
- **The name** is computed once (computedName): the title, then the description, then the label the app points to,
  a neighbouring label, a button's tooltip; a row or cell with no name is the text it holds (contentText), and so is
  a nameless menu item, button or link, as in Electron apps. rawName is the element's own name before any of that,
  and swiftUILabel finds a SwiftUI control's label when the element arrives without one.
- **States** (selected, expanded, disabled), **value**, **description** and **position** (3 of 6) are read on demand.

Objects are cheap and short-lived: one is made per event, and the focus and its ancestors are kept between events.

## 4. App modules

[AppModule.swift](Sources/TurnOverCore/AppModule.swift) is one object per running application, found by bundle
identifier through AppModuleHandler.appModule(for:), made on first use. An app without a module gets the base class.
A module can:

- **choose object classes** for the app's controls (objectClass): TurnOverSettingsAppModule in
  [TurnOverSettingsAppModule.swift](Sources/TurnOverCore/Modules/TurnOverSettingsAppModule.swift) gives every control
  a class that looks harder for a label, because the Settings app hands over labels late;
- **redirect a misreported focus** and **handle the app's events** before the objects do;
- **carry scripts** that work anywhere in the app: Finder's module declares what Command Down says with nothing
  selected, and the Windows-style Return and F2.

The modules TurnOver ships are registered in one place,
[BuiltInModules.swift](Sources/TurnOverCore/Modules/BuiltInModules.swift); plugins register theirs the same way.

## 5. Events reaching the object

[Events.swift](Sources/TurnOverCore/Events.swift) holds the queue. Each event runs the chain: global plugins, the app
module, then the object's own handler (event_gainFocus, event_selection, event_caret and the rest). A handler that
does not pass the event on stops it. Events are queued while a script runs and drained when it finishes; a script
waiting for the application pumps the run loop so the events keep arriving and can see one is pending.

The object's class is what makes the difference. A SelectableList's gainFocus speaks the list and its selected row;
its selection event speaks the row that changed. EditableText's caret event compares the old and new selection to say
selected or unselected text, and speaks nothing for a caret move its own script is already waiting on.

## 6. Speaking the object

Speech.speakObject in [Speech.swift](Sources/TurnOverCore/Speech.swift) builds the announcement from
objectPropertiesSpeech (name, role, value, states, description, shortcut, position) and adds, for a list or table
taking focus, its selected row, or, with nothing selected, its count: N items, nothing selected, or empty. A table or
outline with no rows is empty even though its children are columns and a header. For a text field it adds the
selection or the line at the caret. The same focus reported twice within half a second is said once.

## 7. Where a change belongs

- **One app behaves oddly**: its app module. Add a rule there (an objectClass, an event handler, a script with an
  isAvailable check). Finder's Command Down with nothing selected is the model. Nothing else can be affected.
- **A kind of control behaves oddly in several apps**: the behaviour class (SelectableList.swift, EditableText.swift and their neighbours), with the apps it was
  seen in named in the comment, and a fixture test (TESTING.md) that pins it.
- **The focus is wrong**: a named rule in FocusChanges.swift, narrow enough to say in one sentence.

Shared code (the focus rules, the behaviours, the key tap, speech) is used by every app at once, and a change that
helps one app can silently break another: Return taken from the settings panes by a ribbon's Tab script, a Space that
stopped playing a podcast. [PATTERNS.md](../PATTERNS.md) lists the ways Mac apps misbehave and the answers already
in place; [CONTRIBUTING.md](../CONTRIBUTING.md) asks for an issue first before a change to the shared parts, and
that what works is kept. The rule of thumb: the narrowest place that fixes it, and a test that says what it fixed.
