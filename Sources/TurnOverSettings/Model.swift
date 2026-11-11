// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import TurnOverControl

@MainActor
final class Model: ObservableObject {
    @Published var state: [String: Any] = [:]
    @Published var connected = false
    /// TurnOver closed the connection at once, five times running: this window is an old build's, left open across an
    /// install, and TurnOver turns it away (issue 77: it knocked every two seconds until it was quit by hand).
    @Published var turnedAway = false
    private var refusals = 0
    private var opened = Date()
    /// A section TurnOver asked the window to show (a settings key pressed): with the first state, or on its own
    /// while the window is open. The sidebar follows it and then clears it.
    @Published var requestedSection: Pane?
    private var connection: ControlClient.Connection?

    init() {
        connect()
    }

    /// Connected to TurnOver and listening for its settings; tried again every two seconds until TurnOver is there,
    /// and again if TurnOver restarts.
    private func connect() {
        opened = Date()
        connection = ControlClient.Connection(received: { [weak self] message in
            self?.refusals = 0
            if message["op"] as? String == "show", let name = message["section"] as? String {
                self?.requestedSection = Pane(rawValue: name)
                return
            }
            guard message["op"] as? String == "state", let json = message["json"] as? String, let data = json.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            self?.state = dict; self?.connected = true
            if let name = dict["_showSection"] as? String { self?.requestedSection = Pane(rawValue: name) }
        }, ended: { [weak self] in
            guard let self else { return }
            if !connected, Date().timeIntervalSince(opened) < 1 { refusals += 1 }
            connected = false; connection = nil
            retry()
        })
        if let connection { connection.send(["op": "subscribe"]) } else { retry() }
    }

    private func retry() {
        guard refusals < 5 else { turnedAway = true; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.connection == nil else { return }
            self.connect()
        }
    }

    func ask() { connection?.send(["op": "ask"]) }

    func get(_ section: String, _ key: String) -> Any? { (state[section] as? [String: Any])?[key] }
    func special(_ key: String) -> Any? { state[key] }

    func set(_ section: String, _ key: String, _ value: Any) {
        var s = state[section] as? [String: Any] ?? [:]; s[key] = value; state[section] = s   // shown at once; TurnOver confirms
        send([section: [key: value]])
    }
    func setSpecial(_ key: String, _ value: Any) { state[key] = value; send([key: value]) }

    private func send(_ patch: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: patch), let s = String(data: data, encoding: .utf8) else { return }
        connection?.send(["op": "patch", "json": s])
    }

    // Bindings onto the settings.
    func bool(_ section: String, _ key: String) -> Binding<Bool> {
        Binding(get: { self.get(section, key) as? Bool ?? false }, set: { self.set(section, key, $0) })
    }
    func string(_ section: String, _ key: String, _ fallback: String) -> Binding<String> {
        Binding(get: { self.get(section, key) as? String ?? fallback }, set: { self.set(section, key, $0) })
    }
    func int(_ section: String, _ key: String) -> Binding<Int> {
        Binding(get: { (self.get(section, key) as? NSNumber)?.intValue ?? 0 }, set: { self.set(section, key, $0) })
    }
    /// A 0–1 value shown as 0–100 (rate, pitch).
    func percent(_ section: String, _ key: String) -> Binding<Double> {
        Binding(get: { ((self.get(section, key) as? NSNumber)?.doubleValue ?? 0.5) * 100 }, set: { self.set(section, key, ($0 / 100 * 100).rounded() / 100) })
    }
    func number(_ section: String, _ key: String) -> Binding<Double> {
        Binding(get: { (self.get(section, key) as? NSNumber)?.doubleValue ?? 0 }, set: { self.set(section, key, Int($0.rounded())) })
    }
}
