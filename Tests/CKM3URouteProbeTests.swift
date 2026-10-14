import Foundation
import XCTest
@testable import CKBridge

final class CKM3URouteProbeTests: XCTestCase {
    func testM3UProbeDefaultsOffAndRequiresOriginalPlayer() {
        XCTAssertFalse(CKM3UProbePolicy.enabled([:]))
        XCTAssertFalse(CKM3UProbePolicy.enabled(["CKM3URouteProbeMode": true]))
        XCTAssertFalse(CKM3UProbePolicy.enabled(["CKM3URouteProbeMode": true, "CKNativeLinkMode": true]))
        XCTAssertTrue(CKM3UProbePolicy.enabled(["CKM3URouteProbeMode": true, "CKNativeLinkMode": true,
                                              "CKOriginalPlayerMode": true]))
    }
    func testM3UProbeRecognizesExactAppTypesNotLookalikes() {
        XCTAssertEqual(CKM3UProbePolicy.tags(typeName: "MonPlayer.ProviderM3UDetailScreen"), ["m3u-provider"])
        XCTAssertTrue(CKM3UProbePolicy.tags(typeName: "OtherApp.ProviderM3UDetailScreen").isEmpty)
        XCTAssertTrue(CKM3UProbePolicy.tags(typeName: "MonPlayer.ProviderM3UDetailScreenFake").isEmpty)
    }
    func testM3UProbeGenericTypesDoNotClaimActiveBranchWhenBothExist() {
        let tags = CKM3UProbePolicy.tags(typeName:
            "SwiftUI._ConditionalContent<MonPlayer.ProviderM3UDetailScreen, MonPlayer.ProviderJsonDetailScreen>")
        XCTAssertEqual(CKM3UProbePolicy.branch(tags), "ambiguous")
    }
    func testM3UProbePlayerDoesNotAuthorizeM3UReplacement() {
        XCTAssertEqual(CKM3UProbePolicy.branch(["player-controller", "m3u-provider"]), "player-candidate")
        XCTAssertEqual(CKM3UProbePolicy.branch(["m3u-provider"]), "m3u-candidate")
        XCTAssertEqual(CKM3UProbePolicy.branch(["json-provider"]), "json-candidate")
        XCTAssertEqual(CKM3UProbePolicy.branch(["m3u-channel-model"]), "unknown")
    }
    func testM3UProbeOriginalPlayerRouteDoesNotIdentifyBrowserEntry() {
        XCTAssertEqual(CKM3UProbePolicy.branch(["case-player", "case-m3u-provider"]), "player-candidate")
        XCTAssertEqual(CKM3UProbePolicy.branch(["case-stream-loading"]), "player-candidate")
    }
    func testM3UProbeNeverLogsSourceValues() {
        let secret = "owned-account-secret-do-not-log"
        let result = CKM3UProbeReflection.snapshot([secret, URL(string: "https://example.invalid/" + secret)!], clock: { 0 })
        XCTAssertTrue(result.tags.isEmpty); XCTAssertTrue(result.fields.isEmpty)
        XCTAssertFalse(result.summary.contains(secret)); XCTAssertFalse(result.summary.contains("example.invalid"))
    }
    func testM3UProbeRejectsOversizedTypeNames() {
        XCTAssertTrue(CKM3UProbePolicy.tags(typeName: String(repeating: "x", count: 9000)).isEmpty)
        XCTAssertFalse(CKM3UProbePolicy.traversable(String(repeating: "x", count: 9000)))
    }
    func testM3UProbeLimitsRootAndNodeCounts() {
        let snapshot = CKM3UProbeReflection.snapshot(Array(repeating: "owned", count: 200), nodes: 4, clock: { 0 })
        XCTAssertEqual(snapshot.visited, 4); XCTAssertTrue(snapshot.truncated)
        let empty = CKM3UProbeReflection.snapshot(["owned"], nodes: 0)
        XCTAssertEqual(empty.visited, 0); XCTAssertTrue(empty.truncated)
    }
    func testM3UProbeZeroTimeBudgetDoesNotReflectValues() {
        let snapshot = CKM3UProbeReflection.snapshot(["owned"], seconds: 0)
        XCTAssertEqual(snapshot.visited, 0); XCTAssertTrue(snapshot.truncated)
    }
    func testM3UProbeSnapshotUsesOnlyKnownFixedTokens() {
        var result = CKM3UProbeSnapshot()
        result.tags = ["router", "m3u-provider"]; result.fields = ["_appRouter", "rootView"]
        XCTAssertEqual(result.summary, "branch=m3u-candidate nodes=0 limited=0 tags=m3u-provider,router fields=_appRouter,rootView")
    }

