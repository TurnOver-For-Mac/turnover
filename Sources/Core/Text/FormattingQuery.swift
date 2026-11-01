// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// Mutable query bookkeeping is confined to one synchronous worker invocation. Exact AX references are retained
/// after configuring their own 50 ms timeout; an equal reference may have a different timeout and is prepared again.
nonisolated package final class FormattingQuery {
    package let context: FormattingFeedback.Context
    package let budget: AXWalkBudget
    private let setTimeout: (AXUIElement) -> AXError
    private var prepared: [ObjectIdentifier: AXUIElement] = [:]

    package init(context: FormattingFeedback.Context, budget: AXWalkBudget,
                 setTimeout: @escaping (AXUIElement) -> AXError = { AXUIElementSetMessagingTimeout($0, 0.05) }) {
        self.context = context; self.budget = budget; self.setTimeout = setTimeout
    }

    package func prepare(_ element: AXUIElement) -> Bool {
        guard budget.check() else { return false }
        if prepared[ObjectIdentifier(element)] != nil { return true }
        guard let error = budget.query({ setTimeout(element) }), error == .success, budget.visit() else { return false }
        prepared[ObjectIdentifier(element)] = element
        return true
    }

    package func attribute(_ element: AXUIElement, _ name: String) -> AXQueryResult<CFTypeRef>? {
        guard prepare(element), let result = budget.query({ element.attributeResult(name) }) else { return nil }
        budget.record(result.status)
        return budget.check() ? result : nil
    }

    package func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> AXQueryResult<CFTypeRef>? {
        guard prepare(element), let result = budget.query({ element.parameterizedResult(name, parameter) }) else { return nil }
        budget.record(result.status)
        return budget.check() ? result : nil
    }

    package func string(_ result: AXQueryResult<CFTypeRef>?) -> String? {
        guard let raw = result?.value, CFGetTypeID(raw) == CFStringGetTypeID(),
              CFStringGetLength(raw as! CFString) <= 128 else { return nil }
        return raw as! String
    }

    package func children(_ parent: AXUIElement) -> [AXUIElement]? {
        guard prepare(parent), let countResult = budget.query({ parent.attributeValueCountResult(kAXChildrenAttribute) }) else { return nil }
        budget.record(countResult.status)
        guard let count = countResult.value, count >= 0, count <= 80, budget.check() else { return nil }
        var children: [AXUIElement] = []
        while children.count < count {
            // The diagnostic decoder intentionally examines at most eight elements. Page the provider too, so
            // menus longer than eight items are fully validated without copying an unbounded AXChildren array.
            let offset = children.count, length = min(8, count - children.count)
            guard let result = budget.query({ parent.attributeValuesResult(kAXChildrenAttribute, index: offset, maxValues: length) }) else { return nil }
            budget.record(result.status)
            guard let array = result.value, budget.check() else { return nil }
            let decoded = AXDiagnosticReport.elements(in: array, maximum: length)
            guard decoded.returnedCount == length, decoded.values.count == length, decoded.malformedCount == 0 else { return nil }
            children.append(contentsOf: decoded.values)
        }
        return children
    }

    package func namedChild(_ parent: AXUIElement, role: String, title: String) -> AXUIElement? {
        guard let children = children(parent) else { return nil }
        var match: AXUIElement?
        for child in children {
            guard let childRole = string(attribute(child, kAXRoleAttribute)) else { return nil }
            guard childRole == role else { continue }
            let label = attribute(child, kAXTitleAttribute)
            // Native menu separators have no title. Unsupported/malformed values cannot conceal a second match.
            if label?.status == .returned(.noValue) { continue }
            guard let name = string(label) else { return nil }
            guard name == title else { continue }
            guard match == nil else { return nil }
            match = child
        }
        return match
    }

    package func submenu(_ parent: AXUIElement) -> AXUIElement? {
        guard let children = children(parent), children.count == 1,
              string(attribute(children[0], kAXRoleAttribute)) == "AXMenu" else { return nil }
        return children[0]
    }

    package func focusIsCurrent(_ app: AXUIElement) -> Bool {
        guard let focus = axElement(attribute(app, kAXFocusedUIElementAttribute)?.value), CFEqual(focus, context.focus),
              let foreground = context.foreground,
              let window = axElement(attribute(app, kAXFocusedWindowAttribute)?.value), CFEqual(window, foreground),
              let focusWindow = axElement(attribute(context.focus, kAXWindowAttribute)?.value), CFEqual(focusWindow, window),
              string(attribute(context.focus, kAXRoleAttribute)) == "AXTextArea", budget.check() else { return false }
        return true
    }

}
