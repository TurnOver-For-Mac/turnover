// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// Settings' General buttons supplied only AXAttributedDescription on macOS 27.2, Settings 1.0 build
/// 2027.1.9.102 (29 Oct 2026, issue 183). It is an optional, undocumented provider attribute queried through the
/// public AX API. Standard title/description/help were absent; their existing naming takes precedence whenever
/// supplied. No private symbol/framework is loaded. Missing, changed, malformed or oversized values fall back
/// to the existing object name, so the observation is confined to this app and can be retested after an update.
package final class SystemSettingsLabelledButton: TurnOverObject {
    package override var name: String {
        let plain = element.attrs([kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute])
        if plain.values.contains(where: { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) { return super.name }
        guard let raw = element.attr("AXAttributedDescription"), let label = Self.label(raw) else { return super.name }
        return label
    }

    package static func label(_ value: CFTypeRef) -> String? {
        let text: String
        if CFGetTypeID(value) == CFStringGetTypeID() {
            guard CFStringGetLength(value as! CFString) <= 512 else { return nil }
            text = value as! String
        } else if CFGetTypeID(value) == CFAttributedStringGetTypeID() {
            guard CFAttributedStringGetLength(value as! CFAttributedString) <= 512 else { return nil }
            text = (value as! NSAttributedString).string
        } else { return nil }
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !Self.isClassName(label) else { return nil }
        return Self.oneLine(label)
    }
}
