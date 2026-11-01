// SPDX-License-Identifier: GPL-3.0-or-later
// Excel's NVDA keys in the Windows style (the parity audit, 13 Oct 2026; NVDA's Commands Quick Reference, Excel):
//   NVDA+Alt+C   the cell's note; twice, the note in a list to read line by line.
//   NVDA+F7      Excel's elements list: the sheets, and the cells with notes; Enter goes there.
//   NVDA+Space   NVDA's way over protected cells: the arrows read the cells around, Excel's keys can't reach them
//                (a locked sheet that won't let them be selected); Escape or NVDA+Space again ends.
// Through Excel's AppleScript (its notes are "Excel comment" there), off the main thread. The first use brings up
// macOS's question whether TurnOver may control Excel, as Word's commands do.
import Foundation
import AppKit

extension ExcelAppModule {
    nonisolated private static let queue = DispatchQueue(label: "turnover.excelscript", qos: .userInitiated)

    nonisolated static func run(_ body: String) -> String? {
        var error: NSDictionary?
        let r = NSAppleScript(source: "with timeout of 60 seconds\ntell application \"Microsoft Excel\"\n\(body)\nend tell\nend timeout")?.executeAndReturnError(&error)
        if let error {
            Log.warning("Excel script error: \(error[NSAppleScript.errorNumber] ?? "?")")
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                onMain { Speech.speakMessage(String(localized: "TurnOver needs permission to control Excel. In System Settings, Privacy and Security, Automation, turn on Microsoft Excel under TurnOver.", comment: "Spoken message")) }
            }
            return nil
        }
        return r?.stringValue
    }

    func declareNVDAKeys() {
        let windows: () -> Bool = { config.general.windowsKeys }
        script("excel_note", String(localized: "Reports the cell's note; twice, shows it to read line by line (NVDA+Alt+C)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+option+c", "kb:turnover+command+c"], category: "Microsoft Excel") { _ in
            let twice = ScriptHandler.lastScriptRepeatCount > 0
            Self.queue.async {
                let note = Self.run("try\nreturn Excel comment text (Excel comment of active cell)\non error\nreturn \"\"\nend try") ?? ""
                onMain {
                    guard !note.isEmpty else { Speech.speakMessage(String(localized: "no note", comment: "Spoken message")); return }
                    if twice {
                        TurnOverMenu.shared.openList("Note", items: note.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { MenuItem(verbatim: $0, .action {}) })
                    } else { Speech.speakMessage(note) }
                }
            }
        }.isAvailable = windows
        script("excel_elementsList", String(localized: "Elements list; lists the workbook's sheets and the cells with notes; Enter goes there (NVDA+F7)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+f7"], category: "Microsoft Excel") { _ in
            Speech.speakMessage(String(localized: "elements", comment: "Spoken message"))
            Self.queue.async {
                let sheets = (Self.run("return name of every worksheet of active workbook as list") ?? "")
                let sheetList = Self.run("set out to \"\"\nrepeat with s in (every worksheet of active workbook)\nset out to out & name of s & linefeed\nend repeat\nreturn out") ?? sheets
                let notes = Self.run("""
                    set out to ""
                    repeat with c in (every Excel comment of active sheet)
                        set out to out & (get address of (parent of c) without row absolute and column absolute) & tab & (Excel comment text c) & linefeed
                    end repeat
                    return out
                    """) ?? ""
                onMain {
                    var items: [MenuItem] = []
                    for name in sheetList.components(separatedBy: .newlines) where !name.isEmpty {
                        items.append(MenuItem("Sheet \(name)", .action {
                            Self.queue.async { _ = Self.run("activate object worksheet \"\(name.replacingOccurrences(of: "\"", with: "\\\""))\" of active workbook") }
                        }))
                    }
                    for line in notes.components(separatedBy: .newlines) where !line.isEmpty {
                        let parts = line.components(separatedBy: "\t")
                        let address = parts[0], text = parts.dropFirst().joined(separator: " ")
                        items.append(MenuItem("Note at \(address): \(text)", .action {
                            Self.queue.async { _ = Self.run("select range \"\(address)\" of active sheet") }
                        }))
                    }
                    if items.isEmpty { Speech.speakMessage(String(localized: "no sheets or notes found", comment: "Spoken message")); return }
                    TurnOverMenu.shared.openList("Elements", items: items)
                }
            }
        }.isAvailable = windows
        script("excel_reviewCells", String(localized: "Cell review; reads the cells around with the arrows, protected ones too; Escape stops (NVDA+Space in Excel)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+space"], category: "Microsoft Excel") { _ in
            Self.queue.async {
                let at = Self.run("return (first row index of active cell as text) & \",\" & (first column index of active cell as text)") ?? "1,1"
                let n = at.split(separator: ",").compactMap { Int($0) }
                onMain { Self.reviewCells(row: n.first ?? 1, column: n.count > 1 ? n[1] : 1) }
            }
        }.isAvailable = windows
    }

    /// The cell review: arrows move a cursor of TurnOver's over the sheet, reading each cell; nothing is selected.
    static func reviewCells(row: Int, column: Int) {
        Speech.speakMessage(String(localized: "cell review. Arrows read the cells; Escape stops", comment: "Spoken message"))
        func read(_ r: Int, _ c: Int) {
            queue.async {
                let v = run("return (string value of cell \(c) of row \(r) of active sheet)") ?? ""
                onMain { Speech.speakMessage("\(v.isEmpty ? Phrases.blank : v), \(ExcelAppModule.address(r, c))") }
            }
        }
        read(row, column)
        func next(_ r: Int, _ c: Int) {
            InputManager.captureNext = { g in
                guard let g, !["escape", "space"].contains(g.keyName) || (g.keyName == "space" && !g.modifiers.contains(.turnover)) else { Speech.speakMessage(String(localized: "cell review off", comment: "Spoken message")); return }
                var r2 = r, c2 = c
                switch g.keyName {
                case "upArrow": r2 = max(1, r - 1)
                case "downArrow": r2 = r + 1
                case "leftArrow": c2 = max(1, c - 1)
                case "rightArrow": c2 = c + 1
                default: Tones.edge(); next(r, c); return
                }
                if r2 == r && c2 == c { Tones.edge() } else { read(r2, c2) }
                next(r2, c2)
            }
        }
        next(row, column)
    }
}
