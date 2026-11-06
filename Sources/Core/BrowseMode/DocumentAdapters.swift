// SPDX-License-Identifier: GPL-3.0-or-later
import ApplicationServices

/// The existing website feedback hooks. This boundary changes their owner, not their scheduling or key policy.
package protocol DocumentAdapter: AnyObject {
    func usesNativeTextFeedback(for element: AXUIElement) -> Bool
    func focusMoved(to element: AXUIElement)
    func checkSoon(_ document: BrowseModeDocument)
}

package final class DocumentAdapters {
    package static var shared = DocumentAdapters()
    private var adapters: [any DocumentAdapter] = []
    package init() {}

    package func register(_ adapter: any DocumentAdapter) { adapters.append(adapter) }

    package func usesNativeTextFeedback(for element: AXUIElement) -> Bool {
        adapters.contains { $0.usesNativeTextFeedback(for: element) }
    }

    package func observe(_ event: Event) {
        // Google Docs: a focus move starts or stops the reading of Google's announcements; a caret move in the editor
        // starts it too (after a restart the focus is already there, and no focus event comes, 12 Oct 2026).
        if event.kind == .gainFocus || (event.kind == .caret && usesNativeTextFeedback(for: event.obj.element)) {
            for adapter in adapters { adapter.focusMoved(to: event.obj.element) }
        }
    }

    package func checkSoon(_ document: BrowseModeDocument) {
        for adapter in adapters { adapter.checkSoon(document) }
    }
}
