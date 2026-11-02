// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AppKit

/// Any other Word text area (a comment, a text box): editable text that is not "unavailable".
class WordTextArea: EditableText {
    override var states: Set<State> { super.states.subtracting([.unavailable]) }   // Word reports AXEnabled false on its text areas
}
