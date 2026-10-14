import Foundation
import XCTest
@testable import CKBridge

final class CKSourceResolverTests: XCTestCase {
    func endpoint(_ session: String, _ mode: String, _ resource: String) -> URL {
        URL(string: "http://127.0.0.1:18761/resolve/\(session)/\(mode)/\(resource)")!
    }
    func channel(_ session: String, _ mode: String, inline: Bool = false) -> CKChannel {
        let source = inline ? "\(CKLicenseFixtures.kid):101112131415161718191a1b1c1d1e1f,\(CKLicenseFixtures.second):303132333435363738393a3b3c3d3e3f" :
            endpoint(session, mode, "keys").absoluteString
        let license = CKLicenseSpec(source: source, headers: ["X-License": "owned-license"],
                                    body: mode == "post" ? .challenge : nil, inheritsStreamHeaders: false)
        return CKChannel(url: endpoint(session, mode, "manifest.mpd"), title: "Owned resolver",
                         keySource: source, headers: ["X-Stream": "owned-stream"],
                         licenseHeaders: [:], metadataFailure: nil, licenseSpec: license)
    }
    func counts(_ session: String, _ mode: String) async throws -> [String: Int] {
        let (data, _) = try await CKHTTP.read(URLRequest(url: endpoint(session, mode, "stats")), role: .license, limit: 4096)
        return try XCTUnwrap(try CKJSON.object(data) as? [String: Int])
    }
    func assertCounts(_ session: String, _ mode: String, keys: Int, manifests: Int) async throws {
        let stats = try await counts(session, mode)
        XCTAssertEqual(stats["keys"], keys); XCTAssertEqual(stats["manifests"], manifests)
        XCTAssertEqual(stats["wrong_headers"], 0); XCTAssertEqual(stats["wrong_challenges"], 0)
        XCTAssertEqual(stats["cookies"], 0)
    }
    func testResolverRefreshesGETKeyMapAndManifestAfterTransientMismatch() async throws {
        let value = try await CKSourceResolver.resolve(channel("resolveget", "get"))
        XCTAssertTrue(value.keys.requiresKeyMap)
        XCTAssertTrue(value.keys.contains(try CKManifestKeyIDs.read(value.data)))
        try await assertCounts("resolveget", "get", keys: 2, manifests: 2)
    }
    func testResolverRefreshesPOSTChallengeFromNewManifestOnRetry() async throws {
        let value = try await CKSourceResolver.resolve(channel("resolvepost", "post"))
        XCTAssertTrue(value.keys.contains(try CKManifestKeyIDs.read(value.data)))
        try await assertCounts("resolvepost", "post", keys: 2, manifests: 2)
    }
    func testResolverPermanentMismatchStopsAfterThreeAttempts() async throws {
        do { _ = try await CKSourceResolver.resolve(channel("resolvepermanent", "permanent")); XCTFail("mismatch") }
        catch let error as CKResolutionError {
            XCTAssertEqual(error.stage, .manifest)
            XCTAssertEqual(error.underlying as? CKFailure, .missingLicenseKey)
        }
        try await assertCounts("resolvepermanent", "permanent", keys: 3, manifests: 3)
    }
    func testResolverPreservesSingleKeyWithInconsistentDeclaredKIDs() async throws {
        let value = try await CKSourceResolver.resolve(channel("resolvesingle", "single"))
        XCTAssertFalse(value.keys.requiresKeyMap)
        XCTAssertFalse(value.keys.contains(try CKManifestKeyIDs.read(value.data)))
        XCTAssertNotNil(value.keys.formatOptions["decryption_key"])
        try await assertCounts("resolvesingle", "single", keys: 1, manifests: 1)
    }
    func testResolverCannotRefreshInlineMapAndDoesNotReplayManifest() async throws {
        do { _ = try await CKSourceResolver.resolve(channel("resolveinline", "inline", inline: true)); XCTFail("mismatch") }
        catch let error as CKResolutionError { XCTAssertEqual(error.underlying as? CKFailure, .missingLicenseKey) }
        try await assertCounts("resolveinline", "inline", keys: 0, manifests: 1)
    }
    func testResolverDoesNotRetryDeniedOrMalformedLicense() async throws {
        for mode in ["deny", "invalid"] {
            let session = "resolve" + mode
            do { _ = try await CKSourceResolver.resolve(channel(session, mode)); XCTFail("license must fail") }
            catch let error as CKResolutionError {
                XCTAssertEqual(error.stage, .key)
                if mode == "invalid" { XCTAssertEqual(error.underlying as? CKFailure, .invalidKey) }
                else if let failure = error.underlying as? CKOpenFailure, case .http(let code) = failure { XCTAssertEqual(code, 403) }
                else { XCTFail("wrong denied failure") }
            }
            try await assertCounts(session, mode, keys: 1, manifests: 0)
        }
    }
    func testResolverCancellationDuringMismatchWaitPreventsNewRequests() async throws {
        let task = Task { try await CKSourceResolver.resolve(channel("resolvecancel", "cancel")) }
        for _ in 0..<80 {
            if try await counts("resolvecancel", "cancel")["manifests"] == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(nanoseconds: 650_000_000)
        try await assertCounts("resolvecancel", "cancel", keys: 1, manifests: 1)
    }
    func testResolverSharedDeadlineBoundsReadsBackoffAndExpiredStart() async throws {
        for (session, mode, timeout, expectedKeys) in [("resolvebudget", "permanent", 0.35, 1),
                                                      ("resolvereadbudget", "deadline", 0.35, 1),
                                                      ("resolveexpired", "matching", 0.0, 0)] {
            let began = ProcessInfo.processInfo.systemUptime
            do { _ = try await CKSourceResolver.resolve(channel(session, mode), timeout: timeout); XCTFail("deadline") }
            catch let error as CKResolutionError {
                XCTAssertEqual((error.underlying as NSError).domain, NSURLErrorDomain)
                XCTAssertEqual((error.underlying as NSError).code, NSURLErrorTimedOut)
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
            let stats = try await counts(session, mode)
            XCTAssertEqual(stats["keys"], expectedKeys)
            XCTAssertEqual(stats["manifests"], mode == "permanent" ? 1 : 0)
        }
    }
    func testResolverMatchingMapStaysOnOneAttemptFastPath() async throws {
        let value = try await CKSourceResolver.resolve(channel("resolvematching", "matching"))
        XCTAssertTrue(value.keys.contains(try CKManifestKeyIDs.read(value.data)))
        try await assertCounts("resolvematching", "matching", keys: 1, manifests: 1)
    }
}
