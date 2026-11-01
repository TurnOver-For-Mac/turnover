// SPDX-License-Identifier: GPL-3.0-or-later
// Scripts and the objects that carry them (NVDA: baseObject.ScriptableObject,
// scriptHandler.script).
//
// A script is a function run in response to a gesture. Objects, app modules,
// global plugins and the global commands all carry scripts; the script handler
// asks each in turn. Bindings are plain strings ("kb:turnover+t") so a user
// gesture map can rebind them later, and every script has a description so
// input help can speak it.
import Foundation

public final class Script {
    public let name: String
    public let description: String
    public let category: String
    public let handler: (KeyboardGesture) -> Void
    /// NVDA's canPropagate: an ancestor of the focus may answer this gesture.
    public var canPropagate = false
    /// NVDA's bypassInputHelp: run even while input help is on (toggleInputHelp itself).
    public var bypassInputHelp = false
    /// NVDA's resumeSayAllMode: Say All continues after this script if it was running.
    public var resumesSayAll = false
    public private(set) weak var owner: ScriptableObject?
    /// A setting that switches this script off (Windows keys): when false the gesture is not taken at all.
    public var isAvailable: (() -> Bool)?
    /// What keyboard help says: the description up to its first explanation, without the reference key in
    /// brackets ("Next heading", not "…; elsewhere …(VO-Command-H)"). 13 Oct 2026: "It's all a bit verbose".
    /// The shortcuts list keeps the whole description.
    public var brief: String { Self.brief(description) }
    /// The category as the key list says it. The category itself stays English: scripts are grouped and found by it.
    public var categoryName: String { Self.categoryName(category) }
    nonisolated public static func categoryName(_ category: String) -> String {
        switch category {
        case "Add-ons": return String(localized: "Add-ons", comment: "A group of commands in the key list")
        case "App Store": return String(localized: "App Store", comment: "A group of commands in the key list")
        case "Browse mode": return String(localized: "Browse mode", comment: "A group of commands in the key list")
        case "Calculator": return String(localized: "Calculator", comment: "A group of commands in the key list")
        case "Calendar": return String(localized: "Calendar", comment: "A group of commands in the key list")
        case "Claude": return String(localized: "Claude", comment: "A group of commands in the key list")
        case "Contacts": return String(localized: "Contacts", comment: "A group of commands in the key list")
        case "Dialogs": return String(localized: "Dialogs", comment: "A group of commands in the key list")
        case "Finder": return String(localized: "Finder", comment: "A group of commands in the key list")
        case "Freeform": return String(localized: "Freeform", comment: "A group of commands in the key list")
        case "Games": return String(localized: "Games", comment: "A group of commands in the key list")
        case "Keynote": return String(localized: "Keynote", comment: "A group of commands in the key list")
        case "Keypad": return String(localized: "Keypad", comment: "A group of commands in the key list")
        case "Kindle": return String(localized: "Kindle", comment: "A group of commands in the key list")
        case "Lists": return String(localized: "Lists", comment: "A group of commands in the key list")
        case "Mail": return String(localized: "Mail", comment: "A group of commands in the key list")
        case "Maps": return String(localized: "Maps", comment: "A group of commands in the key list")
        case "Menus": return String(localized: "Menus", comment: "A group of commands in the key list")
        case "Microsoft Excel": return String(localized: "Microsoft Excel", comment: "A group of commands in the key list")
        case "Microsoft Word": return String(localized: "Microsoft Word", comment: "A group of commands in the key list")
        case "NVDA keys": return String(localized: "NVDA keys", comment: "A group of commands in the key list")
        case "Numbers": return String(localized: "Numbers", comment: "A group of commands in the key list")
        case "Object navigation": return String(localized: "Object navigation", comment: "A group of commands in the key list")
        case "Pages": return String(localized: "Pages", comment: "A group of commands in the key list")
        case "Photos": return String(localized: "Photos", comment: "A group of commands in the key list")
        case "Plugins": return String(localized: "Plugins", comment: "A group of commands in the key list")
        case "Quick navigation": return String(localized: "Quick navigation", comment: "A group of commands in the key list")
        case "Reminders": return String(localized: "Reminders", comment: "A group of commands in the key list")
        case "Safari": return String(localized: "Safari", comment: "A group of commands in the key list")
        case "Selecting": return String(localized: "Selecting", comment: "A group of commands in the key list")
        case "Settings": return String(localized: "Settings", comment: "A group of commands in the key list")
        case "Shortcuts": return String(localized: "Shortcuts", comment: "A group of commands in the key list")
        case "Speech": return String(localized: "Speech", comment: "A group of commands in the key list")
        case "Sliders": return String(localized: "Sliders", comment: "A group of commands in the key list")
        case "System": return String(localized: "System", comment: "A group of commands in the key list")
        case "Tabs": return String(localized: "Tabs", comment: "A group of commands in the key list")
        case "Terminal": return String(localized: "Terminal", comment: "A group of commands in the key list")
        case "Text navigation": return String(localized: "Text navigation", comment: "A group of commands in the key list")
        case "Text review": return String(localized: "Text review", comment: "A group of commands in the key list")
        case "This control": return String(localized: "This control", comment: "A group of commands in the key list")
        case "TurnOver": return String(localized: "TurnOver", comment: "A group of commands in the key list")
        case "VoiceOver keys": return String(localized: "VoiceOver keys", comment: "A group of commands in the key list")
        case "Windows keys": return String(localized: "Windows keys", comment: "A group of commands in the key list")
        case "Your keys": return String(localized: "Your keys", comment: "A group of commands in the key list")
        case "navigation": return String(localized: "navigation", comment: "A group of commands in the key list")
        default: return category
        }
    }
    nonisolated public static func brief(_ description: String) -> String {
        var d = description
        for cut in [" (", "; ", ": ", ". "] { if let r = d.range(of: cut) { d = String(d[..<r.lowerBound]) } }
        d = d.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
        return d.isEmpty ? description : d
    }

