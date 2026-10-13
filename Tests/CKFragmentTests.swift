import Foundation
import Libavcodec
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
        // Unmodified MOV probing can call its init reader twice. Default-off
        // preserves that upstream behavior,not integration-level retries.
        XCTAssertEqual(stats["fault_attempts"], 2)
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
        XCTAssertEqual(CKLiveOptions().formatContextOptions["ck_fragment_resume"] as? Int, 1)
        let ordinary = KSOptions().formatContextOptions
        XCTAssertNil(ordinary["ck_fragment_retry"])
        XCTAssertNil(ordinary["ck_fragment_resume"])
        XCTAssertEqual(ordinary["reconnect"] as? Int, 1, "preserve the pinned ordinary SDK default")
        XCTAssertNil(ordinary["reconnect_on_http_error"])
    }

    private func consumeBody(_ session: String, enabled: Bool = true) throws -> Int32 {
        var context: UnsafeMutablePointer<AVFormatContext>?, options: OpaquePointer?
        let keys = try CKKeySet(["000102030405060708090a0b0c0d0e0f":"101112131415161718191a1b1c1d1e1f",
                                 "202122232425262728292a2b2c2d2e2f":"303132333435363738393a3b3c3d3e3f"])
        keys.formatOptions.forEach { av_dict_set(&options, $0.key, $0.value, 0) }
        av_dict_set(&options, "ck_video_representation", "live-selected", 0)
        av_dict_set(&options, "ck_live_delay", "6", 0)
        av_dict_set(&options, "ck_fragment_retry", "1", 0)
        av_dict_set(&options, "ck_fragment_resume", enabled ? "1" : "0", 0)
        av_dict_set(&options, "headers", "X-Stream: owned-stream\r\n", 0)
        av_dict_set(&options, "rw_timeout", "20000000", 0)
        av_dict_set(&options, "tls_verify", "1", 0)
        defer { av_dict_free(&options); avformat_close_input(&context) }
        var result = avformat_open_input(&context, "http://127.0.0.1:18761/live/\(session)/manifest.mpd", nil, &options)
        guard result >= 0 else { return result }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        for _ in 0..<300 {
            result = av_read_frame(context, packet)
            av_packet_unref(packet)
            if result < 0 { return result }
        }
        return result
    }

    func testActualBodyResumesFromConsumedOffsetsWithSameStrongValidator() async throws {
        XCTAssertEqual(try consumeBody("bodyinitialrecover"), 0)
        let stats = try await CKFragmentFixtures.stats("bodyinitialrecover")
        XCTAssertEqual(stats["body_attempts"], 3); XCTAssertEqual(stats["body_cuts"], 2)
        XCTAssertEqual(stats["body_successes"], 1); XCTAssertEqual(stats["body_positive_offsets"], 2)
        XCTAssertEqual(stats["body_wrong_offset"], 0); XCTAssertEqual(stats["body_wrong_validator"], 0)
        XCTAssertEqual(stats["body_wrong_headers"], 0); XCTAssertEqual(stats["body_initial_range"], 0)
        XCTAssertEqual(stats["body_delivered"], stats["body_total"])
    }

    func testActualBodyChangedIgnoredOrInvalidRangeFailsWithoutAppending() async throws {
        for mode in ["changed", "ignored", "wrongstart", "wrongtotal", "wrongend", "wronglength", "overflow", "duplicate", "deny"] {
            let session = "bodyinitial" + mode
            XCTAssertLessThan(try consumeBody(session), 0, mode)
            let stats = try await CKFragmentFixtures.stats(session)
            XCTAssertEqual(stats["body_attempts"], 2, mode)
            XCTAssertEqual(stats["body_successes"], 0, mode)
            XCTAssertEqual(stats["body_wrong_validator"], 0, mode)
        }
    }

    func testActualBodyMissingOrWeakValidatorFailsWithoutReplay() async throws {
        for mode in ["missing", "weak"] {
            let session = "bodyinitial" + mode
            XCTAssertLessThan(try consumeBody(session), 0, mode)
            let stats = try await CKFragmentFixtures.stats(session)
            XCTAssertEqual(stats["body_attempts"], 1, mode)
        }
    }

    func testActualBodyUnknownLengthOrEncodingNeverAttemptsRangeResume() async throws {
        for mode in ["unknown", "encoded"] {
            let session = "bodyinitial" + mode
            _ = try consumeBody(session)
            let stats = try await CKFragmentFixtures.stats(session)
            XCTAssertEqual(stats["body_attempts"], 1, mode)
        }
    }

    func testActualBodyDefaultOffPreservesNoIntegrationResume() async throws {
        _ = try consumeBody("bodyinitialdefault", enabled: false)
        let stats = try await CKFragmentFixtures.stats("bodyinitialdefault")
        XCTAssertEqual(stats["body_attempts"], 1)
    }

    func testActualBodyRepeatedCutsExhaustAtTwoExtraRequests() async throws {
        XCTAssertLessThan(try consumeBody("bodyinitialexhaustalways"), 0)
        let stats = try await CKFragmentFixtures.stats("bodyinitialexhaustalways")
        XCTAssertEqual(stats["body_attempts"], 3)
        XCTAssertEqual(stats["body_positive_offsets"], 2); XCTAssertEqual(stats["body_wrong_offset"], 0)
    }

    func testActualBodySilentAndTricklingResumesShareFiveSecondDeadline() async throws {
        for mode in ["slow", "trickle"] {
            let session = "bodyinitialbudget" + mode, began = ProcessInfo.processInfo.systemUptime
            XCTAssertLessThan(try consumeBody(session), 0)
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            print("OWNED BODY DEADLINE [\(mode)]: \(elapsed)s")
            XCTAssertLessThan(elapsed, 6.5)
            let stats = try await CKFragmentFixtures.stats(session)
            XCTAssertEqual(stats["body_attempts"], 2)
        }
    }
}
