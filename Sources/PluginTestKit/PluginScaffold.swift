// SPDX-License-Identifier: GPL-3.0-or-later
// turnover-plugin new: a working plugin to start from, with comments that teach (docs/PLUGIN-SCRIPTS-PLAN.md, "Tools and
// tests for authors"; 15 Nov 2026). The files are written by hand here so their comments are the author's first lesson;
// every file loads and, with --script, its first test passes.
import Foundation
import TurnOverCore

public enum PluginScaffold {
    public struct Failure: Error, CustomStringConvertible { public let description: String }

    /// A plugin id from a folder's name: lower-case letters, digits and hyphens.
    public static func identifier(from folderName: String) -> String {
        let words = folderName.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let id = words.joined(separator: "-")
        return id.isEmpty ? "my-plugin" : String(id.prefix(64))
    }

    /// Write the plugin into `folder` (which must be new, or empty). Returns the files written, relative to it.
    @discardableResult
    public static func make(folder: URL, app: String, script: Bool) throws -> [String] {
        guard app.contains("."), !app.contains(" "), !app.contains("*") else {
            throw Failure(description: "--app wants a bundle identifier such as com.apple.calculator, not \"\(app)\"")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path), !((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty {
            throw Failure(description: "\(folder.path) is not empty; make a plugin in a new folder")
        }
        let id = identifier(from: folder.lastPathComponent)
        let name = id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        var files: [(String, String)] = [("manifest.json", script ? scriptManifest(id: id, name: name, app: app) : dataManifest(id: id, name: name, app: app)),
                                         ("profile.json", script ? scriptProfile : dataProfile)]
        if script {
            files += [("main.js", mainScript(name: name)), ("tests/script/first.json", firstTest(name: name))]
        } else {
            files += [("tests/expect.json", dataTests)]
        }
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return files.map(\.0)
    }

    // MARK: Files

    private static func dataManifest(id: String, name: String, app: String) -> String {
        """
        // manifest.json: who made this plugin, and which app it is for. Comments like these are allowed in TurnOver's
        // plugin files; TurnOver ignores them.
        {
          "id": "\(id)",            // letters, digits and hyphens; also the plugin's folder name once installed
          "name": "\(name)",
          "version": "0.1",
          // The apps the plugin works in, by bundle identifier. Nothing applies anywhere else.
          "apps": ["\(app)"],
          // What the rules in profile.json do, in TurnOver's fixed words: read, press, focus, menu, keys, say.
          // `turnover-plugin check` tells you if this list and the rules disagree.
          "abilities": ["read"]
        }

        """
    }

    private static let dataProfile = """
        // profile.json: the rules. Each list is optional. Run `turnover-plugin snapshot <app>` to see the app's items, and
        // `turnover-plugin check <this folder>` after each change.
        {
          // Give an item a name when the app gives it none. "unnamed": true keeps the rule from renaming items that
          // already have a name. Remove the // from the next lines and put in an identifier from the snapshot:
          "labels": [
            // { "match": { "role": "AXButton", "identifier": "some-identifier", "unnamed": true }, "name": "Save" }
          ],
          // A key of its own, as TurnOver writes keys: "turnover+shift+p". It needs a description.
          "keys": [
            // { "key": "turnover+shift+p", "description": "Press the Play button", "action": "press",
            //   "target": { "role": "AXButton", "identifier": "play" }, "letter": "p" }
          ]
        }

        """

    private static let dataTests = """
        // tests/expect.json: checks that run without the app, against screens recorded with
        // `turnover-plugin record <app> <this folder>` (they are written to tests/ as screen-1.json and so on).
        // Each check says which item on which screen, and what TurnOver must say for it:
        //   { "name": "the save button is named", "screen": "screen-1.json",
        //     "item": { "role": "AXButton", "identifier": "save" }, "says": "^Save, button" }
        // Run them with `turnover-plugin test <this folder>`.
        []

        """

    private static func scriptManifest(id: String, name: String, app: String) -> String {
        """
        // manifest.json: who made this plugin, which app it is for, and what its script may do. Comments like these are
        // allowed in TurnOver's plugin files; TurnOver ignores them.
        {
          // 2 because this plugin has a script. A plugin with only rules in profile.json can leave this out.
          "formatVersion": 2,
          "id": "\(id)",            // letters, digits and hyphens; also the plugin's folder name once installed
          "name": "\(name)",
          "version": "0.1",
          // Say in a sentence what the plugin is for. Whoever installs it hears this, marked as your words.
          "description": "Says what the \(name) plugin is for.",
          // The apps the script works in, by bundle identifier. A script must name them: no patterns.
          "apps": ["\(app)"],
          // What the script may do, which the person is asked to agree to in plain words. Ask for as little as you can:
          // read (see items), say (speak), press, focus, menu, keys, edit (change a field), clipboard (put text on it).
          // A request for something not listed here is refused, and the error says which ability to add.
          "abilities": ["say"],
          // The script is always main.js, next to this file.
          "script": "main.js",
          // The commands the script handles. They are listed here, not found by running the script, so TurnOver can show
          // them, check their keys and let the person change them. "id" is letters and digits only; it is the name the
          // script uses. A "key" (such as "turnover+control+shift+h") and a "letter" in the plugin layer are optional.
          "commands": [
            { "id": "hello", "description": "Say hello", "letter": "h" }
          ]
        }

        """
    }

    private static let scriptProfile = """
        // profile.json: rules that need no code (names for items, keys that press things). A plugin with a script may have
        // none, and the script and these rules are approved together. This one is empty.
        {
        }

        """

    private static func mainScript(name: String) -> String {
        """
        // main.js: the script for \(name).
        //
        // It runs in a sandbox, apart from TurnOver. It cannot use the internet, files or other programs; it can only ask
        // TurnOver, through the `turnover` object, for what the manifest's "abilities" allow. Every request is checked.
        //
        // After a change, run `turnover-plugin check <this folder>` and `turnover-plugin test <this folder>`.

        // An event: TurnOver tells the script when the focus lands on an item. The words must be decided before the
        // handler returns (before its first `await`), from the item it was given:
        //   event.say("words")  says these in place of what TurnOver would say (needs "say")
        //   event.silence()     says nothing for this item (needs "say")
        //   neither             TurnOver reads the item as usual
        turnover.on("focus", function (event) {
          const item = event.item;
          if (item.role === "button" && item.name === "") {
            event.say("Unlabelled button");   // change this to something useful for your app
          }
        });

        // A command, declared in manifest.json. TurnOver calls this when the person chooses it. The handler may be
        // `async` and `await` what TurnOver answers (turnover.find, item.press and so on, each with its ability).
        turnover.command("hello", function (context) {
          turnover.say("Hello from " + turnover.plugin.name);   // turnover.say adds to what TurnOver says; it does not replace it
        });

        """
    }

    private static func firstTest(name: String) -> String {
        """
        // tests/script/first.json: runs the script in the real sandbox with no app. Each step is an event or a command,
        // with the item it carries, the answers TurnOver would give to anything the script asks, and what to expect:
        //   "say"  what the script made TurnOver say for the item ("" is silence, null is TurnOver's own words)
        //   "said" what the script spoke itself with turnover.say, in order
        // Run it with `turnover-plugin test <this folder>`.
        {
          "name": "an unlabelled button is announced, and hello is said",
          "steps": [
            { "event": "focus", "item": { "role": "button", "name": "" }, "expect": { "say": "Unlabelled button" } },
            { "event": "focus", "item": { "role": "button", "name": "Save" }, "expect": { "say": null } },
            { "command": "hello", "expect": { "said": ["Hello from \(name)"] } }
          ]
        }

        """
    }
}
