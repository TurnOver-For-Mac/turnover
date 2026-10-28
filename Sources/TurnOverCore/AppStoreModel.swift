// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// A complete committed page, including the cursors used to extend its shelves.
nonisolated public struct AppStoreModel: Sendable {
    public var page: [AppStoreView.Entry] = []
    public var shelves: [String] = []
    public var sidebar: [AppStoreView.Entry] = []
    public var key = ""
    public var title = ""
    public var rootIdentifier = ""
    public var hasCard = false
    var seen: [AXUIElement] = []
    var lastSection: AXUIElement?
    var nextSection: AXUIElement?
    var tails: [Int: AXUIElement] = [:]
    public init() {}

    /// The same routine the view uses when applying a snapshot; a repeated control's position is not identity.
    public func retainingPageSelection(from previous: AppStoreModel, index: Int) -> (index: Int, retained: Bool) {
        let clamped = min(max(0, index), max(0, page.count - 1))
        guard key == previous.key, previous.page.indices.contains(index) else { return (clamped, false) }
        let captured = previous.page[index]
        let matches = AppStoreEntryIdentity.indices(for: captured, in: page)
        guard matches.count == 1, let matched = matches.first,
              AppStoreEntryIdentity.samePresentation(captured, page[matched]) else { return (clamped, false) }
        return (matched, true)
    }

    public func containsSelection(_ captured: AppStoreView.Entry, at index: Int) -> Bool {
        let matches = AppStoreEntryIdentity.indices(for: captured, in: page)
        return matches.count == 1 && matches.first == index && page.indices.contains(index)
            && AppStoreEntryIdentity.samePresentation(captured, page[index])
    }
}

nonisolated public struct AppStorePageMetadata: Sendable {
    public var key: String
    public var title: String
    public var rootIdentifier: String
    public var hasCard: Bool
    public init(key: String, title: String = "", rootIdentifier: String = "", hasCard: Bool = false) {
        self.key = key; self.title = title; self.rootIdentifier = rootIdentifier; self.hasCard = hasCard
    }
}

nonisolated public struct AppStoreModelRequest: Sendable {
    nonisolated public enum Operation: Sendable {
        case page(skipFlatResults: Bool), sidebar, metadata, more, end, carousel(Int)
        case resolve(AppStoreView.Entry, index: Int)
    }
    public let operation: Operation
    public let model: AppStoreModel
    public let session: UUID
    public let id: UUID
    public let revision: Int
}

nonisolated public struct AppStoreModelResult: Sendable {
    public var model: AppStoreModel?
    public var metadata: AppStorePageMetadata?
    public var resolved: AppStoreView.Entry?
    public var more: Bool
    public var needsRefresh: Bool
    public init(model: AppStoreModel? = nil, metadata: AppStorePageMetadata? = nil,
                resolved: AppStoreView.Entry? = nil, more: Bool = false, needsRefresh: Bool = false) {
        self.model = model; self.metadata = metadata; self.resolved = resolved; self.more = more; self.needsRefresh = needsRefresh
    }
}

nonisolated public protocol AppStoreModelSource: Sendable {
    func read(_ request: AppStoreModelRequest, current: @escaping @Sendable () -> Bool) -> AppStoreModelResult?
}

