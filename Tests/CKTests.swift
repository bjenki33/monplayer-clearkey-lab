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
    func testDecodeRedirectedGzipCENCManifestOverHTTP() throws {
        try decodeFixture("http://127.0.0.1:18761/redirect.php", protocols: "http,tcp,crypto,data")
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
}
