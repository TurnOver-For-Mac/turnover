// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps secrets out of the diagnostic log (19 Nov 2026): API keys read aloud from a web page were found in plain text
// in logs, and logs are attached to public issues. One general rule for every app, applied where lines are written
// (`Log.line`): key-like text keeps its first 8 characters and then says how many were removed.
import Foundation

nonisolated public enum LogRedactor {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }
    private static let notKey = "(?<![A-Za-z0-9_-])"
    /// Known prefixes, then at least 16 key characters; AWS and Google keys have their own fixed shapes.
    private static let prefixed = regex(notKey + "(?:github_pat_|gh[pousr]_|xox[baprs]-|sk-)[A-Za-z0-9_-]{16,}"
        + "|(?<![A-Za-z0-9])AKIA[A-Z0-9]{16}|" + notKey + "AIza[A-Za-z0-9_-]{35,}")
    private static let privateKey = regex("-----BEGIN [A-Z ]*PRIVATE KEY-----.*")
    private static let jwt = regex(notKey + "eyJ[A-Za-z0-9_-]*\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+")
    private static let longRun = regex("[A-Za-z0-9+/_=-]{32,}")

    /// Lines with nothing key-like come back unchanged (the same string), after a cheap scan.
    public static func mask(_ line: String) -> String {
        guard mightHoldSecret(line) else { return line }
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var hits: [NSRange] = []
        for re in [prefixed, privateKey, jwt] {
            for m in re.matches(in: line, range: whole) { hits.append(m.range) }
        }
        for m in longRun.matches(in: line, range: whole) where looksLikeSecret(ns.substring(with: m.range)) {
            hits.append(m.range)
        }
        guard !hits.isEmpty else { return line }
        hits.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for r in hits {
            if let last = merged.last, r.location <= last.location + last.length {
                merged[merged.count - 1] = NSRange(location: last.location, length: max(last.length, r.location + r.length - last.location))
            } else { merged.append(r) }
        }
        var out = ""
        var at = 0
        for r in merged {
            out += ns.substring(with: NSRange(location: at, length: r.location - at))
            let token = ns.substring(with: r)
            out += String(token.prefix(8)) + "…[masked \(max(0, token.count - 8))]"
            at = r.location + r.length
        }
        out += ns.substring(from: at)
        return out
    }

    /// Every rule needs a run of 16 or more characters with no space, or the private-key marker (checked last, only when the line has a hyphen).
    private static func mightHoldSecret(_ line: String) -> Bool {
        var run = 0
        for b in line.utf8 {
            if b > 32 { run += 1; if run >= 16 { return true } } else { run = 0 }
        }
        return line.utf8.contains(45) && line.contains("PRIVATE KEY-----")
    }

    /// A long unbroken run is a secret when it mixes lower case, upper case and digits and is not a file path
    /// (starts with a slash, or has several slashes between mostly plain words).
    private static func looksLikeSecret(_ run: String) -> Bool {
        var lower = false, upper = false, digit = false
        for b in run.utf8 {
            switch b {
            case 97...122: lower = true
            case 65...90: upper = true
            case 48...57: digit = true
            default: break
            }
        }
        guard lower && upper && digit else { return false }
        if run.hasPrefix("/") { return false }
        let parts = run.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 3 {
            let words = parts.filter { $0.utf8.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 } }.count
            if words * 2 >= parts.count { return false }
        }
        return true
    }
}