    private class OwnedNode: CustomStringConvertible {
        var next: OwnedNode?
        let _currentSource = "owned-private-account"
        var descriptions = 0
        var description: String { descriptions += 1; return _currentSource }
    }
    private class OwnedParent { let _appRouter = "owned-secret-parent" }
    private final class OwnedChild: OwnedParent { let rootView = "owned-secret-child" }
    private enum OwnedRoute { case providerM3UDetail(String), providerJsonDetail(String) }
    private func ownedNames(_ value: Any) -> String {
        if value is OwnedNode { return "MonPlayer.OwnedNode" }
        if value is OwnedChild { return "MonPlayer.OwnedChild" }
        if value is OwnedRoute { return "MonPlayer.AppRoute" }
        return String(reflecting: type(of: value))
    }
    func testM3UProbeWalksOwnedFieldsWithoutDescriptionsOrValues() {
        let node = OwnedNode()
        let snapshot = CKM3UProbeReflection.snapshot([node], typeNameFor: ownedNames, clock: { 0 })
        XCTAssertTrue(snapshot.fields.contains("_currentSource"))
        XCTAssertFalse(snapshot.summary.contains("owned-private-account")); XCTAssertEqual(node.descriptions, 0)
    }
    func testM3UProbeObjectCycleStopsWithoutRetainingGraph() {
        weak var released: OwnedNode?
        let snapshot = autoreleasepool { () -> CKM3UProbeSnapshot in
            let node = OwnedNode(); node.next = node; released = node
            defer { node.next = nil }
            // Test graph termination independently of cold metadata/CI scheduling.
            return CKM3UProbeReflection.snapshot([node], typeNameFor: ownedNames, clock: { 0 })
        }
        XCTAssertLessThanOrEqual(snapshot.visited, 4); XCTAssertFalse(snapshot.truncated)
        XCTAssertNil(released)
    }
    func testM3UProbeReadOnlySuperclassFieldsAreIncluded() {
        let snapshot = CKM3UProbeReflection.snapshot([OwnedChild()], typeNameFor: ownedNames, clock: { 0 })
        XCTAssertTrue(snapshot.fields.contains("_appRouter")); XCTAssertTrue(snapshot.fields.contains("rootView"))
        XCTAssertFalse(snapshot.summary.contains("owned-secret"))
    }
    func testM3UProbeEnumCaseEvidenceDoesNotLogPayload() {
        let m3u = CKM3UProbeReflection.snapshot([OwnedRoute.providerM3UDetail("owned-secret")], typeNameFor: ownedNames, clock: { 0 })
        let json = CKM3UProbeReflection.snapshot([OwnedRoute.providerJsonDetail("owned-secret")], typeNameFor: ownedNames, clock: { 0 })
        XCTAssertTrue(m3u.tags.contains("case-m3u-provider")); XCTAssertTrue(json.tags.contains("case-json-provider"))
        XCTAssertFalse(m3u.summary.contains("owned-secret")); XCTAssertFalse(json.summary.contains("owned-secret"))
    }
    private struct OwnedM3UTarget { let privateValue = "owned-private-value" }
    private struct OwnedJSONTarget { let privateValue = "owned-private-value" }
    private struct OwnedWrapper { let _rootView: Any }
    private struct OwnedSibling { let content: String = "owned-private-sibling" }
    private struct OwnedPriorityRouter { let _path: [OwnedRoute] }
    private struct OwnedPriorityContainer {
        let unrelated: [OwnedSibling]
        let _router: OwnedPriorityRouter
    }
    private struct OwnedFallbackContainer { let unrelated: OwnedSibling; let deferred: OwnedWrapper }
    private func priorityNames(_ value: Any) -> String {
        if value is OwnedM3UTarget { return "MonPlayer.ProviderM3UDetailScreen" }
        if value is OwnedJSONTarget { return "MonPlayer.ProviderJsonDetailScreen" }
        if value is OwnedWrapper { return "SwiftUI.OwnedWrapper" }
        if value is OwnedSibling { return "SwiftUI.OwnedSibling" }
        if value is OwnedPriorityRouter { return "MonPlayer.AppRouter" }
        if value is OwnedPriorityContainer { return "SwiftUI.OwnedPriorityContainer" }
        if value is OwnedFallbackContainer { return "SwiftUI.OwnedFallbackContainer" }
        return ownedNames(value)
    }
    func testM3UPriorityRootChainPrecedesWideSiblingRootsWithinExistingNodeBudget() {
        let root = OwnedWrapper(_rootView: OwnedWrapper(_rootView: OwnedM3UTarget()))
        let roots: [Any] = [root] + Array(repeating: OwnedSibling(), count: 63)
        let result = CKM3UProbeReflection.snapshot(roots, nodes: 4, typeNameFor: priorityNames, clock: { 0 })
        XCTAssertTrue(result.tags.contains("m3u-provider")); XCTAssertEqual(result.visited, 4)
        XCTAssertTrue(result.limits.contains("nodes")); XCTAssertFalse(result.summary.contains("owned-private"))
    }
    func testM3UPriorityRouterPathPrecedesUnrelatedArray() {
        let root = OwnedPriorityContainer(unrelated: Array(repeating: OwnedSibling(), count: 200),
                                          _router: OwnedPriorityRouter(_path: [.providerM3UDetail("owned-secret")]))
        let result = CKM3UProbeReflection.snapshot([root], nodes: 4, typeNameFor: priorityNames, clock: { 0 })
        XCTAssertTrue(result.tags.contains("router")); XCTAssertTrue(result.tags.contains("case-m3u-provider"))
        XCTAssertTrue(result.fields.contains("_router")); XCTAssertTrue(result.fields.contains("_path"))
        XCTAssertEqual(result.visited, 4); XCTAssertFalse(result.summary.contains("owned-secret"))
    }
    func testM3UPriorityFallbackStillFindsDeferredRootWithoutIncreasingDepth() {
        let root = OwnedFallbackContainer(unrelated: OwnedSibling(), deferred: OwnedWrapper(_rootView: OwnedM3UTarget()))
        let result = CKM3UProbeReflection.snapshot([root], typeNameFor: priorityNames, clock: { 0 })
        XCTAssertTrue(result.tags.contains("m3u-provider")); XCTAssertLessThanOrEqual(result.visited, 8)
        XCTAssertFalse(result.summary.contains("owned-private"))
    }
    func testM3UPriorityReportsRootNodeAndTimeLimitsWithoutReflectingPastBounds() {
        let roots = Array(repeating: "owned-secret", count: 100)
        let result = CKM3UProbeReflection.snapshot(roots, nodes: 0)
        XCTAssertEqual(result.visited, 0); XCTAssertEqual(result.limits, ["roots", "nodes"])
        let timed = CKM3UProbeReflection.snapshot([OwnedM3UTarget()], seconds: 0, typeNameFor: priorityNames)
        XCTAssertEqual(timed.visited, 0); XCTAssertEqual(timed.limits, ["time"])
    }
    func testM3UPriorityReportsDepthLimitConservatively() {
        let root = OwnedWrapper(_rootView: OwnedM3UTarget())
        let result = CKM3UProbeReflection.snapshot([root], depth: 1, typeNameFor: priorityNames, clock: { 0 })
        XCTAssertTrue(result.truncated); XCTAssertTrue(result.limits.contains("depth"))
        XCTAssertEqual(result.visited, 2)
    }
    func testM3UPriorityReportsChildLimitWithoutWalkingLargeScalarCollection() {
        let result = CKM3UProbeReflection.snapshot([Array(repeating: 1, count: 10000)], clock: { 0 })
        XCTAssertEqual(result.visited, 1); XCTAssertTrue(result.limits.contains("children"))
        XCTAssertTrue(result.fields.isEmpty); XCTAssertTrue(result.tags.isEmpty)
    }
    func testM3UPriorityRejectsOversizedTypeNamesAndLogsOnlyFixedReason() {
        let result = CKM3UProbeReflection.snapshot([OwnedM3UTarget()], typeNameFor: { _ in String(repeating: "x", count: 9000) }, clock: { 0 })
        XCTAssertEqual(result.limits, ["types"]); XCTAssertTrue(result.tags.isEmpty)
        XCTAssertTrue(result.fields.isEmpty); XCTAssertFalse(result.summary.contains("xxxx"))
    }
    func testM3UPriorityDoesNotAuthorizeM3UWhenBothActualBranchesAreObserved() {
        let roots: [Any] = [OwnedWrapper(_rootView: OwnedM3UTarget()), OwnedWrapper(_rootView: OwnedJSONTarget())]
        // Structural coverage must not depend on cold metadata or CI scheduling.
        let result = CKM3UProbeReflection.snapshot(roots, typeNameFor: priorityNames, clock: { 0 })
        XCTAssertEqual(CKM3UProbePolicy.branch(result.tags), "ambiguous")
        XCTAssertFalse(result.truncated)
        XCTAssertLessThanOrEqual(result.visited, 256)
        XCTAssertTrue(result.limits.isSubset(of: CKM3UProbeReflection.limitNames))
    }
    func testM3UPriorityTimeLimitCanStopBeforeLaterJSONRootWithoutProvingAbsence() {
        var now: TimeInterval = 0
        let roots: [Any] = [OwnedWrapper(_rootView: OwnedM3UTarget()), OwnedWrapper(_rootView: OwnedJSONTarget())]
        let result = CKM3UProbeReflection.snapshot(roots, typeNameFor: { value in
            if value is OwnedJSONTarget { now = 0.013 }
            return self.priorityNames(value)
        }, clock: { now })
        XCTAssertTrue(result.tags.contains("m3u-provider"))
        XCTAssertFalse(result.tags.contains("json-provider"))
        XCTAssertEqual(result.limits, ["time"]); XCTAssertTrue(result.truncated)
        XCTAssertEqual(CKM3UProbePolicy.branch(result.tags), "m3u-candidate")
    }
    func testM3UPriorityControlledClockStillClampsBudgetToTwelveMilliseconds() {
        var now: TimeInterval = 0
        var reflections = 0
        let result = CKM3UProbeReflection.snapshot([OwnedM3UTarget()], seconds: 999,
            typeNameFor: { value in reflections += 1; return self.priorityNames(value) },
            clock: { defer { now += 0.013 }; return now })
        XCTAssertEqual(result.visited, 0); XCTAssertEqual(result.limits, ["time"])
        XCTAssertEqual(reflections, 0)
    }
    @MainActor
    func testM3UProbeDisabledModeCannotChangeVisibleController() {
        let probe = CKM3URouteProbe(), controller = CKRuntime.top()
        probe.start(info: [:]); XCTAssertFalse(probe.isRunning)
        XCTAssertTrue(CKRuntime.top() === controller)
    }
    @MainActor
    func testM3UProbeEnabledModeHasNoPanelOrNavigationAndStopsIdempotently() {
        let probe = CKM3URouteProbe(), controller = CKRuntime.top()
        probe.start(info: ["CKM3URouteProbeMode": true, "CKNativeLinkMode": true, "CKOriginalPlayerMode": true])
        XCTAssertTrue(probe.isRunning); XCTAssertTrue(CKRuntime.top() === controller)
        probe.stop(); probe.stop(); XCTAssertFalse(probe.isRunning)
        XCTAssertTrue(CKRuntime.top() === controller)
    }
}
