// SPDX-License-Identifier: GPL-3.0-or-later
// How a script's requests reach TurnOver (docs/PLUGIN-SCRIPTS-PLAN.md, "How it joins TurnOver"). ScriptHost has
// already checked each one against the plugin's abilities, the rates and the sizes; the broker does the work and
// answers. The real broker (Accessibility, speech, the menu, the clipboard, storage) is a later stage; tests use a
// fake. The broker is main-actor code and ScriptHost times its calls, so one that is slow costs the script its turn.
import Foundation
import TurnOverPluginWire

/// A JSON value that can cross threads: what a script sends and what a broker answers with.
nonisolated public enum ScriptValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ScriptValue])
    case object([String: ScriptValue])

    /// From the output of JSONSerialization.
    public init(json: Any?) {
        switch json {
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { ScriptValue(json: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { ScriptValue(json: $0) })
        default: self = .null
        }
    }

    /// For JSONSerialization.
    public var json: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { $0.json }
        case .object(let o): return o.mapValues { $0.json }
        }
    }

    public subscript(key: String) -> ScriptValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
}

/// Why a request failed. The message goes to the script's author as the error a rejected promise carries, so it
/// says what to change.
nonisolated public enum ScriptBrokerError: Error, Equatable, Sendable {
    /// Not allowed (a refused key, a menu item that is not the plugin's to choose).
    case refused(String)
    /// The item or handle is gone, or was never given to this plugin.
    case gone(String)
    /// The arguments were not what the operation needs.
    case invalid(String)
    /// Anything else.
    case failed(String)

    public var message: String {
        switch self {
        case .refused(let m), .gone(let m), .invalid(let m), .failed(let m): return m
        }
    }
}

@MainActor public protocol ScriptBroker: AnyObject {
    /// Do one operation for the plugin and answer. `say`, `sound` and `log` are one way: their answer is ignored.
    /// Items travel as objects with a `handle`; a handle the plugin was not given must throw `.gone`.
    func perform(_ operation: ScriptOperation, _ arguments: ScriptValue) throws -> ScriptValue
    /// For the operations answered later (`choose`, `ask`: a question to the person): the answer is given to `completion`, on main,
    /// when there is one. The default answers at once, as `perform` does.
    func perform(deferred operation: ScriptOperation, _ arguments: ScriptValue, completion: @escaping @MainActor (Result<ScriptValue, any Error>) -> Void)
}

extension ScriptBroker {
    public func perform(deferred operation: ScriptOperation, _ arguments: ScriptValue, completion: @escaping @MainActor (Result<ScriptValue, any Error>) -> Void) {
        completion(Result { try perform(operation, arguments) })
    }
}
