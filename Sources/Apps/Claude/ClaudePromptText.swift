// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// Claude's Prompt, where Up and Down at its edge recall earlier messages (Claude's own history).
/// 15 Nov 2026, 16:20 UTC: with the Prompt empty, Up at its edge played the edge sound and said nothing, and Claude
/// filled the field 44 ms later; Down at the end then read the recalled line at once while Claude emptied the field
/// 32 ms later, so the text was heard only as it was being taken away. Here an edge arrow's line waits for the
/// field's value: if it changes within a short time, the line the caret is now on is read ("blank" for an empty
/// field), never the text the same key removed; if nothing changes, the edge reads as everywhere else (16 Nov 2026).
package final class ClaudePromptText: EditableText {
    /// How long after an edge arrow a value change counts as that arrow's history recall. Observed: 28 to 44 ms
    /// (15 Nov 2026). An unchanged edge is read this much later than before; the edge sound is not delayed.
    package static let historyValueChangeWindow: TimeInterval = 0.15

    private struct PendingEdge {
        let id: UUID
        let gesture: KeyboardGesture
        let value: String
        let sentAt: Date
        let keyDownAt: Date
        let keysArrived: Int
    }
    private var pendingEdge: PendingEdge?
    package var historyNow: () -> Date = Date.init
    package var historySchedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
    }

    package override func sendUnwaitedCaretKeyAtEdge(_ gesture: KeyboardGesture, unit: TextUnit, info: TextInfo) {
        pendingEdge = nil
        let isHistoryArrow = gesture.keyName == "upArrow" || gesture.keyName == "downArrow"
        let isPlainKey = gesture.modifiers.isEmpty
        let isThisFieldFocused = API.focusObject?.isSameElement(as: self) == true
        let isBrowsing = API.focusTreeInterceptor?.passThrough == false
        guard unit == .line,
              isHistoryArrow,
              isPlainKey,
              isThisFieldFocused,
              !isBrowsing,
              !SayAll.willResume(gesture),
              let value = element.string(kAXValueAttribute) else {
            super.sendUnwaitedCaretKeyAtEdge(gesture, unit: unit, info: info)
            return
        }
        let pending = PendingEdge(id: UUID(), gesture: gesture, value: value, sentAt: historyNow(),
                                  keyDownAt: InputManager.lastKeyDownAt, keysArrived: ScriptHandler.keysArrivedCount)
        pendingEdge = pending
        gesture.send()
        Tones.edge(keySent: true, sound: appModule.playsNativeCaretBoundarySound)
        // The caret is noted now, as at every edge; its line is read once the field has answered.
        caretMoved(speak: nil, gesture: gesture, info: info)
        historySchedule(Self.historyValueChangeWindow) { [weak self] in
            self?.finishEdgeAfterWindow(id: pending.id)
        }
    }

    /// The pending edge is still this field's: no other key since, the focus still here, not in browse mode.
    private func stillOwns(_ pending: PendingEdge) -> Bool {
        guard API.focusObject?.isSameElement(as: self) == true else { return false }
        guard API.focusTreeInterceptor?.passThrough != false else { return false }
        guard InputManager.lastKeyDownAt == pending.keyDownAt else { return false }
        guard ScriptHandler.keysArrivedCount == pending.keysArrived else { return false }
        guard !EventHandler.isPending(.gainFocus) else { return false }
        return true
    }

    /// The window has passed. A changed value (whether or not Claude reported it) reads the line the caret is now on;
    /// an unchanged one reads as any edge does (the line in a one-line box, nothing in a longer one).
    private func finishEdgeAfterWindow(id: UUID) {
        guard let pending = pendingEdge else { return }
        guard pending.id == id else { return }
        pendingEdge = nil
        guard stillOwns(pending) else { return }
        let valueNow = element.string(kAXValueAttribute)
        let valueChanged = valueNow != pending.value
        if valueChanged || readsLineAtEdge {
            caretMoved(speak: .line, gesture: pending.gesture, info: nil)
        }
    }

    package override func event_valueChange() {
        super.event_valueChange()
        guard let pending = pendingEdge else { return }
        guard stillOwns(pending) else { pendingEdge = nil; return }
        let elapsed = historyNow().timeIntervalSince(pending.sentAt)
        let withinWindow = elapsed >= 0 && elapsed <= Self.historyValueChangeWindow
        guard withinWindow else { pendingEdge = nil; return }
        let valueNow = element.string(kAXValueAttribute)
        // A notice with the value unchanged (the caret's own) is not the recall: keep waiting.
        guard valueNow != pending.value else { return }
        pendingEdge = nil
        Log.io("Claude Prompt: the value changed \(Int(elapsed * 1000)) ms after an edge arrow; read the caret's line")
        caretMoved(speak: .line, gesture: pending.gesture, info: nil)
    }

    package override func event_loseFocus() {
        pendingEdge = nil
        super.event_loseFocus()
    }
}
