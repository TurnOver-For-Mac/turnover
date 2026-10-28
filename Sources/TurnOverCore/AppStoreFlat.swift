// SPDX-License-Identifier: GPL-3.0-or-later
// The App Store's search results page on the flat view (docs/FLAT-VIEW-PLAN.md, step 3; 27 Oct 2026): the first
// area to leave its hand-made reading behind. Behind the developer switch `flatView`; AppStoreView keeps its keys,
// its waits and the rest of its pages.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

final class AppStoreFlatAdapter: FlatAdapter {
    let pid: pid_t
    init(pid: pid_t) { self.pid = pid }
    nonisolated let settleTimes: [Double] = [0.7, 1.5]

    /// The results list: an AXList (subrole AXCollectionList) identified AppStore.search.result in the front window.
    nonisolated func areaRoot() -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)   // never the system's six seconds while the Store is busy
        guard let w = app.element(kAXFocusedWindowAttribute) ?? app.elements(kAXWindowsAttribute).first else { return nil }
        AXUIElementSetMessagingTimeout(w, 0.3)
        return AppStoreView.first(in: w, depth: 6) { AXUIElementSetMessagingTimeout($0, 0.3); return $0.role == "AXList" && $0.string(kAXIdentifierAttribute) == "AppStore.search.result" }
    }
    nonisolated func isItem(_ e: AXUIElement) -> Bool { AppStoreView.isItem(e) }
    /// The app's name as the Store names the tile (the first named thing inside that is not artwork or the offer
    /// button); nil while the Store answers blank.
    nonisolated func name(for e: AXUIElement) -> String? {
        let n = (AppStoreView.identity(of: e).components(separatedBy: ",").first ?? "").trimmingCharacters(in: .whitespaces)
        if n.isEmpty { Self.diagnose(e) }
        return n.isEmpty ? nil : n
    }

    /// Diagnose this reader process's missing row name without bypassing its AXHealth rest or copying all children.
    /// Status and presence only: identifiers and title/description strings may contain private content (issue 166).
    nonisolated(unsafe) private static var lastDiagnosis = Date.distantPast   // every read/write holds diagLock
    private static let diagLock = NSLock()
    nonisolated static func diagnose(_ e: AXUIElement) {
        diagLock.lock(); let due = Date().timeIntervalSince(lastDiagnosis) > 2; if due { lastDiagnosis = Date() }; diagLock.unlock()
        guard due else { return }
        var budget = AXProbeBudget(maximumQueries: 5, durationNanoseconds: 100_000_000)
        defer {
            _ = budget.canContinue()
            Log.io("flat view diagnosis: sampledQueries=\(budget.queries) stop=\(budget.stopped?.rawValue ?? "sampleFinished") providerTreeComplete=false")
        }
        guard budget.beginQuery() else { return }
        let count = e.attributeValueCountResult(kAXChildrenAttribute, policy: .respectBackoff)
        Log.io("flat view diagnosis: healthScope=currentProcess clientPID=\(getpid()) childrenCount=\(count.value.map(String.init) ?? "unknown") \(AXDiagnosticReport.outcome(count))")
        guard !AXDiagnosticReport.shouldStop(count.status), count.value.map({ $0 > 0 }) ?? true, budget.beginQuery() else { return }
        let prefix = e.attributeValuesResult(kAXChildrenAttribute, index: 0, maxValues: 1, policy: .respectBackoff)
        Log.io("flat view diagnosis: childrenPrefix(max=1) \(AXDiagnosticReport.outcome(prefix))")
        guard !AXDiagnosticReport.shouldStop(prefix.status), let raw = prefix.value,
              let child = AXDiagnosticReport.elements(in: raw, maximum: 1).values.first else { return }
        guard budget.beginQuery() else { return }
        let timeout = AXUIElementSetMessagingTimeout(child, 0.05)
        Log.io("flat view diagnosis: sampledChild timeoutConfiguration=\(describeError(timeout)) requestedMs=50")
        guard timeout == .success else { return }
        for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
            guard budget.beginQuery() else { return }
            let result = child.attributeResult(name, policy: .respectBackoff)
            Log.io("flat view diagnosis: sampledChild \(name) \(AXDiagnosticReport.outcome(result)) presence=\(AXDiagnosticReport.stringPresence(result.value))")
            if AXDiagnosticReport.shouldStop(result.status) { return }
        }
    }
    /// The tile's title as the Store gives it (name, subtitle, stars) and its button.
    nonisolated func label(for e: AXUIElement, name: String) -> String {
        let full = AppStoreView.identity(of: e)
        let offer = AppStoreView.first(in: e, depth: 4) { ($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") }
            .flatMap { $0.string(kAXTitleAttribute) ?? $0.string(kAXDescriptionAttribute) } ?? ""
        let base = full.isEmpty ? name : full
        // (The Store's own title already ends with the button's wording on some rows: not twice.)
        return offer.isEmpty || base.hasSuffix(offer) || base.contains(", \(offer),") ? base : "\(base), \(offer)"
    }
    /// The icon's middle, else the tile's left edge (as AppStoreView.clickIcon chooses).
    nonisolated func clickPoint(for e: AXUIElement) -> CGPoint? {
        guard let f = TurnOverObject.frame(e) else { return nil }
        let icon = AppStoreView.first(in: e, depth: 5) { $0.role == "AXImage" && ($0.string(kAXDescriptionAttribute) ?? "Artwork") != "Artwork" }.flatMap { TurnOverObject.frame($0) }
        return icon.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: f.minX + min(20, f.width * 0.1), y: f.midY)
    }
    nonisolated func unsafeHit(_ e: AXUIElement) -> Bool { (e.string(kAXIdentifierAttribute) ?? "").contains("offerButton") || e.role == "AXToolbar" || e.role == "AXMenuBar" }
    /// The window less its toolbar, which floats over the top of the page (a click there hit the toolbar, 18 Oct).
    nonisolated func screenArea() -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        guard let w = app.element(kAXFocusedWindowAttribute), var area = TurnOverObject.frame(w) else { return nil }
        if let tb = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXToolbar" }), let tf = TurnOverObject.frame(tb), tf.maxY > area.minY {
            let cut = min(area.height, tf.maxY - area.minY)
            area.origin.y += cut; area.size.height -= cut
        }
        return area
    }
}


