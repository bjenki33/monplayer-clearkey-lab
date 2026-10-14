import AVFoundation
import Foundation
import UIKit
import XCTest
@testable import CKBridge

final class CKOriginalPlayerTests: XCTestCase {
    @MainActor
    func testOrdinaryOwnedHTTPHLSActuallyPlays() async throws {
        try await controlNativeHLS(URL(string: "http://127.0.0.1:18761/gzip/plainhls/index.m3u8")!, label: "fixtureHTTP")
    }

    @MainActor
    func testOwnedPreMuxedFiniteNativeRingActuallyPlays() async throws {
        try await controlNativeRing(finite: true)
    }

    @MainActor
    func testOwnedPreMuxedLiveNativeRingActuallyPlays() async throws {
        try await controlNativeRing(finite: false)
    }

    @MainActor
    func testDelayedPreMuxedLiveNativeRingActuallyPlays() async throws {
        try await controlNativeRing(finite: false, delayed: true)
    }

    @MainActor
    func testResolvedRemuxWithoutAssetMappingActuallyPlays() async throws {
        _ = try await CKNativeFixtures.load("nativedirecttransport")
        let channel = try XCTUnwrap(CKRegistry.shared.channel(CKNativeFixtures.media("nativedirecttransport")))
        let playback = try CKNativePlayback(channel: channel)
        defer { playback.stop() }
        playback.playing(true); playback.start()
        try await controlNativeHLS(playback.http.url, label: "directRemux")
        print("OWNED DIRECT REMUX REQUESTS: \(playback.stats)")
    }

    @MainActor
    private func controlNativeRing(finite: Bool, delayed: Bool = false) async throws {
        let store = CKNativeStore(), bundle = Bundle(for: CKOriginalPlayerTests.self)
        let directory = try XCTUnwrap(bundle.url(forResource: "plainhls", withExtension: nil, subdirectory: "Fixtures"))
        let initName = try store.initialize(Data(contentsOf: directory.appendingPathComponent("init.mp4")), generation: 0)
        let seed = Task.detached {
            if delayed { try await Task.sleep(nanoseconds: 5_000_000_000) }
            for index in 0..<6 {
                try store.append(Data(contentsOf: directory.appendingPathComponent("segment\(index).m4s")), seconds: 2,
                                 initName: initName, discontinuity: false)
            }
            if finite { store.finish() }
        }
        if !delayed { try await seed.value }
        let server = try CKNativeHTTP(store: store); defer { server.stop() }
        try await controlNativeHLS(server.url, label: delayed ? "delayedRing" : finite ? "finiteRing" : "liveRing")
        try await seed.value
        print("OWNED HLS CONTROL REQUESTS: \(store.stats)")
    }