    public init(name: String, description: String, category: String, owner: ScriptableObject?, handler: @escaping (KeyboardGesture) -> Void) {
        self.name = name; self.description = description; self.category = category; self.owner = owner; self.handler = handler
    }

    /// Whether it is available, timed: a check that talks to the application and takes longer than 15 ms is
    /// logged by name (once in 10 s per script), so slow checks are found rather than guessed (8 Oct 2026).
    private var lastSlowReport = Date.distantPast
    var isAvailableNow: Bool {
        guard let check = isAvailable else { return true }
        let started = DispatchTime.now()
        let ok = check()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        if ms > 15, Date().timeIntervalSince(lastSlowReport) > 10 {
            lastSlowReport = Date()
            Log.warning("script \(name): its availability check took \(Int(ms)) ms")
        }
        return ok
    }
}

open class ScriptableObject {
    public static let defaultCategory = "TurnOver"
    private var scripts: [String: Script] = [:]
    /// normalized identifier → script names, the latest declared first. Several scripts may share a key, each with
    /// its own isAvailable: the first available one runs. (One name per key let a later script silently replace an
    /// earlier one: the ribbon's Tab took Tab from the settings panes and from places that ignore Tab, 5 Oct 2026.)
    /// A script without isAvailable declared later still wins outright, as an override did before.
    private var gestureMap: [String: [String]] = [:]
    private let lock = NSLock()

    public init() {}

    /// Declare a script (NVDA: @script). Bindings may name a layout: "kb(laptop):turnover+l".
    @discardableResult
    public func script(_ name: String, _ description: String, gestures: [String] = [], category: String = ScriptableObject.defaultCategory,
                       canPropagate: Bool = false, bypassInputHelp: Bool = false, resumesSayAll: Bool = false,
                       _ handler: @escaping (KeyboardGesture) -> Void) -> Script {
        let s = Script(name: name, description: description, category: category, owner: self, handler: handler)
        s.canPropagate = canPropagate; s.bypassInputHelp = bypassInputHelp; s.resumesSayAll = resumesSayAll
        lock.lock()
        scripts[name] = s
        for g in gestures { bind(normalizeGestureIdentifier(g), name) }
        lock.unlock()
        return s
    }

    /// Bind a gesture to a script declared here (NVDA: bindGesture).
    public func bindGesture(_ identifier: String, to scriptName: String) {
        lock.lock(); bind(normalizeGestureIdentifier(identifier), scriptName); lock.unlock()
    }
    public func unbindGesture(_ identifier: String) {
        lock.lock(); gestureMap.removeValue(forKey: normalizeGestureIdentifier(identifier)); lock.unlock()
    }
    public func removeScript(_ name: String) {
        lock.lock(); scripts.removeValue(forKey: name); gestureMap = gestureMap.compactMapValues { l in let r = l.filter { $0 != name }; return r.isEmpty ? nil : r }; lock.unlock()
    }

    /// The script bound to a gesture here, if any (NVDA: getScript). Safe from any thread.
    /// Unbind gestures (a subclass giving keys back to the application).
    public func removeGestures(_ ids: [String]) {
        lock.lock(); for g in ids { gestureMap.removeValue(forKey: normalizeGestureIdentifier(g)) }; lock.unlock()
    }

    /// Put a script first for a key (under the lock).
    private func bind(_ id: String, _ name: String) {
        var list = gestureMap[id] ?? []
        list.removeAll { $0 == name }
        list.insert(name, at: 0)
        gestureMap[id] = list
    }

    public func script(for gesture: KeyboardGesture) -> Script? {
        // The candidates under the lock; whether each is available, outside it (a check may be slow: E6 audit).
        lock.lock()
        let candidates = gesture.identifiers.flatMap { id in (gestureMap[id] ?? []).compactMap { scripts[$0] } }
        lock.unlock()
        return candidates.first { $0.isAvailableNow }
    }
    public func script(named name: String) -> Script? { lock.lock(); defer { lock.unlock() }; return scripts[name] }
    /// Every script declared here, bound or not (the keyboard commands editor).
    public var allScripts: [Script] { lock.lock(); defer { lock.unlock() }; return Array(scripts.values) }

    /// Every binding whatever the style or the moment (the plugin checker's clash check): (identifier, scripts).
    public var everyBinding: [(String, [Script])] {
        lock.lock(); defer { lock.unlock() }
        return gestureMap.map { id, names in (id, names.compactMap { scripts[$0] }) }
    }
    /// Every binding, for help and documentation: (identifier, script).
    public var allBindings: [(String, Script)] {
        lock.lock()
        let all = gestureMap.map { id, names in (id, names.compactMap { scripts[$0] }) }
        lock.unlock()
        return all.compactMap { id, list in list.first { $0.isAvailable?() ?? true }.map { (id, $0) } }.sorted { $0.0 < $1.0 }
    }
}
