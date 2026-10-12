import AVFoundation
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import XCTest
@testable import CKBridge

final class CKTests: XCTestCase {
    let kid = "000102030405060708090a0b0c0d0e0f"
    let key = "101112131415161718191a1b1c1d1e1f"
    let secondKid = "202122232425262728292a2b2c2d2e2f"
    let secondKey = "303132333435363738393a3b3c3d3e3f"
    func playlist(_ tags: String, _ url: String = "https://example.invalid/live.mpd") -> Data {
        Data("#EXTM3U\n\(tags)\n#EXTINF:-1,Fixture\n\(url)\n".utf8)
    }
    func testParserClearKeyAndHeaders() throws {
        let data = playlist("#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=\(kid):\(key)\n#EXTVLCOPT:http-user-agent=FixturePlayer\n#EXTVLCOPT:http-referrer=https://example.invalid/")
        let channels = CKPlaylist.parse(data, relativeTo: nil)
        XCTAssertEqual(channels.count, 1); XCTAssertEqual(channels[0].title, "Fixture")
        XCTAssertEqual(channels[0].headers["User-Agent"], "FixturePlayer")
        XCTAssertEqual(channels[0].headers["Referer"], "https://example.invalid/")
        XCTAssertEqual(try CKKeys.defaultKey(CKKeys.parse(Data(channels[0].keySource.utf8))), key)
    }
    func testNoUniversalDRMOrCarryOver() {
        for type in ["widevine", "com.widevine.alpha", "playready", "com.apple.fps", ""] {
            XCTAssertTrue(CKPlaylist.parse(playlist("#KODIPROP:inputstream.adaptive.license_type=\(type)\n#KODIPROP:inputstream.adaptive.license_key=\(kid):\(key)"), relativeTo: nil).isEmpty)
        }
        let first = String(data: playlist("#KODIPROP:inputstream.adaptive.license_type=org.w3.clearkey\n#KODIPROP:inputstream.adaptive.license_key=\(kid):\(key)"), encoding: .utf8)!
        let data = Data((first + "#EXTINF:-1,Plain\nhttps://example.invalid/plain.m3u8\n").utf8)
        XCTAssertEqual(CKPlaylist.parse(data, relativeTo: nil).count, 1)
    }
    func testKeyMapsJWKSAndNoInvalidOrDuplicateKeys() throws {
        XCTAssertEqual(try CKKeys.parse(Data("{\"\(kid)\":\"\(key)\"}".utf8))[kid], key)
        let jwks = #"{"keys":[{"kty":"oct","kid":"AAECAwQFBgcICQoLDA0ODw","k":"EBESExQVFhcYGRobHB0eHw"}]}"#
        XCTAssertEqual(try CKKeys.parse(Data(jwks.utf8))[kid], key)
        XCTAssertThrowsError(try CKKeys.parse(Data("\(kid):short".utf8)))
        XCTAssertThrowsError(try CKKeys.parse(Data("\(kid):\(key),\(kid):00000000000000000000000000000000".utf8)))
        XCTAssertThrowsError(try CKKeys.defaultKey([kid: key, key: kid]))
    }
    func testRemoteLicenseAndRelativeURL() {
        let data = playlist("#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=https://example.invalid/keys\n#EXTHTTP:{\"Origin\":\"https://example.invalid\"}", "stream.mpd|User-Agent=Fixture")
        let channels = CKPlaylist.parse(data, relativeTo: URL(string: "https://example.invalid/list.m3u"))
        XCTAssertEqual(channels.first?.url.absoluteString, "https://example.invalid/stream.mpd")
        XCTAssertEqual(channels.first?.headers["Origin"], "https://example.invalid")
        XCTAssertEqual(channels.first?.headers["User-Agent"], "Fixture")
        XCTAssertFalse(CKPlaylist.safe("bad\r\nInjected: header"))
    }
    func testMemoryRegistryAndUnprotectedPassThrough() {
        let data = playlist("#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=\(kid):\(key)")
        CKRegistry.shared.observe(data, source: nil)
        XCTAssertNotNil(CKRegistry.shared.channel(URL(string: "https://example.invalid/live.mpd")!))
        XCTAssertNil(CKRegistry.shared.channel(URL(string: "https://example.invalid/plain.m3u8")!))
        let item = AVPlayerItem(url: URL(string: "https://example.invalid/plain.m3u8")!)
        XCTAssertFalse(CKRuntime.route(item))
    }
    func testFFmpegDASHCencOptionActuallyExists() {
        XCTAssertTrue(String(cString: avformat_license()).hasPrefix("LGPL"))
        XCTAssertTrue(String(cString: avcodec_license()).hasPrefix("LGPL"))
        XCTAssertTrue(String(cString: avformat_configuration()).contains("--enable-zlib"))
        guard let format = av_find_input_format("dash") else { return XCTFail("DASH is missing from the compiled playback engine") }
        var obj: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(mutating: format.pointee.priv_class)
        let option = av_opt_find(&obj, "cenc_decryption_key", nil, 0, AV_OPT_SEARCH_FAKE_OBJ)
        XCTAssertNotNil(option)
        XCTAssertNotNil(av_opt_find(&obj, "cenc_decryption_keys", nil, 0, AV_OPT_SEARCH_FAKE_OBJ))
        guard let mov = av_find_input_format("mov") else { return XCTFail("MOV is missing") }
        obj = UnsafeMutableRawPointer(mutating: mov.pointee.priv_class)
        XCTAssertNotNil(av_opt_find(&obj, "decryption_keys", nil, 0, AV_OPT_SEARCH_FAKE_OBJ))
    }
    func testOriginalAVPlayerInitAndReplaceStillWork() {
        let url = URL(string: "https://example.invalid/unprotected.mp4")!
        let original = AVPlayer(url: url)
        XCTAssertEqual((original.currentItem?.asset as? AVURLAsset)?.url, url)
        let replacement = AVPlayerItem(url: URL(string: "https://example.invalid/second.m3u8")!)
        original.replaceCurrentItem(with: replacement)
        XCTAssertTrue(original.currentItem === replacement)
        original.replaceCurrentItem(with: nil); XCTAssertNil(original.currentItem)
        XCTAssertNotNil(CKRuntime.placeholderItem(), "registered routing must keep a valid nonnil item in the original UI")
    }
    func testDecodeSyntheticCENCFrameUsingSuppliedKey() throws {
        let bundle = Bundle(for: CKTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "manifest", withExtension: "mpd", subdirectory: "Fixtures"))
        try decodeFixture(url.path, protocols: "file,crypto,data")
    }
    func testDecodeGzipCENCManifestOverHTTP() throws {
        try decodeFixture("http://127.0.0.1:18761/gzip/manifest.mpd", protocols: "http,tcp,crypto,data")
    }
    func testDecodeRedirectedGzipCENCManifestOverHTTP() async throws {
        let initial = URL(string: "http://127.0.0.1:18761/redirect.php")!
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: initial)
        let resolved = try CKManifest.validatedURL(data, response: XCTUnwrap(response as? HTTPURLResponse))
        XCTAssertEqual(resolved.path, "/gzip/manifest.mpd")
        try decodeFixture(resolved.absoluteString, protocols: "http,tcp,crypto,data")
    }
    func testManifestValidationAndSafeDiagnostics() throws {
        let url = URL(string: "https://example.invalid/final/live.mpd")!
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        XCTAssertEqual(try CKManifest.validatedURL(Data("<MPD type=\"dynamic\"/>".utf8), response: response), url)
        XCTAssertThrowsError(try CKManifest.validatedURL(Data("<html>error</html>".utf8), response: response))
        let bad = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil))
        XCTAssertThrowsError(try CKManifest.validatedURL(Data("<MPD/>".utf8), response: bad))
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                            userInfo: [NSLocalizedDescriptionKey: "PRIVATE_KEY_AND_URL", NSURLErrorFailingURLStringErrorKey: "SECRET_URL"])
        let text = CKDiagnostic.message(error, stage: .manifest)
        XCTAssertTrue(text.contains("-1003")); XCTAssertFalse(text.contains("PRIVATE")); XCTAssertFalse(text.contains("SECRET"))
        XCTAssertTrue(CKDiagnostic.message(CKOpenFailure.startupTimeout, stage: .playback).contains("30 seconds"))
    }
    private func decodeFixture(_ path: String, protocols: String) throws {
        var context: UnsafeMutablePointer<AVFormatContext>?
        var options: OpaquePointer?
        av_dict_set(&options, "cenc_decryption_key", key, 0)
        av_dict_set(&options, "protocol_whitelist", protocols, 0)
        av_dict_set(&options, "rw_timeout", "10000000", 0)
        let opened = avformat_open_input(&context, path, nil, &options)
        av_dict_free(&options)
        XCTAssertEqual(opened, 0); guard opened == 0, let context else { return }
        var toClose: UnsafeMutablePointer<AVFormatContext>? = context
        defer { avformat_close_input(&toClose) }
        XCTAssertGreaterThanOrEqual(avformat_find_stream_info(context, nil), 0)
        var decoder: UnsafePointer<AVCodec>?
        let video = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0)
        XCTAssertGreaterThanOrEqual(video, 0); guard video >= 0, let decoder else { return }
        var codec = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&codec) }
        XCTAssertEqual(avcodec_parameters_to_context(codec, context.pointee.streams[Int(video)]!.pointee.codecpar), 0)
        XCTAssertEqual(avcodec_open2(codec, decoder, nil), 0)
        var packet = av_packet_alloc(), frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        var decoded = false
        for _ in 0..<100 {
            if av_read_frame(context, packet) < 0 { break }
            if packet?.pointee.stream_index == video, avcodec_send_packet(codec, packet) >= 0,
               avcodec_receive_frame(codec, frame) == 0, let frame {
                XCTAssertEqual(frame.pointee.width, 128); XCTAssertEqual(frame.pointee.height, 72)
                let luma = try XCTUnwrap(frame.pointee.data.0)
                XCTAssertLessThanOrEqual(abs(Int(luma[0]) - 81), 3, "decrypted synthetic red frame must have expected luma")
                decoded = true; av_packet_unref(packet); break
            }
            av_packet_unref(packet)
        }
        XCTAssertTrue(decoded, "no usable frame decoded from encrypted synthetic fixture")
    }
    func testNestedDiagnosticsRevealCodesNotPrivateDescriptions() {
        let nested = NSError(domain: "Private-domain", code: -875574520,
                             userInfo: [NSLocalizedDescriptionKey: "PRIVATE_URL_AND_KEY"])
        let error = NSError(domain: "KSPlayerErrorDomain", code: 2,
                            userInfo: [NSUnderlyingErrorKey: nested, NSURLErrorFailingURLStringErrorKey: "SECRET"])
        let text = CKDiagnostic.message(error, stage: .playback)
        XCTAssertTrue(text.contains("2/-875574520")); XCTAssertFalse(text.contains("PRIVATE")); XCTAssertFalse(text.contains("SECRET"))
    }

    func testMultikeyOptionsAreDeterministicAndHaveNoArbitraryDefault() throws {
        let keys = try CKKeySet([secondKid: secondKey, kid: key])
        XCTAssertTrue(keys.requiresKeyMap)
        XCTAssertEqual(keys.distinctKeyCount, 2)
        XCTAssertEqual(keys.formatOptions["cenc_decryption_keys"], "\(kid)=\(key):\(secondKid)=\(secondKey)")
        XCTAssertEqual(keys.formatOptions["decryption_keys"], keys.formatOptions["cenc_decryption_keys"])
        XCTAssertNil(keys.formatOptions["decryption_key"])
        XCTAssertNil(keys.formatOptions["cenc_decryption_key"])
    }

    func testSingleDistinctKeyKeepsCK2CompatibilityPath() throws {
        let keys = try CKKeySet([kid: key, secondKid: key])
        XCTAssertFalse(keys.requiresKeyMap)
        XCTAssertEqual(keys.formatOptions, ["cenc_decryption_key": key, "decryption_key": key])
    }

    func testKeyLimitsAndCanonicalConflicts() throws {
        XCTAssertThrowsError(try CKKeySet([:]))
        XCTAssertThrowsError(try CKKeySet([kid: "invalid"]))
        XCTAssertThrowsError(try CKKeySet([kid: key, kid.uppercased(): secondKey]))
        let conflicting = "{\"\(kid)\":\"\(key)\",\"\(kid.uppercased())\":\"\(secondKey)\"}"
        XCTAssertThrowsError(try CKKeys.parse(Data(conflicting.utf8)))
        XCTAssertThrowsError(try CKKeys.parse(Data("\(kid):\(key),".utf8)))
        var tooMany: [String: String] = [:]
        for i in 0..<129 { tooMany[String(format: "%032x", i)] = key }
        XCTAssertThrowsError(try CKKeySet(tooMany))
    }

    func testMultikeyRequiresDASHRatherThanSilentlyIgnoringHLSMap() throws {
        let keys = try CKKeySet([kid: key, secondKid: secondKey])
        let url = URL(string: "https://example.invalid/manifest.php")!
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        XCTAssertEqual(try CKManifest.validatedURL(Data("<MPD/>".utf8), response: response, keySet: keys), url)
        XCTAssertThrowsError(try CKManifest.validatedURL(Data("#EXTM3U\n".utf8), response: response, keySet: keys))
        XCTAssertEqual(try CKManifest.validatedURL(Data("#EXTM3U\n".utf8), response: response, keySet: CKKeySet([kid: key])), url)
    }

    func testDecodeDistinctKeyVideoAndAudio() throws {
        let url = try XCTUnwrap(Bundle(for: CKTests.self).url(forResource: "manifest", withExtension: "mpd", subdirectory: "Fixtures/multikey"))
        XCTAssertTrue(try multiFixtureMatches(url.path, protocols: "file,crypto,data", keys: [kid: key, secondKid: secondKey]),
                      "both red video and reference sine audio must decode using DIFFERENT supplied keys")
    }

    func testDecodeDistinctKeysThroughGzipHTTP() throws {
        XCTAssertTrue(try multiFixtureMatches("http://127.0.0.1:18761/gzip/multikey/manifest.mpd",
                                             protocols: "http,tcp,crypto,data", keys: [kid: key, secondKid: secondKey]))
    }

    func testMissingMultikeyMatchDoesNotUseAnotherDefault() throws {
        let url = try XCTUnwrap(Bundle(for: CKTests.self).url(forResource: "manifest", withExtension: "mpd", subdirectory: "Fixtures/multikey"))
        let unknown = "404142434445464748494a4b4c4d4e4f"
        XCTAssertFalse(try multiFixtureMatches(url.path, protocols: "file,crypto,data", keys: [kid: key, unknown: secondKey]))
    }

    func testWrongMultikeyValuesDoNotProduceValidContent() throws {
        let url = try XCTUnwrap(Bundle(for: CKTests.self).url(forResource: "manifest", withExtension: "mpd", subdirectory: "Fixtures/multikey"))
        XCTAssertFalse(try multiFixtureMatches(url.path, protocols: "file,crypto,data", keys: [kid: secondKey, secondKid: key]))
    }

    private func multiFixtureMatches(_ path: String, protocols: String, keys: [String: String]) throws -> Bool {
        let goldenURL = try XCTUnwrap(Bundle(for: CKTests.self).url(forResource: "audio-reference", withExtension: "f32", subdirectory: "Fixtures/multikey"))
        let bytes = [UInt8](try Data(contentsOf: goldenURL))
        let golden: [Float] = stride(from: 0, to: bytes.count - 3, by: 4).map {
            Float(bitPattern: UInt32(bytes[$0]) | UInt32(bytes[$0 + 1]) << 8 | UInt32(bytes[$0 + 2]) << 16 | UInt32(bytes[$0 + 3]) << 24)
        }
        var context: UnsafeMutablePointer<AVFormatContext>?, options: OpaquePointer?
        try CKKeySet(keys).formatOptions.forEach { av_dict_set(&options, $0.key, $0.value, 0) }
        av_dict_set(&options, "protocol_whitelist", protocols, 0)
        av_dict_set(&options, "rw_timeout", "10000000", 0)
        let opened = avformat_open_input(&context, path, nil, &options)
        if opened == 0 { XCTAssertNil(av_dict_get(options, "cenc_decryption_keys", nil, 0), "compiled DASH engine must consume the map option") }
        av_dict_free(&options)
        guard opened == 0, let context else { return false }
        var toClose: UnsafeMutablePointer<AVFormatContext>? = context
        defer { avformat_close_input(&toClose) }
        guard avformat_find_stream_info(context, nil) >= 0 else { return false }
        var videoDecoder: UnsafePointer<AVCodec>?, audioDecoder: UnsafePointer<AVCodec>?
        let video = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, &videoDecoder, 0)
        let audio = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, &audioDecoder, 0)
        guard video >= 0, audio >= 0, let videoDecoder, let audioDecoder else { return false }
        var videoCodec = avcodec_alloc_context3(videoDecoder), audioCodec = avcodec_alloc_context3(audioDecoder)
        defer { avcodec_free_context(&videoCodec); avcodec_free_context(&audioCodec) }
        guard avcodec_parameters_to_context(videoCodec, context.pointee.streams[Int(video)]!.pointee.codecpar) == 0,
              avcodec_parameters_to_context(audioCodec, context.pointee.streams[Int(audio)]!.pointee.codecpar) == 0,
              avcodec_open2(videoCodec, videoDecoder, nil) == 0, avcodec_open2(audioCodec, audioDecoder, nil) == 0 else { return false }
        var packet = av_packet_alloc(), frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        var videoOK = false, audioSamples = 0
        for _ in 0..<300 {
            guard av_read_frame(context, packet) >= 0, let packet else { break }
            defer { av_packet_unref(packet) }
            let isVideo = packet.pointee.stream_index == video
            guard isVideo || packet.pointee.stream_index == audio else { continue }
            let codec = isVideo ? videoCodec : audioCodec
            guard avcodec_send_packet(codec, packet) >= 0 else { return false }
            while avcodec_receive_frame(codec, frame) == 0, let frame {
                defer { av_frame_unref(frame) }
                guard frame.pointee.decode_error_flags == 0, let plane = frame.pointee.data.0 else { return false }
                if isVideo {
                    guard frame.pointee.width == 128, frame.pointee.height == 72 else { return false }
                    for y in 0..<72 {
                        for x in 0..<128 where abs(Int(plane[y * Int(frame.pointee.linesize.0) + x]) - 81) > 3 { return false }
                    }
                    videoOK = true
                } else {
                    guard frame.pointee.format == AV_SAMPLE_FMT_FLTP.rawValue else { return false }
                    let samples = UnsafeRawPointer(plane).assumingMemoryBound(to: Float.self)
                    let count = Int(frame.pointee.nb_samples)
                    guard audioSamples + count <= golden.count else { return false }
                    for i in 0..<count where !samples[i].isFinite || abs(samples[i] - golden[audioSamples + i]) > 0.0001 { return false }
                    audioSamples += count
                }
            }
            if videoOK, audioSamples >= 4096 { return true }
        }
        return false
    }
}
