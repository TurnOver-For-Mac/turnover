// SPDX-License-Identifier: GPL-3.0-or-later
// Values shared by the reader and its Settings window. Only the reader resolves or saves keys.
import Foundation

public enum KeyboardEditing {
    public struct Key: Codable, Identifiable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var custom: Bool
        public var editable: Bool
        public init(id: String, label: String, custom: Bool, editable: Bool) {
            self.id = id; self.label = label; self.custom = custom; self.editable = editable
        }
    }

    public struct Command: Codable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var category: String
        public var keys: [Key]
        public init(id: String, title: String, category: String, keys: [Key]) {
            self.id = id; self.title = title; self.category = category; self.keys = keys
        }
    }

    public struct Change: Codable, Identifiable, Sendable {
        public var id: String
        public var label: String
        public var target: String
        public var stored: String
        public init(id: String, label: String, target: String, stored: String) {
            self.id = id; self.label = label; self.target = target; self.stored = stored
        }
    }

    public struct State: Codable, Sendable {
        public var commands: [Command]
        public var changes: [Change]
        public var context: String
        public var style: String
        public var layout: String
        public init(commands: [Command], changes: [Change], context: String, style: String, layout: String) {
            self.commands = commands; self.changes = changes; self.context = context; self.style = style; self.layout = layout
        }
    }

    public struct Candidate: Codable, Sendable {
        public var id: String
        public var label: String
        public var warnings: [String]
        public var error: String?
        public init(id: String, label: String, warnings: [String], error: String? = nil) {
            self.id = id; self.label = label; self.warnings = warnings; self.error = error
        }
    }
}