    @MainActor
    private func controlNativeHLS(_ url: URL, label: String) async throws {
        let player = AVPlayer(url: url), item = try XCTUnwrap(player.currentItem)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        player.play()
        for _ in 0..<200 {
            if item.status == .readyToPlay && player.currentTime().seconds > 0.5 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        print("OWNED HLS CONTROL [\(label)]: status \(item.status.rawValue); clock \(player.currentTime().seconds); error \((item.error as NSError?)?.code ?? 0)")
        XCTAssertEqual(item.status, .readyToPlay); XCTAssertGreaterThan(player.currentTime().seconds, 0.5)
    }
    @MainActor
    func testOrdinaryNativeLocalMovieActuallyPlaysWithHooksInstalled() async throws {
        let item = try XCTUnwrap(CKRuntime.placeholderItem())
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        player.play()
        for _ in 0..<100 {
            if item.status == .readyToPlay && player.currentTime().seconds > 0.5 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        print("OWNED ORDINARY NATIVE CONTROL: status \(item.status.rawValue); clock \(player.currentTime().seconds); error \((item.error as NSError?)?.code ?? 0)")
        XCTAssertEqual(item.status, .readyToPlay); XCTAssertGreaterThan(player.currentTime().seconds, 0.5)
        XCTAssertNil(CKNativeItems.session(item))
    }
    private func seeded(count: Int = CKNativeStore.startupSegments) throws -> CKNativeStore {
        let store = CKNativeStore()
        let name = try store.initialize(Data("owned-init".utf8), generation: 0)
        for _ in 0..<count { try store.append(Data("owned-segment".utf8), seconds: 2, initName: name, discontinuity: false) }
        return store
    }
    func testNativeInitialPlaylistWaitsForUsableLiveWindow() throws {
        let store = try seeded(count: 3)
        let master = store.response(path: "/\(store.token)/index.m3u8", wait: 0)
        XCTAssertEqual(master.0, 200)
        XCTAssertTrue(String(decoding: master.2, as: UTF8.self).contains("#EXT-X-STREAM-INF:"))
        XCTAssertEqual(store.response(path: "/\(store.token)/media.m3u8", wait: 0).0, 503)
        for _ in 0..<3 { try store.append(Data([1]), seconds: 2, initName: "init0.mp4", discontinuity: false) }
        XCTAssertEqual(store.response(path: "/\(store.token)/media.m3u8", wait: 0).0, 200)
        store.close()
    }
    func testNativePlaylistUsesRealFragmentDurationAndInitialization() throws {
        let store = try seeded()
        let (status, _, data) = store.response(path: "/\(store.token)/media.m3u8", wait: 0)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(status, 200); XCTAssertTrue(text.contains("#EXT-X-VERSION:7"))
        XCTAssertTrue(text.contains("#EXT-X-TARGETDURATION:2"))
        XCTAssertTrue(text.contains("#EXT-X-MAP:URI=\"init0.mp4\""))
        XCTAssertEqual(text.components(separatedBy: "#EXTINF:").count - 1, 6)
        XCTAssertFalse(text.contains("#EXT-X-ENDLIST")); store.close()
    }
    func testNativeEndpointRejectsWrongTokenAndTraversal() throws {
        let store = try seeded()
        for path in ["/other/index.m3u8", "/\(store.token)/../init0.mp4", "/\(store.token)/%2e%2e/init0.mp4", "/\(store.token)/index.m3u8?url=http://example.invalid"] {
            XCTAssertEqual(store.response(path: path, wait: 0).0, 404)
        }
        store.close()
    }
    func testNativeRingPrunesOnlyCompleteOldFragmentsAndInitializations() throws {
        let store = try seeded()
        let next = try store.initialize(Data("owned-next-init".utf8), generation: 1)
        for index in 0..<19 { try store.append(Data([UInt8(index)]), seconds: 2, initName: next, discontinuity: index == 0) }
        XCTAssertEqual(store.stats["segments"], 18); XCTAssertEqual(store.stats["initializations"], 1)
        XCTAssertEqual(store.response(path: "/\(store.token)/init0.mp4", wait: 0).0, 404)
        let text = String(decoding: store.response(path: "/\(store.token)/media.m3u8", wait: 0).2, as: UTF8.self)
        XCTAssertTrue(text.contains("#EXT-X-MEDIA-SEQUENCE:7"))
        XCTAssertTrue(text.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1")); store.close()
    }
    func testNativeBuffersHaveHardSizeAndCancellationLimits() throws {
        let store = CKNativeStore(), initName = try store.initialize(Data([1]), generation: 0)
        XCTAssertThrowsError(try store.initialize(Data(), generation: 1))
        XCTAssertThrowsError(try store.append(Data(), seconds: 2, initName: initName, discontinuity: false))
        XCTAssertThrowsError(try store.append(Data([1]), seconds: .infinity, initName: initName, discontinuity: false))
        let block = Data(repeating: 7, count: CKNativeStore.segmentLimit)
        for _ in 0..<5 { try store.append(block, seconds: 2, initName: initName, discontinuity: false) }
        XCTAssertLessThanOrEqual(store.stats["bytes"] ?? .max, CKNativeStore.memoryLimit)
        store.close(); XCTAssertTrue(store.closed); XCTAssertEqual(store.stats["bytes"], 0)
        XCTAssertThrowsError(try store.append(Data([1]), seconds: 2, initName: initName, discontinuity: false))
    }
    func testNativeFiniteEndPublishesEndlistWithoutDiscardingMedia() throws {
        let store = try seeded(); store.finish()
        XCTAssertFalse(store.closed)
        let text = String(decoding: store.response(path: "/\(store.token)/media.m3u8", wait: 0).2, as: UTF8.self)
        XCTAssertTrue(text.contains("#EXT-X-ENDLIST"))
        XCTAssertEqual(store.response(path: "/\(store.token)/segment0.m4s", wait: 0).2, Data("owned-segment".utf8))
        store.close()
    }
    func testNativeHTTPServesHeadAndValidatedByteRanges() async throws {
        let store = try seeded(), server = try CKNativeHTTP(store: store)
        defer { server.stop() }
        let url = server.url.deletingLastPathComponent().appendingPathComponent("init0.mp4")
        var request = URLRequest(url: url); request.setValue("bytes=1-4", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(data, Data("wned".utf8))
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 1-4/10")
        request.setValue("bytes=-4", forHTTPHeaderField: "Range")
        let (suffix, _) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(suffix, Data("init".utf8))
        request.setValue("bytes=6-100", forHTTPHeaderField: "Range")
        let (clamped, clampedResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(clamped, Data("init".utf8))
        XCTAssertEqual((clampedResponse as? HTTPURLResponse)?.statusCode, 206)
        request.httpMethod = "HEAD"; request.setValue(nil, forHTTPHeaderField: "Range")
        let (head, headResponse) = try await URLSession.shared.data(for: request)
        XCTAssertTrue(head.isEmpty); XCTAssertEqual((headResponse as? HTTPURLResponse)?.expectedContentLength, 10)
        request.httpMethod = "GET"; request.setValue("bytes=100-101", forHTTPHeaderField: "Range")
        let (_, invalid) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((invalid as? HTTPURLResponse)?.statusCode, 416)
    }
    @MainActor
    func testOriginalItemIdentityStatusAndPlayPauseRemainNative() async throws {
        _ = try await CKNativeFixtures.load("nativeidentity")
        var item: AVPlayerItem? = AVPlayerItem(url: CKNativeFixtures.media("nativeidentity"))
        let player = AVPlayer(playerItem: item)
        XCTAssertTrue(player.currentItem === item)
        let session = try XCTUnwrap(CKNativeItems.session(item))
        XCTAssertEqual((item?.asset as? AVURLAsset)?.url, session.http.url)
        let original = CKRuntime.top()
        player.playImmediately(atRate: 1)
        try await waitFor { item?.status == .readyToPlay && player.timeControlStatus == .playing }
        XCTAssertNil(CKRuntime.presentedController); XCTAssertTrue(CKRuntime.top() === original)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        player.pause(); let paused = player.currentTime().seconds
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(player.rate, 0); XCTAssertEqual(player.currentTime().seconds, paused, accuracy: 0.15)
        player.play(); try await waitFor { player.currentTime().seconds > paused + 0.3 }
        XCTAssertGreaterThan(session.stats["audio_packets"] ?? 0, 0)
        player.pause(); player.replaceCurrentItem(with: nil); item = nil
        try await waitFor { session.store.closed }
    }
    @MainActor
    func testOriginalAssetAndAutomaticallyLoadedKeysRemainNative() async throws {
        _ = try await CKNativeFixtures.load("nativeassetidentity")
        let asset = AVURLAsset(url: CKNativeFixtures.media("nativeassetidentity"))
        let item = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["playable", "tracks"])
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        XCTAssertTrue(item.asset === asset); XCTAssertTrue(player.currentItem === item)
        XCTAssertNotNil(CKNativeItems.session(item))
        player.play()
        try await waitFor { item.status == .readyToPlay && player.timeControlStatus == .playing }
        XCTAssertNil(CKRuntime.presentedController)
    }
    func testOrdinaryAssetsAndPlayerItemsAreNotRemapped() {
        let url = URL(string: "https://example.invalid/ordinary-unobserved.mp4")!
        let asset = AVURLAsset(url: url), item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        XCTAssertEqual(asset.url, url); XCTAssertTrue(item.asset === asset)
        XCTAssertTrue(player.currentItem === item); XCTAssertNil(CKNativeItems.session(item))
        player.pause(); player.replaceCurrentItem(with: nil)
    }
    @MainActor
    func testOfficialRoutingNeverPresentsPrototypeForKnownClearKeyURL() async throws {
        _ = try await CKNativeFixtures.load("nativeprototyperejected")
        let original = CKRuntime.top()
        XCTAssertFalse(CKRuntime.routeURL(CKNativeFixtures.media("nativeprototyperejected")))
        XCTAssertNil(CKRuntime.presentedController); XCTAssertTrue(CKRuntime.top() === original)
    }
    @MainActor
    private func waitFor(_ ready: () -> Bool) async throws {
        for _ in 0..<250 {
            if ready() { return }; try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("native AVPlayer condition did not become ready within25s")
        throw CKNativeFailure.transport
    }
}
