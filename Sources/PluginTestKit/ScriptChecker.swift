// SPDX-License-Identifier: GPL-3.0-or-later
// turnover-plugin check, for a plugin with a script (docs/PLUGIN-SCRIPTS-PLAN.md, "Tools and tests for authors"; 15 Nov 2026).
//
// The script is loaded by the real sandboxed host program, with a broker that refuses everything, and what the host
// reports is read: it failed to load (a syntax error with its line, a command the manifest does not declare, an event the
// interface does not have), or it is ready with the events and commands it registered. Then the manifest's commands are
// compared with the script's. Last, a plain text search warns when the script seems to use something its manifest does not
// ask for; that part is a guess from the script's words, and says so.
import Foundation
import TurnOverCore

public enum ScriptChecker {
    public struct Report {
        public var problems: [String] = []
        public var warnings: [String] = []
        /// The events and commands the script registered, when it loaded.
        public var events: [String] = []
        public var commands: [String] = []
    }

    /// A broker that lets a script ask for nothing: the checker only wants to see what the script registers.
    private final class RefusingBroker: ScriptBroker {
        func perform(_ operation: ScriptOperation, _ arguments: ScriptValue) throws -> ScriptValue {
            throw ScriptBrokerError.refused("The checker answers no requests.")
        }
    }

    public static func check(_ plugin: LoadedPlugin, hostPath: String?) -> Report {
        var report = Report()
        guard let manifest = plugin.manifest, let source = plugin.script else { return report }
        let declared = (manifest.commands ?? []).map(\.id)
        if let hostPath {
            let host = ScriptHost(plugin: ScriptPluginInfo(id: manifest.id, name: manifest.name, version: manifest.version),
                                  abilities: ScriptAbilities.effective(for: plugin), commands: declared, source: source,
                                  hostPath: hostPath, broker: RefusingBroker())
            host.start()
            pumpRunLoop(6) { if case .starting = host.state { return false } else { return true } }
            switch host.state {
            case .failed(let message): report.problems.append("script: \(message)")
            case .starting: report.problems.append("script: it did not finish loading in 6 seconds (an endless loop at the top of main.js?)")
            case .ready, .paused:
                report.events = host.events; report.commands = host.commands
                for id in declared where !host.commands.contains(id) {
                    report.problems.append("command \(id) is in manifest.json, but the script never handles it: add turnover.command(\"\(id)\", function () { … })")
                }
                for id in host.commands where !declared.contains(id) {
                    report.problems.append("the script handles a command \(id) that manifest.json does not declare: add it to \"commands\"")
                }
                // A speech event is sent only to a plugin that may hear what TurnOver says.
                if host.events.contains("speech"), !ScriptAbilities.effective(for: plugin).contains(.hearSpeech) {
                    report.problems.append("the script handles \"speech\", but a plugin without \"hearSpeech\" in \"abilities\" is never sent it: add \"hearSpeech\"")
                }
                // A focus or value event carries the item, so TurnOver sends them only to a plugin that has `read`.
                if !ScriptAbilities.effective(for: plugin).contains(.read) {
                    for name in ["focus", "valueChange"] where host.events.contains(name) {
                        report.problems.append("the script handles \"\(name)\", but a plugin without \"read\" in \"abilities\" is never sent focus or value events (they carry the item): add \"read\"")
                    }
                }
            default: break
            }
            host.stop()
            pumpRunLoop(1) { !host.isRunning }
        } else {
            report.problems.append("script: TurnOver's script program (turnover-plugin-host) was not found beside this tool or in ../Helpers, so the script could not be loaded to check it")
        }
        report.warnings += abilityWarnings(source: source, granted: ScriptAbilities.effective(for: plugin))
        return report
    }

    /// What in the script's words suggests an ability, as (a pattern for the call, what it is called, the abilities it needs).
    private static let uses: [(pattern: String, member: String, needs: [ScriptAbility])] = [
        (#"\.\s*say\s*\("#, "say", [.say]), (#"\.\s*sound\s*\("#, "sound", [.say]), (#"\.\s*silence\s*\("#, "silence", [.say]),
        (#"\bturnover\s*\.\s*focused\s*\("#, "turnover.focused", [.read]), (#"\bturnover\s*\.\s*find\s*\("#, "turnover.find", [.read]),
        (#"\.\s*refresh\s*\("#, "refresh", [.read]), (#"\.\s*parent\s*\("#, "parent", [.read]), (#"\.\s*children\s*\("#, "children", [.read]),
        (#"\.\s*read\s*\("#, "read", [.read, .say]),
        (#"\.\s*press\s*\("#, "press", [.press]), (#"\.\s*focus\s*\("#, "focus", [.focus]),
        (#"\bturnover\s*\.\s*menu\s*\("#, "turnover.menu", [.menu]), (#"\bturnover\s*\.\s*keys\s*\("#, "turnover.keys", [.keys]),
        (#"\.\s*setValue\s*\("#, "setValue", [.edit]), (#"\bturnover\s*\.\s*copy\s*\("#, "turnover.copy", [.clipboard]),
        (#"\bturnover\s*\.\s*choose\s*\("#, "turnover.choose", [.say]), (#"\bturnover\s*\.\s*ask\s*\("#, "turnover.ask", [.say]),
        (#"\bturnover\s*\.\s*tone\s*\("#, "turnover.tone", [.say]),
        (#"\.\s*text\s*\(\s*\{"#, "text", [.read]), (#"\.\s*setCaret\s*\("#, "setCaret", [.edit]), (#"\.\s*select\s*\("#, "select", [.edit]),
        (#"\bturnover\s*\.\s*clipboard\s*\("#, "turnover.clipboard", [.clipboardRead]),
    ]

    /// Warnings for members the script seems to call whose ability the plugin does not have. A guess: the text is searched,
    /// not understood (a comment is skipped, but a method of another object with the same name is not told apart).
    public static func abilityWarnings(source: String, granted: Set<ScriptAbility>) -> [String] {
        let bare = source.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
        var warnings: [String] = []
        for use in uses where bare.range(of: use.pattern, options: .regularExpression) != nil {
            let missing = use.needs.filter { !granted.contains($0) }
            if missing.isEmpty { continue }
            let names = missing.map { "\"\($0.rawValue)\"" }.joined(separator: " and ")
            warnings.append("main.js seems to use \(use.member)(…), which needs \(names) in \"abilities\", and the manifest does not ask for it. This is a guess from the script's words; if it is right, add it, because without it the request is refused.")
        }
        return warnings
    }
}
