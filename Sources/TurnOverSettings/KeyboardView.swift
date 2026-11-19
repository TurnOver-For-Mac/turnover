// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct KeyboardView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Picker("Keyboard style", selection: model.string("general", "keyboardStyle", "mac")) {
                Text("VoiceOver keys").tag("mac"); Text("NVDA keys").tag("windows"); Text("JAWS keys").tag("jaws")
            }
            Toggle("NVDA and JAWS keys where VoiceOver reads too", isOn: model.bool("general", "keysWhereVoiceOverReads"))
            Text("On, Caps Lock is the NVDA key in every app, whichever reader is speaking. Off, VoiceOver's own Caps Lock keys work in the apps VoiceOver reads.").font(.caption)
            Picker("TurnOver key", selection: model.string("general", "bosunKey", "both")) {
                Text("Caps Lock or Control Option").tag("both"); Text("Caps Lock").tag("caps"); Text("Control Option").tag("controlOption")
            }
            Picker("Keyboard layout", selection: model.string("keyboard", "layout", "laptop")) {
                Text("Laptop").tag("laptop"); Text("Desktop, the number pad has its NVDA keys").tag("desktop")
            }
            Section("Typing echo") {
                Picker("Characters", selection: model.int("keyboard", "speakTypedCharacters")) {
                    Text("Off").tag(0); Text("In edit fields").tag(1); Text("Always").tag(2)
                }
                Picker("Words", selection: model.int("keyboard", "speakTypedWords")) {
                    Text("Off").tag(0); Text("In edit fields").tag(1); Text("Always").tag(2)
                }
                Toggle("New line on Return", isOn: model.bool("keyboard", "speakNewLine"))
                Toggle("Command keys, as you press them", isOn: model.bool("keyboard", "speakCommandKeys"))
            }
            Section("Moving around") {
                Toggle("VoiceOver keys move by groups", isOn: model.bool("general", "navigateByGroups"))
                Toggle("NVDA and JAWS keys move by groups too", isOn: model.bool("general", "groupsInWindowsStyle"))
                Picker("Moving the cursor moves the keyboard focus", selection: model.string("general", "focusFollowsCursor", "auto")) {
                    Text("By style: VoiceOver keys only").tag("auto"); Text("Always").tag("on"); Text("Never").tag("off")
                }
            }
            Section("The keypad") {
                Toggle("Keypad commands with VoiceOver keys (VO Clear switches)", isOn: model.bool("keyboard", "numpadCommander"))
                Toggle("Keypad commands with NVDA keys (Clear switches)", isOn: model.bool("keyboard", "keypadCommands"))
            }
        }.formStyle(.grouped).navigationTitle("Keyboard")
    }
}
