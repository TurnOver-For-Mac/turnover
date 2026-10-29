// SPDX-License-Identifier: GPL-3.0-or-later
// Safari requires a native principal class even though this extension only repairs page semantics locally.
// No page data, app-group access or reader commands cross this boundary (29 Oct 2026).
import Foundation
import SafariServices

@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        // Requests stay on Safari's calling thread: there is no shared state or asynchronous transfer of the
        // non-Sendable extension context. Unknown operations and additional message fields fail closed.
        let message = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let isStatus = context.inputItems.count == 1 && message?.count == 1 && message?["op"] as? String == "status"
        let reply: [String: Any] = isStatus
            ? ["ok": true, "mode": "passive", "capture": false, "transmission": false, "commands": false]
            : ["ok": false, "error": "unsupportedRequest"]
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response])
    }
}
