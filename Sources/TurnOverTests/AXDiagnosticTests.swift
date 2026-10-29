// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

func axDiagnosticTests() {
    test("AX diagnostics: hard maxima and negative limits cannot make a probe unlimited") {
        let maximum = AXProbeBudget(maximumQueries: .max, maximumNodes: .max, maximumDepth: .max,
                                    maximumChildren: .max, durationNanoseconds: .max, startedNanoseconds: 0)
        expect(maximum.maximumQueries, 128)
        expect(maximum.maximumNodes, 16)
        expect(maximum.maximumDepth, 6)
        expect(maximum.maximumChildren, 8)
        expect(maximum.durationNanoseconds, 2_000_000_000)
        var zero = AXProbeBudget(maximumQueries: -1, maximumNodes: -1, maximumDepth: -1,
                                 maximumChildren: -1, startedNanoseconds: 0)
        check(!zero.beginQuery(now: 0) && zero.queries == 0, "negative query limit admits no work")
        expect(zero.stopped, .queryLimit)
    }
    test("AX diagnostics: discovery and resampling spend one query allowance") {
        var budget = AXProbeBudget(maximumQueries: 3, startedNanoseconds: 0)
        check(budget.beginQuery(now: 1), "discovery query")
        check(budget.beginQuery(now: 2), "retained-reference query")
        check(budget.beginQuery(now: 3), "fresh-reference query")
        check(!budget.beginQuery(now: 4), "a second pass does not reset the allowance")
        expect(budget.queries, 3)
        expect(budget.stopped, .queryLimit)
    }
    test("AX diagnostics: depth clipping does not consume a node and node limits stop traversal") {
        var budget = AXProbeBudget(maximumNodes: 2, maximumDepth: 1, startedNanoseconds: 0)
        check(!budget.beginNode(depth: 2, now: 0), "deep descendants are skipped")
        check(budget.depthClipped && budget.nodes == 0, "depth clipping is reported without visiting")
        check(budget.beginNode(depth: 0, now: 0) && budget.beginNode(depth: 1, now: 0), "shallower nodes still fit")
        check(!budget.beginNode(depth: 0, now: 0), "node cap stops the shared traversal")
        expect(budget.nodes, 2)
        expect(budget.stopped, .nodeLimit)
    }
    test("AX diagnostics: deadlines reject work at the boundary and do not wrap on an earlier clock") {
        var budget = AXProbeBudget(durationNanoseconds: 50, startedNanoseconds: 100)
        check(budget.beginQuery(now: 149), "query before deadline admitted")
        check(!budget.beginQuery(now: 150), "query exactly at deadline refused")
        expect(budget.stopped, .deadline)
        var earlier = AXProbeBudget(startedNanoseconds: 100)
        check(!earlier.beginQuery(now: 99), "an earlier timestamp never creates unlimited time")
        expect(earlier.stopped, .deadline)
    }
    test("AX diagnostics: provider failures and client backoff stop while absence remains distinct") {
        let backoff = AXQueryStatus.deferred(AXBackoff(reason: .timeout, remainingNanoseconds: 123))
        check(AXDiagnosticReport.shouldStop(backoff), "client rest stops follow-up queries")
        check(AXDiagnosticReport.shouldStop(.returned(.cannotComplete)), "provider cannotComplete stops follow-up queries")
        check(AXDiagnosticReport.shouldStop(.returned(.apiDisabled)), "actual accessibility denial stops follow-up queries")
        for status in [AXQueryStatus.returned(.noValue), .returned(.attributeUnsupported), .batchNull, .invalidResponse] {
            check(!AXDiagnosticReport.shouldStop(status), "absence or a decoding error is not invented provider failure")
        }
        var budget = AXProbeBudget(startedNanoseconds: 0)
        budget.stop(.clientBackoff)
        check(!budget.beginQuery(now: 0), "no query follows a client rest")
        expect(budget.queries, 0)
        var clientStop = AXProbeBudget(startedNanoseconds: 0)
        clientStop.stop(.clientStopped)
        check(!clientStop.beginQuery(now: 0), "other client stops do not authorize another query")
        expect(clientStop.stopped, .clientStopped, "a client work stop is not reported as health backoff")
        var denied = AXProbeBudget(startedNanoseconds: 0)
        denied.stop(.accessibilityDenied)
        check(!denied.beginQuery(now: 0), "a denied client does not keep querying the provider")
        expect(denied.stopped, .accessibilityDenied, "actual denial has a distinct stop reason")
    }
    test("AX diagnostics: outcome reports never serialize a provider value") {
        let secret = "synthetic-private-account@example.invalid"
        let result = AXQueryResult(value: secret, status: .returned(.success), elapsedNanoseconds: 1_250_000, wasAttempted: true)
        let line = AXDiagnosticReport.outcome(result)
        check(!line.contains(secret) && line.contains("attempted=true") && line.contains("1.25"), "only outcome and timing are emitted")
        let deferred = AXQueryResult<String>(value: secret,
                                             status: .deferred(AXBackoff(reason: .slowResponses, remainingNanoseconds: 500_000_000)),
                                             elapsedNanoseconds: 0, wasAttempted: false)
        check(AXDiagnosticReport.outcome(deferred).contains("clientBackoff:slowResponses"), "client deferral stays visible")
        check(!AXDiagnosticReport.outcome(deferred).contains(secret), "backoff never serializes stale payload")
    }
    test("AX diagnostics: unknown roles identifiers and custom actions are not emitted") {
        let secret = "synthetic-secret-label"
        expect(AXDiagnosticReport.role(secret), "other")
        expect(AXDiagnosticReport.subrole(secret), "other")
        expect(AXDiagnosticReport.role("AXList"), "AXList")
        let actions = AXDiagnosticReport.actions(["AXPress", "Name:\(secret), price", secret])
        check(actions.contains("AXPress") && actions.contains("customCount=1") && actions.contains("otherCount=1"), "standard actions and counts retained")
        check(!actions.contains(secret), "custom action text omitted")
        let attributes = AXDiagnosticReport.attributes(["AXChildren", secret])
        check(attributes.contains("AXChildren") && attributes.contains("otherCount=1") && !attributes.contains(secret), "unknown attribute strings omitted")
        expect(AXDiagnosticReport.stringPresence(secret as CFString), "present")
        expect(AXDiagnosticReport.stringPresence("" as CFString), "empty")
    }
    test("AX diagnostics: clipped arrays remain reported across subsequent complete samples") {
        var budget = AXProbeBudget(startedNanoseconds: 0)
        budget.noteArray(total: 9, received: 8)
        check(budget.arraysClipped, "bounded prefix is incomplete")
        budget.noteArray(total: 1, received: 1)
        check(budget.arraysClipped, "a later small array cannot hide earlier clipping")
        var empty = AXProbeBudget(startedNanoseconds: 0)
        empty.noteArray(total: 0, received: 0)
        check(!empty.arraysClipped, "reported empty array is not clipping")
    }
    test("AX diagnostics: malformed array members are counted and decoding has hard prefix limits") {
        let nameValues: [AnyObject] = ["AXPress" as NSString, NSNumber(value: 3)] + Array(repeating: "Name:synthetic-private-label" as NSString, count: 100)
        let names = nameValues as CFArray
        let sample = AXDiagnosticReport.names(in: names)
        expect(sample.returnedCount, 102)
        expect(sample.examinedCount, 64)
        expect(sample.malformedCount, 1)
        check(!AXDiagnosticReport.actions(sample.values).contains("synthetic-private-label"), "bounded custom names still redacted")
        let element = AXUIElementCreateApplication(123_456)   // local object only; never queried
        let values: [AnyObject] = [element, "not an element" as NSString] + Array(repeating: element, count: 20)
        let raw = values as CFArray
        let elements = AXDiagnosticReport.elements(in: raw, maximum: .max)
        expect(elements.examinedCount, 8)
        expect(elements.malformedCount, 1)
        expect(elements.values.count, 7)
        expect(AXDiagnosticReport.elements(in: raw, maximum: -1).examinedCount, 0)
    }
    test("AX diagnostics: oversized custom names are counted without bridging or emitting their content") {
        let secret = "synthetic-private-custom-action"
        let long = ("Name:" + String(repeating: secret, count: 10_000)) as NSString
        let sample = AXDiagnosticReport.names(in: [long, "AXPress" as NSString] as CFArray)
        expect(sample.returnedCount, 2)
        expect(sample.examinedCount, 2)
        expect(sample.oversizedCount, 1)
        expect(sample.malformedCount, 0, "a deliberately omitted long name is not a false type error")
        expect(sample.values, ["AXPress"])
        check(!AXDiagnosticReport.actions(sample.values).contains(secret), "long custom text never reaches the formatter")
        let absent = AXQueryResult<CFTypeRef>(value: nil, status: .returned(.success), elapsedNanoseconds: 0, wasAttempted: true)
        check(AXDiagnosticReport.outcome(absent).contains("returned:success"), "successful nullable output keeps the actual API status")
    }
    test("AX diagnostics: depth-first container discovery reaches content before sidebar and window controls spend the cap") {
        let roles = [0: "AXWindow", 1: "AXSplitGroup", 2: "AXButton", 3: "AXButton", 4: "AXButton", 5: "AXGroup",
                     6: "AXScrollArea", 7: "AXTextField", 8: "AXOutline", 9: "AXButton", 10: "AXGroup", 11: "AXGroup", 12: "AXList"]
        let children = [0: [1, 2, 3, 4], 1: [5, 6], 5: [7, 8, 9], 6: [10], 10: [11], 11: [12], 8: Array(100..<200)]
        var discovery = AXProbeDiscovery(root: 0), budget = AXProbeBudget(startedNanoseconds: 0)
        var visited: [Int] = [], expanded: [Int] = [], foundPath: [Int]?
        while let (node, path) = discovery.next(), budget.beginNode(depth: path.count, now: 0) {
            visited.append(node)
            if roles[node] == "AXList" { foundPath = path; break }
            guard AXProbeDiscoveryPolicy.descends(into: roles[node]) else { continue }
            expanded.append(node); discovery.append(children[node] ?? [], under: path)
        }
        expect(visited, [0, 1, 5, 7, 8, 9, 6, 10, 11, 12])
        expect(foundPath, [0, 1, 0, 0, 0], "original indices survive skipped sidebar controls")
        check(!expanded.contains(8) && !expanded.contains(7) && !expanded.contains(9), "outline and control child branches are not queried")
        expect(budget.nodes, 10)
        check(budget.stopped == nil && discovery.pendingCount == 3, "content found within the same cap; window buttons remain explicitly unvisited")
    }
}
