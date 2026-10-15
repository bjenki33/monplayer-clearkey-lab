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
        XCTAssertEqual(CKM3UProbePolicy.exactTags(typeName: "MonPlayer.AppRouter"), ["router"])
        XCTAssertTrue(CKM3UProbePolicy.exactTags(typeName: "Swift.Optional<MonPlayer.AppRouter>").isEmpty)
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

    private struct OwnedFocusedPublished<Value> { let storage: OwnedFocusedStorage<Value> }
    private struct OwnedFocusedStorage<Value> { let value: Value }
    private struct OwnedFocusedRouter {
        let marker: Int
        let _path: OwnedFocusedPublished<[OwnedRoute]>
        init(marker: Int = 0, _path: OwnedFocusedPublished<[OwnedRoute]>) {
            self.marker = marker; self._path = _path
        }
    }
    private struct OwnedFocusedCarrier {
        let marker: Int
        let some: OwnedFocusedRouter
    }
    private struct OwnedFocusedTupleCarrier { let router: OwnedFocusedRouter }
    private struct OwnedFocusedInternalCarrier { let some: OwnedFocusedRouter }
    private struct OwnedFocusedEmptyCarrier { let marker: Int }
    private struct OwnedFocusedRoot { let _router: OwnedFocusedRouter }
    private struct OwnedFocusedHost {
        let _rootView: OwnedFocusedRoot
        let unrelated: OwnedFocusedSecret
        init(_rootView: OwnedFocusedRoot, unrelated: OwnedFocusedSecret = OwnedFocusedSecret()) {
            self._rootView = _rootView; self.unrelated = unrelated
        }
    }
    private final class OwnedFocusedSecret: CustomStringConvertible {
        var descriptions = 0
        var description: String { descriptions += 1; return "owned-private-route-payload" }
    }
    private final class OwnedFocusedReflectable: CustomReflectable {
        var reflections = 0
        var customMirror: Mirror {
            reflections += 1
            return Mirror(self, children: ["secret": "owned-private-route-payload"])
        }
    }
    private struct OwnedFocusedScalarContainer { let value: OwnedFocusedReflectable }
    private final class OwnedFocusedCycle { var content: OwnedFocusedCycle? }
    private func focusedNames(_ value: Any) -> String {
        if value is OwnedFocusedHost { return "UIKit.UIHostingController<MonPlayer.Root>" }
        if value is OwnedFocusedRoot { return "SwiftUI.ModifiedContent<MonPlayer.Root, SwiftUI.Environment>" }
        if value is OwnedFocusedCarrier { return "Swift.Optional<MonPlayer.AppRouter>" }
        if value is OwnedFocusedTupleCarrier { return "(MonPlayer.AppRouter, MonPlayer.PlayerViewModel)" }
        if value is OwnedFocusedInternalCarrier { return "Swift._Owned<MonPlayer.AppRouter>" }
        if value is OwnedFocusedEmptyCarrier { return "Swift.Optional<MonPlayer.AppRouter>" }
        if value is OwnedFocusedRouter { return "MonPlayer.AppRouter" }
        if value is OwnedFocusedPublished<[OwnedRoute]> { return "Combine.Published<Swift.Array<MonPlayer.AppRoute>>" }
        if value is OwnedFocusedStorage<[OwnedRoute]> { return "Combine.Published<Swift.Array<MonPlayer.AppRoute>>.Storage" }
        if value is [OwnedRoute] { return "Swift.Array<MonPlayer.AppRoute>" }
        if value is OwnedRoute { return "MonPlayer.AppRoute" }
        if value is OwnedFocusedCycle { return "SwiftUI.OwnedFocusedCycle" }
        if value is OwnedFocusedSecret { return "MonPlayer.OwnedFocusedSecret" }
        if value is OwnedFocusedScalarContainer { return "SwiftUI.OwnedFocusedScalarContainer" }
        if value is OwnedFocusedReflectable { return "Swift.String" }
        return String(reflecting: type(of: value))
    }
    func testM3UGenericScanHandsOnlyFirstExactRouterToFocusedRoute() {
        let m3u = OwnedFocusedRouter(marker: 1, _path: OwnedFocusedPublished(storage:
            OwnedFocusedStorage(value: [.providerM3UDetail("owned-private-route-payload")])))
        let json = OwnedFocusedRouter(marker: 2, _path: OwnedFocusedPublished(storage:
            OwnedFocusedStorage(value: [.providerJsonDetail("owned-private-route-payload")])))
        let scan = CKM3UProbeReflection.scan([m3u, json], typeNameFor: focusedNames, clock: { 0 })
        XCTAssertEqual(CKM3UProbePolicy.branch(scan.snapshot.tags), "ambiguous")
        XCTAssertEqual((scan.focusedRouter as? OwnedFocusedRouter)?.marker, 1)
        guard let router = scan.focusedRouter else { return XCTFail("exact router handoff missing") }
        let focused = CKM3UFocusedRouteReflection.snapshot([router], typeNameFor: focusedNames, clock: { 0 })
        XCTAssertTrue(focused.tags.isSuperset(of: ["focused-router", "focused-path", "focused-route",
                                                   "router", "route", "case-m3u-provider"]))
        XCTAssertFalse(focused.tags.contains("case-json-provider"))
        XCTAssertFalse(focused.summary.contains("owned-private"))
    }
    func testM3UGenericScanHandsFirstRouterCarrierToFocusedRoute() {
        let first = OwnedFocusedCarrier(marker: 1, some: OwnedFocusedRouter(_path: OwnedFocusedPublished(storage:
            OwnedFocusedStorage(value: [.providerM3UDetail("owned-private-route-payload")]))))
        let second = OwnedFocusedCarrier(marker: 2, some: OwnedFocusedRouter(_path: OwnedFocusedPublished(storage:
            OwnedFocusedStorage(value: [.providerJsonDetail("owned-private-route-payload")]))))
        let scan = CKM3UProbeReflection.scan([first, second], nodes: 1,
            typeNameFor: focusedNames, clock: { 0 })
        XCTAssertEqual((scan.focusedRouter as? OwnedFocusedCarrier)?.marker, 1)
        guard let carrier = scan.focusedRouter else { return XCTFail("router carrier handoff missing") }
        let focused = CKM3UFocusedRouteReflection.snapshot([carrier], typeNameFor: focusedNames, clock: { 0 })
        XCTAssertTrue(focused.tags.isSuperset(of: ["focused-carrier", "focused-router", "focused-path",
                                                   "focused-route", "case-m3u-provider"]))
        XCTAssertFalse(focused.tags.contains("case-json-provider"))
        XCTAssertFalse(focused.summary.contains("owned-private"))
    }
    func testM3UFocusedRouteUnwrapsTupleRouterCarrier() {
        let carrier = OwnedFocusedTupleCarrier(router: OwnedFocusedRouter(_path: OwnedFocusedPublished(storage:
            OwnedFocusedStorage(value: [.providerM3UDetail("owned-private-route-payload")]))))
        let scan = CKM3UProbeReflection.scan([carrier], nodes: 1,
            typeNameFor: focusedNames, clock: { 0 })
        guard let selected = scan.focusedRouter else { return XCTFail("tuple carrier handoff missing") }
        let focused = CKM3UFocusedRouteReflection.snapshot([selected], typeNameFor: focusedNames, clock: { 0 })
        XCTAssertTrue(focused.tags.isSuperset(of: ["focused-carrier", "focused-router", "focused-path",
                                                   "focused-route", "case-m3u-provider"]))
        XCTAssertFalse(focused.summary.contains("owned-private")); XCTAssertFalse(focused.truncated)
    }
    func testM3UFocusedRouteUnwrapsSwiftInternalRouterCarrier() {
        let carrier = OwnedFocusedInternalCarrier(some: OwnedFocusedRouter(_path: OwnedFocusedPublished(storage:
            OwnedFocusedStorage(value: [.providerM3UDetail("owned-private-route-payload")]))))
        let scan = CKM3UProbeReflection.scan([carrier], nodes: 1,
            typeNameFor: focusedNames, clock: { 0 })
        guard let selected = scan.focusedRouter else { return XCTFail("Swift internal carrier handoff missing") }
        let focused = CKM3UFocusedRouteReflection.snapshot([selected], typeNameFor: focusedNames, clock: { 0 })
        XCTAssertTrue(focused.tags.isSuperset(of: ["focused-carrier", "focused-router", "focused-path",
                                                   "focused-route", "case-m3u-provider"]))
        XCTAssertFalse(focused.summary.contains("owned-private")); XCTAssertFalse(focused.truncated)
    }
    func testM3UGenericScanPrefersLaterExactRouterOverCarrier() {
        let carrier = OwnedFocusedEmptyCarrier(marker: 1)
        let exact = OwnedFocusedRouter(marker: 2, _path: OwnedFocusedPublished(storage:
            OwnedFocusedStorage(value: [.providerM3UDetail("owned-private-route-payload")])))
        let scan = CKM3UProbeReflection.scan([carrier, exact], typeNameFor: focusedNames, clock: { 0 })
        XCTAssertEqual((scan.focusedRouter as? OwnedFocusedRouter)?.marker, 2)
    }
    func testM3UGenericScanRejectsRouterLookalikeAndScalar() {
        let router = OwnedFocusedRouter(_path: OwnedFocusedPublished(storage:
            OwnedFocusedStorage(value: [.providerM3UDetail("owned-private-route-payload")])))
        let lookalike = CKM3UProbeReflection.scan([router], typeNameFor: { _ in "OtherApp.AppRouter" }, clock: { 0 })
        let wrappedLookalike = CKM3UProbeReflection.scan([OwnedFocusedCarrier(marker: 1, some: router)],
            typeNameFor: { _ in "Swift.Optional<OtherApp.AppRouter>" }, clock: { 0 })
        let scalar = CKM3UProbeReflection.scan(["MonPlayer.AppRouter"], clock: { 0 })
        XCTAssertNil(lookalike.focusedRouter); XCTAssertNil(wrappedLookalike.focusedRouter)
        XCTAssertNil(scalar.focusedRouter)
        XCTAssertTrue(lookalike.snapshot.tags.isEmpty); XCTAssertTrue(wrappedLookalike.snapshot.tags.isEmpty)
        XCTAssertTrue(scalar.snapshot.tags.isEmpty)
    }
    func testM3UGenericScanExpiredBudgetCannotHandOffRouter() {
        var typeLookups = 0
        let router = OwnedFocusedRouter(_path: OwnedFocusedPublished(storage: OwnedFocusedStorage(value: [])))
        let scan = CKM3UProbeReflection.scan([router], seconds: 0,
            typeNameFor: { value in typeLookups += 1; return self.focusedNames(value) })
        XCTAssertNil(scan.focusedRouter); XCTAssertEqual(scan.snapshot.visited, 0)
        XCTAssertEqual(scan.snapshot.limits, ["time"]); XCTAssertEqual(typeLookups, 0)
    }
    func testM3UFocusedRouteWalksRootRouterPublishedPathToM3UCase() {
        let router = OwnedFocusedRouter(_path: OwnedFocusedPublished(storage:
            OwnedFocusedStorage(value: [.providerM3UDetail("owned-private-route-payload")])))
        let result = CKM3UFocusedRouteReflection.snapshot(
            [OwnedFocusedHost(_rootView: OwnedFocusedRoot(_router: router))],
            typeNameFor: focusedNames, clock: { 0 })
        XCTAssertTrue(result.tags.isSuperset(of: ["focused-root", "focused-router", "focused-path",
                                                  "focused-route", "router", "route", "case-m3u-provider"]))
        XCTAssertTrue(result.fields.isSuperset(of: ["_rootView", "_router", "_path", "storage", "value"]))
        XCTAssertEqual(CKM3UProbePolicy.branch(result.tags), "m3u-candidate")
        XCTAssertFalse(result.summary.contains("owned-private")); XCTAssertFalse(result.truncated)
    }
    func testM3UFocusedRouteDistinguishesJSONWithoutReadingPayload() {
        let secret = OwnedFocusedSecret()
        let router = OwnedFocusedRouter(_path: OwnedFocusedPublished(storage:
            OwnedFocusedStorage(value: [.providerJsonDetail("owned-private-route-payload")])))
        let result = CKM3UFocusedRouteReflection.snapshot(
            [OwnedFocusedHost(_rootView: OwnedFocusedRoot(_router: router), unrelated: secret)],
            typeNameFor: focusedNames, clock: { 0 })
        XCTAssertTrue(result.tags.contains("case-json-provider"))
        XCTAssertFalse(result.tags.contains("case-m3u-provider"))
        XCTAssertEqual(CKM3UProbePolicy.branch(result.tags), "json-candidate")
        XCTAssertEqual(secret.descriptions, 0); XCTAssertFalse(result.summary.contains("owned-private"))
    }
    func testM3UFocusedRouteStopsCyclesWithinSmallerNodeBudget() {
        weak var released: OwnedFocusedCycle?
        let result = autoreleasepool { () -> CKM3UProbeSnapshot in
            let node = OwnedFocusedCycle(); node.content = node; released = node
            defer { node.content = nil }
            return CKM3UFocusedRouteReflection.snapshot([node], typeNameFor: focusedNames, clock: { 0 })
        }
        XCTAssertLessThanOrEqual(result.visited, 3); XCTAssertFalse(result.truncated); XCTAssertNil(released)
    }
    func testM3UFocusedRouteClampsNodesDepthAndTimeIndependently() {
        let host = OwnedFocusedHost(_rootView: OwnedFocusedRoot(_router:
            OwnedFocusedRouter(_path: OwnedFocusedPublished(storage: OwnedFocusedStorage(value: [])))))
        let nodes = CKM3UFocusedRouteReflection.snapshot([host], nodes: 0, typeNameFor: focusedNames)
        XCTAssertEqual(nodes.visited, 0); XCTAssertEqual(nodes.limits, ["focus-nodes"])
        let depth = CKM3UFocusedRouteReflection.snapshot([host], depth: 0, typeNameFor: focusedNames, clock: { 0 })
        XCTAssertEqual(depth.visited, 1); XCTAssertEqual(depth.limits, ["focus-depth"])
        var now: TimeInterval = 0
        let timed = CKM3UFocusedRouteReflection.snapshot([host], seconds: 999,
            typeNameFor: { value in now = 0.007; return self.focusedNames(value) }, clock: { now })
        XCTAssertEqual(timed.visited, 1); XCTAssertEqual(timed.limits, ["focus-time"])
        XCTAssertEqual(CKM3UFocusedRouteReflection.maximumNodes, 64)
        XCTAssertLessThan(CKM3UFocusedRouteReflection.maximumNodes, 256)
    }
    func testM3UFocusedRouteRejectsOversizedTypeNamesWithFixedReasonOnly() {
        let result = CKM3UFocusedRouteReflection.snapshot([OwnedFocusedRoot(_router:
            OwnedFocusedRouter(_path: OwnedFocusedPublished(storage: OwnedFocusedStorage(value: []))))],
            typeNameFor: { _ in String(repeating: "x", count: 5000) }, clock: { 0 })
        XCTAssertEqual(result.limits, ["focus-types"]); XCTAssertTrue(result.tags.isEmpty)
        XCTAssertTrue(result.fields.isEmpty); XCTAssertFalse(result.summary.contains("xxxx"))
    }
    func testM3UFocusedRouteStopsBeforeReflectingScalarPayload() {
        let payload = OwnedFocusedReflectable()
        let result = CKM3UFocusedRouteReflection.snapshot(
            [OwnedFocusedScalarContainer(value: payload)], typeNameFor: focusedNames, clock: { 0 })
        XCTAssertEqual(payload.reflections, 0); XCTAssertEqual(result.visited, 2)
        XCTAssertEqual(result.fields, ["value"]); XCTAssertFalse(result.summary.contains("owned-private"))
    }
    func testM3UProbeSnapshotMergesFocusedTokensWithinExistingEvidenceBound() {
        var generic = CKM3UProbeSnapshot(tags: ["player-model"], fields: ["content"], limits: [],
                                         visited: 250, truncated: false)
        let focused = CKM3UProbeSnapshot(tags: ["focused-router", "case-m3u-group"], fields: ["_path"],
                                         limits: ["focus-time"], visited: 20, truncated: true)
        generic.merge(focused)
        XCTAssertEqual(generic.visited, 256); XCTAssertTrue(generic.truncated)
        XCTAssertTrue(generic.tags.isSuperset(of: ["player-model", "focused-router", "case-m3u-group"]))
        XCTAssertEqual(generic.limits, ["focus-time"])
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
