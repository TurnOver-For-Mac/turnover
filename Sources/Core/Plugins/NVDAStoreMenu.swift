// SPDX-License-Identifier: GPL-3.0-or-later
// "NVDA add-ons" in the Plugins menu (docs/PLUGIN-PLATFORM-PLAN.md, stage A; 16 Nov 2026): find an add-on in NVDA's store, and
// convert it into a draft plugin that your own AI tool (Claude, ChatGPT, Gemini) or you finish.
//
// TurnOver the screen reader does no networking and no parsing here: every step is the bundled turnover-plugin tool, run as a
// separate program (NVDAStore.swift). Nothing is asked of the store until the person has said yes, once; the yes is a setting
// that can be turned off again. Nothing is installed or approved by any of this: the result is a folder in ~/TurnOver Plugins,
// handed over the way "Make a plugin" hands over.
import Foundation
import AppKit

enum NVDAStoreMenu {

    /// The items of the "NVDA add-ons" submenu.
    static func items() -> [MenuItem] {
        let connected = config.pluginSources.connectToNVDAStore
        let named = config.pluginSources.convertedBy
        return [
            MenuItem("Search NVDA's add-ons", .action { DispatchQueue.main.async { search() } },
                     hint: "Type some words; TurnOver asks NVDA's store and lists what matches"),
            MenuItem("All NVDA's add-ons", .action { DispatchQueue.main.async { showAll() } },
                     hint: "The whole list, by name. Type the first letters of a name to jump to it"),
            MenuItem("Ask NVDA's store for its list of add-ons", .toggle(get: { config.pluginSources.connectToNVDAStore }, set: { setConnected($0) }),
                     hint: connected ? "On. Turn it off and TurnOver asks nothing of NVDA's store. Only the request is sent: nothing about you or your Mac"
                                     : "Off. When it is on, TurnOver fetches the list of add-ons from NVDA's store on the internet. Only the request is sent: nothing about you or your Mac"),
            MenuItem(verbatim: named.isEmpty ? String(localized: "Name to credit for converted add-ons: not set", comment: "A Plugins menu item; the name is asked when first needed")
                                              : String(localized: "Name to credit for converted add-ons: \(named)", comment: "A Plugins menu item; the placeholder is the name"),
                     .action { DispatchQueue.main.async { askName { _ in } } },
                     hint: "Written into a converted plugin as the person who converted it, and read at approval"),
        ]
    }

    // MARK: The yes, asked once

    static func setConnected(_ on: Bool) {
        config.pluginSources.connectToNVDAStore = on
        config.save()
        Log.info("nvda store: asking the store is now \(on ? "on" : "off")")
    }

    /// Runs `then` if the person has said yes; otherwise asks, with "Not now" first so a quick Return agrees to nothing.
    static func whenConnected(_ then: @escaping () -> Void) {
        if config.pluginSources.connectToNVDAStore { then(); return }
        TurnOverMenu.shared.openList(verbatim: String(localized: "TurnOver will fetch the list of add-ons from NVDA's store on the internet. Nothing about you or your Mac is sent beyond the request itself. Connect?", comment: "The question asked once before NVDA's add-on store is used"), items: [
            MenuItem("Not now", .action { Speech.speakMessage(String(localized: "Nothing was asked of NVDA's store.", comment: "Said after Not now to connecting to NVDA's store")) },
                     hint: "Asked again the next time"),
            MenuItem("Connect", .action { setConnected(true); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { then() } },
                     hint: "Turns on Ask NVDA's store for its list of add-ons in this menu, which you can turn off again"),
        ])
    }

    // MARK: Searching

    static func search() {
        whenConnected {
            LineInput.ask(String(localized: "Words to search NVDA's add-ons for", comment: "Asking for a search of NVDA's add-on store")) { text in
                guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                load(search: text)
            }
        }
    }

    static func showAll() { whenConnected { load(search: nil) } }