/// Record names must be unique; ordinary controls also carry an exact element/section scope.
/// Repeated See All buttons in separate shelves are not duplicate app identities (28 Oct 2026, #54).
/// Names are the current adapter's identity, not stable Store product IDs; ambiguous records remain refused.
nonisolated enum AppStoreEntryIdentity {
    /// Only surrounding whitespace is ignored: developer, subtitle, price and other provider words stay intact.
    static func fullText(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func fullIdentity(_ entry: AppStoreView.Entry) -> String { fullText(entry.check.isEmpty ? entry.label : entry.check) }
    static func samePresentation(_ lhs: AppStoreView.Entry, _ rhs: AppStoreView.Entry) -> Bool {
        lhs.kind == rhs.kind && lhs.label == rhs.label && fullIdentity(lhs) == fullIdentity(rhs)
    }
    static func isRecord(_ entry: AppStoreView.Entry) -> Bool { entry.kind == .app || entry.kind == .card }

    static func sameControl(_ lhs: AppStoreView.Entry, _ rhs: AppStoreView.Entry) -> Bool {
        guard CFEqual(lhs.element, rhs.element) else { return false }
        switch (lhs.section, rhs.section) {
        case (nil, nil): return true
        case (let a?, let b?): return CFEqual(a, b)
        default: return false
        }
    }

    static func indices(for captured: AppStoreView.Entry, in page: [AppStoreView.Entry]) -> [Int] {
        func name(_ entry: AppStoreView.Entry) -> String {
            let value = entry.check.isEmpty ? entry.label : entry.check
            return (value.components(separatedBy: ",").first ?? value).trimmingCharacters(in: .whitespaces)
        }
        let wanted = name(captured)
        guard !wanted.isEmpty else { return [] }
        return page.indices.filter { index in
            let candidate = page[index]
            guard candidate.kind == captured.kind, name(candidate) == wanted else { return false }
            return isRecord(captured) || sameControl(candidate, captured)
        }
    }
}

/// Main owns the committed model and command order. The serial worker owns only a request's
/// local builder; its cancellation token is the only state it reads across the boundary (#54).
public final class AppStoreModelOwner {
    public private(set) var model = AppStoreModel()
    public private(set) var session = UUID()
    public private(set) var isLoading = false
    public var onApply: ((AppStoreModel, AppStoreModel) -> Void)?
    private var active = true
    private var revision = 0
    private var latestRequest = UUID()
    private var finishing: UUID?
    private var draining = false
    private var queued: [(UUID, @MainActor () -> Void)] = []
    nonisolated private struct Token: Sendable { var session: UUID; var request: UUID?; var active: Bool }
    nonisolated private let token: Locked<Token>
    nonisolated private let queue: DispatchQueue
    nonisolated private let source: AppStoreModelSource
    nonisolated private let deliver: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    public init(pid: pid_t, source: AppStoreModelSource? = nil, queue: DispatchQueue? = nil,
                deliver: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { onMain($0) }) {
        self.source = source ?? AppStoreAXModelSource(pid: pid)
        self.queue = queue ?? DispatchQueue(label: "turnover.appstore.model", qos: .userInitiated)
        self.deliver = deliver
        let initial = UUID(); session = initial
        token = Locked(Token(session: initial, request: nil, active: true))
    }

    /// A newer page intent retires old reads and commands without waiting for an AX call to return.
    public func invalidate(clearPage: Bool = true) {
        session = UUID(); latestRequest = UUID(); active = true; isLoading = false; finishing = nil; queued = []
        token.value = Token(session: session, request: nil, active: true)
        revision += 1
        if clearPage {
            let old = model
            model = AppStoreModel(); model.sidebar = old.sidebar
            onApply?(old, model)
        }
    }

    public func stop() {
        session = UUID(); latestRequest = UUID(); active = false; isLoading = false; finishing = nil; queued = []
        token.value = Token(session: session, request: nil, active: false)
    }

    public func enqueue(_ command: @escaping @MainActor () -> Void) {
        guard active else { return }
        queued.append((session, command))
        drain()
    }

    public func read(_ operation: AppStoreModelRequest.Operation,
                     then: @escaping @MainActor @Sendable (AppStoreModelResult?) -> Void = { _ in }) {
        guard active else { return }
        guard !isLoading else { enqueue { [weak self] in self?.read(operation, then: then) }; return }
        let id = UUID()
        latestRequest = id; isLoading = true
        let request = AppStoreModelRequest(operation: operation, model: model, session: session, id: id, revision: revision)
        token.value = Token(session: session, request: id, active: true)
        queue.async { [source, weak self] in
            guard let self, current(request) else { return }
            let result = source.read(request, current: { self.current(request) })
            deliver { [weak self] in self?.complete(request, result: result, then: then) }
        }
    }

    nonisolated private func current(_ request: AppStoreModelRequest) -> Bool {
        let current = token.value
        return current.active && current.session == request.session && current.request == request.id
    }

    nonisolated public func isCurrentSession(_ session: UUID) -> Bool {
        let current = token.value
        return current.active && current.session == session
    }

    private func complete(_ request: AppStoreModelRequest, result: AppStoreModelResult?,
                          then: @MainActor @Sendable (AppStoreModelResult?) -> Void) {
        guard active, session == request.session, latestRequest == request.id, revision == request.revision else { return }
        let result = validated(result, for: request)
        finishing = request.id
        defer { if finishing == request.id { finishing = nil } }
        isLoading = false
        let old = model
        if let built = result?.model {
            if !old.key.isEmpty, old.key != built.key { session = UUID(); queued = [] }
            model = built; revision += 1
        }
        token.value = Token(session: session, request: nil, active: active)
        let completedSession = session
        if result?.model != nil { onApply?(old, model) }
        guard active, session == completedSession, latestRequest == request.id else { return }
        // Apply and finish the original gesture before later keys run. A didSet on `loading`
        // previously replayed those keys halfway through confirmation/model application (28 Oct 2026).
        then(result)
        if finishing == request.id { finishing = nil }
        guard active, session == completedSession, latestRequest == request.id else { return }
        drain()
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while active, !isLoading, finishing == nil, !queued.isEmpty {
            let (generation, command) = queued.removeFirst()
            if generation == session { command() }
        }
    }

    private func validated(_ result: AppStoreModelResult?, for request: AppStoreModelRequest) -> AppStoreModelResult? {
        guard case .resolve(let captured, _) = request.operation else { return result }
        if result?.resolved == nil, result?.needsRefresh == true { return .init(needsRefresh: true) }
        guard let resolved = result?.resolved,
              AppStoreEntryIdentity.samePresentation(resolved, captured),
              (result?.metadata?.key ?? result?.model?.key) == model.key else { return nil }
        guard AppStoreEntryIdentity.isRecord(captured) || AppStoreEntryIdentity.sameControl(captured, resolved) else { return nil }
        let matches = AppStoreEntryIdentity.indices(for: captured, in: model.page)
        guard matches.count == 1, let index = matches.first else { return nil }
        var patched = model
        var currentEntry = patched.page[index]
        currentEntry.element = resolved.element
        patched.page[index] = currentEntry
        return .init(model: patched, metadata: result?.metadata, resolved: currentEntry)
    }
}
