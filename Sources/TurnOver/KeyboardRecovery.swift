// SPDX-License-Identifier: GPL-3.0-or-later
import TurnOverCore

extension KeyboardHandler {
    /// Soft recovery ends chord capture while retaining original-process release ownership.
    nonisolated func retireSleepingInsert() { KeypadApplicationDelivery.retireSleeping(owner: ObjectIdentifier(self)) }

    /// Shared retirement completes streams before either reader can accept a late physical release.
    nonisolated func finishSleepingInsert() { KeypadApplicationDelivery.finishSleeping(owner: ObjectIdentifier(self)) }
}
