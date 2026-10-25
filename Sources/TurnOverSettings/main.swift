// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver Settings (18 Oct 2026): TurnOver's settings in an ordinary window, sections down the side, ordinary
// controls. It lives inside TurnOver.app and is read by TurnOver like any app. It never writes the settings file:
// each change goes to TurnOver as a patch (SettingsBridge), and TurnOver answers with the settings as they now are.
// Through TurnOver's control channel, which only programs signed by TurnOver's developer may use (TurnOverControl).
import SwiftUI
import AVFoundation
import TurnOverControl

@MainActor
final class Model: ObservableObject {
    @Published var state: [String: Any] = [:]
    @Published var connected = false
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
        connection = ControlClient.Connection(received: { [weak self] message in
            if message["op"] as? String == "show", let name = message["section"] as? String {
                self?.requestedSection = Pane(rawValue: name)
                return
            }
            guard message["op"] as? String == "state", let json = message["json"] as? String, let data = json.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            self?.state = dict; self?.connected = true
            if let name = dict["_showSection"] as? String { self?.requestedSection = Pane(rawValue: name) }
        }, ended: { [weak self] in
            self?.connected = false; self?.connection = nil
            self?.retry()
        })
        if let connection { connection.send(["op": "subscribe"]) } else { retry() }
    }

    private func retry() {
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

enum Pane: String, CaseIterable, Identifiable {
    // NVDA's order, with TurnOver's own at the end: every setting the menu offered lives here since 21 Oct 2026.
    case general = "General", speech = "Speech", keyboard = "Keyboard", items = "Item details", webPages = "Web pages", documents = "Documents",
         recognition = "Screen recognition", otherApps = "Other apps' speech", readers = "Screen reader behaviour"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    @State private var section: Pane? = .general
    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $section) { s in Text(s.rawValue).tag(s) }
                .navigationSplitViewColumnWidth(190)
                .accessibilityLabel("Settings sections")
        } detail: {
            if !model.connected {
                Text("Waiting for TurnOver. Start it with Command Control Period.").padding()
            } else {
                switch section ?? .general {
                case .general: GeneralView()
                case .speech: SpeechView()
                case .keyboard: KeyboardView()
                case .items: ItemsView()
                case .webPages: WebPagesView()
                case .documents: DocumentsView()
                case .recognition: RecognitionView()
                case .otherApps: OtherAppsView()
                case .readers: ReadersView()
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onReceive(model.$requestedSection) { requested in
            guard let requested else { return }
            section = requested
            model.requestedSection = nil
        }
    }
}

/// The voices on the Mac, listed once and again each time the window comes to the front: listing and sorting them on
/// every redraw made the window slow to answer accessibility questions, and the arrow keys in the sidebar waited half
/// a second (22 Oct 2026). A voice installed or a language added while the window is open shows up on the next return.
@MainActor
final class VoiceLists: ObservableObject {
    static let shared = VoiceLists()
    @Published private(set) var all: [AVSpeechSynthesisVoice] = []
    @Published private(set) var offered: [AVSpeechSynthesisVoice] = []
    @Published private(set) var rotorCandidates: [AVSpeechSynthesisVoice] = []
    private var observer: NSObjectProtocol?

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// A voice's label in the picker, made once per refresh rather than on every redraw.
    private var labels: [String: String] = [:]
    func label(for voice: AVSpeechSynthesisVoice) -> String { labels[voice.identifier] ?? voice.name }

    func refresh() {
        let mine = Locale.preferredLanguages.map { String($0.prefix(2)) }
        let wanted = Set(mine + ["en"])
        let voices = AVSpeechSynthesisVoice.speechVoices()
        all = voices
        // English and the Mac's own languages, the Mac's languages first and Eloquence before the rest.
        offered = voices.filter { wanted.contains(String($0.language.prefix(2))) }.sorted { a, b in
            let la = mine.firstIndex(of: String(a.language.prefix(2))) ?? 99, lb = mine.firstIndex(of: String(b.language.prefix(2))) ?? 99
            if la != lb { return la < lb }
            let ea = a.identifier.contains("eloquence"), eb = b.identifier.contains("eloquence")
            if ea != eb { return ea }
            return a.name < b.name
        }
        // The voices of the Mac's own languages and English, as the rotor offers them.
        rotorCandidates = voices.filter { wanted.contains(String($0.language.prefix(2))) }
            .sorted { $0.name == $1.name ? $0.language < $1.language : $0.name < $1.name }
        var made: [String: String] = [:]
        for v in voices {
            let language = Locale.current.localizedString(forIdentifier: v.language) ?? v.language
            let quality = v.quality == .premium ? ", premium" : v.quality == .enhanced ? ", enhanced" : ""
            made[v.identifier] = "\(v.name), \(language)\(quality)"
        }
        labels = made
    }
}

struct SpeechView: View {
    @EnvironmentObject var model: Model
    @ObservedObject private var voiceLists = VoiceLists.shared
    /// The voices offered, listed once (VoiceLists); a voice set earlier from outside the list stays selectable.
    private var voices: [AVSpeechSynthesisVoice] {
        let current = model.get("speech", "voice") as? String ?? ""
        if voiceLists.offered.contains(where: { $0.identifier == current }) || current.isEmpty { return voiceLists.offered }
        let extra = voiceLists.all.filter { $0.identifier == current }
        return voiceLists.offered + extra
    }
    private let natural = ["af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river",
                           "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx",
                           "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george", "bm_lewis"]
    private var rotorChosen: [String] { (model.state["speech"] as? [String: Any])?["rotorVoices"] as? [String] ?? [] }
    private var rotorCandidates: [AVSpeechSynthesisVoice] { voiceLists.rotorCandidates }
    private var outputDevices: [(uid: String, name: String)] {
        ((model.special("_outputDevices") as? [[String: Any]]) ?? []).compactMap { d in
            guard let uid = d["uid"] as? String, let name = d["name"] as? String else { return nil }
            return (uid, name)
        }
    }
    /// The languages with an installed voice other than the main voice's, each with its voices (from the bridge).
    private var otherLanguages: [OtherLanguage] {
        let raw = (model.special("_otherLanguages") as? [[String: Any]]) ?? []
        return raw.compactMap { entry in
            guard let code = entry["code"] as? String, let name = entry["name"] as? String else { return nil }
            let voices = ((entry["voices"] as? [[String: Any]]) ?? []).compactMap { voice -> OtherLanguage.Voice? in
                guard let id = voice["id"] as? String, let voiceName = voice["name"] as? String else { return nil }
                return OtherLanguage.Voice(id: id, name: voiceName, language: voice["language"] as? String ?? "")
            }
            return OtherLanguage(code: code, name: name, voices: voices)
        }
    }
    private func naturalName(_ v: String) -> String { "\(v.dropFirst(3).capitalized), \(v.hasPrefix("b") ? "British" : "American")" }
    var body: some View {
        Form {
            Picker("Voice", selection: model.string("speech", "voice", "")) {
                ForEach(voices, id: \.identifier) { v in Text(voiceLists.label(for: v)).tag(v.identifier) }
            }
            Slider(value: model.percent("speech", "rate"), in: 10...100, step: 5) { Text("Rate") }
                .accessibilityValue("\(Int(model.percent("speech", "rate").wrappedValue)) percent")
            Slider(value: model.percent("speech", "pitch"), in: 0...100, step: 5) { Text("Pitch") }
                .accessibilityValue("\(Int(model.percent("speech", "pitch").wrappedValue)) percent")
            Slider(value: model.number("speech", "volume"), in: 10...200, step: 10) { Text("Volume") }
                .accessibilityValue("\(Int(model.number("speech", "volume").wrappedValue)) percent")
            Picker("Punctuation", selection: model.int("speech", "symbolLevel")) {
                Text("None").tag(0); Text("Some").tag(1); Text("Most").tag(2); Text("All").tag(3)
            }
            Toggle("Switch language when text says it is in another", isOn: model.bool("speech", "autoLanguageSwitching"))
            Picker("Lower other sounds while TurnOver speaks", selection: model.string("speech", "ducking", "off")) {
                Text("No").tag("off"); Text("While speaking").tag("speech"); Text("Always").tag("always")
            }
            Picker("Where speech plays", selection: model.string("speech", "outputDevice", "")) {
                Text("The Mac's default output").tag("")
                ForEach(outputDevices, id: \.uid) { d in Text(d.name).tag(d.uid) }
            }
            DisclosureGroup("Capitals") {
                Toggle("Say cap before a capital", isOn: model.bool("speech", "sayCapForCapitals"))
                Slider(value: model.number("speech", "capitalPitch"), in: 0...100, step: 10) { Text("Raise the pitch for a capital") }
                    .accessibilityValue(model.number("speech", "capitalPitch").wrappedValue == 0 ? "off" : "\(Int(model.number("speech", "capitalPitch").wrappedValue)) percent")
            }
            // The speech rotor's own short list (18 Oct 2026): none ticked, every voice.
            // Folded until opened: a picker per language is the costliest part of the pane to draw (23 Oct 2026).
            DisclosureGroup("Voices for other languages") {
                if otherLanguages.isEmpty {
                    Text("No voices for other languages are installed.").font(.caption)
                } else {
                    Text("Text marked as another language is read in that language's voice, when language switching is on.").font(.caption)
                    ForEach(otherLanguages, id: \.code) { language in
                        OtherLanguageRow(language: language)
                    }
                }
            }
            // Folded away: the list is long by nature (every voice the rotor could step through).
            DisclosureGroup(rotorChosen.isEmpty ? "Voices in the rotor: every voice" : "Voices in the rotor: \(rotorChosen.count) chosen") {
                Text(rotorChosen.isEmpty ? "Every voice: tick the ones you want VO-Command-Shift to step through." : "\(rotorChosen.count) chosen for VO-Command-Shift.").font(.caption)
                ForEach(rotorCandidates, id: \.identifier) { v in
                    Toggle("\(v.name), \(Locale.current.localizedString(forIdentifier: v.language) ?? v.language)", isOn: Binding(
                        get: { rotorChosen.contains(v.identifier) },
                        set: { on in
                            var list = rotorChosen.filter { $0 != v.identifier }
                            if on { list.append(v.identifier) }
                            model.set("speech", "rotorVoices", list)
                        }))
                }
            }
            if model.special("_kokoroAvailable") as? Bool == true {
                Section("Say all") {
                    Picker("Say all voice", selection: Binding(
                        get: { (model.special("_kokoroMode") as? String) == "off" ? "same" : (model.special("_kokoroVoice") as? String ?? "bf_emma") },
                        set: { v in if v == "same" { model.setSpecial("_kokoroMode", "off") } else { model.setSpecial("_kokoroVoice", v); model.setSpecial("_kokoroMode", "reading") } })) {
                        Text("Same as speech").tag("same")
                        ForEach(natural, id: \.self) { Text("\(naturalName($0)), natural").tag($0) }
                    }
                    Slider(value: Binding(get: { model.special("_kokoroSpeed") as? Double ?? 1.1 }, set: { model.setSpecial("_kokoroSpeed", ($0 * 10).rounded() / 10) }), in: 0.6...2.0, step: 0.1) { Text("Natural voice speed") }
                    Text("Say all reads ahead in the natural voice; moving around and typing stay in your speech voice.").font(.caption)
                }
            }
        }.formStyle(.grouped).navigationTitle("Speech")
    }
}

struct OtherLanguage {
    struct Voice { let id: String; let name: String; let language: String }
    let code: String
    let name: String
    let voices: [Voice]
}

/// One language: its voice (Automatic is the best installed one) and its own rate (the main rate until changed).
struct OtherLanguageRow: View {
    @EnvironmentObject var model: Model
    let language: OtherLanguage
    private var chosenVoices: [String: String] { model.get("speech", "languageVoices") as? [String: String] ?? [:] }
    private var rates: [String: Double] {
        let raw = model.get("speech", "languageRates") as? [String: Any] ?? [:]
        return raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }
    private var mainRatePercent: Double { ((model.get("speech", "rate") as? NSNumber)?.doubleValue ?? 0.55) * 100 }
    private var voiceChoice: Binding<String> {
        Binding(get: { chosenVoices[language.code] ?? "" }, set: { chosen in
            var all = chosenVoices
            if chosen.isEmpty { all.removeValue(forKey: language.code) } else { all[language.code] = chosen }
            model.set("speech", "languageVoices", all)
        })
    }
    private var ratePercent: Binding<Double> {
        Binding(get: { (rates[language.code] ?? (mainRatePercent / 100)) * 100 }, set: { percent in
            var all = rates
            all[language.code] = (percent / 100 * 100).rounded() / 100
            model.set("speech", "languageRates", all)
        })
    }
    var body: some View {
        Picker("\(language.name) voice", selection: voiceChoice) {
            Text("Automatic\(language.voices.first.map { ": \($0.name)" } ?? "")").tag("")
            ForEach(language.voices, id: \.id) { voice in Text("\(voice.name), \(voice.language)").tag(voice.id) }
        }
        Slider(value: ratePercent, in: 10...100, step: 5) { Text("\(language.name) rate") }
            .accessibilityValue(rates[language.code] == nil ? "\(Int(ratePercent.wrappedValue)), same as the main voice" : "\(Int(ratePercent.wrappedValue))")
    }
}

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

struct ItemsView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Toggle("Help text of items", isOn: model.bool("presentation", "reportObjectDescriptions"))
            Toggle("Each item's keyboard shortcut", isOn: model.bool("presentation", "reportKeyboardShortcuts"))
            Toggle("Position, such as 3 of 10", isOn: model.bool("presentation", "reportObjectPositionInformation"))
            Toggle("Hints after a pause", isOn: model.bool("presentation", "speakHints"))
            Toggle("Say which plugin an app has as it comes to the front", isOn: model.bool("presentation", "announcePlugins"))
            Picker("Heading, link and button: when to say them", selection: model.string("documentFormatting", "roleOrder", "auto")) {
                Text("By keyboard style").tag("auto"); Text("Before the words, as NVDA").tag("before"); Text("After the words, as VoiceOver").tag("after")
            }
        }.formStyle(.grouped).navigationTitle("Item details")
    }
}

