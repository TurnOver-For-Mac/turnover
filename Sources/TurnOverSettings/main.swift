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

enum Pane: String, CaseIterable, Identifiable {
    // NVDA's order, with TurnOver's own at the end: every setting the menu offered lives here since 21 Oct 2026.
    case general = "General", speech = "Speech", sounds = "Sounds", braille = "Braille", keyboard = "Keyboard", items = "Item details", webPages = "Web pages", documents = "Documents",
         recognition = "Screen recognition", otherApps = "Other apps' speech", readers = "Screen reader behaviour"
    var id: String { rawValue }
    /// As the sidebar shows it. (The raw value stays English: TurnOver asks for a section by it.)
    var title: String {
        switch self {
        case .general: return String(localized: "General", comment: "A section of the Settings window")
        case .speech: return String(localized: "Speech", comment: "A section of the Settings window")
        case .sounds: return String(localized: "Sounds", comment: "A section of the Settings window")
        case .braille: return String(localized: "Braille", comment: "A section of the Settings window")
        case .keyboard: return String(localized: "Keyboard", comment: "A section of the Settings window")
        case .items: return String(localized: "Item details", comment: "A section of the Settings window")
        case .webPages: return String(localized: "Web pages", comment: "A section of the Settings window")
        case .documents: return String(localized: "Documents", comment: "A section of the Settings window")
        case .recognition: return String(localized: "Screen recognition", comment: "A section of the Settings window")
        case .otherApps: return String(localized: "Other apps' speech", comment: "A section of the Settings window")
        case .readers: return String(localized: "Screen reader behaviour", comment: "A section of the Settings window")
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    @State private var section: Pane? = .general
    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $section) { s in Text(s.title).tag(s) }
                .navigationSplitViewColumnWidth(190)
                .accessibilityLabel("Settings sections")
        } detail: {
            if model.turnedAway {
                Text("TurnOver turned this window away: it was probably updated while the window was open. Quit Settings and open it again from the TurnOver menu.").padding()
            } else if !model.connected {
                Text("Waiting for TurnOver. Start it with Command Control Period.").padding()
            } else {
                switch section ?? .general {
                case .general: GeneralView()
                case .speech: SpeechView()
                case .sounds: SoundsView()
                case .braille: BrailleView()
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
        // Not Apple's novelty voices (Bells, Bubbles, Zarvox and the rest, 15 of them: Oliver, 2 Nov 2026, "a big list of
        // shit nonsense voices that apple like to ship"). A novelty voice already chosen stays selectable (voices).
        let real = voices.filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
        // English and the Mac's own languages, the Mac's languages first and Eloquence before the rest.
        offered = real.filter { wanted.contains(String($0.language.prefix(2))) }.sorted { a, b in
            let la = mine.firstIndex(of: String(a.language.prefix(2))) ?? 99, lb = mine.firstIndex(of: String(b.language.prefix(2))) ?? 99
            if la != lb { return la < lb }
            let ea = a.identifier.contains("eloquence"), eb = b.identifier.contains("eloquence")
            if ea != eb { return ea }
            return a.name < b.name
        }
        // The voices of the Mac's own languages and English, as the rotor offers them.
        rotorCandidates = real.filter { wanted.contains(String($0.language.prefix(2))) }
            .sorted { $0.name == $1.name ? $0.language < $1.language : $0.name < $1.name }
        var made: [String: String] = [:]
        for v in voices {
            let language = Locale.current.localizedString(forIdentifier: v.language) ?? v.language
            made[v.identifier] = v.quality == .premium ? String(localized: "\(v.name), \(language), premium", comment: "A voice: its name, language and quality")
                : v.quality == .enhanced ? String(localized: "\(v.name), \(language), enhanced", comment: "A voice: its name, language and quality") : "\(v.name), \(language)"
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
    @State private var showRotor = false
    @State private var showLanguages = false
    /// One voice's tick in the rotor's list, named outright: SwiftUI left such switches nameless here (2 Nov 2026).
    private func rotorToggle(_ id: String, _ name: String) -> some View {
        Toggle(name, isOn: Binding(
            get: { rotorChosen.contains(id) },
            set: { on in
                var list = rotorChosen.filter { $0 != id }
                if on { list.append(id) }
                model.set("speech", "rotorVoices", list)
            }))
        .accessibilityLabel(name)
    }
    /// The voice chosen above, in the rotor or not, without Tabbing through every voice's switch (Oliver, 2 Nov 2026:
    /// "the menu and selection isn't great"). None ticked is every voice: so switching one off when none or only it is
    /// ticked ticks all the others, and all of them ticked is none.
    private func inRotor(_ id: String) -> some View {
        let title = String(localized: "In the rotor", comment: "A switch in Speech settings, under Voice: the voice chosen there is one VO-Command-Shift steps through")
        return Toggle(title, isOn: Binding(
            get: { rotorChosen.isEmpty || rotorChosen.contains(id) },
            set: { on in
                let all = rotorAll
                var list = rotorChosen.isEmpty ? all : rotorChosen
                list.removeAll { $0 == id }
                if on { list.append(id) }
                if list.isEmpty { list = all.filter { $0 != id } }
                if !all.isEmpty, Set(all).isSubset(of: list) { list = [] }
                model.set("speech", "rotorVoices", list)
            }))
        .accessibilityLabel(title)
    }
    /// The natural voices as entries of the Voice list and the rotor ("external:…"), named by TurnOver.
    private var naturalEntries: [(id: String, name: String)] {
        ((model.special("_naturalVoiceEntries") as? [[String: Any]]) ?? []).compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return (id, name)
        }
    }
    /// The natural voices this Mac has (Phonon's), named by TurnOver.
    private var natural: [(id: String, name: String)] {
        ((model.special("_kokoroVoices") as? [[String: Any]]) ?? []).compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return (id, name)
        }
    }
    /// An EQ slider's name: the labels come from a list, so SwiftUI does not put them in the catalog by itself
    /// (a tester heard "Treble" under a Russian interface, 8 Nov 2026).
    private func eqName(_ name: String) -> String {
        switch name {
        case "Bass": return String(localized: "Bass", comment: "An equalizer slider: the low frequencies")
        case "Middle": return String(localized: "Middle", comment: "An equalizer slider: the middle frequencies")
        case "Treble": return String(localized: "Treble", comment: "An equalizer slider: the high frequencies")
        default: return name
        }
    }
    private var rotorChosen: [String] { (model.state["speech"] as? [String: Any])?["rotorVoices"] as? [String] ?? [] }
    private var rotorCandidates: [AVSpeechSynthesisVoice] { voiceLists.rotorCandidates }
    /// Every voice the rotor's list offers, the natural ones first.
    private var rotorAll: [String] { naturalEntries.map(\.id) + rotorCandidates.map(\.identifier) }
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
    var body: some View {
        Form {
            // The natural voices are in the same list (2 Nov 2026): one chosen speaks everything, and the Mac voice
            // chosen before it stays underneath for other languages and raised capitals.
            Picker("Voice", selection: Binding(
                get: { model.special("_speechVoice") as? String ?? (model.get("speech", "voice") as? String ?? "") },
                set: { v in model.setSpecial("_speechVoice", v) })) {
                // Natural voices and the Mac's apart (2 Nov 2026).
                if !naturalEntries.isEmpty {
                    Section("Natural voices") { ForEach(naturalEntries, id: \.id) { Text($0.name).tag($0.id) } }
                }
                Section("Mac voices") { ForEach(voices, id: \.identifier) { v in Text(voiceLists.label(for: v)).tag(v.identifier) } }
            }
            // Downloading and removing the natural voices, beside the Voice list they add to (Oliver, 6 Nov 2026: "an
            // option, like in windows, to download natural voices"; "next to voice selection"; "a choice to remove").
            // All 25 at once: the engine they share is most of the size.
            if model.special("_kokoroAvailable") as? Bool == true {
                if model.special("_naturalDownloaded") as? Bool == false {
                    if model.special("_naturalDownloading") as? Bool == true {
                        Text("Downloading the natural voices…")
                    } else {
                        Button("Download natural voices, about 170 MB") { model.setSpecial("_downloadNaturalVoices", true) }
                            .accessibilityHint("25 English voices made on your Mac. They download once, from Hugging Face; nothing you read or type leaves your Mac.")
                    }
                } else if model.special("_naturalRemovable") as? Bool == true {
                    Button("Remove natural voices") { model.setSpecial("_removeNaturalVoices", true) }
                        .accessibilityHint("Deletes the downloaded natural voices, about 170 MB, and goes back to your Mac voice.")
                }
            }
            let chosenVoice = model.special("_speechVoice") as? String ?? (model.get("speech", "voice") as? String ?? "")
            // Not for a voice the list doesn't offer (another language's): it couldn't be switched off.
            if rotorAll.contains(chosenVoice) { inRotor(chosenVoice) }
            Slider(value: model.percent("speech", "rate"), in: 10...100, step: 5) { Text("Rate") }
                .accessibilityValue("\(Int(model.percent("speech", "rate").wrappedValue)) percent")
            Slider(value: model.percent("speech", "pitch"), in: 0...100, step: 5) { Text("Pitch") }
                .accessibilityValue("\(Int(model.percent("speech", "pitch").wrappedValue)) percent")
            Slider(value: model.number("speech", "volume"), in: 10...200, step: 10) { Text("Volume") }
                .accessibilityValue("\(Int(model.number("speech", "volume").wrappedValue)) percent")
            // The EQ, for every voice (2 Nov 2026); each voice keeps its own, with its rate and volume.
            ForEach([("Bass", "bass"), ("Middle", "middle"), ("Treble", "treble")], id: \.1) { name, key in
                let db = model.number("speech", key).wrappedValue
                Slider(value: model.number("speech", key), in: -12...12, step: 1) { Text(eqName(name)) }
                    .accessibilityValue(db == 0 ? "0" : String(localized: "\(String(format: "%+.0f", db)) decibels", comment: "An EQ slider's value"))
            }
            Picker("Punctuation", selection: model.int("speech", "symbolLevel")) {
                Text("None").tag(0); Text("Some").tag(1); Text("Most").tag(2); Text("All").tag(3)
            }
            Toggle("Switch language when text says it is in another", isOn: model.bool("speech", "autoLanguageSwitching"))
            Picker("Where speech plays", selection: model.string("speech", "outputDevice", "")) {
                Text("The Mac's default output").tag("")
                ForEach(outputDevices, id: \.uid) { d in Text(d.name).tag(d.uid) }
            }
            // Sections and switches, not fold-outs: SwiftUI's DisclosureGroup offers accessibility no action to open it
            // (measured 2 Nov 2026: pressed, it stayed shut), so its contents couldn't be reached by keyboard at all.
            Section("Capitals") {
                Toggle("Say cap before a capital", isOn: model.bool("speech", "sayCapForCapitals"))
                    .accessibilityLabel("Say cap before a capital")
                Slider(value: model.number("speech", "capitalPitch"), in: 0...100, step: 10) { Text("Raise the pitch for a capital") }
                    .accessibilityValue(model.number("speech", "capitalPitch").wrappedValue == 0 ? String(localized: "off", comment: "A setting that is off")
                        : String(localized: "\(Int(model.number("speech", "capitalPitch").wrappedValue)) percent", comment: "A slider's value"))
            }
            // The speech rotor's own short list (18 Oct 2026): none ticked, every voice.
            // Folded until opened: a picker per language is the costliest part of the pane to draw (23 Oct 2026).
            Toggle("Show voices for other languages", isOn: $showLanguages).accessibilityLabel("Show voices for other languages")
            if showLanguages {
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
            let rotorTitle = rotorChosen.isEmpty ? String(localized: "Show the voices in the rotor: every voice", comment: "A switch in Speech settings")
                : String(localized: "Show the voices in the rotor: \(String(rotorChosen.count)) chosen", comment: "A switch in Speech settings")
            Toggle(rotorTitle, isOn: $showRotor).accessibilityLabel(rotorTitle)
            if showRotor {
                Section(String(localized: "Natural voices in the rotor", comment: "A group in Speech settings")) {
                    Text(rotorChosen.isEmpty ? String(localized: "None ticked, VO-Command-Shift steps through every voice. Tick the ones you want.", comment: "Speech settings")
                         : String(localized: "\(String(rotorChosen.count)) ticked for VO-Command-Shift.", comment: "Speech settings")).font(.caption)
                    ForEach(naturalEntries, id: \.id) { v in rotorToggle(v.id, v.name) }
                }
                Section(String(localized: "Mac voices in the rotor", comment: "A group in Speech settings")) {
                    ForEach(rotorCandidates, id: \.identifier) { v in
                        rotorToggle(v.identifier, "\(v.name), \(Locale.current.localizedString(forIdentifier: v.language) ?? v.language)")
                    }
                }
            }
            // The natural voice (2 Nov 2026): chosen in Voice above for all speech, or here for say all only; its speed
            // and EQ.
            if model.special("_kokoroAvailable") as? Bool == true {
                let mode = model.special("_kokoroMode") as? String ?? "off"
                if model.special("_naturalDownloaded") as? Bool != false {
                    Section("Natural voice") {
                        if mode == "everything" {
                            Text("The voice above is a natural voice, so it speaks everything, with the rate, volume and EQ above. Other languages and raised capitals keep the Mac voice chosen before it, which also steps in if the natural voice is slow.").font(.caption)
                        } else {
                            Picker("Say all voice", selection: Binding(
                                get: { mode == "reading" ? (model.special("_kokoroVoice") as? String ?? "") : "same" },
                                set: { v in if v == "same" { model.setSpecial("_kokoroMode", "off") } else { model.setSpecial("_kokoroVoice", v); model.setSpecial("_kokoroMode", "reading") } })) {
                                Text("Same as speech").tag("same")
                                ForEach(natural, id: \.id) { Text($0.name).tag($0.id) }
                            }
                        }
                    }
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
            .accessibilityValue(rates[language.code] == nil ? String(localized: "\(String(Int(ratePercent.wrappedValue))), same as the main voice", comment: "A language's speech rate, when it is the main voice's") : "\(Int(ratePercent.wrappedValue))")
    }
}

/// Braille: starts with the one setting that had no control once the menu lost its settings (#27, 22 Oct 2026); the
/// rest of braille's settings, still in Tools, join it in their own change.
struct BrailleView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Picker("Panning moves the cursor", selection: model.string("braille", "panMovesCaret", "line")) {
                Text("Line by line").tag("line"); Text("To the text shown").tag("window"); Text("Off").tag("off")
            }
            Text("Panning on to another line moves the caret there, so the arrows carry on from what was read. Tethered to review, panning moves only the review cursor.").font(.caption)
        }.formStyle(.grouped).navigationTitle("Braille")
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
    /// "everywhere", or the bundle identifier of the app the list is for.
    @State private var scope = "everywhere"
    // The verbosity manager (27 Oct 2026): what is said about an item, in order, each piece on or off; one list for
    // everywhere and one for the app last in front, kept apart. The three old switches (help text, shortcut,
    // position) are rows of this list now. The names match Config.Verbosity.titles.
    private static let pieces = ["name", "role", "value", "state", "description", "shortcut", "position", "level"]
    private static var titles: [String: String] {
        ["name": String(localized: "Name", comment: "A piece of an item's announcement, in the reading order"), "role": String(localized: "Kind, such as button or link", comment: "A piece of an item's announcement, in the reading order"),
         "value": String(localized: "Value", comment: "A piece of an item's announcement, in the reading order"), "state": String(localized: "State, such as checked or expanded", comment: "A piece of an item's announcement, in the reading order"),
         "description": String(localized: "Help text", comment: "A piece of an item's announcement, in the reading order"), "shortcut": String(localized: "Keyboard shortcut", comment: "A piece of an item's announcement, in the reading order"),
         "position": String(localized: "Position, such as 3 of 10", comment: "A piece of an item's announcement, in the reading order"), "level": String(localized: "Level, in a tree or outline", comment: "A piece of an item's announcement, in the reading order")]
    }
    private var frontApp: (bundle: String, name: String)? {
        guard let d = model.special("_frontApp") as? [String: Any], let b = d["bundle"] as? String, let n = d["name"] as? String else { return nil }
        return (b, n)
    }
    private var everywhere: [String: Any] { model.get("presentation", "verbosity") as? [String: Any] ?? [:] }
    private var byApp: [String: Any] { model.get("presentation", "verbosityByApp") as? [String: Any] ?? [:] }
    private var ownList: Bool { scope == "everywhere" || byApp[scope] != nil }
    private var current: [String: Any] { scope == "everywhere" ? everywhere : (byApp[scope] as? [String: Any] ?? everywhere) }
    private var order: [String] {
        var o = (current["order"] as? [String] ?? []).filter { Self.pieces.contains($0) }
        for p in Self.pieces where !o.contains(p) { o.append(p) }
        return o
    }
    private var off: [String] { current["off"] as? [String] ?? [] }
    private func save(order: [String], off: [String]) {
        let v: [String: Any] = ["order": order, "off": off]
        if scope == "everywhere" { model.set("presentation", "verbosity", v) } else { var d = byApp; d[scope] = v; model.set("presentation", "verbosityByApp", d) }
    }
    private func move(_ piece: String, by delta: Int) {
        var o = order
        guard let i = o.firstIndex(of: piece), o.indices.contains(i + delta) else { return }
        o.swapAt(i, i + delta)
        save(order: o, off: off)
    }
    var body: some View {
        Form {
            Section("What is said about an item, in order") {
                Picker("For", selection: $scope) {
                    Text("Everywhere").tag("everywhere")
                    if let f = frontApp { Text(f.name).tag(f.bundle) }
                }
                if scope != "everywhere", !ownList {
                    Text("Using the everywhere list. A change here starts a list for this app.")
                }
                ForEach(Array(order.enumerated()), id: \.element) { i, piece in
                    let title = Self.titles[piece] ?? piece
                    HStack {
                        Toggle(title, isOn: Binding(get: { !off.contains(piece) }, set: { on in
                            var o = off.filter { $0 != piece }; if !on { o.append(piece) }; save(order: order, off: o)
                        }))
                        Spacer()
                        Button("Up") { move(piece, by: -1) }.disabled(i == 0).accessibilityLabel("Move \(title) up")
                        Button("Down") { move(piece, by: 1) }.disabled(i == order.count - 1).accessibilityLabel("Move \(title) down")
                    }
                }
                if scope != "everywhere", ownList {
                    Button("Use the everywhere list for this app") { var d = byApp; d[scope] = nil; model.set("presentation", "verbosityByApp", d) }
                }
            }
            // Another app came to the front while the list was for the one before: back to everywhere, so the controls
            // never edit an app the picker no longer names (a code review, 27 Oct 2026).
            .onChange(of: frontApp?.bundle) { _, now in if scope != "everywhere", scope != now { scope = "everywhere" } }
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
    private let kinds: [(String, String)] = [
        ("headings", String(localized: "Headings", comment: "A kind of element in Documents settings")), ("links", String(localized: "Links", comment: "A kind of element in Documents settings")),
        ("lists", String(localized: "Lists", comment: "A kind of element in Documents settings")), ("tables", String(localized: "Tables", comment: "A kind of element in Documents settings")),
        ("landmarks", String(localized: "Landmarks", comment: "A kind of element in Documents settings")), ("graphics", String(localized: "Graphics", comment: "A kind of element in Documents settings")),
        ("blockQuotes", String(localized: "Block quotes", comment: "A kind of element in Documents settings")), ("spellingErrors", String(localized: "Spelling errors", comment: "A kind of element in Documents settings"))]
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
            Toggle("Recognise again when the screen changes, while a result is open", isOn: model.bool("recognition", "autoRefresh"))
            Text("The window is looked at each second; when it has changed, what is new is read.").font(.caption)
            Toggle("Read the whole result as it opens", isOn: model.bool("recognition", "autoSayAll"))
            // macOS 26 and later only: earlier, recognition reads text alone (ScreenInterface needs Vision's newer readers).
            if #available(macOS 26.0, *) {
                Text("Press the screen recognition key twice (VO-Shift-Y, or TurnOver R) for the window's controls: each row is one, such as \"Save, button\", and Return clicks it. Pressed once, it reads the text.").font(.caption)
            }
            Toggle("After Return clicks something, recognise again", isOn: model.bool("recognition", "refreshAfterClick"))
            Text("The screen that follows a click is read without pressing the key again; off, the result closes after the click.").font(.caption)
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
            // Steam's switch: every setting has a place in this window (21 Oct 2026), and Big Picture reading, off
            // since it became a choice on 21 Oct, couldn't be found (the maintainer, 25 Oct 2026). Its Games item in the
            // TurnOver menu's Tools went on 2 Nov 2026: game reading is always on. Saved in the settings file, so it
            // holds across restarts.
            Section("Steam") {
                Toggle("Read Steam's Big Picture", isOn: model.bool("games", "readBigPictureChosen"))
                    .accessibilityLabel("Read Steam's Big Picture")
                    .accessibilityHint("Makes Steam open a debugging port on this Mac while it runs, which other programs here could use too.")
                Text("Big Picture makes Steam open a debugging port on this Mac while it runs, which other programs here could use too. Off removes it. Steam needs restarting after this is turned on.").font(.caption)
                Button("Restart Steam") { model.setSpecial("_restartSteam", true) }
            }
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
    var body: some View {
        Form {
            Section("Starting") {
                Toggle("Open TurnOver at login", isOn: model.bool("general", "openAtLogin"))
                Toggle("Show TurnOver in the menu bar", isOn: model.bool("general", "showInMenuBar"))
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

/// Everything TurnOver plays, in one place (Oliver, 2 Nov 2026), as NVDA's Audio panel: whose sounds, the hand-over,
/// progress bars, and other apps' sound lowered while TurnOver speaks. Audio graphs will join them.
struct SoundsView: View {
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
    /// Whose sounds: the file keeps "" until one is chosen, so the pop-up shows what plays meanwhile, as TurnOver works it
    /// out (Config.General.effectiveSounds; it showed nothing chosen, a review, 2 Nov 2026).
    private var whose: Binding<String> {
        Binding(get: {
            let s = model.get("general", "sounds") as? String ?? ""
            return s.isEmpty ? model.special("_effectiveSounds") as? String ?? "voiceover" : s
        }, set: { model.set("general", "sounds", $0) })
    }
    var body: some View {
        Form {
            Picker("Whose sounds", selection: whose) {
                Text("VoiceOver's").tag("voiceover"); Text("TurnOver's").tag("turnover")
            }
            Text("VoiceOver's: VoiceOver's own sounds where it has one, such as links and boundaries, and TurnOver's set for the rest. TurnOver's: its set throughout.").font(.caption)
            Toggle("Sounds as I move and press", isOn: model.bool("general", "navigationSounds"))
            Picker("When TurnOver takes over from VoiceOver", selection: handOver) {
                Text("Words").tag("words"); Text("A sound").tag("sound"); Text("Nothing").tag("nothing")
            }
            Picker("Progress bars", selection: model.string("presentation", "progressBars", "beep")) {
                Text("Beep").tag("beep"); Text("Speak the percentage").tag("speak"); Text("Beep and speak").tag("both"); Text("Off").tag("off")
            }
            Picker("Lower other sounds while TurnOver speaks", selection: model.string("speech", "ducking", "off")) {
                Text("No").tag("off"); Text("While speaking").tag("speech"); Text("Always").tag("always")
            }
        }.formStyle(.grouped).navigationTitle("Sounds")
    }
}

/// TurnOver is on or off; VoiceOver is on or off. The two things that relate them live here, and the experimental
/// readers per app, folded away (22 Oct 2026; last in the list, the place for the things most people never touch).
struct ReadersView: View {
    @EnvironmentObject var model: Model
    private var coexist: Binding<Bool> {
        Binding(get: { model.special("_coexist") as? Bool ?? false }, set: { model.setSpecial("_coexist", $0) })
    }
    var body: some View {
        Form {
            Section {
                // Named and described for accessibility explicitly: the long label came through empty, read as "switch, on"
                // with nothing said about what it does (25 Oct 2026), while the shorter one below was read.
                // One switch for the two readers swapping (25 Oct 2026: a second, for the quit alone, said the same by halves).
                Toggle("TurnOver and VoiceOver swap: one comes on as the other goes off", isOn: model.bool("applications", "swapWithVoiceOver"))
                    .accessibilityLabel("TurnOver and VoiceOver swap: one comes on as the other goes off")
                    .accessibilityHint("Off: each reader has its own switch and neither turns the other on or off; TurnOver is still quiet while VoiceOver is on.")
                Text("On: TurnOver turns VoiceOver off as it starts and on as it quits, comes on when VoiceOver turns off and steps aside when VoiceOver comes on. Off: each reader has its own switch and neither turns the other on or off, for VoiceOver reading inside a virtual machine such as Parallels. Either way one reader speaks at a time: while VoiceOver is on, TurnOver is quiet.").font(.caption)
            }
            // A plain section, not a disclosure group: the triangle took the focus but neither Return nor VO Space
            // opened it (Oliver, 28 Oct 2026: "I can't get into the experimental part").
            Section(header: Text("Experimental: readers per app, CoExist")) {
                Toggle("CoExist: VoiceOver stays running alongside TurnOver", isOn: coexist)
                Text("VoiceOver is kept quiet by an audio tap where TurnOver reads and keeps passwords and macOS's own prompts. Removed on 24 Oct 2026 and back as an experiment: it can leave a Mac silent if macOS asks for audio permission while VoiceOver is muted. Changing it restarts TurnOver.").font(.caption)
                Toggle("Readers per app", isOn: model.bool("applications", "perAppReaders"))
                Text("A list of apps for each reader, a mode (TurnOver in its apps, everywhere, or VoiceOver everywhere), and switching between the readers as you change apps. The list is under Tools in the TurnOver menu while this is on. Off, TurnOver reads everywhere while it is on.").font(.caption)
            }
        }.formStyle(.grouped).navigationTitle("Screen reader behaviour")
    }
}

/// The window's manners (25 Oct 2026, an AppleVis reader's first evening with the window): Escape closes it, as it
/// closes TurnOver's menu; the app goes with its last window, and with TurnOver, instead of lingering with no window
/// where only a force quit found it.
final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    private var escapeMonitor: Any?
    /// Looks at which TurnOver was missing. Main-actor isolated; a static, since the timer's closure
    /// may not carry the delegate itself (Swift 6).
    @MainActor private static var turnOverGoneChecks = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape with no modifier, outside a field being edited (there it cancels the edit) and with no menu open.
            guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  let window = NSApp.keyWindow, !(window.firstResponder is NSText), NSApp.mainMenu?.highlightedItem == nil else { return event }
            window.performClose(nil)
            return nil
        }
        // TurnOver gone for four seconds: the window closes with it. An update's restart closes it too, which is wanted:
        // a window left open through an update showed TurnOver as off until reopened (build 22).
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                // Either copy, the published TurnOver or TurnOver Developer (issue 248).
                let running = [ActiveReader.published, ActiveReader.developer].contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
                Self.turnOverGoneChecks = running ? 0 : Self.turnOverGoneChecks + 1
                if Self.turnOverGoneChecks >= 2 { NSApp.terminate(nil) }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TurnOverSettingsApp: App {
    @StateObject private var model = Model()
    @NSApplicationDelegateAdaptor(SettingsAppDelegate.self) private var delegate
    init() {
        // Tab reaches every control, pop-ups and sliders too, whatever the Mac's Keyboard navigation setting says: with
        // it off, a Tab through Speech met only the ducking pop-up (an AppleVis reader, 25 Oct 2026). This app's domain.
        UserDefaults.standard.set(2, forKey: "AppleKeyboardUIMode")
    }
    var body: some Scene {
        WindowGroup("TurnOver Settings") { ContentView().environmentObject(model) }
            .windowResizability(.contentSize)
    }
}
