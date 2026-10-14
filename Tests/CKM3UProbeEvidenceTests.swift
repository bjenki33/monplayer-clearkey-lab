import Foundation
import XCTest
@testable import CKBridge

final class CKM3UProbeEvidenceTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(CKM3UProbeEvidence.fileName)
    }
    private func read(_ url: URL) throws -> CKM3UProbeEvidenceReport {
        try JSONDecoder().decode(CKM3UProbeEvidenceReport.self, from: Data(contentsOf: url))
    }
    func testM3UEvidenceDropsUnknownTokensAndNeverPersistsValues() throws {
        let url = try temporaryURL(), store = CKM3UProbeEvidence(url: url)
        var snapshot = CKM3UProbeSnapshot()
        snapshot.tags = ["router", "m3u-provider", "owned-secret"]
        snapshot.fields = ["rootView", "owned-account", "https://example.invalid/key"]
        store.update(.started, ticks: 0, seconds: 0)
        store.update(.sample, ticks: 1, seconds: 1, snapshot: snapshot)
        store.drainForTesting()
        let record = try XCTUnwrap(read(url).records.last)
        XCTAssertEqual(record.tags, ["m3u-provider", "router"])
        XCTAssertEqual(record.fields, ["rootView"])
        XCTAssertEqual(record.branch, "m3u-candidate")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(body.contains("owned-secret")); XCTAssertFalse(body.contains("owned-account"))
        XCTAssertFalse(body.contains("example.invalid"))
    }
    func testM3UEvidenceClampsCountsAndNonfiniteSeconds() throws {
        let url = try temporaryURL(), store = CKM3UProbeEvidence(url: url)
        var snapshot = CKM3UProbeSnapshot(); snapshot.visited = 1000
        store.update(.started, ticks: -2, seconds: .nan)
        store.update(.sample, ticks: 1000, seconds: .infinity, missingControllerTicks: 1000, snapshot: snapshot)
        store.drainForTesting()
        let report = try read(url), record = try XCTUnwrap(report.records.last)
        XCTAssertEqual(report.ticks, 300); XCTAssertEqual(report.missingControllerTicks, 300)
        XCTAssertEqual(record.nodes, 256); XCTAssertEqual(record.foregroundSeconds, 0)
    }
    func testM3UEvidenceV2LimitReasonsAreWhitelistedAndSeparateFromUserData() throws {
        let url = try temporaryURL(), store = CKM3UProbeEvidence(url: url)
        var snapshot = CKM3UProbeSnapshot()
        snapshot.limits = ["time", "nodes", "owned-secret"]; snapshot.truncated = true
        store.update(.started, ticks: 0, seconds: 0)
        store.update(.sample, ticks: 1, seconds: 1, snapshot: snapshot)
        store.drainForTesting()
        let report = try read(url), record = try XCTUnwrap(report.records.last)
        XCTAssertEqual(report.schema, 2); XCTAssertEqual(record.limits, ["nodes", "time"])
        XCTAssertEqual(CKM3UProbeEvidence.fileName, "CKM3URouteProbe-v2.json")
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("owned-secret"))
    }
    func testM3UEvidenceMaximumSamplesAndBytesAreBounded() throws {
        let url = try temporaryURL(), store = CKM3UProbeEvidence(url: url)
        var snapshot = CKM3UProbeSnapshot()
        snapshot.tags = Set(CKM3UProbePolicy.names.values).union(CKM3UProbePolicy.cases.values)
        snapshot.fields = CKM3UProbePolicy.fields; snapshot.visited = 256
        snapshot.limits = CKM3UProbeReflection.limitNames; snapshot.truncated = true
        store.update(.started, ticks: 0, seconds: 0)
        for tick in 1...200 { store.update(.sample, ticks: tick, seconds: Double(tick), snapshot: snapshot) }
        store.update(.stopped, ticks: 200, seconds: 200)
        store.drainForTesting()
        XCTAssertEqual(try read(url).records.count, 50)
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, CKM3UProbeEvidence.maximumBytes)
    }
    func testM3UEvidenceHeartbeatHasNoRecordsOrValues() throws {
        let url = try temporaryURL(), store = CKM3UProbeEvidence(url: url)
        store.update(.started, ticks: 0, seconds: 0)
        store.update(nil, ticks: 15, seconds: 15, missingControllerTicks: 3)
        store.drainForTesting()
        let report = try read(url)
        XCTAssertEqual(report.records.count, 1); XCTAssertEqual(report.ticks, 15)
        XCTAssertEqual(report.missingControllerTicks, 3)
    }
    func testM3UEvidenceStartStopAreIdempotentAndStopFreezesReport() throws {
        let url = try temporaryURL(), store = CKM3UProbeEvidence(url: url)
        store.update(.started, ticks: 0, seconds: 0)
        store.update(.started, ticks: 0, seconds: 0)
        store.update(.stopped, ticks: 1, seconds: 1)
        store.update(.sample, ticks: 2, seconds: 2, snapshot: CKM3UProbeSnapshot())
        store.update(.stopped, ticks: 3, seconds: 3)
        store.update(nil, ticks: 4, seconds: 4)
        store.drainForTesting()
        let report = try read(url)
        XCTAssertEqual(report.records.map(\.event), [.started, .stopped])
        XCTAssertEqual(report.ticks, 1); XCTAssertEqual(report.state, .stopped)
    }
    func testM3UEvidenceCannotWriteBeforeStartOrToMissingDirectory() throws {
        let url = try temporaryURL(), store = CKM3UProbeEvidence(url: url)
        store.update(.sample, ticks: 1, seconds: 1, snapshot: CKM3UProbeSnapshot())
        store.update(nil, ticks: 2, seconds: 2); store.update(.stopped, ticks: 2, seconds: 2)
        store.drainForTesting(); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let badURL = url.deletingLastPathComponent().appendingPathComponent("missing/report.json")
        let badStore = CKM3UProbeEvidence(url: badURL)
        badStore.update(.started, ticks: 0, seconds: 0); badStore.drainForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: badURL.path))
    }
    func testM3UEvidenceDedicatedReportResetsButNeighborRemainsUntouched() throws {
        let url = try temporaryURL(), neighbor = url.deletingLastPathComponent().appendingPathComponent("owned-neighbor.json")
        let owned = Data("owned-neighbor-content".utf8)
        try owned.write(to: neighbor); try Data("owned-old-report".utf8).write(to: url)
        let store = CKM3UProbeEvidence(url: url)
        store.update(.started, ticks: 0, seconds: 0); store.drainForTesting()
        XCTAssertEqual(try Data(contentsOf: neighbor), owned)
        XCTAssertEqual(try read(url).records.count, 1)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("owned-old-report"))
    }
    @MainActor
    func testM3UEvidenceDisabledProbeCreatesNoFileAndLeavesControllerUntouched() throws {
        let url = try temporaryURL(), controller = CKRuntime.top()
        let probe = CKM3URouteProbe(evidenceURL: url)
        probe.start(info: [:]); probe.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(probe.isRunning); XCTAssertTrue(CKRuntime.top() === controller)
    }
}
