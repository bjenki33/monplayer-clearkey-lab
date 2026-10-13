import Foundation
import UIKit
import XCTest
@testable import CKBridge

enum CKLicenseFixtures {
    static let kid = "000102030405060708090a0b0c0d0e0f"
    static let second = "202122232425262728292a2b2c2d2e2f"
    static func channel(mode: String = "standard", modern: Bool = true, template: String? = nil,
                        response: String = "R", manifest: String = "http://127.0.0.1:18761/licensed/owned/manifest.mpd") throws -> CKChannel {
        let endpoint = "http://127.0.0.1:18761/license/\(mode)"
        let tags: String
        if modern {
            var license: [String:Any] = ["server_url":endpoint,"req_headers":"X-License=owned-license"]
            if let template { license["req_data"] = Data(template.utf8).base64EncodedString() }
            let json = try JSONSerialization.data(withJSONObject: ["org.w3.clearkey":["license":license]], options: .sortedKeys)
            tags = "#KODIPROP:inputstream.adaptive.drm=\(String(decoding: json, as: UTF8.self))"
        } else {
            let type = mode == "form" ? "&Content-Type=application%2Fx-www-form-urlencoded" : ""
            tags = "#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=\(endpoint)|X-License=owned-license\(type)|\(template ?? "R{SSM}")|\(response)"
        }
        let text = "#EXTM3U\n#EXTINF:-1,Owned licensed fixture\n\(tags)\n#KODIPROP:inputstream.adaptive.stream_headers=X-Stream=owned-stream\n\(manifest)\n"
        return try XCTUnwrap(CKPlaylist.parse(Data(text.utf8), relativeTo: nil).first)
    }
}

