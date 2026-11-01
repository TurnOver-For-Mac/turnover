// SPDX-License-Identifier: GPL-3.0-or-later
// A value read from any thread and written on the main thread, behind a lock (8 Oct 2026, from the team review):
// the keyboard thread asks "is the menu open?" while the main thread opens and closes it.
import Foundation

nonisolated public final class Locked<T>: @unchecked Sendable {
    public let lock = NSLock()
    private var _value: T
    public init(_ value: T) { _value = value }
    public var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    /// The value with `lock` already held by the caller (a read and a write that must be one step).
    public var unsafeValue: T { get { _value } set { _value = newValue } }
}

/// A value handed across threads by code that knows it is safe (an attributed string fetched on one thread and
/// read on another, never both at once). Swift 6 cannot see that; this says so in one place.
nonisolated public struct Handed<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}

/// Run on the main thread, with the body typed as main-actor code: the hop the key thread, the speech queue and
/// the walks use to come back. (DispatchQueue.main.async alone leaves the compiler unsure where the body runs.)
nonisolated public func onMain(after delay: TimeInterval = 0, _ body: @escaping @MainActor () -> Void) {
    if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(body) } }
    else { DispatchQueue.main.async { MainActor.assumeIsolated(body) } }
}
