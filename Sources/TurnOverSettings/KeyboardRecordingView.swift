// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct KeyboardRecordingView: View {
    @ObservedObject var editor: KeyboardEditorModel
    let request: KeyboardEditRequest
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var previewFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.oldKey == nil ? "Add a key" : "Change a key").font(.title2)
            Text(request.command.title).font(.headline)
            if let key = request.oldKey { Text("Replaces \(key.label). The old key will go to the application.") }
            if editor.recording {
                Text("Press the new key. Escape cancels. Recording ends after 30 seconds.")
            } else if let candidate = editor.candidate {
                Text(candidate.label).font(.title3).accessibilityFocused($previewFocused)
                if let error = candidate.error { Text(error) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(candidate.warnings, id: \.self) { Text($0) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 180)
                if candidate.warnings.isEmpty, candidate.error == nil { Text("No conflicting assignment found in the built-in styles.") }
            } else {
                Text(editor.message.isEmpty ? "No key recorded." : editor.message)
            }
            Text("Warnings compare TurnOver’s built-in VoiceOver and NVDA styles. Other readers’ custom assignments are not available.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { editor.cancel(request.id); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if !editor.recording {
                    Button("Record again") { editor.record(request) }.disabled(editor.saving)
                }
                Button(editor.saving ? "Saving…" : "Save key") { editor.save(request.id) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editor.recording || editor.candidate == nil || editor.candidate?.error != nil || editor.saving)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { editor.record(request) }
        .onDisappear { editor.cancel(request.id) }
        .onChange(of: editor.candidate?.id) { previewFocused = editor.candidate != nil }
        .onChange(of: editor.savedRequest) { if editor.savedRequest == request.id { dismiss() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            editor.cancel(request.id)
        }
    }
}
