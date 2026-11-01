// SPDX-License-Identifier: GPL-3.0-or-later
// Computer braille: one cell per character, so a routing key lands on the character under it. North American
// Computer Braille (the 8-dot US computer code, a published standard): the 64 cells of Braille ASCII for
// space to underscore; capital letters and @ [ \ ] ^ _ add dot 7; lower-case letters and ` { | } ~ are the plain
// cells. Cells are ISO 11548-1 bytes: dot n is bit n-1. Contracted braille and other languages come later
// through liblouis (docs/BRAILLE-PLAN.md).
import Foundation

public enum BrailleTable {
    /// Dots for 0x20 to 0x5F, in order (Braille ASCII).
    private static let ascii: [String] = [
        "", "2346", "5", "3456", "1246", "146", "12346", "3", "12356", "23456", "16", "346", "6", "36", "46", "34",
        "356", "2", "23", "25", "256", "26", "235", "2356", "236", "35", "156", "56", "126", "123456", "345", "1456",
        "4", "1", "12", "14", "145", "15", "124", "1245", "125", "24", "245", "13", "123", "134", "1345", "135",
        "1234", "12345", "1235", "234", "2345", "136", "1236", "2456", "1346", "13456", "1356", "246", "1256", "12456", "45", "456",
    ]
    private static let cells: [UInt8] = ascii.map { s in s.reduce(0) { $0 | (1 << (($1.wholeNumberValue ?? 1) - 1)) } }

    /// Dots 7 and 8: the caret.
    public static let cursor: UInt8 = 0xC0
    static let dot7: UInt8 = 0x40, dot8: UInt8 = 0x80

    /// One cell for one UTF-16 unit, matching TextInfo offsets.
    public static func cells(for text: String) -> [UInt8] {
        (text as NSString).utf16Units.map(cell(for:))
    }

    static func cell(for u: UInt16) -> UInt8 {
        switch u {
        case 0x20...0x3F: return cells[Int(u) - 0x20]
        case 0x40...0x5F: return cells[Int(u) - 0x20] | dot7
        case 0x60...0x7E: return cells[Int(u) - 0x40]
        case 0x09, 0x0A, 0x0D, 0xA0, 0x2028, 0x2029: return 0
        default:
            // A letter with an accent: its plain letter, with dot 8 to show there is more to it.
            if let s = UnicodeScalar(u), let base = String(Character(s)).applyingTransform(.stripDiacritics, reverse: false)?.utf16.first,
               base < 0x7F, base != u {
                return cell(for: base) | dot8
            }
            // Typographic quotes and dashes as their plain forms.
            switch u {
            case 0x2018, 0x2019: return cell(for: 0x27)
            case 0x201C, 0x201D: return cell(for: 0x22)
            case 0x2013, 0x2014: return cell(for: 0x2D)
            case 0x2026: return cell(for: 0x2E)
            default: return cell(for: 0x3F) | dot8   // unknown: a question mark with dot 8
            }
        }
    }
}

private extension NSString {
    var utf16Units: [UInt16] { (0..<length).map { character(at: $0) } }
}