struct DocumentsView: View {
    @EnvironmentObject var model: Model
    private let kinds: [(String, String)] = [("headings", "Headings"), ("links", "Links"), ("lists", "Lists"), ("tables", "Tables"),
                                              ("landmarks", "Landmarks"), ("graphics", "Graphics"), ("blockQuotes", "Block quotes"), ("spellingErrors", "Spelling errors")]
    var body: some View {
        Form {
            ForEach(kinds, id: \.0) { k in
                Picker(k.1, selection: model.string("documentFormatting", k.0, "speech")) {
                    Text("Said").tag("speech"); Text("A sound").tag("tone"); Text("Nothing").tag("off")
                }
            }
            Toggle("Say heading levels", isOn: model.bool("documentFormatting", "reportHeadingLevel"))
            Section("Tables") {
                Toggle("Row and column headers", isOn: model.bool("documentFormatting", "tableHeaders"))
                Toggle("Cell positions", isOn: model.bool("documentFormatting", "tableCellCoordinates"))
            }
            Section("Fonts, said as the caret moves into new formatting") {
                Toggle("Font name", isOn: model.bool("documentFormatting", "reportFontName"))
                Toggle("Font size", isOn: model.bool("documentFormatting", "reportFontSize"))
                Toggle("Bold, italic and underline", isOn: model.bool("documentFormatting", "reportFontAttributes"))
            }
        }.formStyle(.grouped).navigationTitle("Documents")
    }
}

