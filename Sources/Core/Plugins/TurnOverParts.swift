// SPDX-License-Identifier: GPL-3.0-or-later
// The parts this TurnOver has that plugin makers asked for, by a short name, so an AI making a plugin can tell
// whether a fix it asked for has reached its TurnOver: `turnover-plugin parts`. When a parts request on
// github.com/TurnOver-For-Mac/turnover-plugins is closed, the answer names the part (14 Oct 2026: the Outlook
// plugin session had no way to learn its fix had arrived, and build numbers don't say it on a test build).
import Foundation

public enum TurnOverParts {
    public static let all: [(name: String, what: String, request: Int?)] = [
        ("plugin-try", "turnover-plugin try: TurnOver presses keys in the app for an AI and reports what it said", nil),
        ("pane-focus-reports", "A nameless pane's focus report is ignored while the list, table or control TurnOver is on still has the keyboard (Outlook's reading pane)", 2),
        ("search-breadth-first", "Plugin rules are matched breadth first, never down a copy of the same element (Outlook's search field)", 2),
        ("hold-list", "A plugin's hold rule: TurnOver walks a list that reports nothing as the arrows move, and Return presses the row (Libation's book grid)", 4),
        ("name-from-further", "nameFrom: nextText and previousText look beside the elements it sits in, up to six levels; ancestorHelp; rowText (Libation)", 5),
        ("class-name-titles", "A title that is only a class name (Avalonia.Controls.Grid) is no name: not read, and matched by unnamed (Libation)", 5),
        ("incrementor-value", "An empty number box reads its spinner's number (Avalonia's NumericUpDown, Libation)", 5),
        ("check-patience", "turnover-plugin check searches up to six seconds, for slow, deep apps (Libation)", 6),
        ("view-reload", "A plugin's view removed at a reload stops at once, without quitting the app (Libation)", 6),
        ("read-separates-texts", "A read key, a watch with read text, and names from child text give each of a group's texts its own phrase, with a comma between, outside web pages (Asobi's game card)", 3),
    ]
}
