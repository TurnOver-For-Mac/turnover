// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX
import Darwin

/// Capture the physical event once, at the module boundary, before a script or model read can queue it.
/// KeyboardGesture.timestamp is mach_absolute_time ticks; Date() at eventual script execution is not its origin.
/// A timestamp establishes event ordering, not an attestation that a human generated the event.
nonisolated public struct AppStoreActionPress: Sendable {
    public let originTick: UInt64
    private init(originTick: UInt64) { self.originTick = originTick }
    public static let synthetic = Self(originTick: 0)

    public static func receive(_ gesture: KeyboardGesture) -> Self? {
        gesture.isRepeat ? nil : Self(originTick: gesture.timestamp)
    }

    public static func dispatch(_ gesture: KeyboardGesture, action: (Self) -> Void) {
        if let press = receive(gesture) { action(press) }
    }
}

/// A second press confirms only the exact offer first presented. This is an intent token, not proof that a
/// provider's label identifies a product: the caller must supply a nonempty, unambiguous model identity and
/// resolve/validate the current button again before performing any action (App Store review, 28 Oct 2026).
nonisolated public struct AppStorePurchaseConfirmation: Sendable {
    nonisolated public enum Decision: Equatable, Sendable { case prompt, confirm, ignore }
    nonisolated public struct Context: Sendable {
        public let page: UUID
        public let itemIdentity: String
        public let offerTitle: String
        public let button: AXUIElement

        public init(page: UUID, itemIdentity: String, offerTitle: String, button: AXUIElement) {
            self.page = page; self.itemIdentity = itemIdentity; self.offerTitle = offerTitle; self.button = button
        }

        fileprivate var isIdentified: Bool {
            !itemIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !offerTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        fileprivate func matches(_ other: Context) -> Bool {
            page == other.page && itemIdentity == other.itemIdentity && offerTitle == other.offerTitle &&
            CFEqual(button, other.button)
        }
    }

    private var pending: (context: Context, at: Date, armTick: UInt64)?
    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    public init() {}

    /// armTick is sampled when the prompt would actually be spoken, not when the initiating key arrived. A key
    /// physically received before that cutoff cannot confirm, even if a blocked script executes it afterwards.
    /// Synthetic input may prompt but never confirms. The caller carries the same press through every retry.
    public mutating func decide(_ context: Context, press: AppStoreActionPress, at now: Date, armTick: UInt64) -> Decision {
        guard context.isIdentified, now.timeIntervalSinceReferenceDate.isFinite else { pending = nil; return .ignore }
        guard press.originTick <= armTick else { return .ignore }   // a future event cannot establish intent
        if let previous = pending {
            guard press.originTick > previous.armTick else { return .ignore }   // keep pending; do not rearm on queued keys
            let elapsed = now.timeIntervalSince(previous.at)
            let physicalElapsed = Double(press.originTick - previous.armTick) * Self.secondsPerTick
            if elapsed.isFinite, elapsed >= 0, elapsed < 5, physicalElapsed < 5, context.matches(previous.context) {
                pending = nil
                return .confirm
            }
        }
        pending = (context, now, armTick)
        return .prompt
    }

    /// The model owner resets on page/session replacement, accepted selection changes and non-purchase actions.
    public mutating func reset() { pending = nil }
}
