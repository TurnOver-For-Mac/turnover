// SPDX-License-Identifier: GPL-3.0-or-later
// FaceTime (18 Oct 2026, the Apple apps sweep). FaceTime is the iPad app: its window holds the recent calls (each a
// button: the person, Audio or Video, when), the New FaceTime and Create Link buttons, and the effects buttons
// (probe, names masked). Tab reached the first recent call; the arrows said nothing (driver). TurnOver reads the
// window's content as a document, as it does Books and Maps: Down through the recent calls, Tab to the buttons.
// Return on a recent call calls that person, as it does with VoiceOver.
import Foundation
import ApplicationServices

final class FaceTimeAppModule: AppModule {
    static let bundleID = "com.apple.FaceTime"
    static let contentSubrole = "iOSContentGroup"

    override func browseRoot(for element: AXUIElement, ancestors: [TurnOverObject]) -> AXUIElement? {
        // Not in a text field (the New FaceTime "To" field): that stays a field.
        if ["AXTextField", "AXTextArea", "AXComboBox"].contains(element.role) { return nil }
        if element.string(kAXSubroleAttribute) == Self.contentSubrole { return element }
        return ancestors.first { $0.element.string(kAXSubroleAttribute) == Self.contentSubrole }?.element
    }
}
