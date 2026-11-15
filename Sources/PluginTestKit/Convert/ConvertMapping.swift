// SPDX-License-Identifier: GPL-3.0-or-later
// The one table that says what an NVDA call becomes in a TurnOver script (docs/PLUGIN-PLATFORM-PLAN.md, stage A; the
// study's mapping list, nvda-addon-study.md section 3). Each row has the ability the call needs. A call that is not in
// this table is never guessed at: it is kept as the original Python and listed in the report.
import Foundation

nonisolated public enum ConvertMapping {
    /// How well a call comes across.
    public enum Fit: String, Sendable {
        /// A mechanical translation exists when every argument is a plain literal.
        case exact
        /// There is a script call for the idea, but a person must supply what NVDA objects stand for.
        case partial
        /// TurnOver's scripts cannot do it yet; a later stage would (the row says which piece).
        case nothingYet
        /// Taken out on purpose: nothing is lost (logging, translation set-up).
        case dropped
        /// The sandbox rules it out. A function that uses it is not carried over.
        case never
    }

    public struct Row: Sendable {
        public let nvda: String
        public let fit: Fit
        /// The ability the original's behaviour needs in TurnOver's words ("say", "read" …), or nil.
        public let ability: String?
        /// For `exact`: the JavaScript, with {0}, {1} for literal arguments. "" means the statement is left out.
        public let template: String?
        public let argc: Int
        public let why: String
        /// The stage B piece that would carry it.
        public let later: String?
    }

    private static func row(_ nvda: String, _ fit: Fit, ability: String? = nil, template: String? = nil, argc: Int = 0, later: String? = nil, _ why: String) -> Row {
        Row(nvda: nvda, fit: fit, ability: ability, template: template, argc: argc, why: why, later: later)
    }

    /// Names are as the call is written after imports are followed (ui.message), or ".method" for a method on an object.
    public static let rows: [Row] = [
        row("ui.message", .exact, ability: "say", template: "turnover.say({0})", argc: 1, "speaks a message"),
        row("speech.speakMessage", .exact, ability: "say", template: "turnover.say({0})", argc: 1, "speaks a message"),
        row("api.copyToClip", .exact, ability: "clipboard", template: "await turnover.copy({0})", argc: 1, "puts text on the clipboard"),
        row("nextHandler", .dropped, template: "", "NVDA's hand-on to the next handler; TurnOver carries on as usual after a handler"),
        row("speech.speak", .partial, ability: "say", "speaks a list of speech items; a person must write the words"),
        row("api.getFocusObject", .partial, ability: "read", "the item with the focus: await turnover.focused()"),
        row("api.getNavigatorObject", .partial, ability: "read", "NVDA's navigator object has no match in TurnOver; await turnover.focused() is the nearest"),
        row("api.getForegroundObject", .partial, ability: "read", "the foreground window; items are found with turnover.find"),
        row(".setFocus", .partial, ability: "focus", later: "a match made from a snapshot of the Mac app", "moves the focus to an item: find it with turnover.find, then await item.focus()"),
        row(".doAction", .partial, ability: "press", later: "a match made from a snapshot of the Mac app", "presses a control: find it with turnover.find, then await item.press()"),
        row("gesture.send", .partial, ability: "keys", "sends the pressed key on to the app: await turnover.keys(\"…\") with the key a person chooses"),
        row("winUser.mouse_event", .partial, ability: "press", "a mouse click becomes item.press() where the control can be pressed"),
        row("winUser.setCursorPos", .partial, ability: "press", "moving the mouse has no equivalent; pressing the item replaces the click"),
        row("core.callLater", .partial, "runs a function later: setTimeout, which pauses while none of the plugin's apps is in front"),
        row("wx.CallLater", .partial, "runs a function later: setTimeout, which pauses while none of the plugin's apps is in front"),
        row("wx.PyTimer", .partial, "a repeating timer: setInterval, which pauses while none of the plugin's apps is in front"),
        row("threading.Timer", .partial, "runs a function later: setTimeout, which pauses while none of the plugin's apps is in front"),
        row("queueHandler.queueFunction", .partial, "runs a function in NVDA's queue; a person writes it as plain JavaScript"),
        row("tones.beep", .nothingYet, later: "tones at a chosen pitch (turnover.tone)", "a beep of a chosen pitch has no equivalent yet"),
        row("nvwave.playWaveFile", .nothingYet, later: "the add-on's own sounds, with their own approval", "a script can play only TurnOver's own sounds today"),
        row("ui.browseableMessage", .nothingYet, later: "a list to choose from (turnover.choose)", "a window of text has no equivalent yet"),
        row(".makeTextInfo", .nothingYet, later: "the selection and lines of the focused item", "reading the selection or a line has no equivalent yet"),
        row("textInfos.*", .nothingYet, later: "the selection and lines of the focused item", "reading text by position has no equivalent yet"),
        row("config.conf", .nothingYet, later: "options TurnOver shows itself", "settings the person can change have no equivalent yet; a script can keep its own data with turnover.storage"),
        row("braille.handler.message", .dropped, template: "", "braille is TurnOver's own; a plugin does not send it"),
        row("addonHandler.initTranslation", .dropped, template: "", "translation set-up is not needed: the plugin's text is its own"),
        row("logHandler.log.*", .dropped, template: "", "logging; console.log is the script's own"),
        row("api.getClipData", .never, later: "reading the clipboard, with its own approval (clipboardRead)", "a script can never read the clipboard"),
        row("speech.setSpeechMode", .never, "a plugin cannot change TurnOver's settings"),
        row("os.startfile", .never, "a script cannot start programs or open files"),
        row("os.system", .never, "a script cannot start programs"),
        row("os.popen", .never, "a script cannot start programs"),
        row("webbrowser.open", .never, "a script cannot open web pages"),
        row("open", .never, "a script has no files of its own beyond turnover.storage"),
    ]

    private static let exactNames: [String: Row] = Dictionary(rows.filter { !$0.nvda.hasSuffix("*") }.map { ($0.nvda, $0) }, uniquingKeysWith: { a, _ in a })
    private static let prefixRows: [Row] = rows.filter { $0.nvda.hasSuffix("*") }

    /// The row for a call name as the parser gives it, or nil: a call not in the table is never guessed at.
    public static func row(for name: String) -> Row? {
        if let r = exactNames[name] { return r }
        for p in prefixRows where name.hasPrefix(String(p.nvda.dropLast())) { return p }
        if let dot = name.lastIndex(of: ".") {
            let method = String(name[dot...])
            if let r = exactNames[method] { return r }
        }
        return nil
    }

    /// Rows for a reference that is not a call (config.conf["x"]).
    public static func row(forReference name: String) -> Row? {
        for r in rows where r.fit == .nothingYet && (name == r.nvda || name.hasPrefix(r.nvda + ".") || (r.nvda.hasSuffix("*") && name.hasPrefix(String(r.nvda.dropLast())))) && !r.nvda.hasPrefix(".") { return r }
        return nil
    }

    // MARK: Events

    public struct EventRow: Sendable {
        public let nvda: String
        public let script: String?
        public let ability: String?
        public let fit: Fit
        public let why: String
        public let later: String?
    }
    private static func event(_ n: String, _ script: String?, _ ability: String?, _ fit: Fit, _ why: String, later: String? = nil) -> EventRow {
        EventRow(nvda: n, script: script, ability: ability, fit: fit, why: why, later: later)
    }
    public static let events: [EventRow] = [
        event("gainFocus", "focus", "read", .exact, "an item took the focus"),
        event("focusEntered", "focus", "read", .partial, "NVDA tells it when focus enters a group; TurnOver tells the script about the item that takes the focus"),
        event("foreground", "appFocus", nil, .exact, "a window came to the front"),
        event("appModule_gainFocus", "appFocus", nil, .exact, "the app came to the front"),
        event("appModule_loseFocus", "appBlur", nil, .exact, "the app went to the back"),
        event("valueChange", "valueChange", "read", .exact, "an item's value changed"),
        event("loseFocus", nil, nil, .nothingYet, "an item losing the focus is not sent to scripts", later: "more events"),
        event("becomeNavigatorObject", nil, nil, .nothingYet, "NVDA's navigator object does not exist in TurnOver"),
        event("nameChange", nil, nil, .nothingYet, "name changes are not sent to scripts yet", later: "more events"),
        event("stateChange", nil, nil, .nothingYet, "state changes are not sent to scripts yet", later: "more events"),
        event("selection", nil, nil, .nothingYet, "selection changes are not sent to scripts yet", later: "more events"),
        event("show", nil, nil, .nothingYet, "a window or popup appearing is not sent to scripts yet", later: "more events"),
        event("caret", nil, nil, .never, "caret moves are never sent to scripts, by design"),
        event("typedCharacter", nil, nil, .never, "typed characters are never sent to scripts, by design"),
        event("NVDAObject_init", nil, nil, .partial, "renaming an item when it is made becomes a label rule in profile.json, once a person has found the Mac item"),
    ]
    public static func eventRow(for name: String) -> EventRow? { events.first { $0.nvda == name } }

    // MARK: Modules

    /// Modules whose use means a function cannot come across, and why. Used by a function, unless the row above allows the call.
    public static let neverModules: [String: String] = [
        "subprocess": "it starts other programs", "socket": "it uses the network", "ssl": "it uses the network",
        "urllib": "it uses the internet", "http": "it uses the internet", "requests": "it uses the internet",
        "ftplib": "it uses the internet", "smtplib": "it uses the internet",
        "winreg": "it reads the Windows registry", "comtypes": "it uses Windows' own components",
        "ctypes": "it uses the Windows system interface directly", "winUser": "it uses the Windows system interface directly",
        "pickle": "it loads saved data that can hold code", "webbrowser": "it opens web pages",
    ]
    /// Modules that make a whole file a service, not a handful of lines: every function in a file that imports one is left out.
    public static let serviceModules: Set<String> = ["subprocess", "socket", "ssl", "urllib", "http", "requests", "ftplib", "smtplib", "winreg", "comtypes"]
    /// Imports that are dropped on purpose, and why.
    public static let droppedModules: [String: String] = [
        "addonHandler": "translation set-up: not needed, the plugin's text is its own",
        "wx": "a script has no windows or dialogs of its own",
        "gui": "settings panels and dialogs: a script has none (options are a later stage)",
        "logHandler": "logging",
    ]
    /// Modules that belong to NVDA, so a call into one that the table lacks is listed, not guessed at.
    public static let nvdaModules: Set<String> = [
        "api", "ui", "speech", "config", "gui", "core", "tones", "nvwave", "controlTypes", "textInfos", "scriptHandler", "eventHandler",
        "queueHandler", "winUser", "braille", "brailleInput", "keyboardHandler", "inputCore", "globalCommands", "appModuleHandler",
        "globalPluginHandler", "NVDAObjects", "speechViewer", "versionInfo", "buildVersion", "languageHandler", "windowUtils", "vision",
        "synthDriverHandler", "contentRecog", "compoundDocuments", "globalVars",
    ]
}
