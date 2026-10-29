// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// TV/macOS 27.2 exposed a pressable sidebar cell without changing the selected row (#186, 29 Oct 2026).
/// The module chooses this strategy; other media apps retain their existing cell-press behaviour.
nonisolated package enum MediaSidebarSelection {
    package enum Outcome: Sendable, Equatable { case selected, alreadyOpen, failed }
    /// Worker-only, finite protocol: three exact-handle timeout setups, four target-freshness reads, one settable
    /// query, one write and one selected-row count/slice. Each array slice requests exactly one element.
    /// The current callback remains pure. Fresh-window queries are explicit boundaries, never AX scope admission.
    package static func select(row: AXUIElement, outline: AXUIElement, cell: AXUIElement, expectedLabel: String,
                               allowAlreadyOpen: Bool, current: @escaping @Sendable () -> Bool,
                               windowCurrent: @escaping @Sendable () -> Bool) -> Outcome {
        let end = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(500_000_000)
        guard !end.overflow else { return .failed }
        let alive: @Sendable () -> Bool = { current() && DispatchTime.now().uptimeNanoseconds < end.partialValue }
        return AXReadScope.with(while: alive) {
            guard alive(), windowCurrent(), alive() else { return .failed }
            for element in [outline, row, cell] {
                guard alive(), AXUIElementSetMessagingTimeout(element, 0.05) == .success else { return .failed }
            }
            let parent = row.attributeResult(kAXParentAttribute)
            guard let parent = axElement(parent.value), CFEqual(parent, outline), alive() else { return .failed }
            let childCount = row.attributeValueCountResult(kAXChildrenAttribute)
            guard childCount.value == 1, alive() else { return .failed }
            let children = row.attributeValuesResult(kAXChildrenAttribute, index: 0, maxValues: 1)
            guard let array = children.value, alive() else { return .failed }
            let child = AXDiagnosticReport.elements(in: array, maximum: 1)
            guard child.returnedCount == 1, child.malformedCount == 0, child.values.count == 1,
                  CFEqual(child.values[0], cell), alive() else { return .failed }
            let description = cell.attributeResult(kAXDescriptionAttribute)
            guard let raw = description.value, CFGetTypeID(raw) == CFStringGetTypeID(),
                  CFStringGetLength(raw as! CFString) <= 512, !expectedLabel.isEmpty,
                  raw as! String == expectedLabel, alive() else { return .failed }
            if allowAlreadyOpen {
                return membership(row: row, outline: outline, current: alive, windowCurrent: windowCurrent) ? .alreadyOpen : .failed
            }
            var settable: DarwinBoolean = false
            let capability = AXHealth.query(pid: outline.pid) {
                AXUIElementIsAttributeSettable(outline, kAXSelectedRowsAttribute as CFString, &settable)
            }
            guard capability.status == .returned(.success), settable.boolValue,
                  alive(), windowCurrent(), alive() else { return .failed }
            let selection = AXHealth.query(pid: outline.pid) {
                AXUIElementSetAttributeValue(outline, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
            }
            guard selection.status == .returned(.success), alive() else { return .failed }
            return membership(row: row, outline: outline, current: alive, windowCurrent: windowCurrent) ? .selected : .failed
        }
    }

    /// The caller has prepared this exact outline handle. This check reads at most one selected element,
    /// refusing missing, multi-selection or malformed replies rather than claiming a partial match.
    package static func membership(row: AXUIElement, outline: AXUIElement,
                                   current: @escaping @Sendable () -> Bool,
                                   windowCurrent: @escaping @Sendable () -> Bool) -> Bool {
        guard current() else { return false }
        let count = outline.attributeValueCountResult(kAXSelectedRowsAttribute)
        guard count.value == 1, current() else { return false }
        let values = outline.attributeValuesResult(kAXSelectedRowsAttribute, index: 0, maxValues: 1)
        guard let raw = values.value, current() else { return false }
        let sample = AXDiagnosticReport.elements(in: raw, maximum: 1)
        return sample.returnedCount == 1 && sample.malformedCount == 0 && sample.values.count == 1
            && CFEqual(sample.values[0], row) && windowCurrent() && current()
    }
}
