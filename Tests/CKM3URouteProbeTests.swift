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
        let result = CKM3UProbeReflection.snapshot([secret, URL(string: "https://example.invalid/" + secret)!])
        XCTAssertTrue(result.tags.isEmpty); XCTAssertTrue(result.fields.isEmpty)
        XCTAssertFalse(result.summary.contains(secret)); XCTAssertFalse(result.summary.contains("example.invalid"))
    }
    func testM3UProbeRejectsOversizedTypeNames() {
        XCTAssertTrue(CKM3UProbePolicy.tags(typeName: String(repeating: "x", count: 9000)).isEmpty)
        XCTAssertFalse(CKM3UProbePolicy.traversable(String(repeating: "x", count: 9000)))
    }
    func testM3UProbeLimitsRootAndNodeCounts() {
        let snapshot = CKM3UProbeReflection.snapshot(Array(repeating: "owned", count: 200), nodes: 4)
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
        let snapshot = CKM3UProbeReflection.snapshot([node], typeNameFor: ownedNames)
        XCTAssertTrue(snapshot.fields.contains("_currentSource"))
        XCTAssertFalse(snapshot.summary.contains("owned-private-account")); XCTAssertEqual(node.descriptions, 0)
    }
    func testM3UProbeObjectCycleStopsWithoutRetainingGraph() {
        let node = OwnedNode(); node.next = node
        defer { node.next = nil }
        let snapshot = CKM3UProbeReflection.snapshot([node], typeNameFor: ownedNames)
        XCTAssertLessThanOrEqual(snapshot.visited, 4); XCTAssertFalse(snapshot.truncated)
    }
    func testM3UProbeReadOnlySuperclassFieldsAreIncluded() {
        let snapshot = CKM3UProbeReflection.snapshot([OwnedChild()], typeNameFor: ownedNames)
        XCTAssertTrue(snapshot.fields.contains("_appRouter")); XCTAssertTrue(snapshot.fields.contains("rootView"))
        XCTAssertFalse(snapshot.summary.contains("owned-secret"))
    }
    func testM3UProbeEnumCaseEvidenceDoesNotLogPayload() {
        let m3u = CKM3UProbeReflection.snapshot([OwnedRoute.providerM3UDetail("owned-secret")], typeNameFor: ownedNames)
        let json = CKM3UProbeReflection.snapshot([OwnedRoute.providerJsonDetail("owned-secret")], typeNameFor: ownedNames)
        XCTAssertTrue(m3u.tags.contains("case-m3u-provider")); XCTAssertTrue(json.tags.contains("case-json-provider"))
        XCTAssertFalse(m3u.summary.contains("owned-secret")); XCTAssertFalse(json.summary.contains("owned-secret"))
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
