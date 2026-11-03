// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices

/// A client decision to leave an app alone, distinct from a reply returned by the accessibility API.
public struct AXBackoff: Equatable, Sendable {
    public enum Reason: String, Sendable { case timeout, slowResponses }
    public let reason: Reason
    public let remainingNanoseconds: UInt64
    public init(reason: Reason, remainingNanoseconds: UInt64) {
        self.reason = reason; self.remainingNanoseconds = remainingNanoseconds
    }
}

public enum AXQueryStatus: Equatable, Sendable, CustomStringConvertible {
    case returned(AXError)
    case deferred(AXBackoff)
    /// The caller cancelled or exhausted its own work budget; no AX API was attempted and no provider error exists.
    case clientWorkStopped
    /// A batch's CFNull does not identify the per-attribute AX error; keep it distinct from genuine noValue.
    case batchNull
    /// The API succeeded but a batch slot could not be decoded. This is not an invented provider error.
    case invalidResponse

    public var description: String {
        switch self {
        case .returned(let error): return "returned:\(describeError(error))"
        case .deferred(let rest): return "clientBackoff:\(rest.reason.rawValue)(\(rest.remainingNanoseconds / 1_000_000)ms)"
        case .clientWorkStopped: return "client:workStopped"
        case .batchNull: return "batch:unspecifiedAbsence"
        case .invalidResponse: return "client:invalidResponse"
        }
    }
}

public enum AXQueryPolicy: Sendable {
    case respectBackoff
    /// For explicitly bounded diagnostic comparisons only, never normal reader retries. The call is still timed
    /// and contributes to health accounting. A standalone probe observes its own health, not the reader's (#166).
    case diagnosticDirect
}

/// The provider's returned error and the client's decision must survive beyond an optional value. Existing
/// convenience wrappers keep their legacy behaviour; diagnostic callers use this result to explain absence.
public struct AXQueryResult<Value> {
    private let rawValue: Value?
    public let status: AXQueryStatus
    public let elapsedNanoseconds: UInt64
    /// Whether the requested AX API was invoked, not proof of IPC or physical/provider work.
    public let wasAttempted: Bool
    public var value: Value? { status == .returned(.success) ? rawValue : nil }
    public var error: AXError? { if case .returned(let error) = status { return error }; return nil }
    public var legacyError: AXError { error ?? .cannotComplete }

    public init(value: Value?, status: AXQueryStatus, elapsedNanoseconds: UInt64, wasAttempted: Bool) {
        rawValue = value; self.status = status
        self.elapsedNanoseconds = elapsedNanoseconds; self.wasAttempted = wasAttempted
    }
}

extension AXQueryResult: Sendable where Value: Sendable {}

package struct AXQueryExecution {
    package let status: AXQueryStatus
    package let elapsedNanoseconds: UInt64
    package let wasAttempted: Bool
    package var legacyError: AXError { if case .returned(let error) = status { return error }; return .cannotComplete }

    func result<Value>(_ value: Value?) -> AXQueryResult<Value> {
        AXQueryResult(value: value, status: status, elapsedNanoseconds: elapsedNanoseconds, wasAttempted: wasAttempted)
    }
}

public struct AXAttributeBatchResult {
    public let query: AXQueryResult<CFArray>
    public let attributes: [String: AXQueryResult<CFTypeRef>]
    public let isAligned: Bool

    package init(query: AXQueryResult<CFArray>, names: [String]) {
        self.query = query
        let values = query.value
        let count = values.map { CFArrayGetCount($0) }
        isAligned = count == names.count
        var attributes: [String: AXQueryResult<CFTypeRef>] = [:]
        withExtendedLifetime(values) {
            for (index, name) in names.enumerated() {
                var status = query.status
                var value: CFTypeRef?
                if status == .returned(.success) {
                    if let values, index < CFArrayGetCount(values), let pointer = CFArrayGetValueAtIndex(values, index) {
                        // Keep the array alive while borrowing only requested slots, rather than bridging an
                        // unexpectedly large reply into another whole Swift array (#166).
                        let raw = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
                        if CFGetTypeID(raw) == CFNullGetTypeID() {
                            status = .batchNull
                        } else if CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetType(raw as! AXValue) == .axError {
                            var error = AXError.failure
                            status = AXValueGetValue(raw as! AXValue, .axError, &error) ? .returned(error) : .invalidResponse
                        } else { value = raw }
                    } else { status = .invalidResponse }
                }
                attributes[name] = AXQueryResult(value: value, status: status,
                                                elapsedNanoseconds: query.elapsedNanoseconds, wasAttempted: query.wasAttempted)
            }
        }
        self.attributes = attributes
    }
}

