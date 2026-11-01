// SPDX-License-Identifier: GPL-3.0-or-later
// A keyboard style's own key table (docs/KEYBOARD-STYLES-PLAN.md, 19 Oct 2026): Narrator's and JAWS's keys, each naming one
// of TurnOver's commands. VoiceOver keys and NVDA keys are the built-in gestures (the Mac and Windows styles as they
// were); the newer styles are data over the same commands, embedded in the program (Resources/keymaps,
// make-embedded.py). Looked up after the user's own keys and before everything else.
//
// A table: {"style": "jaws", "keys": {"kb:turnover+i": "reportCurrentLine", "kb:turnover+f6": "=kb:turnover+f7", ...},
// "duringSayAll": {"kb:leftArrow": "jaws_sayAllBack", ...}}. Keys are written as gestures are ("turnover" for the
// screen reader key: Caps Lock, or Control and Option). A value is a command's script name, or "=" and another key:
// do whatever that key does here, in the Windows family (20 Oct 2026), so an app's own command on it (Word's, a web
// page's elements list) comes along. "duringSayAll" keys apply only to a key pressed while say all reads, and plain
// keys (arrows, Page Up) belong there: in "keys" they would take typing and moving away from every app.
import Foundation

public enum StyleKeymap {
    nonisolated(unsafe) private static var cache: [KeyboardStyle: (keys: [String: String], sayAll: [String: String])] = [:]   // main thread

    /// The table for a style, normalised; empty for the built-in styles or when there is none.
    public static func keys(for style: KeyboardStyle) -> [String: String] { table(for: style).keys }
    /// The style's keys that apply while say all reads.
    public static func sayAllKeys(for style: KeyboardStyle) -> [String: String] { table(for: style).sayAll }

    private static func table(for style: KeyboardStyle) -> (keys: [String: String], sayAll: [String: String]) {
        if let k = cache[style] { return k }
        var k: (keys: [String: String], sayAll: [String: String]) = ([:], [:])
        if let entry = EmbeddedResources.keymaps.first(where: { $0.name == "\(style.rawValue).json" }),
           let data = EmbeddedResources.unpack(entry.packed) {
            k = (parse(data), parse(data, section: "duringSayAll"))
        }
        cache[style] = k
        return k
    }

    /// A table's keys and command names, with the keys in their normal form; nil entries and bad JSON give nothing.
    public static func parse(_ data: Data, section: String = "keys") -> [String: String] {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let keys = top[section] as? [String: String] else { return [:] }
        var out: [String: String] = [:]
        for (id, name) in keys where !name.isEmpty { out[normalizeGestureIdentifier(id)] = name }
        return out
    }

    /// The command the style's table gives this key, if any.
    public static func script(for g: KeyboardGesture) -> Script? {
        let style = config.general.style
        guard style == .narrator || style == .jaws else { return nil }
        let t = table(for: style)
        let sayAll = SayAll.isRunning || SayAll.keyArrivedDuringSayAll.value
        for id in UserGestures.identifiers(of: g) {
            let key = normalizeGestureIdentifier(id)
            if sayAll, let name = t.sayAll[key], let s = resolve(name) { return s }
            if let name = t.keys[key] { return resolve(name) }
        }
        return nil
    }

    /// Where VoiceOver reads, the key layer (WindowsKeyLayer) answers the style's keys with VoiceOver's: the key each one
    /// stands for there. An alias ("=kb:turnover+…") stands for its NVDA key, whose VoiceOver twin it takes; a reading key
    /// (Caps Lock U, O, J, L, M and Period) for the arrow it presses instead (GlobalCommands.pressInstead), posted as it
    /// is, so VoiceOver reads where the caret lands. Only the aliases had one, and the six went quiet or ran NVDA's
    /// meaning of the letter (the review of pull request 144, 29 Oct 2026).
    public static func voiceOverStandIns(for style: KeyboardStyle) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in keys(for: style) {
            if value.hasPrefix("=") { out[key] = normalizeGestureIdentifier(String(value.dropFirst())) }
            else if let r = GlobalCommands.readingKeys.first(where: { $0.name == value }) { out[key] = normalizeGestureIdentifier("kb:" + r.key) }
        }
        return out
    }

    /// A command by name, or what another key does ("=kb:…"), looked up without the style's table.
    static func resolve(_ value: String) -> Script? {
        if value.hasPrefix("=") {
            guard let other = KeyboardGesture(identifier: String(value.dropFirst())) else { return nil }
            return ScriptHandler.findScript(for: other, styleTable: false)
        }
        return ScriptHandler.findScript(named: value)
    }
}
