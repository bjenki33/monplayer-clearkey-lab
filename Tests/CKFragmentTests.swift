import Foundation
import Libavformat
import Libavutil
import KSPlayer
import XCTest
@testable import CKBridge

enum CKFragmentFixtures {
    static func stats(_ session: String) async throws -> [String:Double] {
        let request = URLRequest(url: URL(string: "http://127.0.0.1:18761/live/\(session)/stats")!)
        let (data, _) = try await CKHTTP.read(request, role: .license, limit: 4096)
        return try XCTUnwrap(try CKJSON.object(data) as? [String:Double])
    }
}

final class CKFragmentTests: XCTestCase {
    func open(_ session: String, enabled: Bool = true) -> Int32 {
        var context: UnsafeMutablePointer<AVFormatContext>?, options: OpaquePointer?
        av_dict_set(&options, "ck_video_representation", "live-selected", 0)
        av_dict_set(&options, "ck_live_delay", "6", 0)
        av_dict_set(&options, "ck_fragment_retry", enabled ? "1" : "0", 0)
        av_dict_set(&options, "rw_timeout", "20000000", 0)
        av_dict_set(&options, "headers", "X-Stream: owned-stream\r\n", 0)
        av_dict_set(&options, "tls_verify", "1", 0)
        defer { av_dict_free(&options); avformat_close_input(&context) }
        return avformat_open_input(&context, "http://127.0.0.1:18761/live/\(session)/manifest.mpd", nil, &options)
    }
    func testActualInitPreBodyDisconnectRecoversWithExactlyTwoExtraRequests() async throws {
        XCTAssertEqual(open("segmentinitrecover"), 0)
        let stats = try await CKFragmentFixtures.stats("segmentinitrecover")
        XCTAssertEqual(stats["fault_attempts"], 3); XCTAssertEqual(stats["fault_failures"], 2)
        XCTAssertEqual(stats["fault_successes"], 1)
        XCTAssertEqual(stats["fault_offset_changed"], 0); XCTAssertEqual(stats["fault_wrong_headers"], 0)
    }
    func testActualDefaultOffDoesNotRetryFragmentConnectionFailure() async throws {
        XCTAssertLessThan(open("segmentinitdefault", enabled: false), 0)
        let stats = try await CKFragmentFixtures.stats("segmentinitdefault")
        XCTAssertEqual(stats["fault_attempts"], 1)
    }
    func testActualFragmentTransportExhaustionIsBoundedAndFails() async throws {
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertLessThan(open("segmentinitexhaustalways"), 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 4)
        let stats = try await CKFragmentFixtures.stats("segmentinitexhaustalways")
        XCTAssertEqual(stats["fault_attempts"], 3)
    }
    func testActualFragmentAuthAndHTTPServerErrorsNeverRetry() async throws {
        for session in ["segmentinitdeny", "segmentinitserver"] {
            XCTAssertLessThan(open(session), 0)
            let stats = try await CKFragmentFixtures.stats(session)
            XCTAssertEqual(stats["fault_attempts"], 1)
        }
    }
    func testActualFragmentRecoveryHasOneDeadlineNotRepeatedFullTimeouts() async throws {
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertLessThan(open("segmentinitbudgetslow"), 0)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        XCTAssertLessThan(elapsed, 6.5, "recovery must not multiply the initial20s I/O timeout")
        let stats = try await CKFragmentFixtures.stats("segmentinitbudgetslow")
        XCTAssertEqual(stats["fault_attempts"], 2)
    }
    func testActualTricklingHeadersCannotExtendFragmentRecoveryDeadline() async throws {
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertLessThan(open("segmentinitbudgettrickle"), 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 6.5)
        let stats = try await CKFragmentFixtures.stats("segmentinitbudgettrickle")
        XCTAssertEqual(stats["fault_attempts"], 2)
    }
    func testSelectedLiveOptionsEnableRecoveryWithoutChangingOrdinaryDefaults() {
        XCTAssertEqual(CKLiveOptions().formatContextOptions["ck_fragment_retry"] as? Int, 1)
        let ordinary = KSOptions().formatContextOptions
        XCTAssertNil(ordinary["ck_fragment_retry"])
        XCTAssertNil(ordinary["reconnect"]); XCTAssertNil(ordinary["reconnect_on_http_error"])
    }
}
