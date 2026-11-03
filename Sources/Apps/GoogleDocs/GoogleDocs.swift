// SPDX-License-Identifier: GPL-3.0-or-later
// Google Docs, Sheets and Slides expose their drawn documents through their own screen reader support.
// Their hidden typing target does not move its AX caret; Google's announcement region supplies feedback
// (observed in Safari, 12 Oct 2026). This integration is selected by a document URL, not a browser bundle.
import Foundation

package enum GoogleDocs {
    nonisolated package static func isGoogleEditor(_ url: String) -> Bool {
        guard let u = URL(string: url), u.host == "docs.google.com" else { return false }
        return ["/document/", "/spreadsheets/", "/presentation/"].contains { u.path.contains($0) }
    }
}
