// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
import TurnOverCore
import TurnOverControl

func keyboardEditorTests() {
    func owner() -> ScriptableObject {
        let owner = ScriptableObject()
        owner.script("first", "First command", gestures: ["kb:turnover+t"], category: "Reading") { _ in }
        owner.script("second", "Second command", gestures: ["kb:turnover+s"], category: "Speech") { _ in }
        owner.script("unbound", "Unbound command", category: "Reading") { _ in }
        return owner
    }
    func keys(_ map: KeyboardMap, _ name: String, _ overrides: [String: String] = [:]) -> [String] {
        map.state(overrides: overrides, context: "Test app", style: "VoiceOver keys").commands.first { $0.id == name }?.keys.map(\.id) ?? []
    }

    test("keyboard editor: right Option T reports time, then date through normal command resolution") {
        let saved = config
        defer { config = saved; KeySettings.refresh(); ScriptHandler.clearLastScript() }
        config.general.keyboardStyle = "mac"
        config.keyboard.optionCommander = true
        config.keyboard.userGestures = [:]
        config.keyboard.multiPressTimeoutMs = 2000
        ScriptHandler.clearLastScript()
        // The real right-Option device flag, without relying on the editor's identifier parser.
        let right = KeyboardGesture(keyCode: 17, modifiers: .option, characters: "†", timestamp: 0, isRepeat: false,
                                    flags: CGEventFlags.maskAlternate.union(CGEventFlags(rawValue: 0x40)))
        guard let command = ScriptHandler.findScript(for: right) else { return Harness.fail("right Option T has no command") }
        expect(command.name, "dateTime")
        let formatter = DateFormatter()
        formatter.dateStyle = .none; formatter.timeStyle = .short
        let beforeTime = formatter.string(from: Date())
        ScriptHandler.executeScript(command, gesture: right)
        check([beforeTime, formatter.string(from: Date())].contains(Speech.lastRaw), "the first press sends the time to speech")
        formatter.dateStyle = .full; formatter.timeStyle = .none
        let beforeDate = formatter.string(from: Date())
        guard let repeated = ScriptHandler.findScript(for: right) else { return Harness.fail("the second press has no command") }
        ScriptHandler.executeScript(repeated, gesture: right)
        check([beforeDate, formatter.string(from: Date())].contains(Speech.lastRaw), "the second press sends the date to speech")
    }

    test("keyboard editor: left Option T and default right Option T with Commander off pass through") {
        let saved = config
        defer { config = saved; KeySettings.refresh(); ScriptHandler.clearLastScript() }
        config.general.keyboardStyle = "mac"
        config.keyboard.optionCommander = true
        config.keyboard.userGestures = [:]
        let left = KeyboardGesture(keyCode: 17, modifiers: .option, characters: "†", timestamp: 0, isRepeat: false, flags: .maskAlternate)
        check(ScriptHandler.findScript(for: left) == nil, "left Option T has no TurnOver command")
        check(!InputManager.handleKeyDown(left), "left Option T is not swallowed")
        expect(left.typedCharacter, "†")
        config.keyboard.optionCommander = false
        let right = KeyboardGesture(keyCode: 17, modifiers: .option, characters: "†", timestamp: 0, isRepeat: false,
                                    flags: CGEventFlags.maskAlternate.union(CGEventFlags(rawValue: 0x40)))
        check(ScriptHandler.findScript(for: right) == nil, "Commander off disables the default right Option T")
        check(!InputManager.handleKeyDown(right), "right Option T goes to the app with Commander off")
        expect(right.typedCharacter, "†")
    }

    test("keyboard editor: all commands, including unbound commands, retain their categories") {
        let map = KeyboardMap(sources: [.init(owner())], layout: "laptop")
        let state = map.state(overrides: [:], context: "Test app", style: "VoiceOver keys")
        expect(state.commands.map(\.id), ["first", "unbound", "second"])
        expect(keys(map, "unbound"), [])
        expect(keys(map, "first"), ["kb:turnover+t"])
        expect(state.context, "Test app")
    }
    test("keyboard editor: every preset binding matches command resolution in both layouts") {
        let saved = config
        defer { config = saved }
        config.keyboard.userGestures = [:]
        config.keyboard.optionCommander = false
        let owners: [ScriptableObject] = [VoiceOverKeysPlugin(), GlobalCommands.shared]
        for style in KeyboardStyle.allCases {
            config.general.keyboardStyle = style.rawValue
            for layout in ["laptop", "desktop"] {
                config.keyboard.layout = layout
                let styleKeys = StyleKeymap.keys(for: style)
                let map = KeyboardMap(sources: owners.map { .init($0) }, layout: layout, styleKeys: styleKeys)
                let state = map.state(overrides: [:], context: "", style: style.rawValue)
                let listed = Dictionary(uniqueKeysWithValues: state.commands.flatMap { command in command.keys.map { ($0.id, command.id) } })
                let ids = Set(owners.flatMap { $0.everyBinding.map(\.0) } + Array(styleKeys.keys))
                var checked = 0
                for id in ids where id.hasPrefix("kb:") || id.hasPrefix("kb(\(layout)):") {
                    guard let g = KeyboardGesture(identifier: id) else { continue }
                    var expected = owners.lazy.compactMap { $0.script(for: g) }.first
                    if let value = styleKeys[g.identifier] {
                        let replacement: Script?
                        if value.hasPrefix("="), let alias = KeyboardGesture(identifier: String(value.dropFirst())) {
                            replacement = owners.lazy.compactMap { $0.script(for: alias) }.first
                        } else {
                            replacement = owners.lazy.compactMap { $0.script(named: value) }.first
                        }
                        if let replacement { expected = replacement }
                    }
                    let named = expected.flatMap { $0.description.isEmpty ? nil : $0.name }
                    expect(listed[g.identifier], named, "\(style.rawValue) \(layout) \(g.identifier)")
                    checked += 1
                }
                check(checked > 150, "the complete preset table was checked for \(style.rawValue) \(layout)")
                for owner in owners {
                    for command in owner.allScripts where !command.description.isEmpty {
                        check(state.commands.contains { $0.id == command.name }, "\(command.name) is in the catalogue")
                    }
                }
            }
        }
    }
    test("keyboard editor: changing a key removes the old default and preserves unrelated assignments") {
        let map = KeyboardMap(sources: [.init(owner())], layout: "laptop")
        let before = ["kb:rightoption+m": "app:com.apple.mail", "kb:turnover+9": "file:/tmp/example.applescript"]
        let changed = map.assigning("kb:turnover+s", to: "first", replacing: "kb:turnover+t", in: before)!
        expect(changed["kb:turnover+t"], "none")
        expect(changed["kb:turnover+s"], "script:first")
        expect(changed["kb:rightoption+m"], before["kb:rightoption+m"])
        expect(changed["kb:turnover+9"], before["kb:turnover+9"])
        expect(keys(map, "first", changed), ["kb:turnover+s"])
        expect(keys(map, "second", changed), [])
        var c = Config(); c.keyboard.userGestures = changed
        expect(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c)).keyboard.userGestures, changed)
    }
    test("keyboard editor: Say All preset keys are labelled, editable and overridden before the style") {
        let saved = config
        defer { config = saved }
        config.general.keyboardStyle = "jaws"
        let map = KeyboardMap(sources: [.init(VoiceOverKeysPlugin()), .init(GlobalCommands.shared)], layout: "laptop",
                              styleKeys: StyleKeymap.keys(for: .jaws), sayAllKeys: StyleKeymap.sayAllKeys(for: .jaws))
        let state = map.state(overrides: [:], context: "", style: "jaws")
        for (id, name) in StyleKeymap.sayAllKeys(for: .jaws) {
            let key = state.commands.first { $0.id == name }?.keys.first { $0.id == id }
            check(key?.label.contains("during Say All") == true, "\(id) is labelled as conditional")
            let removed = map.removing(id, from: name, in: [:])!
            check(!keys(map, name, removed).contains(id), "\(id) can be removed")
            let changed = map.assigning("kb:turnover+8", to: name, replacing: id, in: [:])!
            expect(changed[id], "none")
            check(keys(map, name, changed).contains("kb:turnover+8"), "\(name) can be reassigned")
        }
        check(map.candidate("kb:rightArrow", for: "reportCurrentFocus", overrides: [:]).warnings.contains { $0.contains("During Say All") }, "conditional conflict is explained")
    }
    test("keyboard editor: remove and restore distinguish an override from a disabled default") {
        let map = KeyboardMap(sources: [.init(owner())], layout: "laptop")
        var changed = map.removing("kb:turnover+t", from: "first", in: [:])!
        expect(keys(map, "first", changed), [])
        expect(changed["kb:turnover+t"], "none")
        changed["kb:turnover+t"] = nil
        expect(keys(map, "first", changed), ["kb:turnover+t"])
        check(map.removing("kb:turnover+t", from: "second", in: [:]) == nil, "stale command selection cannot remove another command's key")
    }
    test("keyboard editor: layout precedence and an unavailable custom command match runtime fallback") {
        let saved = config
        defer { config = saved }
        config.keyboard.layout = "laptop"
        let source = owner()
        source.script("laptop", "Laptop command", gestures: ["kb(laptop):turnover+t"] ) { _ in }
        source.script("desktop", "Desktop command", gestures: ["kb(desktop):turnover+t"] ) { _ in }
        let map = KeyboardMap(sources: [.init(source)], layout: "laptop")
        expect(keys(map, "laptop"), ["kb:turnover+t"])
        expect(keys(map, "desktop"), [])
        let overrides = ["kb:turnover+t": "script:second", "kb(laptop):turnover+t": "script:appNotHere"]
        expect(keys(map, "laptop", overrides), ["kb:turnover+t"], "unknown layout override falls back to default, not the general override")
        let changed = map.assigning("kb:turnover+t", to: "unbound", replacing: nil, in: overrides)!
        expect(changed["kb(laptop):turnover+t"], nil, "the old layout override must not hide the new key")
        expect(keys(map, "unbound", changed), ["kb:turnover+t"])
    }
    test("keyboard editor: essential keys and keypad mode controls cannot be reassigned") {
        let map = KeyboardMap(sources: [.init(owner())], layout: "laptop")
        for id in ["kb:escape", "kb:turnover+space", "kb:command+control+,", "kb:command+control+.", "kb:numpad0", "kb:numpadClear"] {
            check(map.assigning(id, to: "first", replacing: nil, in: [:]) == nil, "\(id) rejected")
            check(map.candidate(id, for: "first", overrides: [:]).error != nil, "\(id) explained")
        }
        check(map.assigning("kb:turnover+8", to: "missing", replacing: nil, in: [:]) == nil, "unknown command rejected")
    }
    test("keyboard editor: conflicts include both styles without changing the live style") {
        let saved = config.general.keyboardStyle
        let vo = ScriptableObject(), nvda = ScriptableObject()
        vo.script("voice", "VoiceOver command", gestures: ["kb:turnover+t"]) { _ in }.isAvailable = { false }
        nvda.script("windows", "NVDA command", gestures: ["kb:turnover+t"]) { _ in }
        let map = KeyboardMap(sources: [.init(vo, reference: "VoiceOver style"), .init(nvda, reference: "NVDA style"), .init(owner())], layout: "laptop")
        let candidate = map.candidate("kb:turnover+t", for: "unbound", overrides: [:])
        check(candidate.warnings.contains { $0.contains("VoiceOver style: VoiceOver command") }, "inactive style is included")
        check(candidate.warnings.contains { $0.contains("NVDA style: NVDA command") }, "NVDA conflict included")
        check(candidate.warnings.contains { $0.contains("Currently assigned") }, "current assignment named")
        expect(config.general.keyboardStyle, saved)
        check(map.candidate("kb:a", for: "unbound", overrides: [:]).warnings.contains { $0.contains("normally types") }, "typing key warns")
    }
    test("keyboard editor: right Option and numpad identifiers round-trip independently") {
        for id in ["kb:rightoption+s", "kb:rightoption+shift+n", "kb:option+s", "kb:numpad8", "kb:turnover+numpad8"] {
            let gesture = UserGestures.gesture(for: id)!
            expect(UserGestures.storedIdentifier(of: gesture), id)
        }
        let map = KeyboardMap(sources: [.init(owner())], layout: "laptop")
        let changed = map.assigning("kb:rightoption+s", to: "first", replacing: nil, in: [:])!
        check(keys(map, "first", changed).contains("kb:rightoption+s"), "right Option kept")
        check(!keys(map, "first", changed).contains("kb:option+s"), "left Option not assigned")
    }
    test("keyboard editor: unavailable bindings do not hide a lower-priority owner") {
        let higher = ScriptableObject(), lower = owner()
        higher.script("inactive", "Inactive command", gestures: ["kb:turnover+t"]) { _ in }.isAvailable = { false }
        let map = KeyboardMap(sources: [.init(higher), .init(lower)], layout: "laptop")
        expect(keys(map, "first"), ["kb:turnover+t"])
        expect(keys(map, "inactive"), [])
    }
    test("keyboard editor: keypad commands and JAWS aliases use the same default tables") {
        let vo = VoiceOverKeysPlugin()
        let mac = Keypad.bindings(windows: false) { id in vo.everyBinding.first { $0.0 == id }?.1.first?.name }
        check(mac.contains { $0 == ("kb:numpad1", "vo_itemChooser") }, "VoiceOver keypad 1 opens the item chooser")
        let windows = Keypad.bindings(windows: true) { _ in nil }
        check(windows.contains { $0 == ("kb:numpad8", "nvda_reviewCurrentLine") }, "NVDA keypad 8 reads the review line")
        check(ScriptHandler.findScript(named: "keypad_reviewPreviousCharacter") != nil, "keypad-only command can be assigned by name")
        let map = KeyboardMap(sources: [.init(owner())], layout: "laptop", styleKeys: ["kb:turnover+i": "=kb:turnover+t"])
        check(keys(map, "first").contains("kb:turnover+i"), "style alias appears on the resolved command")
    }
    test("keyboard editor: capture cancellation only clears the capture it owns") {
        let old = UUID(), new = UUID()
        defer { InputManager.captureNext = nil }
        InputManager.beginCapture(owner: old, while: { true }, done: { _ in })
        InputManager.beginCapture(owner: new, while: { true }, done: { _ in })
        InputManager.cancelCapture(owner: old)
        check(InputManager.isCapturing, "a stale cancellation cannot cancel a newer prompt")
        InputManager.cancelCapture(owner: new)
        check(!InputManager.isCapturing, "the owning prompt cancels")
        InputManager.beginCapture(owner: old, while: { true }, done: { _ in })
        InputManager.captureNext = { _ in }
        InputManager.cancelCapture(owner: old)
        check(InputManager.isCapturing, "an unrelated legacy prompt is preserved")
    }
    test("keyboard editor: a repeat is swallowed without completing key capture") {
        defer { InputManager.captureNext = nil }
        InputManager.beginCapture(owner: UUID(), while: { true }, done: { _ in })
        let key = KeyboardGesture(keyCode: 17, modifiers: .turnover, characters: "", timestamp: 0, isRepeat: true, flags: [])
        check(InputManager.handleKeyDown(key), "repeat swallowed")
        check(InputManager.isCapturing, "capture waits for a fresh press")
    }
    test("keyboard editor: changed keys include imported actions and stored values for safe restoration") {
        let map = KeyboardMap(sources: [.init(owner())], layout: "laptop")
        let overrides = ["kb:turnover+s": "none", "kb:rightoption+m": "app:com.apple.mail", "kb:turnover+8": "shortcut:example"]
        let state = map.state(overrides: overrides, context: "", style: "")
        expect(Dictionary(uniqueKeysWithValues: state.changes.map { ($0.id, $0.stored) }), overrides)
        expect(keys(map, "second", overrides), [])
        let decoded = try JSONDecoder().decode(KeyboardEditing.State.self, from: JSONEncoder().encode(state))
        expect(decoded.changes.map(\.stored), state.changes.map(\.stored))
    }
}
