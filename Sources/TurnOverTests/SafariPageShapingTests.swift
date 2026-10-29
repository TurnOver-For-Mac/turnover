// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import JavaScriptCore

/// Run the exact content script against the synthetic DOM in Apple's JavaScript engine. Safari and Node do not
/// need to be open or installed; no website, native messaging permission or private page content is involved.
func safariPageShapingTests() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func failed(_ message: String) {
        test("Safari passive: regression harness executes") { check(false, message) }
    }
    do {
        let source = try String(contentsOf: root.appendingPathComponent("Extension/content.js"), encoding: .utf8)
        let harness = try String(contentsOf: root.appendingPathComponent("Extension/tests/passive-tests.js"), encoding: .utf8)
        guard let context = JSContext() else { failed("JavaScriptCore context unavailable"); return }
        context.evaluateScript(harness)
        guard context.exception == nil else { failed(context.exception.toString() ?? "harness evaluation failed"); return }
        guard let runner = context.objectForKeyedSubscript("runPassiveExtensionTests"), !runner.isUndefined else {
            failed("plain JavaScript regression entry point missing"); return
        }
        let result = runner.call(withArguments: [source])
        guard context.exception == nil else { failed(context.exception.toString() ?? "content-script regression failed"); return }
        guard let records = result?.toArray() as? [[String: Any]], !records.isEmpty,
              records.allSatisfy({ $0["name"] is String && $0["passed"] is Bool && $0["error"] is String }) else {
            failed("malformed or empty regression result"); return
        }
        for record in records {
            let name = record["name"] as! String
            test("Safari passive: " + name) { check(record["passed"] as! Bool, record["error"] as! String) }
        }
    } catch {
        failed("could not read the versioned passive extension fixture: \(error)")
    }
}