struct WebPagesView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Toggle("Type into a field as soon as it has the focus", isOn: model.bool("virtualBuffers", "autoFocusMode"))
            Toggle("Read a page through as it opens", isOn: model.bool("virtualBuffers", "autoSayAllOnPageLoad"))
            Toggle("Single-letter keys go round the page", isOn: model.bool("virtualBuffers", "wrapQuickNav"))
            Toggle("Links and buttons in the line, as on screen", isOn: model.bool("virtualBuffers", "screenLayout"))
            Toggle("Name undescribed pictures by their file name", isOn: model.bool("virtualBuffers", "imageFileNames"))
            Slider(value: model.number("virtualBuffers", "maxLineLength"), in: 40...250, step: 10) { Text("Longest line") }
                .accessibilityValue("\(Int(model.number("virtualBuffers", "maxLineLength").wrappedValue)) characters")
        }.formStyle(.grouped).navigationTitle("Web pages")
    }
}

struct RecognitionView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Toggle("Read new text as it appears, while a result is open", isOn: model.bool("recognition", "autoRefresh"))
            Toggle("Read the whole result as it opens", isOn: model.bool("recognition", "autoSayAll"))
        }.formStyle(.grouped).navigationTitle("Screen recognition")
    }
}

struct OtherAppsView: View {
    @EnvironmentObject var model: Model
    private var apps: [(id: String, name: String, allowed: Bool)] {
        ((model.special("_speechPortApps") as? [[String: Any]]) ?? []).compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return (id, name, d["allowed"] as? Bool ?? false)
        }
    }
    var body: some View {
        Form {
            if apps.isEmpty {
                Text("No app has asked to speak through TurnOver yet. A game or another program can ask; it appears here, and you choose whether it may.").font(.caption)
            } else {
                ForEach(apps, id: \.id) { a in
                    Toggle(a.name, isOn: Binding(get: { a.allowed }, set: { on in model.setSpecial("_speechPortAllowed", ["id": a.id, "allowed": on]) }))
                }
                Text("Allowed: it can make TurnOver speak while it is the app in front.").font(.caption)
            }
        }.formStyle(.grouped).navigationTitle("Other apps' speech")
    }
}

