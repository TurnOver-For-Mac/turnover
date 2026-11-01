// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// Ulysses 42 (84473), macOS 27.2, 1 Nov 2026: Strong/Emphasis have no AX check state. At a collapsed
/// caret the shortcut inserts an opening Markdown XL tag; its characters have a plain font even though
/// subsequent typing is styled. Read the verified built-in markup, never infer typing state from that font.
/// Custom markup, changed/localized menus and unsupported syntax remain unknown (issue 212).
nonisolated package enum UlyssesFormatting {
    package static func read(_ context: FormattingFeedback.Context, _ kind: FormattingFeedback.Kind,
                             _ budget: AXWalkBudget) -> FormattingFeedback.State {
        collect(context, kind, budget, setTimeout: { AXUIElementSetMessagingTimeout($0, 0.05) })
    }

    package static func collect(_ context: FormattingFeedback.Context, _ kind: FormattingFeedback.Kind,
                                _ budget: AXWalkBudget, setTimeout: @escaping (AXUIElement) -> AXError) -> FormattingFeedback.State {
        guard context.bundleIdentifier == "com.ulyssesapp.mac", context.foreground != nil else { return .unknown }
        let query = FormattingQuery(context: context, budget: budget, setTimeout: setTimeout)
        let app = AXUIElementCreateApplication(context.pid)
        guard query.focusIsCurrent(app),
              let bar = axElement(query.attribute(app, kAXMenuBarAttribute)?.value),
              isMarkdownXL(bar, query: query), shortcutMatches(bar, kind: kind, query: query),
              let count = number(query.attribute(context.focus, kAXNumberOfCharactersAttribute)?.value),
              count >= 0, count <= 1_000_000_000,
              let range = cfRange(query.attribute(context.focus, kAXSelectedTextRangeAttribute)?.value),
              range.location >= 0, range.location <= count, range.length >= 0,
              range.length <= count - range.location, range.length <= 4096 else { return .unknown }
        let start = max(0, range.location - 4096)
        let length = min(8192, count - start)
        guard range.location + range.length <= start + length else { return .unknown }
        let text: String
        if length == 0 { text = "" }
        else {
            guard let raw = query.parameterized(context.focus, kAXStringForRangeParameterizedAttribute,
                                                axRangeValue(start, length))?.value,
                  CFGetTypeID(raw) == CFStringGetTypeID(), CFStringGetLength(raw as! CFString) == length else { return .unknown }
            text = raw as! String
        }
        guard let slice = paragraph(in: text, chunkStart: start, storyLength: count,
                                    selection: NSRange(location: range.location, length: range.length)) else { return .unknown }
        let state = UlyssesFormattingSyntax.state(in: slice.text, selection: slice.selection, kind: kind, isCompleteParagraph: true)
        // Reading the menu and text crosses provider calls; refuse a result if selection, count or real focus changed.
        guard query.focusIsCurrent(app),
              number(query.attribute(context.focus, kAXNumberOfCharactersAttribute)?.value) == count,
              let after = cfRange(query.attribute(context.focus, kAXSelectedTextRangeAttribute)?.value),
              after.location == range.location, after.length == range.length, budget.check() else { return .unknown }
        return state
    }

    private static func number(_ raw: CFTypeRef?) -> Int? {
        guard let raw, CFGetTypeID(raw) == CFNumberGetTypeID(), let number = raw as? NSNumber,
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 1_000_000_000,
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }

    private static func isMarkdownXL(_ bar: AXUIElement, query: FormattingQuery) -> Bool {
        guard let edit = query.namedChild(bar, role: "AXMenuBarItem", title: "Edit"), let editMenu = query.submenu(edit),
              let convert = query.namedChild(editMenu, role: "AXMenuItem", title: "Convert Markup"),
              let menu = query.submenu(convert),
              let builtin = query.namedChild(menu, role: "AXMenuItem", title: "Markdown XL"),
              let mark = query.attribute(builtin, kAXMenuItemMarkCharAttribute),
              mark.status == .returned(.success), query.string(mark) == "✓",
              let items = query.children(menu) else { return false }
        for item in items where !CFEqual(item, builtin) {
            guard let result = query.attribute(item, kAXMenuItemMarkCharAttribute),
                  result.status == .returned(.noValue) else { return false }
        }
        return query.budget.check()
    }

    private static func shortcutMatches(_ bar: AXUIElement, kind: FormattingFeedback.Kind, query: FormattingQuery) -> Bool {
        guard let markup = query.namedChild(bar, role: "AXMenuBarItem", title: "Markup"), let menu = query.submenu(markup),
              let item = query.namedChild(menu, role: "AXMenuItem", title: kind == .bold ? "Strong" : "Emphasis"),
              query.string(query.attribute(item, kAXMenuItemCmdCharAttribute))?.lowercased() == (kind == .bold ? "b" : "i"),
              number(query.attribute(item, kAXMenuItemCmdModifiersAttribute)?.value) == 0,
              let enabled = query.attribute(item, kAXEnabledAttribute)?.value,
              CFGetTypeID(enabled) == CFBooleanGetTypeID(), CFBooleanGetValue(enabled as! CFBoolean) else { return false }
        return true
    }

    /// Only a complete bounded paragraph is parsed. Starting halfway through a long paragraph could turn a closing
    /// tag into an opening one; ending early could hide unsupported syntax. Never read the whole sheet as a fallback.
    package static func paragraph(in chunk: String, chunkStart: Int, storyLength: Int,
                                  selection: NSRange) -> (text: String, selection: NSRange)? {
        let ns = chunk as NSString
        guard chunkStart >= 0, storyLength >= chunkStart, ns.length <= 8192,
              ns.length <= storyLength - chunkStart, selection.location >= chunkStart,
              selection.length >= 0, selection.location - chunkStart <= ns.length,
              selection.length <= ns.length - (selection.location - chunkStart) else { return nil }
        let location = selection.location - chunkStart, end = location + selection.length
        let before = ns.rangeOfCharacter(from: .newlines, options: .backwards, range: NSRange(location: 0, length: location))
        let start = before.location == NSNotFound ? 0 : before.location + before.length
        guard before.location != NSNotFound || chunkStart == 0 else { return nil }
        let after = ns.rangeOfCharacter(from: .newlines, range: NSRange(location: end, length: ns.length - end))
        let finish = after.location == NSNotFound ? ns.length : after.location
        guard after.location != NSNotFound || chunkStart + ns.length == storyLength,
              ns.rangeOfCharacter(from: .newlines, range: NSRange(location: start, length: finish - start)).location == NSNotFound else { return nil }
        return (ns.substring(with: NSRange(location: start, length: finish - start)),
                NSRange(location: location - start, length: selection.length))
    }
}
