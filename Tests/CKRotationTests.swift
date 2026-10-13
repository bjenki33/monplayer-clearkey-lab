import Foundation
import UIKit
import XCTest
@testable import CKBridge

enum CKRotationFixtures {
    static let third = "404142434445464748494a4b4c4d4e4f"
    static let thirdKey = "505152535455565758595a5b5c5d5e5f"
    static func channel(_ session: String, preloaded: Bool = false, omitNew: Bool = false) throws -> CKChannel {
        var channel = try CKLicenseFixtures.channel(manifest: "http://127.0.0.1:18761/live/\(session)/manifest.mpd")
        if preloaded {
            var values = [CKLicenseFixtures.kid:"101112131415161718191a1b1c1d1e1f",
                          CKLicenseFixtures.second:"303132333435363738393a3b3c3d3e3f"]
            if !omitNew { values[third] = thirdKey }
            let data = try JSONSerialization.data(withJSONObject: values, options: .sortedKeys)
            channel.licenseSpec = CKLicenseSpec(source: String(decoding: data, as: UTF8.self), headers: [:])
        } else {
            channel.licenseSpec = CKLicenseSpec(source: "http://127.0.0.1:18761/renew/\(session)",
                                                 headers: ["X-License":"owned-license"], body: .challenge,
                                                 inheritsStreamHeaders: false)
        }
        return channel
    }
    static func advance(_ session: String) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18761/rotate/\(session)/advance")!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }
    static func stats(_ session: String) async throws -> [String:Double] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18761/live/\(session)/stats")!)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Double])
    }
}

