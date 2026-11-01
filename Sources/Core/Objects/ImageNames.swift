// SPDX-License-Identifier: GPL-3.0-or-later
// A picture's name from its file, for pictures a page left without a description (a tester, AppleVis, 9 Oct 2026).
// "IMG_2041.jpg" and "a3f9c2e1.png" say nothing, so names that are only a camera number or a hash are dropped.
import Foundation
import ApplicationServices

nonisolated public enum ImageNames {
    /// The element's file name made readable, or "" when there is none worth saying.
    public static func fromFile(_ el: AXUIElement) -> String {
        guard let u = el.attr(kAXURLAttribute) else { return "" }
        let url = (u as? URL) ?? (u as? NSURL).map { $0 as URL } ?? (u as? String).flatMap(URL.init(string:))
        guard let url else { return "" }
        return readable(url.deletingPathExtension().lastPathComponent)
    }

    /// "sunset-beach_2x" → "sunset beach". Pure, for the tests.
    public static func readable(_ raw: String) -> String {
        var s = raw.removingPercentEncoding ?? raw
        s = s.replacingOccurrences(of: "[-_+.]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\b(@?\\d+x|\\d{2,4}x\\d{2,4}|thumb|thumbnail|small|large|medium|min|copy)\\b", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let letters = s.filter(\.isLetter).count
        // A camera number (IMG 2041, DSC 0042), a hash or an id: nothing to say.
        if letters < 3 { return "" }
        if s.range(of: "^(img|dsc|dscn|pxl|screenshot|image|photo|pic)\\s*\\d+$", options: [.regularExpression, .caseInsensitive]) != nil { return "" }
        let words = s.split(separator: " ")
        if words.count == 1, s.count >= 12, s.range(of: "^[0-9a-f]+$", options: [.regularExpression, .caseInsensitive]) != nil { return "" }
        if Double(s.filter(\.isNumber).count) > Double(s.count) * 0.4 { return "" }
        return s
    }
}
