// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One TV scroll's optional early read and existing 500 ms settling point (#188, 29 Oct 2026).
/// Main owns this token. A current same-page publication can finish it without waiting for either timer;
/// an unchanged early read cannot advance the scroll position. There are at most two reads per token.
final class MediaShelfReadiness {
    enum Outcome { case ready, unchanged, cancelled }
    enum Phase { case early, settled }
    private let pageID: String
    private let initialKeys: Set<String>
    private let initialCount: Int
    private let current: @MainActor () -> Bool
    private let read: @MainActor (MediaShelfReadiness, Phase, @escaping @MainActor @Sendable () -> Void) -> Void
    private let completed: @MainActor (MediaShelfReadiness, Outcome) -> Void
    private var finished = false, reading = false, settleDue = false
    private var readPhase: Phase?
    private let started = DispatchTime.now().uptimeNanoseconds

    init(pageID: String, itemKeys: [String], current: @escaping @MainActor () -> Bool,
         read: @escaping @MainActor (MediaShelfReadiness, Phase, @escaping @MainActor @Sendable () -> Void) -> Void,
         completed: @escaping @MainActor (MediaShelfReadiness, Outcome) -> Void) {
        self.pageID = pageID; initialKeys = Set(itemKeys); initialCount = itemKeys.count
        self.current = current; self.read = read; self.completed = completed
    }

    func start(delay: @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void) {
        delay(0.15) { [weak self] in self?.check(settled: false) }
        delay(0.5) { [weak self] in self?.check(settled: true) }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        record("cancelled")
    }
    func invalidate() { finish(.cancelled) }

    /// Called only after the owner commits a window-validated snapshot. Count growth alone can be duplicates;
    /// the same captured page must also contain an item key absent before this scroll.
    func observe(pageID: String, itemKeys: [String], fromRead: Bool) {
        guard isCurrent() else { return }
        guard pageID == self.pageID else { finish(.cancelled); return }
        guard itemKeys.count > initialCount, itemKeys.contains(where: { !initialKeys.contains($0) }) else { return }
        let outcome = fromRead ? (readPhase == .early ? "earlyReady" : "settledReady") : "overlapReady"
        finish(.ready, diagnostic: outcome)
    }

    private func isCurrent() -> Bool {
        guard !finished else { return false }
        guard current() else { finish(.cancelled); return false }
        return true
    }

    private func check(settled: Bool) {
        guard isCurrent() else { return }
        if settled { settleDue = true }
        // If the early read crosses 500 ms, let it finish, then make the settled read at the SAME position.
        // This coalesces the timer without treating an early, slow response as a fresh settled snapshot.
        guard !reading else { return }
        reading = true
        readPhase = settled ? .settled : .early
        read(self, settled ? .settled : .early) { [weak self] in
            guard let self, isCurrent() else { return }
            reading = false
            if settled { finish(.unchanged, diagnostic: "settledUnchanged") }
            else if settleDue { check(settled: true) }
        }
    }

    private func record(_ outcome: String) {
        let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        Log.io("media: shelf readiness outcome=\(outcome) elapsedMs=\(elapsed)")
    }

    private func finish(_ outcome: Outcome, diagnostic: String = "cancelled") {
        guard !finished else { return }
        finished = true
        record(diagnostic)
        // The owner detaches this token before invoking a continuation. A continuation can begin another
        // load through the existing serial work owner without an old timer completing that new load.
        completed(self, outcome)
    }
}