final class CKLicenseTests: XCTestCase {
    let ids = [CKLicenseFixtures.kid, CKLicenseFixtures.second]
    func manifest(_ content: String, namespace: String = "urn:mpeg:cenc:2013") -> Data {
        Data("<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" xmlns:c=\"\(namespace)\"><Period>\(content)</Period></MPD>".utf8)
    }
    func testManifestDiscoversDistinctDeclaredAudioVideoIDs() throws {
        let data = manifest("<AdaptationSet><ContentProtection c:default_KID=\"00010203-0405-0607-0809-0a0b0c0d0e0f\"/></AdaptationSet><AdaptationSet><ContentProtection c:default_KID=\"\(ids[1]) \(ids[0])\"/></AdaptationSet>")
        XCTAssertEqual(try CKManifestKeyIDs.read(data), ids)
        let prefixed = Data("<d:MPD xmlns:d=\"urn:mpeg:dash:schema:mpd:2011\" xmlns:x=\"urn:mpeg:cenc:2013\"><d:Period><d:ContentProtection x:default_KID=\"\(ids[0])\"/></d:Period></d:MPD>".utf8)
        XCTAssertEqual(try CKManifestKeyIDs.read(prefixed), [ids[0]])
        XCTAssertNoThrow(try CKManifest.kind(prefixed))
    }
    func testManifestRejectsMissingFakeNamespaceInvalidAndEntityIDs() {
        for data in [manifest(""), manifest("<ContentProtection c:default_KID=\"\(ids[0])\"/>", namespace: "urn:fake"),
                     manifest("<ContentProtection c:default_KID=\"not-a-valid-id\"/>"),
                     Data("<!DOCTYPE MPD [<!ENTITY kid 'bad'>]><MPD/>".utf8),
                     Data("<html/>".utf8), Data(repeating: 32, count: 2 * 1024 * 1024 + 1)] {
            XCTAssertThrowsError(try CKManifestKeyIDs.read(data))
        }
        let scoped = manifest("<AdaptationSet xmlns:c=\"urn:fake\"><ContentProtection c:default_KID=\"\(ids[1])\"/></AdaptationSet><ContentProtection c:default_KID=\"\(ids[0])\"/>")
        XCTAssertEqual(try? CKManifestKeyIDs.read(scoped), [ids[0]], "prefix scopes must not leak between adaptation groups")
    }
    func testStandardChallengeCanonicalBase64URLAndBounds() throws {
        let data = try CKLicenseBody.challengeData(kids: Array(ids.reversed()) + [ids[0]])
        let object = try XCTUnwrap(try CKJSON.object(data) as? [String:Any])
        XCTAssertEqual(object["type"] as? String, "temporary")
        XCTAssertEqual(object["kids"] as? [String], ["AAECAwQFBgcICQoLDA0ODw", "ICEiIyQlJicoKSorLC0uLw"])
        XCTAssertThrowsError(try CKLicenseBody.challengeData(kids: []))
        XCTAssertThrowsError(try CKLicenseBody.challengeData(kids: ["missing"]))
        XCTAssertThrowsError(try CKLicenseBody.challengeData(kids: Array(repeating: ids[0], count: 129)))
    }
    func testDeclaredTemplateEncodingsAndUnambiguousSingleKID() throws {
        let challenge = try CKLicenseBody.challengeData(kids: ids)
        XCTAssertEqual(try CKLicenseBody.legacy("R{SSM}").data(kids: ids), challenge)
        XCTAssertEqual(try CKLicenseBody.legacy("b{SSM}").data(kids: ids), Data(challenge.base64EncodedString().utf8))
        let modern = try CKLicenseBody.modern(#"{"challenge":"{CHA-B64}"}"#).data(kids: ids)
        let object = try XCTUnwrap(try CKJSON.object(modern) as? [String:String])
        XCTAssertEqual(CKKeys.base64(object["challenge"] ?? ""), challenge)
        XCTAssertEqual(try CKLicenseBody.modern("{KID-HEX}").data(kids: [ids[0]]), Data(ids[0].utf8))
        XCTAssertEqual(try CKLicenseBody.modern("{KID-UUID}").data(kids: [ids[0]]), Data("00010203-0405-0607-0809-0a0b0c0d0e0f".utf8))
        XCTAssertThrowsError(try CKLicenseBody.modern("{KID-HEX}").data(kids: ids))
        XCTAssertThrowsError(try CKLicenseBody.legacy("R{SSM}").data(kids: []))
        for token in ["{SID-RAW}","{PSSH-B64}","{UNKNOWN}"] { XCTAssertThrowsError(try CKLicenseBody.modern(token)) }
        XCTAssertThrowsError(try CKLicenseBody.legacy("{SSM}"))
        XCTAssertThrowsError(try CKLicenseBody.legacy("R{KID}"))
    }
    func testModernPOSTIsolatesLicenseHeadersAndValidatesJSONBody() throws {
        let channel = try CKLicenseFixtures.channel()
        let request = try XCTUnwrap(channel.keyRequest(kids: ids))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-License"), "owned-license")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Stream"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(channel.headers["X-License"])
        XCTAssertThrowsError(try channel.keyRequest())
        let invalid = try CKLicenseFixtures.channel(template: #"{"challenge":"{CHA-RAW}"}"#)
        XCTAssertThrowsError(try invalid.keyRequest(kids: ids), "raw JSON injected inside a JSON string is invalid,not silently sent")
    }
    func testResponseWrappersRejectAmbiguityAndPersistentPolicy() throws {
        let map = Data("{\"\(ids[0])\":\"101112131415161718191a1b1c1d1e1f\"}".utf8)
        XCTAssertEqual(try CKLicenseResponse.legacy("B").unwrap(Data(map.base64EncodedString().utf8)), map)
        let outer = try JSONSerialization.data(withJSONObject: ["payload":map.base64EncodedString()])
        XCTAssertEqual(try CKLicenseResponse.legacy("JBpayload").unwrap(outer), map)
        for flag in ["auto","HB","J","Jpayload;hdcp","Jpayload/nested","BJpayload"] {
            XCTAssertThrowsError(try CKLicenseResponse.legacy(flag))
        }
        XCTAssertThrowsError(try CKLicenseResponse.legacy("Jpayload").unwrap(Data(#"{"payload":"one","payload":"two"}"#.utf8)))
        let license = try CKLicenseFixtures.channel().license
        let persistent = Data(#"{"keys":[{"kty":"oct","kid":"AAECAwQFBgcICQoLDA0ODw","k":"EBESExQVFhcYGRobHB0eHw"}],"type":"persistent-license"}"#.utf8)
        XCTAssertThrowsError(try license.keys(from: persistent, requested: [ids[0]]))
    }
    func testRedirectPolicyPreservesPOSTAndRejectsOriginMethodAndLoops() throws {
        let original = try XCTUnwrap(try CKLicenseFixtures.channel().keyRequest(kids: ids))
        let policy = CKHTTPRedirectPolicy(request: original, role: .license)
        let next = URLRequest(url: URL(string: "http://127.0.0.1:18761/license/redirected")!)
        let response = try XCTUnwrap(HTTPURLResponse(url: original.url!, statusCode: 307, httpVersion: nil, headerFields: nil))
        XCTAssertEqual(policy.follow(response, proposed: next)?.httpBody, original.httpBody)
        let response302 = try XCTUnwrap(HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: nil))
        XCTAssertNil(CKHTTPRedirectPolicy(request: original, role: .license).follow(response302, proposed: next))
        XCTAssertNil(CKHTTPRedirectPolicy(request: original, role: .license).follow(response, proposed: URLRequest(url: URL(string: "http://localhost:18761/license/standard")!)))
        let loop = CKHTTPRedirectPolicy(request: original, role: .license)
        for _ in 0..<5 { XCTAssertNotNil(loop.follow(response, proposed: next)) }
        XCTAssertNil(loop.follow(response, proposed: next)); XCTAssertTrue(loop.wasDenied)
        XCTAssertTrue(CKHTTPRedirectPolicy.sameOrigin(URL(string: "https://EXAMPLE.invalid/a")!, URL(string: "https://example.invalid:443/b")!))
        XCTAssertFalse(CKHTTPRedirectPolicy.sameOrigin(URL(string: "https://example.invalid")!, URL(string: "http://example.invalid")!))
    }
    func testActualStandardPOSTAndLegacyGETResolveTwoDistinctKeys() async throws {
        let modern = try await CKSourceResolver.resolve(CKLicenseFixtures.channel())
        XCTAssertEqual(modern.keys.distinctKeyCount, 2); XCTAssertTrue(modern.keys.requiresKeyMap)
        let legacy = try CKLicenseFixtures.channel(modern: false, template: "")
        XCTAssertEqual(try legacy.keyRequest()?.httpMethod, "GET")
        let legacyResult = try await CKSourceResolver.resolve(legacy)
        XCTAssertEqual(legacyResult.keys.formatOptions, modern.keys.formatOptions)
    }
    func testActualDeclaredModernAndFormPOSTBodies() async throws {
        for channel in [try CKLicenseFixtures.channel(mode: "template", template: #"{"challenge":"{CHA-B64}"}"#),
                        try CKLicenseFixtures.channel(mode: "form", modern: false, template: "challenge=B{SSM}"),
                        try CKLicenseFixtures.channel(template: #"{"fixture":"owned"}"#)] {
            let result = try await CKSourceResolver.resolve(channel)
            XCTAssertEqual(result.keys.distinctKeyCount, 2)
        }
    }
    func testActualLegacyWrappedResponsesReachKeyMap() async throws {
        for (mode, wrapper) in [("base64","B"),("json","Jpayload"),("jsonbase64","JBpayload")] {
            let result = try await CKSourceResolver.resolve(CKLicenseFixtures.channel(mode: mode, modern: false, response: wrapper))
            XCTAssertEqual(result.keys.distinctKeyCount, 2)
        }
    }
    func testActualMissingConflictingMalformedAndPersistentLicensesFail() async throws {
        for (mode, expected) in [("missing",CKFailure.missingLicenseKey),("conflict",.invalidKey),
                                 ("invalid",.invalidKey),("persistent",.unsupportedLicense),("oversize",.responseTooLarge)] {
            do {
                _ = try await CKSourceResolver.resolve(CKLicenseFixtures.channel(mode: mode))
                XCTFail("bad owned license must not resolve")
            } catch let error as CKResolutionError {
                XCTAssertEqual(error.stage, .key)
                XCTAssertEqual(error.underlying as? CKFailure, expected)
            }
        }
    }
    func testActualRedirectPOSTPreservedUnsafeRedirectsBlocked() async throws {
        let result = try await CKSourceResolver.resolve(CKLicenseFixtures.channel(mode: "redirect307"))
        XCTAssertEqual(result.keys.distinctKeyCount, 2)
        for mode in ["redirectcross","redirect302","loop"] {
            do { _ = try await CKSourceResolver.resolve(CKLicenseFixtures.channel(mode: mode)); XCTFail("redirect must fail closed") }
            catch let error as CKResolutionError {
                XCTAssertEqual(error.underlying as? CKFailure, .unsafeRedirect, "owned redirect mode \(mode): \(CKDiagnostic.message(error.underlying, stage: error.stage))")
            }
        }
    }
    func testActualEphemeralSessionsDoNotRetainResponseCookies() async throws {
        _ = try await CKSourceResolver.resolve(CKLicenseFixtures.channel())
        let (data, _) = try await CKHTTP.read(URLRequest(url: URL(string: "http://127.0.0.1:18761/license/cookiecheck")!), role: .license, limit: 1024)
        let object = try XCTUnwrap(try CKJSON.object(data) as? [String:Bool])
        XCTAssertEqual(object["cookie_present"], false)
    }
    func testActualSlowRequestCancellationDoesNotWaitForServer() async throws {
        let task = Task { try await CKHTTP.read(URLRequest(url: URL(string: "http://127.0.0.1:18761/license/slow")!), role: .license, limit: 1024 * 1024) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let began = ProcessInfo.processInfo.systemUptime; task.cancel()
        do { _ = try await task.value; XCTFail("canceled request must fail") } catch { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 3)
    }

    func testPOSTRejectsTransportHeaderSpoofingAndMissingDeclaredIDs() throws {
        var channel = try CKLicenseFixtures.channel()
        var license = channel.license
        license = CKLicenseSpec(source: license.source, headers: ["Content-Length":"1"], body: .challenge,
                                inheritsStreamHeaders: false)
        channel.licenseSpec = license
        XCTAssertThrowsError(try channel.keyRequest(kids: ids))
        XCTAssertThrowsError(try CKLicenseBody.challenge.data(kids: []))
    }

    func testLicensedReserveNeedsDecodedDataWithoutChangingLegacyPolicy() {
        let live = CKLiveOptions()
        let early = [CKTests.Capacity(packetCount: 38)]
        XCTAssertTrue(live.playable(capacitys: early, isFirst: true, isSeek: false).isPlayable)
        live.useLicensedStartupReserve()
        XCTAssertFalse(live.playable(capacitys: early, isFirst: true, isSeek: false).isPlayable)
        XCTAssertTrue(live.playable(capacitys: [CKTests.Capacity(packetCount: 75)], isFirst: true, isSeek: false).isPlayable)
        XCTAssertFalse(live.playable(capacitys: [CKTests.Capacity(packetCount: 150, frameCount: 0)], isFirst: true, isSeek: false).isPlayable)
        XCTAssertEqual(live.preferredForwardBufferDuration, 4); XCTAssertEqual(live.maxBufferDuration, 20)
    }

    func testActualStreamingResponseLimitWithoutContentLength() async throws {
        do {
            _ = try await CKHTTP.read(URLRequest(url: URL(string: "http://127.0.0.1:18761/license/oversizestream")!), role: .license, limit: 1024 * 1024)
            XCTFail("streaming payload must remain bounded")
        } catch { XCTAssertEqual(error as? CKFailure, .responseTooLarge) }
    }

    @MainActor
    func testClosedControllerCannotAttachLateLicenseOrShowStaleError() async throws {
        let controller = CKPlaybackController(channel: try CKLicenseFixtures.channel(mode: "slow"))
        controller.loadViewIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        let status = controller.status.text
        controller.close()
        try await Task.sleep(nanoseconds: 6_200_000_000)
        XCTAssertNil(controller.layer); XCTAssertNil(controller.playerOptions)
        XCTAssertNil(controller.metrics.playableSeconds)
        XCTAssertEqual(controller.status.text, status, "closing must invalidate old opens/errors")
    }
}