struct GeneralView: View {
    @EnvironmentObject var model: Model
    /// What you hear as TurnOver takes over and hands back: two flags in the file, one choice here.
    private var handOver: Binding<String> {
        Binding(get: {
            if model.get("general", "handOverNothing") as? Bool == true { return "nothing" }
            if model.get("general", "handOverChimes") as? Bool == true { return "sound" }
            return "words"
        }, set: { v in
            model.set("general", "handOverNothing", v == "nothing")
            model.set("general", "handOverChimes", v == "sound")
        })
    }
    var body: some View {
        Form {
            Section("Starting") {
                Toggle("Open TurnOver at login", isOn: model.bool("general", "openAtLogin"))
                Toggle("Show TurnOver in the menu bar", isOn: model.bool("general", "showInMenuBar"))
            }
            Section("Sounds") {
                Picker("Sounds", selection: model.string("general", "sounds", "turnover")) {
                    Text("VoiceOver's").tag("voiceover"); Text("TurnOver's").tag("turnover")
                }
                Toggle("Sounds as I move and press", isOn: model.bool("general", "navigationSounds"))
                Picker("When TurnOver takes over from VoiceOver", selection: handOver) {
                    Text("Words").tag("words"); Text("A sound").tag("sound"); Text("Nothing").tag("nothing")
                }
            }
            Section("Alerts") {
                Toggle("Read notifications from other apps", isOn: model.bool("presentation", "reportNotifications"))
                Toggle("Read changes on screen as they happen", isOn: model.bool("presentation", "reportDynamicContentChanges"))
            }
            Picker("Screen Curtain while TurnOver reads", selection: model.string("general", "screenCurtain", "follow")) {
                Text("The same as VoiceOver's").tag("follow"); Text("Always on").tag("on"); Text("Off").tag("off")
            }
        }.formStyle(.grouped).navigationTitle("General")
    }
}