/// The results page's own host (docs/FLAT-VIEW-PLAN.md, 27 Oct 2026): the keys, the speech and the waits for a
/// search results page, around the flat screen and nothing of the old page machinery. AppStoreView hands over to it
/// when a results page is up and takes back when the page changes.
final class AppStoreResults {
    let view: FlatScreen
    private(set) var items: [FlatItem] = []
    private(set) var index = 0
    private var spokeFirst = false
    private var extending = false
    /// Opens a row at the point the hit test confirmed (AppStoreView clicks there and waits for the page).
    private let openRow: (String, CGPoint) -> Void

    init(pid: pid_t, openRow: @escaping (String, CGPoint) -> Void) {
        self.openRow = openRow
        view = FlatScreen(name: "App Store results", adapter: AppStoreFlatAdapter(pid: pid))
        view.onChange = { [weak self] items in self?.changed(items) }
    }

    func start() { items = []; index = 0; spokeFirst = false; extending = false; view.begin() }
    func stop() { view.end() }

    private func changed(_ new: [FlatItem]) {
        items = new
        index = min(index, max(0, items.count - 1))
        if !spokeFirst, !items.isEmpty { spokeFirst = true; speak(index) }
    }

    private func speak(_ i: Int) {
        guard items.indices.contains(i) else { return }
        Speech.speakItem(items[i].label)
        Hints.schedule("Return opens the app's page. Up and Down move; Escape goes back.")
    }

    func move(_ d: Int) {
        guard !items.isEmpty else { Speech.speakMessage("still reading the results; a moment"); return }
        let j = index + d
        if items.indices.contains(j) { index = j; speak(j); return }
        guard d > 0, !extending else { Tones.edge(); speak(index); return }
        // Past the last tile seen: the next screen, then the first new tile.
        extending = true
        let had = items.count
        view.extend { [weak self] count in
            guard let self else { return }
            extending = false
            if count > had { index = had; speak(index) } else { Tones.edge(); speak(index) }
        }
    }
    func toEnd(_ last: Bool) {
        guard !items.isEmpty else { return }
        if !last { index = 0; speak(0); return }
        sweep(upTo: 40) { [weak self] in guard let self else { return }; index = items.count - 1; speak(index) }
    }
    func letter(_ ch: Character) {
        guard !items.isEmpty else { return }
        if let j = next(ch, after: index) { index = j; speak(j); return }
        sweep(upTo: 40, until: { [weak self] in self?.next(ch, after: self?.index ?? 0) != nil }) { [weak self] in
            guard let self else { return }
            if let j = next(ch, after: index) { index = j; speak(j) } else { Tones.edge() }
        }
    }
    private func next(_ ch: Character, after i: Int) -> Int? {
        guard !items.isEmpty else { return nil }
        for k in 1...items.count { let j = (i + k) % items.count; if items[j].name?.lowercased().first == ch { return j } }
        return nil
    }
    /// Screens scanned one after another until `until` holds, the end, or `upTo` screens.
    private func sweep(upTo: Int, until: @escaping () -> Bool = { false }, then: @escaping () -> Void) {
        guard upTo > 0, !until() else { then(); return }
        let had = items.count
        view.extend { [weak self] count in
            guard let self else { return }
            if count == had { then() } else { sweep(upTo: upTo - 1, until: until, then: then) }
        }
    }
    func open() {
        guard items.indices.contains(index), let name = items[index].name else { Speech.speakMessage("nothing to open yet"); return }
        view.resolve(items[index]) { [weak self] point in
            guard let self else { return }
            guard let point else { Speech.speakMessage("Not opened: the row isn't on screen now."); return }
            openRow(name, point)
        }
    }
}
