// SPDX-License-Identifier: GPL-3.0-or-later
// Which command a key reaches, and who else would have answered it (the team review, 8 Oct 2026; turnover-coretest
// --explain and turnover-plugin explain, docs/PLUGIN-TOOLKIT-PLAN.md item 3). Plugins first, then the app module, the
// document, the focus and its ancestors, then TurnOver's global commands.
import Foundation
import AppKit
import ApplicationServices

public enum KeyExplainer {
    /// The lines of the explanation for the focus in the application `pid` (or the front one).
    public static func explain(_ g: KeyboardGesture, pid: pid_t?) -> [String] {
        var out: [String] = []
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) } ?? NSWorkspace.shared.frontmostApplication
        guard let app else { return ["no application"] }
        let pid = app.processIdentifier
        let ax = AXUIElementCreateApplication(pid)
        let module = AppModuleHandler.shared.appModule(for: pid)
        if let f = ax.element(kAXFocusedUIElementAttribute) {
            let obj = ObjectFactory.make(f)
            let ancestors = obj.ancestors
            API.setFocusObject(obj, ancestors: ancestors, interceptor: BrowseModeHandler.shared.document(for: obj, ancestors: ancestors))
            out.append("focus: \(obj.axRole) \"\(obj.name.prefix(40))\" (\(type(of: obj))) in \(app.localizedName ?? "") (\(type(of: module))), style \(config.general.keyboardStyle)")
        } else { out.append("no focus in \(app.localizedName ?? ""); global plugins and commands only") }
        out.append("\(g.displayName) (\(g.identifier)), in the order asked:")
        var winner: Script?
        func row(_ who: String, _ s: Script?, propagates: Bool = true) {
            let answer = s.map { "\($0.name)" + (propagates ? "" : " (cannot propagate: skipped)") } ?? "—"
            let runs = s != nil && propagates && winner == nil
            if runs { winner = s }
            out.append("  \(who.padding(toLength: 34, withPad: " ", startingAt: 0)) \(answer)\(runs ? "  ← runs" : "")")
        }
        for p in GlobalPluginHandler.shared.plugins { row("plugin \(type(of: p))", p.script(for: g)) }
        row("app module \(type(of: module))", module.script(for: g))
        if let d = API.focusTreeInterceptor { row("document (\(d.passThrough ? "focus mode" : "browse mode"))", d.script(for: g)) }
        if let f = API.focusObject {
            row("focus \(f.axRole)", f.script(for: g))
            for a in API.focusAncestors { let s = a.script(for: g); row("ancestor \(a.axRole)", s, propagates: s?.canPropagate ?? true) }
        }
        row("global commands", GlobalCommands.shared.script(for: g))
        out.append(winner.map { "runs: \($0.name): \($0.description)" } ?? "passes to the application")
        return out
    }
}
