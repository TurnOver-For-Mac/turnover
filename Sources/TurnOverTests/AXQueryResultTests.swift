// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX
import AXFixtures

func axQueryResultTests() {
    let fakePID = pid_t(Int32.max - 100)
    func query(_ error: AXError, took: UInt64 = 1, policy: AXQueryPolicy = .respectBackoff) -> AXQueryExecution {
        var ticks: [UInt64] = [100, 100 + took]
        return AXHealth.query(pid: fakePID, policy: policy, clock: { ticks.removeFirst() }) { error }
    }

    test("AX outcomes: genuine provider errors remain distinct and attempted") {
        defer { AXHealth.forget(pid: fakePID) }
        for error in [AXError.noValue, .attributeUnsupported, .parameterizedAttributeUnsupported, .cannotComplete, .invalidUIElement] {
            let result = query(error)
            expect(result.status, .returned(error))
            check(result.wasAttempted, "the API body ran")
            expect(result.elapsedNanoseconds, 1)
            expect(result.legacyError, error)
        }
    }
    test("AX outcomes: client backoff skips the provider without inventing its error") {
        defer { AXHealth.forget(pid: fakePID) }
        expect(query(.cannotComplete, took: 1_000_000_000).status, .returned(.cannotComplete))
        let before = AXStats.calls
        var called = false
        let skipped = AXHealth.query(pid: fakePID) { called = true; return .success }
        guard case .deferred(let rest) = skipped.status else { return check(false, "expected client deferral") }
        expect(rest.reason, .timeout)
        check(rest.remainingNanoseconds > 0 && rest.remainingNanoseconds <= 3_000_000_000, "remaining backoff reported")
        check(!called && !skipped.wasAttempted, "no provider read during backoff")
        expect(skipped.elapsedNanoseconds, 0)
        expect(AXStats.calls, before, "skipped calls do not become provider timing samples")
        let result = AXQueryResult<String>(value: nil, status: skipped.status, elapsedNanoseconds: 0, wasAttempted: false)
        check(result.error == nil, "deferral has no actual AXError")
        expect(result.legacyError, .cannotComplete, "legacy convenience contract stays compatible")
    }
    test("AX outcomes: an explicit diagnostic bypass does not silently clear backoff") {
        defer { AXHealth.forget(pid: fakePID) }
        _ = query(.cannotComplete, took: 1_000_000_000)
        let direct = query(.success, policy: .diagnosticDirect)
        expect(direct.status, .returned(.success))
        check(direct.wasAttempted, "explicit provider comparison was performed")
        var called = false
        let normal = AXHealth.query(pid: fakePID) { called = true; return .success }
        if case .deferred = normal.status {} else { check(false, "normal reader still respects backoff") }
        check(!called, "diagnostic bypass is not a global policy change")
    }
    test("AX outcomes: slow response backoff is distinct from timeout backoff") {
        defer { AXHealth.forget(pid: fakePID) }
        for _ in 0..<3 { expect(query(.success, took: 500_000_000).status, .returned(.success)) }
        let next = query(.success)
        guard case .deferred(let rest) = next.status else { return check(false, "slow responses should defer the next read") }
        expect(rest.reason, .slowResponses)
        check(!next.wasAttempted, "slow responses stop subsequent reads too")
    }
    test("AX outcomes: timeout and slow-response accounting cannot shorten or relabel timeout backoff") {
        defer { AXHealth.forget(pid: fakePID) }
        for duration: UInt64 in [1_300_000_000, 1_000_000_000] {
            AXHealth.forget(pid: fakePID)
            if duration == 1_000_000_000 {
                for _ in 0..<2 { _ = query(.success, took: 500_000_000) }
            }
            expect(query(.cannotComplete, took: duration).status, .returned(.cannotComplete))
            guard let rest = AXHealth.backoff(for: fakePID) else { check(false, "timeout backoff expected"); continue }
            expect(rest.reason, .timeout, "the actual timeout dominates its slow-response accounting")
            check(rest.remainingNanoseconds > 1_500_000_000, "the three-second rest was not shortened to the drip rest")
        }
    }
    test("AX outcomes: array count and prefix read use the replay provider and requested range") {
        let fixture = AXFixture(app: "Public sample", bundle: "test.ax", recorded: "", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1, 2, 3])]),
            .init(id: 1, attrs: ["AXRole": .string("AXButton")]),
            .init(id: 2, attrs: ["AXRole": .string("AXButton")]),
            .init(id: 3, attrs: ["AXRole": .string("AXButton")]),
        ])
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let root = AXReplay.root else { return check(false, "fixture root") }
        let count = root.attributeValueCountResult(kAXChildrenAttribute)
        expect(count.value, 3); expect(count.status, .returned(.success))
        let prefix = root.attributeValuesResult(kAXChildrenAttribute, index: 0, maxValues: 2)
        expect((prefix.value as? [AXUIElement])?.compactMap { AXReplay.id(of: $0) }, [1, 2])
        let tail = root.attributeValuesResult(kAXChildrenAttribute, index: 2, maxValues: 20)
        expect((tail.value as? [AXUIElement])?.compactMap { AXReplay.id(of: $0) }, [3])
        expect(root.attributeValuesResult(kAXChildrenAttribute, index: -1, maxValues: 1).error, .illegalArgument)
        expect(root.attributeValueCountResult(kAXRoleAttribute).error, .illegalArgument, "scalar is not an array of one")
    }
    test("AX outcomes: typed attributes and batch slots preserve missing values and enumeration") {
        let fixture = AXFixture(app: "Public sample", bundle: "test.ax", recorded: "", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXTextArea"), "AXValue": .string("public"), "AXNumberOfCharacters": .number(6)],
                  params: [kAXStringForRangeParameterizedAttribute], actions: [kAXPressAction]),
        ])
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let root = AXReplay.root else { return check(false, "fixture root") }
        expect(root.attributeResult("missing").error, .noValue)
        expect(root.attributeResult(kAXRoleAttribute).value as? String, "AXTextArea")
        expect(root.parameterizedResult(kAXStringForRangeParameterizedAttribute, axRangeValue(1, 2)).value as? String, "ub")
        expect(root.attributeNamesResult().value as? [String], ["AXNumberOfCharacters", "AXRole", "AXValue"])
        expect(root.parameterizedAttributeNamesResult().value as? [String], [kAXStringForRangeParameterizedAttribute])
        expect(root.actionNamesResult().value as? [String], [kAXPressAction])
        let batch = root.attributesResult([kAXRoleAttribute, "missing", kAXValueAttribute])
        expect(batch.query.status, .returned(.success))
        check(batch.isAligned, "each slot has a corresponding result")
        expect(batch.attributes[kAXRoleAttribute]?.value as? String, "AXTextArea")
        expect(batch.attributes["missing"]?.error, .noValue, "embedded AXError is preserved")
        expect(batch.attributes[kAXValueAttribute]?.value as? String, "public")
        check(root.attrs([kAXRoleAttribute, "missing"])["missing"] == nil, "legacy attrs still omits provider errors")
    }
    test("AX outcomes: null or truncated batch slots do not invent a provider noValue error") {
        let raw = AXQueryResult<CFArray>(value: [kCFNull!, "public" as CFString] as CFArray,
                                        status: .returned(.success), elapsedNanoseconds: 10, wasAttempted: true)
        let batch = AXAttributeBatchResult(query: raw, names: ["null", "present", "missing"])
        check(!batch.isAligned, "truncated replies are identifiable")
        expect(batch.query.status, .returned(.success), "actual top-level return remains available")
        expect(batch.attributes["null"]?.status, .batchNull)
        check(batch.attributes["null"]?.error == nil, "CFNull does not identify a provider error code")
        expect(batch.attributes["missing"]?.status, .invalidResponse)
        check(batch.attributes["missing"]?.error == nil, "missing slot is a decoding failure, not an AXError")
        expect(batch.attributes["present"]?.value as? String, "public")
    }
    test("AX outcomes: actual wrapper deferral preserves the legacy optional contract") {
        let fixture = AXFixture(app: "Public sample", bundle: "test.ax", recorded: "", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow")]),
        ])
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let root = AXReplay.root else { return check(false, "fixture root") }
        defer { AXHealth.forget(pid: root.pid) }
        var ticks: [UInt64] = [100, 1_000_000_100]
        _ = AXHealth.query(pid: root.pid, clock: { ticks.removeFirst() }) { .cannotComplete }
        let before = AXStats.calls
        let typed = root.attributeResult(kAXRoleAttribute)
        if case .deferred = typed.status {} else { check(false, "typed API identifies client deferral") }
        check(typed.error == nil && typed.value == nil && !typed.wasAttempted, "not a returned provider error")
        let legacy = root.attrError(kAXRoleAttribute)
        check(legacy.0 == nil, "legacy value remains absent")
        expect(legacy.1, .cannotComplete, "legacy error mapping stays compatible")
        check(root.attr(kAXRoleAttribute) == nil, "legacy optional still works")
        let batch = root.attributesResult([kAXRoleAttribute, "missing"])
        if case .deferred(let rest) = batch.query.status { expect(rest.reason, .timeout) }
        else { check(false, "batch query retains client deferral") }
        // The remaining duration changes between reads, so inspect every slot's source rather than its exact age.
        for slot in batch.attributes.values {
            if case .deferred = slot.status {} else { check(false, "batch slot retains client deferral") }
            check(!slot.wasAttempted && slot.error == nil, "no invented per-slot provider failure")
        }
        expect(AXStats.calls, before, "none of the deferred wrappers reach the provider")
    }
}