public extension AXUIElement {
    func attributeResult(_ name: String, policy: AXQueryPolicy = .respectBackoff) -> AXQueryResult<CFTypeRef> {
        if let snapshot = AXSnapshot.current {
            let value = snapshot.attribute(name, of: self)
            return AXQueryResult(value: value, status: .returned(value == nil ? .noValue : .success), elapsedNanoseconds: 0, wasAttempted: false)
        }
        var value: CFTypeRef?
        let execution = AXHealth.query(self, policy: policy) { AXUIElementCopyAttributeValue(self, name as CFString, &value) }
        return execution.result(value)
    }

    func attributeSettableResult(_ name: String, policy: AXQueryPolicy = .respectBackoff) -> AXQueryResult<Bool> {
        if let snapshot = AXSnapshot.current {
            let value = snapshot.nodes[ElementKey(self)]?.settable[name]
            return AXQueryResult(value: value, status: .returned(value == nil ? .attributeUnsupported : .success), elapsedNanoseconds: 0, wasAttempted: false)
        }
        var settable: DarwinBoolean = false
        let execution = AXHealth.query(self, policy: policy) { AXUIElementIsAttributeSettable(self, name as CFString, &settable) }
        return execution.result(settable.boolValue)
    }

    func parameterizedResult(_ name: String, _ parameter: CFTypeRef, policy: AXQueryPolicy = .respectBackoff) -> AXQueryResult<CFTypeRef> {
        var value: CFTypeRef?
        let execution = AXHealth.query(self, policy: policy) { AXUIElementCopyParameterizedAttributeValue(self, name as CFString, parameter, &value) }
        return execution.result(value)
    }

    func attributeValueCountResult(_ name: String, policy: AXQueryPolicy = .respectBackoff) -> AXQueryResult<Int> {
        if let snapshot = AXSnapshot.current {
            let value = (snapshot.attribute(name, of: self) as? [AnyObject])?.count
            return AXQueryResult(value: value, status: .returned(value == nil ? .noValue : .success), elapsedNanoseconds: 0, wasAttempted: false)
        }
        var count: CFIndex = 0
        let execution = AXHealth.query(self, policy: policy) { AXUIElementGetAttributeValueCount(self, name as CFString, &count) }
        return execution.result(count)
    }

    /// Requests only the specified slice, unlike attr/elements which copy the entire attribute value.
    func attributeValuesResult(_ name: String, index: Int, maxValues: Int, policy: AXQueryPolicy = .respectBackoff) -> AXQueryResult<CFArray> {
        if let snapshot = AXSnapshot.current {
            let all = snapshot.attribute(name, of: self) as? [AnyObject]
            let values = all.map { Array($0.dropFirst(max(0, index)).prefix(max(0, maxValues))) as CFArray }
            return AXQueryResult(value: values, status: .returned(all == nil ? .noValue : .success), elapsedNanoseconds: 0, wasAttempted: false)
        }
        var values: CFArray?
        let execution = AXHealth.query(self, policy: policy) { AXUIElementCopyAttributeValues(self, name as CFString, index, maxValues, &values) }
        return execution.result(values)
    }

    func attributeNamesResult(policy: AXQueryPolicy = .respectBackoff) -> AXQueryResult<CFArray> {
        if let snapshot = AXSnapshot.current {
            let names = snapshot.nodes[ElementKey(self)].map { Array($0.attributes.keys) as CFArray }
            return AXQueryResult(value: names, status: .returned(names == nil ? .noValue : .success), elapsedNanoseconds: 0, wasAttempted: false)
        }
        var names: CFArray?
        let execution = AXHealth.query(self, policy: policy) { AXUIElementCopyAttributeNames(self, &names) }
        return execution.result(names)
    }

    func parameterizedAttributeNamesResult(policy: AXQueryPolicy = .respectBackoff) -> AXQueryResult<CFArray> {
        var names: CFArray?
        let execution = AXHealth.query(self, policy: policy) { AXUIElementCopyParameterizedAttributeNames(self, &names) }
        return execution.result(names)
    }

    func actionNamesResult(policy: AXQueryPolicy = .respectBackoff) -> AXQueryResult<CFArray> {
        if let snapshot = AXSnapshot.current { return AXQueryResult(value: (snapshot.nodes[ElementKey(self)]?.actions ?? []) as CFArray, status: .returned(.success), elapsedNanoseconds: 0, wasAttempted: false) }
        var names: CFArray?
        let execution = AXHealth.query(self, policy: policy) { AXUIElementCopyActionNames(self, &names) }
        return execution.result(names)
    }

    func attributesResult(_ names: [String], policy: AXQueryPolicy = .respectBackoff) -> AXAttributeBatchResult {
        if let snapshot = AXSnapshot.current {
            let values = names.map { snapshot.attribute($0, of: self) ?? kCFNull! } as CFArray
            return AXAttributeBatchResult(query: AXQueryResult(value: values, status: .returned(.success), elapsedNanoseconds: 0, wasAttempted: false), names: names)
        }
        var values: CFArray?
        let execution = AXHealth.query(self, policy: policy) {
            AXUIElementCopyMultipleAttributeValues(self, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        }
        return AXAttributeBatchResult(query: execution.result(values), names: names)
    }
}
