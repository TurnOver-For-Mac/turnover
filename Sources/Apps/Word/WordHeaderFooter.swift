// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AppKit

/// A header or footer area: ordinary editable text named by its description.
final class WordHeaderFooter: WordTextArea {
    override var name: String { (element.string(kAXDescriptionAttribute) ?? "").replacingOccurrences(of: " -Section 1-", with: "") }
}
