// SPDX-License-Identifier: GPL-3.0-or-later
// App recipes (docs/APP-RECIPES-PLAN.md, 8 Oct 2026): an app described by data, not by code. A recipe names the parts
// of a shape TurnOver already drives (a chat app's message box, transcript and conversations) and how to tell its
// items; the view for that shape (ChatView, MediaView) does the work. A recipe is the "view" section of a plugin's
// profile.json (PLUGIN-GUIDE.md), applied to the apps the manifest names; TurnOver's own ship as files in
// Resources/recipes (a bundle, a name and a view). One that will not load is reported by name, never ignored.
import Foundation
import ApplicationServices

/// The "view" section: which shape, and its parts.
nonisolated public struct RecipeView: Codable {
    public var kind: String
    public var chat: Chat?
    public var panes: Panes?

    /// An app of named parts (a sidebar, a list, the detail, a toolbar): Tab and Shift Tab go round them in the
    /// order given, Command Control 1 to 9 straight to one. Each part is found by a match; a part that can take the
    /// keyboard gets it, a list that cannot is held by TurnOver's cursor (as Finder's sidebar), anything else is
    /// read by the cursor. The shape most Mac apps have (PanesView).
    public struct Panes: Codable {
        public var parts: [Part]
        public init(parts: [Part]) { self.parts = parts }
        public struct Part: Codable {
            public var name: String
            public var match: ElementMatch
            /// Said after the name the first time, how to use it ("Up and Down choose a folder").
            public var hint: String?
            public init(name: String, match: ElementMatch, hint: String? = nil) { self.name = name; self.match = match; self.hint = hint }
        }
    }
    public init(kind: String, chat: Chat? = nil, panes: Panes? = nil) { self.kind = kind; self.chat = chat; self.panes = panes }

    /// A chat app: the keyboard stays in the message box; Tab and Shift Tab take the cursor to the messages and the
    /// conversations (ChatView). The parts by accessibility identifier; the items by a match (the same matches as
    /// a profile's rules).
    public struct Chat: Codable {
        public var conversations: String
        public var transcript: String
        public var composer: String
        public var title: String
        public var sectionsPrefix: String?
        public var searchField: String?
        public var resultsPrefix: String?
        public var saysSent: Bool?
        public var message: ElementMatch
        public var conversation: ElementMatch
        /// Parts found by a match instead of an identifier, keyed "conversations", "transcript", "composer", "title":
        /// for chat apps built as web pages (Discord), whose parts have labels ("Messages in general") but no
        /// identifiers. A part with a match here ignores its identifier string. Recipes without it work as before.
        public var match: [String: ElementMatch]?
    }

    /// The shapes TurnOver has views for.
    public static let kinds = ["chat", "media", "panes"]

    /// The kind is known and its section is there.
    public func validate() throws {
        guard Self.kinds.contains(kind) else { throw RecipeError.unknownKind(kind) }
        if kind == "chat", chat == nil { throw RecipeError.missing("chat") }
        if kind == "panes" { guard let p = panes, !p.parts.isEmpty else { throw RecipeError.missing("panes with at least one part") } }
    }
}

/// A view for one app: TurnOver's own (a file), or a plugin's (its profile's view, for each app in its manifest).
nonisolated public struct Recipe: Codable {
    public var bundle: String
    public var name: String
    public var view: RecipeView
    public init(bundle: String, name: String, view: RecipeView) { self.bundle = bundle; self.name = name; self.view = view }
}

public enum RecipeError: Error { case missing(String), unknownKind(String) }

public enum Recipes {
    private static let lock = NSLock()
    private static var byBundle: [String: Recipe] = [:]
    /// Built-in files that would not load, by name, with the reason (plugins report their own).
    public private(set) static var problems: [(file: String, reason: String)] = []

    /// Load the built-in recipes, then the plugins' views over them (a plugin's recipe for WhatsApp replaces
    /// TurnOver's). Main thread, at start and whenever the plugins reload.
    /// `builtIn`: a folder of recipe files (the tests' copy); nil, the ones built into the program (make-embedded.py).
    public static func load(builtIn: URL? = nil, plugins: [LoadedPlugin]) {
        var found: [String: Recipe] = [:]
        var bad: [(String, String)] = []
        if builtIn == nil {
            for (name, packed) in EmbeddedResources.recipes {
                do {
                    guard let data = EmbeddedResources.unpack(packed) else { throw RecipeError.missing("data") }
                    let r = try parse(data: data); found[r.bundle] = r
                } catch { bad.append((name, describe(error))); Log.error("recipe \(name): \(describe(error))") }
            }
        }
        if let builtIn {
            let files = ((try? FileManager.default.contentsOfDirectory(at: builtIn, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do { let r = try parse(f); found[r.bundle] = r }
                catch { bad.append((f.lastPathComponent, describe(error))); Log.error("recipe \(f.lastPathComponent): \(describe(error))") }
            }
        }
        for p in plugins { for r in p.recipes { found[r.bundle] = r } }
        lock.lock(); byBundle = found; problems = bad; lock.unlock()
        Log.info("recipes: \(found.count) loaded (\(found.keys.sorted().joined(separator: ", ")))\(bad.isEmpty ? "" : "; \(bad.count) would not load")")
        BuiltInModules.registerRecipeApps()
    }

    /// One built-in file, checked.
    public static func parse(_ url: URL) throws -> Recipe { try parse(data: Data(contentsOf: url)) }

    public static func parse(data: Data) throws -> Recipe {
        let r = try JSONDecoder().decode(Recipe.self, from: data)
        if r.bundle.isEmpty { throw RecipeError.missing("bundle") }
        try r.view.validate()
        return r
    }

    public static func describe(_ e: Error) -> String {
        if case RecipeError.missing(let what) = e { return "no \"\(what)\" section" }
        if case RecipeError.unknownKind(let k) = e { return "\"\(k)\" is not a kind TurnOver knows (\(RecipeView.kinds.joined(separator: ", ")))" }
        if let d = e as? DecodingError { return ProfileStore.describe(d) }
        return e.localizedDescription
    }

    public static func recipe(for bundle: String) -> Recipe? { lock.lock(); defer { lock.unlock() }; return byBundle[bundle] }
    public static func bundles(kind: String) -> [String] { lock.lock(); defer { lock.unlock() }; return byBundle.values.filter { $0.view.kind == kind }.map(\.bundle).sorted() }
    public static var all: [Recipe] { lock.lock(); defer { lock.unlock() }; return byBundle.values.sorted { $0.name < $1.name } }
}

public extension ChatView.Spec {
    /// The spec a chat view section describes.
    init(_ c: RecipeView.Chat) {
        self.init(conversationsID: c.conversations, transcriptID: c.transcript, composerID: c.composer, titleID: c.title,
                  isMessage: { ElementMatcher.matches($0, c.message) }, isConversation: { ElementMatcher.matches($0, c.conversation) })
        sectionsPrefix = c.sectionsPrefix; searchFieldID = c.searchField; resultsPrefix = c.resultsPrefix; saysSent = c.saysSent ?? false
        let ids = ["conversations": c.conversations, "transcript": c.transcript, "composer": c.composer, "title": c.title]
        for (part, m) in c.match ?? [:] { if let id = ids[part] { partMatch[id] = { ElementMatcher.matches($0, m) } } }
    }
}
