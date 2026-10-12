import AVFoundation
import Foundation
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
        guard let format = av_find_input_format("dash") else { return XCTFail("DASH is missing from the compiled playback engine") }
        var obj: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(mutating: format.pointee.priv_class)
        let option = av_opt_find(&obj, "cenc_decryption_key", nil, 0, AV_OPT_SEARCH_FAKE_OBJ)
        XCTAssertNotNil(option)
    }
}