final class CKRotationTests: XCTestCase {
    func testCadenceIsExplicitDynamicSinglePeriodAndBounded() {
        func manifest(_ cadence: String, type: String = "dynamic", extra: String = "") -> Data {
            Data("<MPD type=\"\(type)\" minimumUpdatePeriod=\"\(cadence)\"><Period/>\(extra)</MPD>".utf8)
        }
        XCTAssertEqual(CKRotationCadence.read(manifest("PT0.1S")), 2)
        XCTAssertEqual(CKRotationCadence.read(manifest("PT1M30S")), 60)
        XCTAssertEqual(CKRotationCadence.read(manifest("PT12.5S")), 12.5)
        for value in ["PT", "P1D", "PT0S", "PT-1S", "PTNaNS", "PT1e2S", "PT1Sbad"] {
            XCTAssertNil(CKRotationCadence.read(manifest(value)))
        }
        XCTAssertNil(CKRotationCadence.read(manifest("PT2S", type: "static")))
        XCTAssertNil(CKRotationCadence.read(manifest("PT2S", extra: "<Period/>")))
        XCTAssertNil(CKRotationCadence.read(Data("<!DOCTYPE MPD><MPD type=\"dynamic\"/>".utf8)))
    }
    func testLegacyGETAndInconsistentSingleKeyDoNotStartPolling() async throws {
        let channel = try CKLicenseFixtures.channel(modern: false, template: "", manifest: "http://127.0.0.1:18761/live/legacyrotationpolicy/manifest.mpd")
        let source = try await CKSourceResolver.resolve(channel)
        XCTAssertNil(CKRotationState.begin(channel: channel, source: source))
        var inline = try CKRotationFixtures.channel("rotationpolicy", preloaded: true)
        inline.licenseSpec = CKLicenseSpec(source: "\(CKLicenseFixtures.kid):101112131415161718191a1b1c1d1e1f", headers: [:])
        let single = CKResolvedSource(keys: try CKKeySet([CKLicenseFixtures.kid:"101112131415161718191a1b1c1d1e1f"]),
                                      data: source.data, url: source.url, keySeconds: 0, manifestSeconds: 0)
        XCTAssertNil(CKRotationState.begin(channel: inline, source: single))
    }
    func testMergingIsAtomicRejectsConflictsAndLifetimeBound() throws {
        let first = try CKKeySet([CKLicenseFixtures.kid:"101112131415161718191a1b1c1d1e1f"])
        let next = try first.including(CKKeySet([CKRotationFixtures.third:CKRotationFixtures.thirdKey]))
        XCTAssertTrue(next.contains([CKLicenseFixtures.kid, CKRotationFixtures.third]))
        XCTAssertFalse(first.contains([CKRotationFixtures.third]), "failed/late updates cannot mutate the current set")
        XCTAssertThrowsError(try first.including(CKKeySet([CKLicenseFixtures.kid:CKRotationFixtures.thirdKey])))
        let many = try CKKeySet(Dictionary(uniqueKeysWithValues: (0..<128).map {
            (String(format: "%032x", $0), "101112131415161718191a1b1c1d1e1f")
        }))
        XCTAssertThrowsError(try many.including(CKKeySet([CKRotationFixtures.third:CKRotationFixtures.thirdKey])))
    }
    func testActualNewKeyIsFetchedOnlyAfterDeclaredChangeAndNotRepeated() async throws {
        let session = "rotationnetwork", channel = try CKRotationFixtures.channel(session)
        let source = try await CKSourceResolver.resolve(channel)
        let initial = try XCTUnwrap(CKRotationState.begin(channel: channel, source: source))
        XCTAssertFalse(initial.keys.contains([CKRotationFixtures.third]), "the new key must NOT be preloaded")
        let unchanged = try await CKKeyRotation.refresh(channel, state: initial)
        XCTAssertFalse(unchanged.changed); XCTAssertFalse(unchanged.fetched)
        try await CKRotationFixtures.advance(session)
        let changed = try await CKKeyRotation.refresh(channel, state: unchanged.state)
        XCTAssertTrue(changed.changed); XCTAssertTrue(changed.fetched)
        XCTAssertTrue(changed.state.keys.contains([CKRotationFixtures.third]))
        let again = try await CKKeyRotation.refresh(channel, state: changed.state)
        XCTAssertFalse(again.changed); XCTAssertFalse(again.fetched)
        let stats = try await CKRotationFixtures.stats(session)
        XCTAssertEqual(stats["license_requests"], 2); XCTAssertEqual(stats["new_key_requests"], 1)
    }
    func testActualPreloadedRotationNeverAcquiresLicense() async throws {
        let session = "rotationpreloadednetwork", channel = try CKRotationFixtures.channel(session, preloaded: true)
        let source = try await CKSourceResolver.resolve(channel)
        let initial = try XCTUnwrap(CKRotationState.begin(channel: channel, source: source))
        XCTAssertTrue(initial.keys.contains([CKRotationFixtures.third]))
        try await CKRotationFixtures.advance(session)
        let changed = try await CKKeyRotation.refresh(channel, state: initial)
        XCTAssertTrue(changed.changed); XCTAssertFalse(changed.fetched)
        let stats = try await CKRotationFixtures.stats(session)
        XCTAssertEqual(stats["license_requests"] ?? 0, 0)
    }
    func testActualUnknownInlineKeyFailsWithoutGuessingEndpoint() async throws {
        let session = "rotationmissinginline", channel = try CKRotationFixtures.channel(session, preloaded: true, omitNew: true)
        let source = try await CKSourceResolver.resolve(channel)
        let initial = try XCTUnwrap(CKRotationState.begin(channel: channel, source: source))
        try await CKRotationFixtures.advance(session)
        do { _ = try await CKKeyRotation.refresh(channel, state: initial); XCTFail("missing key must fail") }
        catch let failure as CKResolutionError { XCTAssertEqual(failure.underlying as? CKFailure, .missingLicenseKey) }
        let stats = try await CKRotationFixtures.stats(session)
        XCTAssertEqual(stats["license_requests"] ?? 0, 0)
    }
    func testActualRenewalMissingConflictingOrDeniedResponseDoesNotCommit() async throws {
        for mode in ["missing", "conflict", "denied"] {
            let session = "rotationnegative" + mode, channel = try CKRotationFixtures.channel(session)
            let source = try await CKSourceResolver.resolve(channel)
            let initial = try XCTUnwrap(CKRotationState.begin(channel: channel, source: source))
            try await CKRotationFixtures.advance(session)
            do { _ = try await CKKeyRotation.refresh(channel, state: initial); XCTFail("bad renewal must fail") }
            catch let failure as CKResolutionError {
                XCTAssertEqual(failure.stage, .key)
                if mode != "denied" { XCTAssertEqual(failure.underlying as? CKFailure, mode == "missing" ? .missingLicenseKey : .invalidKey) }
                else if case .http(403)? = failure.underlying as? CKOpenFailure { }
                else { XCTFail("denied license must remain HTTP403") }
            }
            XCTAssertFalse(initial.keys.contains([CKRotationFixtures.third]))
        }
    }
    func testActualCanceledRenewalDoesNotReturnFreshKeys() async throws {
        let session = "rotationcancelslow", channel = try CKRotationFixtures.channel(session)
        let source = try await CKSourceResolver.resolve(channel)
        let initial = try XCTUnwrap(CKRotationState.begin(channel: channel, source: source))
        try await CKRotationFixtures.advance(session)
        let task = Task { try await CKKeyRotation.refresh(channel, state: initial) }
        try await Task.sleep(nanoseconds: 300_000_000); let began = ProcessInfo.processInfo.systemUptime; task.cancel()
        do { _ = try await task.value; XCTFail("canceled renewal cannot return") } catch { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 3)
        XCTAssertFalse(initial.keys.contains([CKRotationFixtures.third]))
    }
}
