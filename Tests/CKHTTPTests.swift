import Foundation
import UIKit
import XCTest
@testable import CKBridge

final class CKHTTPTests: XCTestCase {
    func request(_ session: String, _ mode: String, timeout: TimeInterval = 20) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18761/transport/\(session)/\(mode)")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("owned-stream", forHTTPHeaderField: "X-Stream")
        return request
    }
    func stats(_ session: String) async throws -> [String:Any] {
        let (data, _) = try await CKHTTP.read(request(session, "stats"), role: .license, limit: 4096)
        return try XCTUnwrap(try CKJSON.object(data) as? [String:Any])
    }
    func count(_ session: String, _ expected: Int) async throws {
        let value = try await stats(session)
        XCTAssertEqual(value["attempts"] as? Int, expected)
        XCTAssertEqual(value["cookies"] as? Int, 0)
        XCTAssertEqual(value["wrong_headers"] as? Int, 0)
    }
    func expectHTTP(_ request: URLRequest, role: CKHTTPRole, code: Int) async throws {
        do { _ = try await CKHTTP.read(request, role: role, limit: 2048); XCTFail("must fail") }
        catch let error as CKOpenFailure {
            guard case .http(let status) = error else { XCTFail("wrong failure"); return }
            XCTAssertEqual(status, code)
        }
    }
    func testRetryPolicyExcludesLicensesPOSTRangeAuthTLSAndUnsafeFailures() {
        let get = request("policy", "recover")
        func delay(_ request: URLRequest, _ role: CKHTTPRole, _ error: Error, _ attempt: Int = 1,
                   _ remaining: TimeInterval = 20) -> TimeInterval? {
            CKHTTPRetry.delay(request: request, role: role, error: error, response: nil,
                              failedAttempt: attempt, remaining: remaining)
        }
        XCTAssertEqual(delay(get, .manifest, CKOpenFailure.http(503)), 0.25)
        XCTAssertEqual(delay(get, .manifest, URLError(.networkConnectionLost), 2), 0.75)
        XCTAssertNil(delay(get, .manifest, CKOpenFailure.http(503), 3))
        XCTAssertNil(delay(get, .manifest, CKOpenFailure.http(503), 1, 0.3))
        XCTAssertNil(delay(get, .license, CKOpenFailure.http(503)))
        var post = get; post.httpMethod = "POST"; post.httpBody = Data("owned".utf8)
        XCTAssertNil(delay(post, .manifest, CKOpenFailure.http(503)))
        var ranged = get; ranged.setValue("bytes=0-", forHTTPHeaderField: "Range")
        XCTAssertNil(delay(ranged, .manifest, CKOpenFailure.http(503)))
        for status in [400,401,403,404,500] { XCTAssertNil(delay(get, .manifest, CKOpenFailure.http(status))) }
        for code in [URLError.secureConnectionFailed, .serverCertificateUntrusted, .cancelled,
                     .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed] {
            XCTAssertNil(delay(get, .manifest, URLError(code)))
        }
        for error in [CKFailure.responseTooLarge, .unsafeRedirect, .invalidMetadata] {
            XCTAssertNil(delay(get, .manifest, error))
        }
        XCTAssertNil(delay(get, .manifest, CKOpenFailure.invalidManifest))
    }
    func testRetryAfterParsesDatesAndNeverShortensInvalidOrLongServerWait() throws {
        let now = Date(timeIntervalSince1970: 784111777)
        XCTAssertEqual(CKHTTPRetry.retryAfter("1", now: now), 1)
        XCTAssertEqual(CKHTTPRetry.retryAfter("Sun, 06 Nov 1994 08:49:38 GMT", now: now), 1)
        XCTAssertEqual(CKHTTPRetry.retryAfter("Sunday, 06-Nov-94 08:49:38 GMT", now: now), 1)
        XCTAssertEqual(CKHTTPRetry.retryAfter("Sun Nov 6 08:49:38 1994", now: now), 1)
        for invalid in ["", "-1", "1.5", "no-wait", String(repeating: "9", count: 129)] {
            XCTAssertNil(CKHTTPRetry.retryAfter(invalid, now: now))
        }
        let get = request("policy", "recover")
        for (header, expected) in [("1", Optional(1.0)), ("120", nil), ("bad", nil)] {
            let response = try XCTUnwrap(HTTPURLResponse(url: get.url!, statusCode: 503, httpVersion: nil,
                                                        headerFields: ["Retry-After": header]))
            XCTAssertEqual(CKHTTPRetry.delay(request: get, role: .manifest, error: CKOpenFailure.http(503),
                                            response: response, failedAttempt: 1, remaining: 20), expected)
        }
    }
    func testActualManifestRecoversTwoTemporaryFailuresAndKeepsHeadersIsolated() async throws {
        let (data, _) = try await CKHTTP.read(request("recover", "recover"), role: .manifest, limit: 2048)
        XCTAssertEqual(data, Data("<MPD/>".utf8))
        try await count("recover", 3)
    }
    func testActualManifestExhaustionStopsAfterThreeAttempts() async throws {
        try await expectHTTP(request("exhaust", "always"), role: .manifest, code: 503)
        try await count("exhaust", 3)
    }
    func testActualAuthenticationAndPermanentErrorsAreNotRetried() async throws {
        for code in [401,403,404,500] {
            let session = "permanent\(code)"
            try await expectHTTP(request(session, String(code)), role: .manifest, code: code)
            try await count(session, 1)
        }
    }
    func testActualLicenseGETAndPOSTAreNotAutomaticallyReplayed() async throws {
        try await expectHTTP(request("licenseget", "always"), role: .license, code: 503)
        try await count("licenseget", 1)
        var post = request("licensepost", "always"); post.httpMethod = "POST"; post.httpBody = Data("owned".utf8)
        try await expectHTTP(post, role: .license, code: 503)
        try await count("licensepost", 1)
        post = request("manifestpost", "always"); post.httpMethod = "POST"; post.httpBody = Data("owned".utf8)
        try await expectHTTP(post, role: .manifest, code: 503)
        try await count("manifestpost", 1)
    }
    func testActualRetryAfterWaitAndLongOrMalformedWaitFailWithoutReplay() async throws {
        _ = try await CKHTTP.read(request("rate", "rate"), role: .manifest, limit: 2048)
        let value = try await stats("rate"), times = try XCTUnwrap(value["times"] as? [Double])
        XCTAssertEqual(times.count, 2)
        if times.count == 2 { XCTAssertGreaterThanOrEqual(times[1] - times[0], 0.95) }
        try await count("rate", 2)
        for mode in ["longwait", "invalidwait"] {
            try await expectHTTP(request(mode, mode), role: .manifest, code: 503)
            try await count(mode, 1)
        }
    }
    func testActualEarlyDisconnectAndPartialBodyRestartFromEmptyBuffer() async throws {
        for mode in ["drop", "partial"] {
            let (data, _) = try await CKHTTP.read(request(mode, mode), role: .manifest, limit: 2048)
            XCTAssertEqual(data, Data("<MPD/>".utf8), "failed prefixes must never contaminate a fresh attempt")
            try await count(mode, 2)
        }
    }
    func testActualSizeAndParserFailuresDoNotRetry() async throws {
        do { _ = try await CKHTTP.read(request("oversize", "oversize"), role: .manifest, limit: 2048); XCTFail("size") }
        catch { XCTAssertEqual(error as? CKFailure, .responseTooLarge) }
        try await count("oversize", 1)
        let (data, _) = try await CKHTTP.read(request("invalid", "invalidmanifest"), role: .manifest, limit: 2048)
        XCTAssertThrowsError(try CKManifest.kind(data))
        try await count("invalid", 1)
    }
    func testActualSharedDeadlineCannotBecomeThreeFullTimeouts() async throws {
        let began = ProcessInfo.processInfo.systemUptime
        try await expectHTTP(request("deadline", "deadline", timeout: 0.4), role: .manifest, code: 503)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
        try await count("deadline", 1)
    }
    func testActualCancellationDuringBackoffStopsNewAttempts() async throws {
        let task = Task { try await CKHTTP.read(request("cancelwait", "cancelwait"), role: .manifest, limit: 2048) }
        for _ in 0..<30 {
            if try await stats("cancelwait")["attempts"] as? Int == 1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await count("cancelwait", 1)
        let began = ProcessInfo.processInfo.systemUptime; task.cancel()
        do { _ = try await task.value; XCTFail("cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
        try await Task.sleep(nanoseconds: 2_100_000_000)
        try await count("cancelwait", 1)
    }
    func testActualCancellationDuringManifestReadReturnsPromptly() async throws {
        let task = Task { try await CKHTTP.read(request("cancelslow", "slow"), role: .manifest, limit: 2048) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let began = ProcessInfo.processInfo.systemUptime; task.cancel()
        do { _ = try await task.value; XCTFail("cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
        try await count("cancelslow", 1)
    }
    func testActualConcurrentRetriesCannotBorrowOtherChannelHeadersOrCookies() async throws {
        var alpha = request("alpha", "recover"), beta = request("beta", "recover")
        alpha.setValue("alpha", forHTTPHeaderField: "X-Owned")
        beta.setValue("beta", forHTTPHeaderField: "X-Owned")
        async let first = CKHTTP.read(alpha, role: .manifest, limit: 2048)
        async let second = CKHTTP.read(beta, role: .manifest, limit: 2048)
        let values = try await (first, second)
        XCTAssertEqual(values.0.0, values.1.0)
        try await count("alpha", 3); try await count("beta", 3)
    }

    @MainActor
    func testClosedControllerCannotAttachRecoveredManifestFromOldGeneration() async throws {
        let channel = try CKLicenseFixtures.channel(manifest: request("closedretry", "cancelwait").url!.absoluteString)
        let controller = CKPlaybackController(channel: channel)
        controller.loadViewIfNeeded()
        for _ in 0..<40 {
            if try await stats("closedretry")["attempts"] as? Int == 1 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try await count("closedretry", 1)
        controller.close(); let status = controller.status.text
        try await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertNil(controller.layer); XCTAssertNil(controller.playerOptions)
        XCTAssertNil(controller.metrics.playableSeconds)
        XCTAssertEqual(controller.status.text, status)
        try await count("closedretry", 1)
    }
}
