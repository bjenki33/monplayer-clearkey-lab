import AVFoundation
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import KSPlayer
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
        XCTAssertNotNil(av_opt_find(&obj, "ck_live_delay", nil, 0, AV_OPT_SEARCH_FAKE_OBJ))
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

    func testDASHURLAlignmentBoundariesActuallyDecodeTwoKeyVideoAndAudio() throws {
        let prefix = "http://127.0.0.1:18761/licensed/", suffix = "/manifest.mpd"
        for length in [63,64,65,127,128,129] {
            let path = prefix + String(repeating: "a", count: length - prefix.utf8.count - suffix.utf8.count) + suffix
            XCTAssertEqual(path.utf8.count, length)
            XCTAssertTrue(try multiFixtureMatches(path, protocols: "http,tcp,crypto,data",
                                                 keys: [kid:key,secondKid:secondKey], headers: "X-Stream:owned-stream\r\n"),
                          "real decoder must retain video/audio at the\(length)-byte URL boundary")
        }
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

    func testModernKodiInlineKeysReachTheSameMultikeyEngine() throws {
        let json = "{\"org.w3.clearkey\":{\"license\":{\"keyids\":{\"\(kid)\":\"\(key)\",\"\(secondKid)\":\"\(secondKey)\"}}}}"
        let channel = try XCTUnwrap(CKPlaylist.parse(playlist("#KODIPROP:inputstream.adaptive.drm=\(json)"), relativeTo: nil).first)
        XCTAssertNil(channel.metadataFailure)
        XCTAssertNil(try channel.keyRequest())
        let map = try CKKeys.parse(Data(channel.keySource.utf8))
        XCTAssertEqual(map, [kid: key, secondKid: secondKey])
        let url = try XCTUnwrap(Bundle(for: CKTests.self).url(forResource: "manifest", withExtension: "mpd", subdirectory: "Fixtures/multikey"))
        XCTAssertTrue(try multiFixtureMatches(url.path, protocols: "file,crypto,data", keys: map))
    }

    func testKodiLegacyAndLicenseHeadersAreSeparated() throws {
        let tags = "#KODIPROP:inputstream.adaptive.drm_legacy=org.w3.clearkey|https://example.invalid/license|Authorization=Bearer+license&X-License=only\n#EXTHTTP:{\"Authorization\":\"Bearer stream\",\"Origin\":\"https://example.invalid\"}"
        let channel = try XCTUnwrap(CKPlaylist.parse(playlist(tags), relativeTo: nil).first)
        let request = try XCTUnwrap(channel.keyRequest())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer license")
        XCTAssertEqual(channel.headers["Authorization"], "Bearer stream")
        XCTAssertNil(channel.headers["X-License"])
        XCTAssertEqual(channel.licenseHeaders["X-License"], "only")
    }

    func testOldLicensePipeHeadersAndRawFlagRemainGETCompatible() throws {
        let tags = "#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=https://example.invalid/keys|User-Agent=License%2BClient||R\n#EXTVLCOPT:http-user-agent=StreamClient"
        let channel = try XCTUnwrap(CKPlaylist.parse(playlist(tags), relativeTo: nil).first)
        XCTAssertEqual(channel.keySource, "https://example.invalid/keys")
        XCTAssertEqual(try channel.keyRequest()?.value(forHTTPHeaderField: "User-Agent"), "License+Client")
        XCTAssertEqual(channel.headers["User-Agent"], "StreamClient")
    }

    func testDataURIAndBareBase64KeyPayloads() throws {
        let jwks = #"{"keys":[{"kty":"oct","kid":"AAECAwQFBgcICQoLDA0ODw","k":"EBESExQVFhcYGRobHB0eHw"}]}"#
        let encoded = Data(jwks.utf8).base64EncodedString()
        for value in [encoded, "data:application/json;base64," + encoded] {
            XCTAssertEqual(try CKKeys.parse(Data(value.utf8)), [kid: key])
        }
        let withBOM = (Data([239, 187, 191]) + Data(jwks.utf8)).base64EncodedString()
        XCTAssertEqual(try CKKeys.parse(Data(withBOM.utf8)), [kid: key])
        let modern = "{\"org.w3.clearkey\":{\"license\":{\"server_url\":\"data:application/json;base64,\(encoded)\"}}}"
        let channel = try XCTUnwrap(CKPlaylist.parse(playlist("#KODIPROP:inputstream.adaptive.drm=\(modern)"), relativeTo: nil).first)
        XCTAssertNil(channel.metadataFailure)
        XCTAssertEqual(try CKKeys.parse(Data(channel.keySource.utf8)), [kid: key])
        XCTAssertThrowsError(try CKKeys.parse(Data("data:text/html;base64,".utf8)))
        XCTAssertThrowsError(try CKKeys.parse(Data("data:application/json;base64,%%%".utf8)))
    }

    func testModernRemoteLicenseUsesDeclaredStandardPOSTNotGuessedGET() throws {
        let modern = #"{"org.w3.clearkey":{"license":{"server_url":"https://example.invalid/standard-license"}}}"#
        let channel = try XCTUnwrap(CKPlaylist.parse(playlist("#KODIPROP:inputstream.adaptive.drm=\(modern)"), relativeTo: nil).first)
        XCTAssertNil(channel.metadataFailure)
        XCTAssertThrowsError(try channel.keyRequest())
        XCTAssertEqual(try channel.keyRequest(kids: [kid])?.httpMethod, "POST")
        XCTAssertTrue(CKDiagnostic.message(CKFailure.unsupportedLicense, stage: .key).contains("No guessed GET"))
    }

    func testLicenseBodyAndWrapperAreNotSilentlyIgnored() throws {
        let tags = "#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=https://example.invalid/keys|Content-Type=application%2Fjson|R{SSM}|R"
        let channel = try XCTUnwrap(CKPlaylist.parse(playlist(tags), relativeTo: nil).first)
        XCTAssertNil(channel.metadataFailure)
        XCTAssertThrowsError(try channel.keyRequest())
        XCTAssertEqual(try channel.keyRequest(kids: [kid])?.httpBody, try CKLicenseBody.challengeData(kids: [kid]))
        let modern = "{\"org.w3.clearkey\":{\"license\":{\"keyids\":{\"\(kid)\":\"\(key)\"},\"req_data\":\"BODY\"}}}"
        XCTAssertEqual(CKPlaylist.parse(playlist("#KODIPROP:inputstream.adaptive.drm=\(modern)"), relativeTo: nil).first?.metadataFailure, .invalidMetadata)
    }

    func testRepeatedAndEscapedJSONKeysAreRejected() throws {
        let duplicate = "{\"\(kid)\":\"\(key)\",\"\(kid)\":\"\(secondKey)\"}"
        XCTAssertThrowsError(try CKKeys.parse(Data(duplicate.utf8)))
        XCTAssertThrowsError(try CKJSON.object(Data(#"{"license":{},"\u006cicense":{}}"#.utf8)))
        XCTAssertThrowsError(try CKJSON.object(Data(#"{"keys":[{"kid":"one","kid":"two"}]}"#.utf8)))
        XCTAssertNoThrow(try CKJSON.object(Data(#"{"quoted":"\"kid\":", "nested":[true,false,null,3.2,{}]}"#.utf8)))
        let deep = String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34)
        XCTAssertThrowsError(try CKJSON.object(Data(deep.utf8)))
    }

    func testConflictingClearDeclarationsFailInsteadOfChoosingOne() throws {
        let tags = "#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=\(kid):\(key)\n#KODIPROP:inputstream.adaptive.drm_legacy=org.w3.clearkey|\(kid):\(secondKey)"
        let channel = try XCTUnwrap(CKPlaylist.parse(playlist(tags), relativeTo: nil).first)
        XCTAssertEqual(channel.metadataFailure, .invalidMetadata)
        XCTAssertThrowsError(try channel.keyRequest())
        let equivalent = tags.replacingOccurrences(of: "|\(kid):\(secondKey)", with: "|\(kid):\(key)")
        XCTAssertNil(CKPlaylist.parse(playlist(equivalent), relativeTo: nil).first?.metadataFailure)
    }

    func testModernWidevineIsNotMisclassifiedAsClearKey() throws {
        let wide = #"{"com.widevine.alpha":{"license":{"server_url":"https://example.invalid/org.w3.clearkey"}}}"#
        XCTAssertTrue(CKPlaylist.parse(playlist("#KODIPROP:inputstream.adaptive.drm=\(wide)"), relativeTo: nil).isEmpty)
        XCTAssertTrue(CKPlaylist.parse(playlist("#KODIPROP:inputstream.adaptive.drm_legacy=com.microsoft.playready|https://example.invalid/keys"), relativeTo: nil).isEmpty)
    }

    func testHeaderCaseOverridesEncodingAndInjectionRejection() throws {
        var headers: [String: String] = [:]
        try CKHeaders.merge("Authorization=Bearer+one&authorization=Bearer%20two&X-Plus=a%2Bb", into: &headers)
        XCTAssertEqual(headers["Authorization"], "Bearer two")
        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual(headers["X-Plus"], "a+b")
        for text in ["Bad%3AName=value", "X-Test=bad%0D%0AInjected", "X-Test=%00", "X-Test=%GG"] {
            XCTAssertThrowsError(try CKHeaders.merge(text, into: &headers))
        }
        let unsafe = "#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=\(kid):\(key)\n#KODIPROP:inputstream.adaptive.stream_headers=X-Test=bad%0D%0AInjected"
        XCTAssertEqual(CKPlaylist.parse(playlist(unsafe), relativeTo: nil).first?.metadataFailure, .invalidMetadata)
    }

    func testRegistryDropsStaleKeyWhenURLBecomesUnprotected() {
        let url = URL(string: "https://example.invalid/stale-ck4.mpd")!
        let owner = URL(string: "https://example.invalid/refresh-list.m3u")!
        CKRegistry.shared.observe(playlist("#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=\(kid):\(key)", url.absoluteString), source: owner)
        XCTAssertNotNil(CKRegistry.shared.channel(url))
        CKRegistry.shared.observe(playlist("", url.absoluteString), source: owner)
        XCTAssertNil(CKRegistry.shared.channel(url))
    }

    func testHLSResponseDoesNotEraseChannelMetadata() {
        let url = URL(string: "https://example.invalid/hls-preserved-ck4.mpd")!
        CKRegistry.shared.observe(playlist("#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=\(kid):\(key)", url.absoluteString), source: nil)
        let hls = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=90000\n\(url.absoluteString)\n".utf8)
        XCTAssertNil(CKPlaylist.report(hls, relativeTo: nil))
        CKRegistry.shared.observe(hls, source: nil)
        XCTAssertNotNil(CKRegistry.shared.channel(url))
    }

    func testNoMetadataCarryOverAndMalformedMetadataIsVisible() throws {
        let first = String(data: playlist("#KODIPROP:inputstream.adaptive.drm_legacy=org.w3.clearkey|\(kid):\(key)|X-License=only"), encoding: .utf8)!
        let second = "#EXTINF:-1,Second\n#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=\(kid):\(key)\nhttps://example.invalid/second-isolated.mpd\n"
        let report = try XCTUnwrap(CKPlaylist.report(Data((first + second).utf8), relativeTo: nil))
        XCTAssertEqual(report.channels.count, 2)
        XCTAssertNil(report.channels[1].licenseHeaders["X-License"])
        let invalid = try XCTUnwrap(CKPlaylist.report(playlist("#KODIPROP:inputstream.adaptive.drm={invalid}"), relativeTo: nil))
        XCTAssertEqual(invalid.metadataIssues, 1)
        XCTAssertTrue(invalid.channels.isEmpty)
    }

    func testUnimplementedHeaderScopeAndInvalidPriorityAreExplicit() throws {
        let tags = "#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=\(kid):\(key)\n#KODIPROP:inputstream.adaptive.manifest_headers=Authorization=manifest-only"
        XCTAssertEqual(CKPlaylist.parse(playlist(tags), relativeTo: nil).first?.metadataFailure, .unsupportedMetadata)
        for priority in ["true", "0", "1.5"] {
            let modern = "{\"org.w3.clearkey\":{\"priority\":\(priority),\"license\":{\"keyids\":{\"\(kid)\":\"\(key)\"}}}}"
            XCTAssertEqual(CKPlaylist.parse(playlist("#KODIPROP:inputstream.adaptive.drm=\(modern)"), relativeTo: nil).first?.metadataFailure, .invalidMetadata)
        }
    }

    func testDeclaredVideoSelectionAvoidsOpeningBrokenUnusedVariants() throws {
        let keys = [kid: key, secondKid: secondKey]
        let path = "http://127.0.0.1:18761/gzip/multikey/variants.mpd"
        XCTAssertFalse(try multiFixtureMatches(path, protocols: "http,tcp,crypto,data", keys: keys))
        XCTAssertTrue(try multiFixtureMatches(path, protocols: "http,tcp,crypto,data", keys: keys,
                                              selection: "selected"))
    }

    func testMissingDeclaredVideoDoesNotSilentlySelectAnotherRendition() throws {
        XCTAssertFalse(try multiFixtureMatches("http://127.0.0.1:18761/gzip/multikey/variants.mpd",
                                               protocols: "http,tcp,crypto,data",
                                               keys: [kid: key, secondKid: secondKey], selection: "absent"))
    }

    func liveVariants(_ items: String, periods: Int = 1, type: String = "dynamic") -> Data {
        let period = "<Period><AdaptationSet contentType=\"video\" mimeType=\"video/mp4\">\(items)</AdaptationSet></Period>"
        return Data("<MPD type=\"\(type)\">\(String(repeating: period, count: periods))</MPD>".utf8)
    }

    func testLiveSelectionKeepsHighestResolutionThenBitrate() throws {
        let items = """
        <Representation id="low" height="480" bandwidth="1200000"/>
        <Representation id="hd1" height="1080" bandwidth="3400000"/>
        <Representation id="hd2" height="1080" bandwidth="5200000"/>
        """
        let plan = try XCTUnwrap(CKDASHSelection.plan(liveVariants(items)))
        XCTAssertEqual(plan.id, "hd2"); XCTAssertEqual(plan.height, 1080)
        XCTAssertEqual(plan.bandwidth, 5200000); XCTAssertEqual(plan.renditionCount, 3)
        XCTAssertNil(CKDASHSelection.plan(liveVariants(items, type: "static")))
        XCTAssertNil(CKDASHSelection.plan(liveVariants(items, periods: 2)))
    }

    func testLiveSelectionDeclinesAmbiguousMissingAndUnsafeIdentifiers() {
        let good = "<Representation id=\"good\" height=\"720\" bandwidth=\"2000000\"/>"
        for other in [good, "<Representation height=\"1080\" bandwidth=\"4000000\"/>",
                      "<Representation id=\"bad/path\" height=\"1080\" bandwidth=\"4000000\"/>",
                      "<Representation id=\"bad\" height=\"1080\" bandwidth=\"-1\"/>"] {
            XCTAssertNil(CKDASHSelection.plan(liveVariants(good + other)))
        }
        XCTAssertNil(CKDASHSelection.plan(liveVariants(good)))
        XCTAssertFalse(CKDASHSelection.safeID(String(repeating: "x", count: 129)))
        XCTAssertTrue(CKDASHSelection.safeID("video=5200000:hd"))
    }

    func testDeclaredFrameRateParsesIntegerRationalAndRejectsUnsafeRates() {
        XCTAssertEqual(CKDASHSelection.parseFrameRate("25"), 25)
        XCTAssertEqual(CKDASHSelection.parseFrameRate("30000/1001") ?? 0, 29.97003, accuracy: 0.0001)
        XCTAssertEqual(CKDASHSelection.parseFrameRate("120"), 120)
        for value in ["", "0", "0/1", "25/0", "25/", "/25", "25/1/1", "-25", "+25", "25.0",
                      " 25", "25 ", "NaN", "inf", "600", "1/2", String(repeating: "9", count: 33)] {
            XCTAssertNil(CKDASHSelection.parseFrameRate(value), "invalid frameRate must not become guessed FPS")
        }
        XCTAssertNil(CKDASHSelection.parseFrameRate(nil))
    }

    func testSelectedFrameRateInheritanceAndOverrideStayWithSelectedVideo() throws {
        let xml = """
        <MPD type="dynamic"><Period><AdaptationSet contentType="video" frameRate="25">
        <Representation id="low" height="480" bandwidth="1000000" frameRate="50"/>
        <Representation id="hd" height="1080" bandwidth="5000000"/>
        </AdaptationSet><AdaptationSet contentType="audio" frameRate="48"/></Period></MPD>
        """
        XCTAssertEqual(try XCTUnwrap(CKDASHSelection.plan(Data(xml.utf8))).frameRate, 25)
        let rational = xml.replacingOccurrences(of: "id=\"hd\"", with: "id=\"hd\" frameRate=\"30000/1001\"")
        XCTAssertEqual(try XCTUnwrap(CKDASHSelection.plan(Data(rational.utf8))).frameRate ?? 0, 29.97003, accuracy: 0.0001)
        let unsafe = xml.replacingOccurrences(of: "id=\"hd\"", with: "id=\"hd\" frameRate=\"600\"")
        XCTAssertNil(try XCTUnwrap(CKDASHSelection.plan(Data(unsafe.utf8))).frameRate)
    }

    final class RateTrack: MediaPlayerTrack {
        var trackID: Int32 = 0
        var name = "owned rate test"
        var languageCode: String?
        var mediaType: AVFoundation.AVMediaType = .video
        var nominalFrameRate: Float = 600
        var bitRate: Int64 = 1000000
        var isEnabled = true
        var isImageSubtitle = false
        var rotation: Int16 = 0
        var dovi: DOVIDecoderConfigurationRecord?
        var fieldOrder: FFmpegFieldOrder = .progressive
        var formatDescription: CMFormatDescription?
        var description: String { name }
    }

    func testBadVideoRateCorrectionBeforeBufferAndInterlaceProcessing() {
        for reported: Float in [300, 600, 0, -1, .nan, .infinity] {
            let track = RateTrack(); track.nominalFrameRate = reported
            let options = CKLiveOptions(declaredFrameRate: 25)
            options.process(assetTrack: track)
            XCTAssertEqual(track.nominalFrameRate, 25)
            XCTAssertTrue(options.capacitySnapshot.contains("(MPD)"))
        }
        let interlaced = RateTrack(); interlaced.nominalFrameRate = 300; interlaced.fieldOrder = .tt
        let options = CKLiveOptions(declaredFrameRate: 25)
        options.process(assetTrack: interlaced)
        XCTAssertEqual(interlaced.nominalFrameRate, 50, "upstream deinterlace output rate must be retained")
        XCTAssertFalse(options.hardwareDecode)
        XCTAssertTrue(options.videoFilters.contains(where: { $0.hasPrefix("yadif=") }))
    }

    func testRateCorrectionDoesNotChangeNormalMissingDeclarationOrAudio() {
        for rate: Float in [24, 25, 29.97, 50, 60, 120, 240] {
            let track = RateTrack(); track.nominalFrameRate = rate
            CKLiveOptions(declaredFrameRate: 25).process(assetTrack: track)
            XCTAssertEqual(track.nominalFrameRate, rate)
        }
        let unchanged = RateTrack()
        CKLiveOptions().process(assetTrack: unchanged)
        XCTAssertEqual(unchanged.nominalFrameRate, 600)
        for declaration: Float in [0, -1, 600, .nan, .infinity] {
            let track = RateTrack()
            CKLiveOptions(declaredFrameRate: declaration).process(assetTrack: track)
            XCTAssertEqual(track.nominalFrameRate, 600)
        }
        let audio = RateTrack(); audio.mediaType = .audio; audio.nominalFrameRate = 48
        CKLiveOptions(declaredFrameRate: 25).process(assetTrack: audio)
        XCTAssertEqual(audio.nominalFrameRate, 48)
    }

    func testInflatedRateCapacitiesReproduceFreezeAndCorrectWithoutForcePlay() {
        let options = CKLiveOptions(declaredFrameRate: 25)
        let track = RateTrack(); options.process(assetTrack: track)
        for (frames, packets, audioPackets) in [(3, 328, 718), (4, 728, 1468)] {
            var video = Capacity(fps: 600, packetCount: packets, frameCount: frames)
            let audio = Capacity(fps: 48, packetCount: audioPackets, frameCount: 32,
                                 frameMaxCount: 32, mediaType: .audio)
            XCTAssertFalse(options.playable(capacitys: [video, audio], isFirst: true, isSeek: false).isPlayable)
            video.fps = track.nominalFrameRate
            XCTAssertTrue(options.playable(capacitys: [video, audio], isFirst: true, isSeek: false).isPlayable)
            XCTAssertTrue(options.playable(capacitys: [video, audio], isFirst: false, isSeek: false).isPlayable)
        }
        XCTAssertFalse(options.playable(capacitys: [Capacity(packetCount: 20)], isFirst: true, isSeek: false).isPlayable)
        XCTAssertFalse(options.playable(capacitys: [Capacity(packetCount: 328, frameCount: 0)], isFirst: true, isSeek: false).isPlayable)
        let emptyAudio = Capacity(fps: 48, packetCount: 0, frameCount: 0, mediaType: .audio)
        XCTAssertFalse(options.playable(capacitys: [Capacity(packetCount: 328), emptyAudio], isFirst: true, isSeek: false).isPlayable)
    }

    struct Capacity: CapacityProtocol {
        var fps: Float = 25
        var packetCount: Int
        var frameCount: Int = 2
        var frameMaxCount = 4
        var isEndOfFile = false
        var mediaType: AVFoundation.AVMediaType = .video
    }
    func testLiveStartupReserveAndRefillAreSeparateWithoutZeroBufferHack() {
        let options = CKLiveOptions()
        XCTAssertEqual(options.maxBufferDuration, 20); XCTAssertFalse(options.videoAdaptable)
        XCTAssertFalse(options.isSecondOpen)
        XCTAssertEqual(options.formatContextOptions["ck_live_delay"] as? Int, 6)
        let reserve = [Capacity(packetCount: 38)]
        XCTAssertTrue(options.playable(capacitys: reserve, isFirst: true, isSeek: false).isPlayable)
        XCTAssertFalse(options.playable(capacitys: reserve, isFirst: false, isSeek: false).isPlayable)
        XCTAssertFalse(options.playable(capacitys: [Capacity(packetCount: 2)], isFirst: true, isSeek: false).isPlayable)
        XCTAssertFalse(options.playable(capacitys: [Capacity(packetCount: 100, frameCount: 0)], isFirst: true, isSeek: false).isPlayable)
        XCTAssertTrue(options.playable(capacitys: [Capacity(packetCount: 105)], isFirst: false, isSeek: false).isPlayable)
        var hugeFPS = Capacity(packetCount: 100)
        hugeFPS.fps = .greatestFiniteMagnitude
        _ = options.playable(capacitys: [hugeFPS], isFirst: true, isSeek: false)
        XCTAssertTrue(options.capacitySnapshot.contains("fps1000"), "diagnostic conversion must not trap")
    }

    func testPlaybackMetricsDoNotCountInitialBufferOrDuplicateStatesAsStalls() {
        var metrics = CKPlaybackMetrics(now: 100)
        metrics.state(buffering: true, playable: false, now: 101)
        metrics.state(buffering: true, playable: false, now: 102)
        XCTAssertEqual(metrics.rebufferCount, 0)
        metrics.state(buffering: false, playable: true, now: 103)
        metrics.state(buffering: true, playable: false, now: 104)
        metrics.state(buffering: true, playable: false, now: 105)
        XCTAssertEqual(metrics.rebufferCount, 1); XCTAssertEqual(metrics.playableSeconds, 3)
        metrics.state(buffering: false, playable: true, now: 106)
        XCTAssertEqual(metrics.playableSeconds, 3)
        XCTAssertTrue(metrics.summary.contains("Ready 3.0s"))
        metrics.state(buffering: false, playable: false, now: 107)
        metrics.resumedByUser()
        metrics.state(buffering: true, playable: false, now: 108)
        XCTAssertEqual(metrics.rebufferCount, 1, "manual pause/resume is not a network stall")
    }

    func testAuthorizedPOSTLicenseKeysActuallyDecodeTwoKeyVideoAndAudio() async throws {
        let channel = try CKLicenseFixtures.channel()
        let result = try await CKSourceResolver.resolve(channel)
        let headers = channel.headers.map { "\($0.key):\($0.value)\r\n" }.joined()
        XCTAssertTrue(try multiFixtureMatches(result.url.absoluteString, protocols: "http,tcp,crypto,data",
                                             keys: [:], resolvedKeys: result.keys, headers: headers))
    }

    private func multiFixtureMatches(_ path: String, protocols: String, keys: [String: String],
                                     selection: String? = nil, resolvedKeys: CKKeySet? = nil,
                                     headers: String? = nil) throws -> Bool {
        let goldenURL = try XCTUnwrap(Bundle(for: CKTests.self).url(forResource: "audio-reference", withExtension: "f32", subdirectory: "Fixtures/multikey"))
        let bytes = [UInt8](try Data(contentsOf: goldenURL))
        let golden: [Float] = stride(from: 0, to: bytes.count - 3, by: 4).map {
            Float(bitPattern: UInt32(bytes[$0]) | UInt32(bytes[$0 + 1]) << 8 | UInt32(bytes[$0 + 2]) << 16 | UInt32(bytes[$0 + 3]) << 24)
        }
        var context: UnsafeMutablePointer<AVFormatContext>?, options: OpaquePointer?
        let keySet = try resolvedKeys ?? CKKeySet(keys)
        keySet.formatOptions.forEach { av_dict_set(&options, $0.key, $0.value, 0) }
        if let headers { av_dict_set(&options, "headers", headers, 0) }
        av_dict_set(&options, "protocol_whitelist", protocols, 0)
        av_dict_set(&options, "rw_timeout", "10000000", 0)
        if let selection { av_dict_set(&options, "ck_video_representation", selection, 0) }
        let opened = avformat_open_input(&context, path, nil, &options)
        if opened == 0 { XCTAssertNil(av_dict_get(options, "cenc_decryption_keys", nil, 0), "compiled DASH engine must consume the map option") }
        if opened == 0, selection != nil {
            XCTAssertNil(av_dict_get(options, "ck_video_representation", nil, 0))
            XCTAssertEqual(context?.pointee.nb_streams, 2, "selected video and original audio only")
        }
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
