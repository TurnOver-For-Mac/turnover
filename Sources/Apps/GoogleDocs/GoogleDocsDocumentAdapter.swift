// SPDX-License-Identifier: GPL-3.0-or-later
import ApplicationServices

/// Delegate to the existing implementation unchanged. Background collection and additional editing-key
/// pass-through are separate changes, so this first boundary can be compared directly with current behavior.
package final class GoogleDocsDocumentAdapter: DocumentAdapter {
    package init() {}
    package func usesNativeTextFeedback(for element: AXUIElement) -> Bool { GoogleDocs.isEditor(element) }
    package func focusMoved(to element: AXUIElement) { GoogleDocs.focusMoved(to: element) }
    package func checkSoon(_ document: BrowseModeDocument) { GoogleDocs.checkSoon(document) }
}
