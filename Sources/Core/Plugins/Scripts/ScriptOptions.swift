// SPDX-License-Identifier: GPL-3.0-or-later
// A plugin's options (docs/PLUGIN-PLATFORM-PLAN.md, stage B; 16 Nov 2026): declared in the manifest, shown by TurnOver in its
// own Plugins menu, kept in TurnOver's own settings, read by the script with `turnover.options.get(id)`, and told to the script
// with an `optionsChange` event. They need no ability: they are the person's own settings, and the script can only read them.
// The author's words (labels, choices) are plain text and short, shown as written. Anything that is not a value the option allows
// is never stored and never reaches the script: a bad saved value falls back to the default.
import Foundation

/// What an option holds: a switch, a number, or text (a choice is its text).
nonisolated public enum PluginOptionValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { throw DecodingError.typeMismatch(PluginOptionValue.self, .init(codingPath: decoder.codingPath, debugDescription: "an option's value is true or false, a number or text")) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }

    public var scriptValue: ScriptValue {
        switch self {
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        }
    }
    /// From something stored or sent: only the three kinds exist.
    public init?(any: Any?) {
        switch any {
        case let n as NSNumber: self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        default: return nil
        }
    }
    var json: Any {
        switch self { case .bool(let b): return b; case .number(let n): return n; case .string(let s): return s }
    }
}

/// Words an author writes that TurnOver shows or says as theirs: no line breaks, no control or invisible formatting characters,
/// and none of the private marks TurnOver's own speech uses inside text.
nonisolated public enum PluginText {
    public static func isPlain(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: return false
            default: break
            }
        }
        return true
    }
}

nonisolated public struct PluginOption: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    /// "switch", "choice", "text" or "number".
    public var kind: String
    public var choices: [String]?
    public var min: Double?
    public var max: Double?
    public var defaultValue: PluginOptionValue

    enum CodingKeys: String, CodingKey { case id, label, kind, choices, min, max; case defaultValue = "default" }

    public init(id: String, label: String, kind: String, choices: [String]? = nil, min: Double? = nil, max: Double? = nil, defaultValue: PluginOptionValue) {
        self.id = id; self.label = label; self.kind = kind; self.choices = choices; self.min = min; self.max = max; self.defaultValue = defaultValue
    }

    public static let kinds = ["switch", "choice", "text", "number"]
    /// At most this many options, this many characters in a label or a choice, in a text option's value, and this many choices.
    public static let maxCount = 20
    public static let labelCharacters = 80
    public static let textCharacters = 200
    public static let maxChoices = 50

    /// Each thing wrong with the declaration, in words for the author.
    public func problems() -> [String] {
        var out: [String] = []
        if id.isEmpty || !PluginFormat.isValidCommandID(id) { out.append("the id \"\(id)\" must be letters and digits only: the script names it in code") }
        let name = id.isEmpty ? "an option" : "option \(id)"
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { out.append("\(name) needs a label: it is what the person sees in the menu") }
        else if label.count > Self.labelCharacters { out.append("\(name): the label is \(label.count) characters; at most \(Self.labelCharacters)") }
        else if !PluginText.isPlain(label) { out.append("\(name): the label must be plain text, with no line breaks or control characters") }
        guard Self.kinds.contains(kind) else { out.append("\(name): kind \"\(kind)\" is not one TurnOver has (\(Self.kinds.joined(separator: ", ")))"); return out }
        if kind != "choice", choices != nil { out.append("\(name): choices belong to a choice option only") }
        if kind != "number", min != nil || max != nil { out.append("\(name): min and max belong to a number option only") }
        switch kind {
        case "switch":
            if case .bool = defaultValue {} else { out.append("\(name): the default of a switch is true or false") }
        case "choice":
            let list = choices ?? []
            if list.isEmpty || list.count > Self.maxChoices { out.append("\(name): a choice needs 1 to \(Self.maxChoices) choices") }
            if Set(list).count != list.count { out.append("\(name): two choices are the same") }
            for c in list {
                if c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("\(name): a choice is empty") }
                else if c.count > Self.labelCharacters { out.append("\(name): a choice is \(c.count) characters; at most \(Self.labelCharacters)") }
                else if !PluginText.isPlain(c) { out.append("\(name): a choice must be plain text") }
            }
            if case .string(let d) = defaultValue, list.contains(d) {} else { out.append("\(name): the default must be one of the choices") }
        case "text":
            if case .string(let d) = defaultValue {
                if d.count > Self.textCharacters { out.append("\(name): the default is longer than \(Self.textCharacters) characters") }
                else if !PluginText.isPlain(d) { out.append("\(name): the default must be plain text") }
            } else { out.append("\(name): the default of a text option is text") }
        default:   // number
            guard let lo = min, let hi = max, lo.isFinite, hi.isFinite else { out.append("\(name): a number needs a min and a max"); break }
            if lo > hi { out.append("\(name): min is larger than max") }
            if case .number(let d) = defaultValue, d.isFinite, d >= lo, d <= hi {} else { out.append("\(name): the default must be a number from \(lo) to \(hi)") }
        }
        return out
    }

    /// The value as this option allows it, or nil if it is not one it allows.
    public func accepting(_ value: PluginOptionValue) -> PluginOptionValue? {
        switch (kind, value) {
        case ("switch", .bool): return value
        case ("choice", .string(let s)): return (choices ?? []).contains(s) ? value : nil
        case ("text", .string(let s)): return s.count <= Self.textCharacters && PluginText.isPlain(s) ? value : nil
        case ("number", .number(let n)):
            guard n.isFinite, let lo = min, let hi = max, n >= lo, n <= hi else { return nil }
            return value
        default: return nil
        }
    }
}

/// The values of every plugin's options, in TurnOver's own settings. Nothing is stored that the option does not allow, and what is
/// read back is checked again, so a changed file cannot give a script a value its option never had.
package final class ScriptOptionsStore {
    package static let defaultsKey = "pluginOptions"
    private var stored: [String: [String: PluginOptionValue]] = [:]
    private let save: ([String: [String: Any]]) -> Void

    /// `load` is what was saved, as property-list data; `save` keeps it. Tests give neither (memory only).
    package init(load: [String: Any] = [:], save: @escaping ([String: [String: Any]]) -> Void = { _ in }) {
        self.save = save
        for (plugin, any) in load {
            guard let inner = any as? [String: Any] else { continue }
            var values: [String: PluginOptionValue] = [:]
            for (id, raw) in inner { if let v = PluginOptionValue(any: raw) { values[id] = v } }
            stored[plugin] = values
        }
    }

    /// TurnOver's own settings (UserDefaults).
    package static func live() -> ScriptOptionsStore {
        ScriptOptionsStore(load: UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]) { UserDefaults.standard.set($0, forKey: defaultsKey) }
    }

    package func value(of option: PluginOption, plugin: String) -> PluginOptionValue {
        if let kept = stored[plugin]?[option.id], let ok = option.accepting(kept) { return ok }
        return option.defaultValue
    }

    package func values(for options: [PluginOption], plugin: String) -> [String: PluginOptionValue] {
        Dictionary(options.map { ($0.id, value(of: $0, plugin: plugin)) }, uniquingKeysWith: { a, _ in a })
    }

    /// Keep a new value if the option allows it; the value kept, or nil.
    @discardableResult
    package func set(_ value: PluginOptionValue, of option: PluginOption, plugin: String) -> PluginOptionValue? {
        guard let ok = option.accepting(value) else { return nil }
        stored[plugin, default: [:]][option.id] = ok
        save(stored.mapValues { $0.mapValues(\.json) })
        return ok
    }
}
