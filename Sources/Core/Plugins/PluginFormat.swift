// SPDX-License-Identifier: GPL-3.0-or-later
// The plugin format, made for people writing it by hand (docs/PLUGIN-TOOLKIT-PLAN.md, item 2; 11 Oct 2026).
//
// - Comments (// to the end of the line, and /* … */) and a trailing comma before } or ] are allowed.
// - Every error and warning names the file and the line, in words: "profile.json, line 12: nameFrom must be one of
//   nextText, previousText, childText, parentText, help, description".
// - A field TurnOver does not know is a warning, with the nearest field it does know ("did you mean name?"): a
//   misspelt field used to be ignored without a word.
// - formatVersion (the format the plugin is written in; 1 today) and minimumTurnOver (the oldest TurnOver it works
//   with) in the manifest. TurnOver reads every older format; a newer one is refused with a reason, never half-read.
import Foundation

nonisolated public enum PluginFormat {
    /// The newest format this TurnOver reads.
    public static let currentVersion = 1

    /// The values a field may take, where it is a choice.
    public static let choices: [String: [String]] = [
        "nameFrom": ["nextText", "previousText", "childText", "parentText", "help", "description", "ancestorHelp", "rowText"],
        "action": ["press", "focus", "read", "menu", "keys", "say"],
        "read": ["value", "text"],
        "kind": ["profile"],
    ]

    /// The fields each part of the format knows (for the unknown-field warning).
    static let manifestFields = ["id", "name", "version", "author", "description", "apps", "kind", "formatVersion", "minimumTurnOver", "$schema",
                                  "summary", "contact", "changes", "abilities", "privacy", "license", "provides"]
    static let profileFields = ["labels", "keys", "watch", "silence", "view", "hold", "$schema"]
    static let holdFields = ["focus", "items"]
    static let labelFields = ["match", "name", "nameFrom", "role"]
    static let keyFields = ["key", "description", "action", "target", "menu", "keys", "say", "letter"]
    static let watchFields = ["match", "prefix", "read"]
    static let matchFields = ["role", "roles", "subrole", "identifier", "title", "description", "help", "value", "text", "window",
                              "inside", "parent", "unnamed", "pressable", "nth", "any"]

    // MARK: Lenient JSON

    /// The text with comments and trailing commas blanked out (replaced by spaces), so every line keeps its number.
    public static func clean(_ text: String) -> String {
        trailingCommas(withoutComments(Array(text)))
    }

    static func withoutComments(_ chars: [Character]) -> [Character] {
        var out = [Character](); out.reserveCapacity(chars.count)
        var i = 0, inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1; continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { out.append(" "); i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                out.append(" "); out.append(" "); i += 2
                while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") { out.append(chars[i] == "\n" ? "\n" : " "); i += 1 }
                if i < chars.count { out.append(" "); out.append(" "); i += 2 }
                continue
            }
            out.append(c); i += 1
        }
        return out
    }

    static func trailingCommas(_ chars: [Character]) -> String {
        var out = chars
        var inString = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
                i += 1; continue
            }
            if c == "\"" { inString = true }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { out[i] = " " }
            }
            i += 1
        }
        return String(out)
    }

    // MARK: Where a value is

    /// The line (from 1) where the value at a path starts: ["labels", 2, "match", "role"]. Nil if not found.
    public static func line(of path: [String], in text: String) -> Int? {
        var finder = Locator(Array(text.utf8))
        return finder.find(path)
    }

    /// Every key in the text with its path and line, for the unknown-field and choice checks.
    static func keys(in text: String) -> [(path: [String], key: String, line: Int, value: Any?)] {
        var finder = Locator(Array(text.utf8))
        finder.collect = true
        _ = finder.find([])
        return finder.found
    }

    // MARK: Decoding

    public struct Problem: CustomStringConvertible, Sendable {
        public var file: String
        public var line: Int?
        public var message: String
        public var isError: Bool
        public var description: String { "\(file)\(line.map { ", line \($0)" } ?? ""): \(message)" }
    }

    /// Decode a file of the format, or throw the first problem in words with its line.
    public static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let file = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw PluginFormatError(problem: Problem(file: file, line: nil, message: "cannot be read (is it there?)", isError: true)) }
        guard let raw = String(data: data, encoding: .utf8) else { throw PluginFormatError(problem: Problem(file: file, line: nil, message: "is not text in UTF-8", isError: true)) }
        let text = clean(raw)
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch let e as DecodingError {
            throw PluginFormatError(problem: problem(e, file: file, text: text))
        }
    }

    static func problem(_ e: DecodingError, file: String, text: String) -> Problem {
        func names(_ c: [CodingKey]) -> [String] { c.map { $0.intValue.map(String.init) ?? $0.stringValue } }
        func spoken(_ c: [CodingKey]) -> String {
            let p = c.map { $0.intValue.map { "item \($0 + 1)" } ?? $0.stringValue }
            return p.isEmpty ? "the top" : p.joined(separator: ", ")
        }
        switch e {
        case .keyNotFound(let k, let c):
            return Problem(file: file, line: line(of: names(c.codingPath), in: text), message: "\(spoken(c.codingPath)) needs \"\(k.stringValue)\"", isError: true)
        case .typeMismatch(let t, let c):
            return Problem(file: file, line: line(of: names(c.codingPath), in: text), message: "\(spoken(c.codingPath)) should be \(typeWords(t))", isError: true)
        case .valueNotFound(let t, let c):
            return Problem(file: file, line: line(of: names(c.codingPath), in: text), message: "\(spoken(c.codingPath)) is empty; it should be \(typeWords(t))", isError: true)
        case .dataCorrupted(let c):
            // JSONSerialization's own words carry the line: "… around line 7, column 3."
            let inner = (c.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String ?? c.debugDescription
            var line: Int? = nil
            if let r = inner.range(of: #"line (\d+)"#, options: .regularExpression) { line = Int(inner[r].dropFirst(5)) }
            let what = inner.contains("Unexpected end") ? "the file ends too early (a missing } or ])"
                : inner.contains("No string key") ? "a field name must be in double quotes"
                : inner.contains("Badly formed") || inner.contains("Invalid value") ? "this is not valid JSON (a missing comma, quote or bracket?)"
                : "this is not valid JSON"
            return Problem(file: file, line: line ?? self.line(of: names(c.codingPath), in: text), message: what, isError: true)
        @unknown default:
            return Problem(file: file, line: nil, message: "\(e)", isError: true)
        }
    }

    static func typeWords(_ t: Any.Type) -> String {
        let s = "\(t)"
        if s.contains("Array") { return "a list in [ ]" }
        if s.contains("String") { return "text in quotes" }
        if s.contains("Int") { return "a whole number" }
        if s.contains("Bool") { return "true or false" }
        if s.contains("Dictionary") || s.contains("Match") || s.contains("Rule") || s.contains("Box") { return "a group in { }" }
        return s
    }

    // MARK: Checks beyond decoding

    /// Warnings and errors a decoder does not give: unknown fields, values outside their choices, the format version.
    public static func check(manifest: URL?, profile: URL?) -> [Problem] {
        var out: [Problem] = []
        if let manifest, let raw = try? String(contentsOf: manifest, encoding: .utf8) {
            let text = clean(raw)
            for k in keys(in: text) {
                let fields = fieldsFor(path: k.path, inManifest: true)
                if let fields, !fields.contains(k.key) {
                    out.append(Problem(file: "manifest.json", line: k.line, message: unknown(k.key, fields), isError: false))
                }
                if k.path.isEmpty, k.key == "formatVersion", let v = k.value as? Int, v > currentVersion {
                    out.append(Problem(file: "manifest.json", line: k.line, message: "written in format \(v); this TurnOver reads up to format \(currentVersion). Update TurnOver.", isError: true))
                }
                if k.path.isEmpty, k.key == "minimumTurnOver", let v = k.value as? String, compare(v, turnOverVersion) == .orderedDescending {
                    out.append(Problem(file: "manifest.json", line: k.line, message: "needs TurnOver \(v) or later; this is \(turnOverVersion). Update TurnOver.", isError: true))
                }
                if k.path.isEmpty, k.key == "kind", let v = k.value as? String, !(choices["kind"] ?? []).contains(v) {
                    out.append(Problem(file: "manifest.json", line: k.line, message: "kind \"\(v)\" is not one TurnOver loads; the only kind is \"profile\" (data, no code)", isError: true))
                }
            }
        }
        if let profile, let raw = try? String(contentsOf: profile, encoding: .utf8) {
            let text = clean(raw)
            for k in keys(in: text) {
                if let fields = fieldsFor(path: k.path, inManifest: false), !fields.contains(k.key) {
                    out.append(Problem(file: "profile.json", line: k.line, message: unknown(k.key, fields), isError: false))
                }
                if let allowed = choices[k.key], k.key != "kind", let v = k.value as? String, !allowed.contains(v), fieldsFor(path: k.path, inManifest: false) != nil {
                    out.append(Problem(file: "profile.json", line: k.line, message: "\(k.key) must be one of \(allowed.joined(separator: ", ")); \"\(v)\" is not", isError: true))
                }
            }
        }
        return out
    }

    /// The fields allowed at a path, or nil where TurnOver does not check (the view section has its own checks).
    static func fieldsFor(path: [String], inManifest: Bool) -> [String]? {
        if inManifest { return path.isEmpty ? manifestFields : nil }
        let named = path.filter { Int($0) == nil }   // list positions dropped
        guard let first = named.first else { return profileFields }
        if first == "view" { return nil }
        // Inside a match, nested matches (inside, parent, any) are matches too.
        let matchWords: Set<String> = ["match", "target", "inside", "parent", "any", "focus", "items"]
        if first == "silence" { return named.count == 1 || matchWords.contains(named.last!) ? matchFields : nil }
        if named.count == 1 {
            switch first { case "labels": return labelFields; case "keys": return keyFields; case "watch": return watchFields; case "hold": return holdFields; default: return nil }
        }
        if matchWords.contains(named.last!) { return matchFields }
        if first == "keys", named.last == "menu" { return nil }
        return nil
    }

    static func unknown(_ key: String, _ fields: [String]) -> String {
        let near = fields.min { distance(key.lowercased(), $0.lowercased()) < distance(key.lowercased(), $1.lowercased()) }
        let hint = near.flatMap { distance(key.lowercased(), $0.lowercased()) <= 3 ? " (did you mean \"\($0)\"?)" : nil } ?? ""
        return "TurnOver does not know the field \"\(key)\"; it is ignored\(hint)"
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[b.count]
    }

    /// This TurnOver's version, from the app (2.0); the tools take it from the installed app.
    public static var turnOverVersion: String {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, Bundle.main.bundleIdentifier?.contains("turnover") == true || Bundle.main.bundleIdentifier?.contains("turnover") == true { return v }
        if let v = Bundle(path: "/Applications/TurnOver.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return v }
        return "2.0"
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }
}

public struct PluginFormatError: Error, CustomStringConvertible {
    public let problem: PluginFormat.Problem
    public var description: String { problem.description }
}

/// A small JSON walker that knows the line of every value (the decoder does not).
nonisolated struct Locator {
    let b: [UInt8]
    var i = 0
    var line = 1
    var collect = false
    var found: [(path: [String], key: String, line: Int, value: Any?)] = []
    init(_ b: [UInt8]) { self.b = b }

    mutating func skip() {
        while i < b.count {
            let c = b[i]
            if c == 0x0A { line += 1; i += 1 } else if c == 0x20 || c == 0x09 || c == 0x0D { i += 1 } else { break }
        }
    }

    /// Walks the whole value at the current place; returns the line where `target` starts, if met.
    mutating func find(_ target: [String]) -> Int? {
        var hit: Int? = nil
        skip()
        value(path: [], target: target, hit: &hit)
        return hit
    }

    mutating func value(path: [String], target: [String], hit: inout Int?) {
        skip()
        guard i < b.count else { return }
        if path == target, hit == nil { hit = line }
        switch b[i] {
        case 0x7B: // {
            i += 1
            while true {
                skip()
                guard i < b.count else { return }
                if b[i] == 0x7D { i += 1; return }
                if b[i] == 0x2C { i += 1; continue }
                guard b[i] == 0x22 else { i += 1; continue }
                let keyLine = line
                let key = string()
                skip()
                if i < b.count, b[i] == 0x3A { i += 1 }
                skip()
                let valueLine = line
                let start = i
                value(path: path + [key], target: target, hit: &hit)
                if collect {
                    var v: Any? = nil
                    let slice = Array(b[start..<i])
                    if let s = String(bytes: slice, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                        if s.hasPrefix("\"") { v = (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed)) as? String }
                        else if let n = Int(s) { v = n }
                    }
                    found.append((path, key, keyLine == valueLine ? keyLine : keyLine, v))
                }
            }
        case 0x5B: // [
            i += 1
            var n = 0
            while true {
                skip()
                guard i < b.count else { return }
                if b[i] == 0x5D { i += 1; return }
                if b[i] == 0x2C { i += 1; continue }
                value(path: path + [String(n)], target: target, hit: &hit)
                n += 1
            }
        case 0x22:
            _ = string()
        default:
            while i < b.count, ![0x2C, 0x7D, 0x5D, 0x0A].contains(b[i]) { i += 1 }
        }
    }

    mutating func string() -> String {
        var out: [UInt8] = []
        i += 1
        while i < b.count, b[i] != 0x22 {
            if b[i] == 0x5C, i + 1 < b.count { out.append(b[i]); out.append(b[i + 1]); i += 2; continue }
            if b[i] == 0x0A { line += 1 }
            out.append(b[i]); i += 1
        }
        i += 1
        return String(bytes: out, encoding: .utf8) ?? ""
    }
}
