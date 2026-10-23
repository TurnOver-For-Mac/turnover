// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import TurnOverControl

@MainActor
final class KeyboardEditorModel: ObservableObject {
    @Published private(set) var state: KeyboardEditing.State?
    @Published private(set) var candidate: KeyboardEditing.Candidate?
    @Published private(set) var recording = false
    @Published private(set) var message = ""
    @Published private(set) var savedRequest: String?
    @Published private(set) var saving = false
    var send: (([String: Any]) -> Void)?
    private var request: String?

    func refresh() { send?(["op": "keyboard", "action": "list"]) }

    func record(_ edit: KeyboardEditRequest) {
        request = edit.id; candidate = nil; message = ""; recording = true; saving = false
        var payload: [String: Any] = ["op": "keyboard", "action": "capture", "request": edit.id, "command": edit.command.id]
        if let key = edit.oldKey { payload["oldKey"] = key.id }
        send?(payload)
    }

    func cancel(_ id: String) {
        send?(["op": "keyboard", "action": "cancel", "request": id])
        if request == id { request = nil; candidate = nil; recording = false; saving = false }
    }

    func save(_ id: String) {
        guard request == id, candidate?.error == nil, candidate != nil, !saving else { return }
        saving = true
        send?(["op": "keyboard", "action": "save", "request": id])
    }

    func remove(_ key: KeyboardEditing.Key, from command: KeyboardEditing.Command) {
        send?(["op": "keyboard", "action": "remove", "key": key.id, "command": command.id])
    }

    func restore(_ change: KeyboardEditing.Change) {
        send?(["op": "keyboard", "action": "restore", "key": change.id, "target": change.stored])
    }

    func disconnected() {
        request = nil; candidate = nil; recording = false; saving = false; state = nil
        message = "TurnOver disconnected. No pending key assignment was saved."
    }

    func receive(_ message: [String: Any]) -> Bool {
        guard let op = message["op"] as? String, op.hasPrefix("keyboard") else { return false }
        let id = message["request"] as? String ?? ""
        let data = (message["json"] as? String)?.data(using: .utf8)
        switch op {
        case "keyboardState":
            if let data, let state = try? JSONDecoder().decode(KeyboardEditing.State.self, from: data) { self.state = state }
        case "keyboardRecording" where id == request:
            recording = true
        case "keyboardCandidate" where id == request:
            if let data { candidate = try? JSONDecoder().decode(KeyboardEditing.Candidate.self, from: data) }
            recording = false
        case "keyboardResult" where id.isEmpty || id == request:
            self.message = message["message"] as? String ?? ""
            recording = false; saving = false
            if message["saved"] as? Bool == true {
                savedRequest = id
            } else if id == request { candidate = nil }
        default: break
        }
        return true
    }
}

struct KeyboardEditRequest: Identifiable {
    let id = UUID().uuidString
    var command: KeyboardEditing.Command
    var oldKey: KeyboardEditing.Key?
}
