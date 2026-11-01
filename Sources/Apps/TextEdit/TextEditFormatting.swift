// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// Observed 1 Nov 2026, macOS 27.2, TextEdit 1.21: the closed Format > Font menu reports typing style even in an
/// empty rich-text editor. Bold/Italic return a check mark when on and AXError.noValue when off. This is deliberately
/// TextEdit-specific: absent attributes and character fonts do not establish typing style in other apps (#212).
/// The observed English menu identities are required. A localized or changed menu remains unknown until probed.
nonisolated package enum TextEditFormatting {
    package static func read(_ context: FormattingFeedback.Context, _ kind: FormattingFeedback.Kind,
                             _ budget: AXWalkBudget) -> FormattingFeedback.State {
        collect(context, kind, budget, setTimeout: { AXUIElementSetMessagingTimeout($0, 0.05) })
    }

    /// The timeout seam lets fixtures exercise the actual collector without asking a nonexistent replay PID.
    package static func collect(_ context: FormattingFeedback.Context, _ kind: FormattingFeedback.Kind,
                                _ budget: AXWalkBudget, setTimeout: @escaping (AXUIElement) -> AXError) -> FormattingFeedback.State {
        guard context.bundleIdentifier == "com.apple.TextEdit", context.foreground != nil, budget.check() else { return .unknown }
        return state(kind, query: FormattingQuery(context: context, budget: budget, setTimeout: setTimeout))
    }

    package static func markState(_ result: AXQueryResult<CFTypeRef>) -> FormattingFeedback.State {
        if result.status == .returned(.noValue) { return .off }
        guard result.status == .returned(.success), let value = result.value,
              CFGetTypeID(value) == CFStringGetTypeID(), CFStringGetLength(value as! CFString) == 1,
              value as! String == "✓" else { return .unknown }
        return .on
    }

    private static func commandItem(_ parent: AXUIElement, _ kind: FormattingFeedback.Kind, query: FormattingQuery) -> AXUIElement? {
        guard let children = query.children(parent) else { return nil }
        let expectedKey = kind == .bold ? "b" : "i"
        let expectedName = kind == .bold ? "Bold" : "Italic"
        var match: AXUIElement?
        for child in children {
            guard query.string(query.attribute(child, kAXRoleAttribute)) == "AXMenuItem" else { return nil }
            let shortcut = query.attribute(child, kAXMenuItemCmdCharAttribute)
            if shortcut?.status == .returned(.noValue) { continue }
            guard let character = query.string(shortcut) else { return nil }
            guard character.lowercased() == expectedKey else { continue }
            guard let raw = query.attribute(child, kAXMenuItemCmdModifiersAttribute)?.value,
                  CFGetTypeID(raw) == CFNumberGetTypeID() else { return nil }
            guard (raw as! NSNumber).doubleValue == 0 else { continue }
            // A remapped or duplicate shortcut is not proof that the intended formatting command ran.
            guard match == nil, query.string(query.attribute(child, kAXTitleAttribute)) == expectedName else { return nil }
            match = child
        }
        return match
    }

    private static func state(_ kind: FormattingFeedback.Kind, query: FormattingQuery) -> FormattingFeedback.State {
        let app = AXUIElementCreateApplication(query.context.pid)
        guard query.focusIsCurrent(app),
              let menuBar = axElement(query.attribute(app, kAXMenuBarAttribute)?.value),
              let format = query.namedChild(menuBar, role: "AXMenuBarItem", title: "Format"),
              let formatMenu = query.submenu(format),
              let font = query.namedChild(formatMenu, role: "AXMenuItem", title: "Font"),
              let fontMenu = query.submenu(font),
              let item = commandItem(fontMenu, kind, query: query),
              let enabled = query.attribute(item, kAXEnabledAttribute)?.value,
              CFGetTypeID(enabled) == CFBooleanGetTypeID(), CFBooleanGetValue(enabled as! CFBoolean),
              let mark = query.attribute(item, kAXMenuItemMarkCharAttribute), query.budget.check() else { return .unknown }
        let state = TextEditFormatting.markState(mark)
        return query.focusIsCurrent(app) && query.budget.check() ? state : .unknown
    }
}