/// TurnOver is on or off; VoiceOver is on or off. The two things that relate them live here, and the experimental
/// readers per app, folded away (22 Oct 2026; last in the list, the place for the things most people never touch).
struct ReadersView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Section {
                Toggle("TurnOver comes on when VoiceOver turns off, and off when VoiceOver comes on", isOn: model.bool("applications", "swapWithVoiceOver"))
                Text("Off: each reader has its own switch and neither changes the other. Command Control Period is TurnOver's; Command F5 is VoiceOver's.").font(.caption)
            }
            Section {
                Toggle("VoiceOver comes on when TurnOver quits", isOn: model.bool("applications", "voiceOverOnAtQuit"))
                Text("Off: quitting TurnOver leaves VoiceOver as it is, so with VoiceOver off the Mac has no speech until you press Command F5. For VoiceOver reading inside a virtual machine.").font(.caption)
            }
            DisclosureGroup("Experimental: readers per app") {
                Toggle("Readers per app", isOn: model.bool("applications", "perAppReaders"))
                Text("A list of apps for each reader, a mode (TurnOver in its apps, everywhere, or VoiceOver everywhere), and switching between the readers as you change apps. The list is under Tools in the TurnOver menu while this is on. Off, TurnOver reads everywhere while it is on.").font(.caption)
            }
        }.formStyle(.grouped).navigationTitle("Screen reader behaviour")
    }
}

@main
struct TurnOverSettingsApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup("TurnOver Settings") { ContentView().environmentObject(model) }
            .windowResizability(.contentSize)
    }
}