    /// The tool is run off the main thread, with a soft tick each second so the wait is not silence (as the briefs do).
    private static func inBackground<T: Sendable>(_ work: @escaping @Sendable () -> T, then: @escaping @MainActor (T) -> Void) {
        let done = Locked(false)
        func tick() { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if !done.value { Tones.beep(880, 30, volume: 0.1); tick() } } }
        tick()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async { done.value = true; then(result) }
        }
    }

    static func load(search: String?) {
        Speech.speakMessage(String(localized: "Asking NVDA's store", comment: "Said while NVDA's add-on store is asked"))
        let connected = config.pluginSources.connectToNVDAStore
        inBackground({ NVDAStore.fetchList(search: search, connected: connected, run: { ToolProcess.run($0, timeout: $1) }) }) { result in
            switch result {
            case .failure(let f): Speech.speakMessage(f.words)
            case .success(let found):
                if found.isEmpty { Speech.speakMessage(search.map { String(localized: "No add-on on NVDA's store matches \($0).", comment: "A search of NVDA's add-on store found nothing; the placeholder is the words") } ?? String(localized: "NVDA's store list was empty.", comment: "The store list had nothing in it")); return }
                let title = search.map { String(localized: "NVDA add-ons matching \($0)", comment: "A list of NVDA add-ons; the placeholder is the search words") } ?? String(localized: "NVDA add-ons", comment: "A list of every NVDA add-on")
                TurnOverMenu.shared.openList(verbatim: title, items: found.map { i in
                    MenuItem(verbatim: NVDAStore.title(i), .action { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { details(i) } }, hint: NVDAStore.hint(i))
                })
            }
        }
    }

    // MARK: One add-on

    static func details(_ item: NVDAStore.Item) {
        Speech.speakMessage(String(localized: "Asking NVDA's store about \(item.name)", comment: "Said while the store is asked about one add-on; the placeholder is its name"))
        let connected = config.pluginSources.connectToNVDAStore
        inBackground({ NVDAStore.fetchDetail(id: item.id, connected: connected, run: { ToolProcess.run($0, timeout: $1) }) }) { result in
            switch result {
            case .failure(let f): Speech.speakMessage(f.words)
            case .success(let d):
                var list: [MenuItem] = [MenuItem(verbatim: String(localized: "About \(d.item.name)", comment: "An item that reads out the details of an NVDA add-on; the placeholder is its name"),
                                                 .select { Speech.speakMessage(NVDAStore.facts(d)) },
                                                 hint: String(localized: "Reads its version, author, licence and source, and whether it can come across", comment: "Hint for the About item"))]
                for ai in PluginAI.allCases {
                    list.append(MenuItem("Convert with \(ai.rawValue)", .action { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { convert(d.item, with: ai) } },
                                         hint: "Makes a draft plugin in a new folder in TurnOver Plugins, and gives it to \(ai.rawValue) to finish. Nothing is installed or approved"))
                }
                list.append(MenuItem("Convert it myself", .action { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { convert(d.item, with: nil) } },
                                     hint: "Makes a draft plugin in a new folder in TurnOver Plugins and opens it, with a brief for finishing it yourself. Nothing is installed or approved"))
                TurnOverMenu.shared.openList(verbatim: String(localized: "\(d.item.name)", comment: "The list for one NVDA add-on; the placeholder is its name"), items: list)
            }
        }
    }

    // MARK: The name to credit

    /// The name kept in settings, or asked for once. Escape or nothing typed cancels.
    static func askName(then: @escaping (String?) -> Void) {
        let kept = config.pluginSources.convertedBy
        LineInput.ask(String(localized: "Your name, to credit as the person who converted it. It goes into the plugin and is read at approval", comment: "Asking who to credit for a conversion"), initial: kept) { text in
            let name = NVDAStore.creditName(text ?? "")
            guard !name.isEmpty else { Speech.speakMessage(String(localized: "No name given.", comment: "Said when the credit name was left empty")); then(nil); return }
            config.pluginSources.convertedBy = name
            config.save()
            Speech.speakMessage(String(localized: "Credited as \(name).", comment: "Said after the credit name is kept; the placeholder is the name"))
            then(name)
        }
    }

    // MARK: Converting

    static func convert(_ item: NVDAStore.Item, with ai: PluginAI?) {
        let name = config.pluginSources.convertedBy
        guard !NVDAStore.creditName(name).isEmpty else {
            askName { given in if given != nil { convert(item, with: ai) } }
            return
        }
        Speech.speakMessage(String(localized: "Converting \(item.name). This can take a while", comment: "Said while an NVDA add-on is converted; the placeholder is its name"))
        let connected = config.pluginSources.connectToNVDAStore
        let base = PluginBrief.briefsFolder
        inBackground({ NVDAStore.convert(item, convertedBy: name, base: base, connected: connected, run: { ToolProcess.run($0, timeout: $1) }) }) { outcome in
            switch outcome {
            case .failed(let f): Speech.speakMessage(f.words)
            case .nothingToConvert(let folder):
                Speech.speakMessage(String(localized: "Nothing in \(item.name) can come across to the Mac, so no plugin was made. The report is CONVERSION.md in \(folder.path). Nothing is installed or approved.", comment: "An add-on could not be converted; the placeholders are its name and the folder"))
            case .made(let folder):
                let handed = PluginAI.handOver(ai, folder: folder, task: "finish translating this NVDA add-on into a TurnOver plugin", chatText: PluginBrief.conversionChatText(folder: folder))
                Log.info("nvda store: \(item.id) converted into \(folder.lastPathComponent): \(handed.opened ? "handed over" : "not handed over")")
                Speech.speakMessage(String(localized: "\(item.name) is converted into a draft in \(folder.path). The translation is not reviewed.", comment: "An add-on was converted; the placeholders are its name and the folder") + " " + handed.words)
            }
        }
    }
}
