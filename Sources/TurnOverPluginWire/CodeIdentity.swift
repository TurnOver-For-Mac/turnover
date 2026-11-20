// SPDX-License-Identifier: GPL-3.0-or-later
// Who a program is, by its signature, and the requirement text each end of the keeper's connection puts on the other
// (docs/PLUGIN-SCRIPTS-PLAN.md, "The keeper", 15 Nov 2026). Public Security calls only.
import Foundation
import Security

public enum CodeIdentity {
    /// This program's own team identifier, read from its own signature, or nil: an ad hoc build, an unsigned program, or
    /// a signature that cannot be read. The keeper and TurnOver both answer nobody without one.
    public static func ownTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// A signing identifier is letters, digits, dot and hyphen, so it can never carry a quote into the requirement text.
    static func isValidIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x2D }
    }

    /// A team identifier is ten capital letters and digits.
    static func isValidTeam(_ team: String) -> Bool {
        team.utf8.count == 10 && team.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }
    }

    /// The requirement that a program is signed by Apple's chain for this team, with this identifier. Nil for an
    /// identifier or team of any other shape: a refusal, never a requirement built from text it cannot trust.
    public static func requirement(identifier: String, team: String) -> String? {
        guard isValidIdentifier(identifier), isValidTeam(team) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
