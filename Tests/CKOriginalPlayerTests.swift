import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import UIKit
import XCTest
@testable import CKBridge

final class CKOriginalPlayerTests: XCTestCase {
    @MainActor
    func testOriginalPlayerStartupTimingOnOwnedTwoSecondLiveSource() async throws {
        try await exerciseStartup("nativestartuplatency")
    }

    @MainActor
    func testOriginalPlayerStartupTimingOnOwnedFourSecondLiveSource() async throws {
        try await exerciseStartup("nativelonggopstartup")
    }

    @MainActor
    private func exerciseStartup(_ name: String) async throws {
        _ = try await CKNativeFixtures.load(name)
        let began = ProcessInfo.processInfo.systemUptime
        let player = AVPlayer(url: CKNativeFixtures.media(name))
        let item = try XCTUnwrap(player.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        player.play()
        var firstFrame: TimeInterval?, frames: Set<UInt64> = []
        while ProcessInfo.processInfo.systemUptime - began < 32 {
            if item.status == .readyToPlay, player.timeControlStatus == .playing,
               let buffer = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
                firstFrame = ProcessInfo.processInfo.systemUptime - began
                frames.insert(fingerprint(buffer)); break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let latency = try XCTUnwrap(firstFrame, "actual native frame must arrive,not just ready metadata")
        let clock = player.currentTime().seconds
        for _ in 0..<40 {
            if let buffer = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
                frames.insert(fingerprint(buffer))
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let audio = item.tracks.filter { $0.isEnabled && $0.assetTrack?.mediaType == .audio }
        let stereo = audio.compactMap(\.assetTrack).flatMap(\.formatDescriptions).contains {
            CMAudioFormatDescriptionGetStreamBasicDescription($0 as! CMAudioFormatDescription)?.pointee.mChannelsPerFrame == 2
        }
        let statsURL = URL(string: "http://127.0.0.1:18761/live/\(name)/stats")!
        let (data, _) = try await URLSession.shared.data(from: statsURL)
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Double])
        print("OWNED ORIGINAL STARTUP [\(name)]: first frame \(latency)s; advance \(player.currentTime().seconds-clock)s; distinct frames \(frames.count); stereo \(stereo); ages \(stats)")
        XCTAssertGreaterThan(player.currentTime().seconds-clock, 7)
        XCTAssertGreaterThan(frames.count, 30); XCTAssertTrue(stereo)
        XCTAssertEqual(stats["future_requests"] ?? 0, 0)
        XCTAssertEqual(stats["expired_requests"] ?? 0, 0)
        XCTAssertNil(CKRuntime.presentedController)
    }

    private func fingerprint(_ buffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let pointer = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytes = pointer.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 1469598103934665603
        for y in Swift.stride(from: 0, to: height, by: max(1, height / 12)) {
            for x in Swift.stride(from: 0, to: width, by: max(1, width / 16)) {
                hash = (hash ^ UInt64(bytes[y * stride + x * 4])) &* 1099511628211
            }
        }
        return hash
    }

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
        let ready = await Task.detached { playback.store.waitUntilReady(seconds: 25) }.value
        XCTAssertTrue(ready)
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
        let redirect = delayed ? CKNativeWarmRedirect(store: store, httpURL: server.url) : nil
        try await controlNativeHLS(server.url, label: delayed ? "delayedRing" : finite ? "finiteRing" : "liveRing", redirect: redirect)
        try await seed.value
        print("OWNED HLS CONTROL REQUESTS: \(store.stats)")
    }

    @MainActor
    private func controlNativeHLS(_ url: URL, label: String, redirect: CKNativeWarmRedirect? = nil) async throws {
        let player: AVPlayer
        if let redirect {
            let asset = AVURLAsset(url: redirect.url); redirect.attach(asset)
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        } else { player = AVPlayer(url: url) }
        let item = try XCTUnwrap(player.currentItem)
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
        let store = try seeded(count: 2)
        let master = store.response(path: "/\(store.token)/index.m3u8", wait: 0)
        XCTAssertEqual(master.0, 200)
        XCTAssertTrue(String(decoding: master.2, as: UTF8.self).contains("#EXT-X-STREAM-INF:"))
        XCTAssertEqual(store.response(path: "/\(store.token)/media.m3u8", wait: 0).0, 503)
        try store.append(Data([1]), seconds: 2, initName: "init0.mp4", discontinuity: false)
        XCTAssertEqual(store.response(path: "/\(store.token)/media.m3u8", wait: 0).0, 200)
        store.close()
    }
    func testNativePlaylistUsesRealFragmentDurationAndInitialization() throws {
        let store = try seeded(count: 6)
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
        let store = try seeded(count: 6)
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
    func testNativePreparationGateHonorsReadinessFailureAndCancellation() throws {
        let store = try seeded(count: 0)
        XCTAssertFalse(store.waitUntilReady(seconds: 0))
        XCTAssertFalse(store.waitUntilReady(seconds: 1, interrupted: { true }))
        for _ in 0..<6 { try store.append(Data([1]), seconds: 2, initName: "init0.mp4", discontinuity: false) }
        XCTAssertTrue(store.waitUntilReady(seconds: 0))
        store.close(); XCTAssertFalse(store.waitUntilReady(seconds: 0))
    }
    func testNativeWarmupUsesDurationNotJustThreeFragments() throws {
        let store = CKNativeStore(), name = try store.initialize(Data([1]), generation: 0)
        for _ in 0..<3 { try store.append(Data([1]), seconds: 1.8, initName: name, discontinuity: false) }
        XCTAssertFalse(store.ready); XCTAssertFalse(store.waitUntilReady(seconds: 0))
        XCTAssertEqual(store.response(path: "/\(store.token)/media.m3u8", wait: 0).0, 503)
        try store.append(Data([1]), seconds: 1.8, initName: name, discontinuity: false)
        XCTAssertTrue(store.ready); XCTAssertTrue(store.waitUntilReady(seconds: 0))
        XCTAssertEqual(store.response(path: "/\(store.token)/media.m3u8", wait: 0).0, 200)
        store.close()
    }
    func testNativeLongFragmentsDoNotRequireSixGOPs() throws {
        let store = CKNativeStore(), name = try store.initialize(Data([1]), generation: 0)
        for _ in 0..<3 { try store.append(Data([1]), seconds: 4, initName: name, discontinuity: false) }
        XCTAssertEqual(store.count, 3); XCTAssertTrue(store.ready)
        XCTAssertTrue(store.waitUntilReady(seconds: 0))
        let text = String(decoding: store.response(path: "/\(store.token)/media.m3u8", wait: 0).2, as: UTF8.self)
        XCTAssertTrue(text.contains("#EXT-X-TARGETDURATION:4"))
        XCTAssertEqual(text.components(separatedBy: "#EXTINF:").count - 1, 3)
        store.close()
    }
    func testNativeMixedFragmentReserveMayNeedMoreThanSixFragments() throws {
        let store = CKNativeStore(), name = try store.initialize(Data([1]), generation: 0)
        try store.append(Data([1]), seconds: 6, initName: name, discontinuity: false)
        for _ in 0..<6 { try store.append(Data([1]), seconds: 1.8, initName: name, discontinuity: false) }
        XCTAssertEqual(store.count, 7); XCTAssertFalse(store.ready)
        try store.append(Data([1]), seconds: 1.8, initName: name, discontinuity: false)
        XCTAssertTrue(store.ready); store.close()
    }
    func testNativeWarmupWaitWakesWhenDurationReserveArrives() async throws {
        let store = try seeded(count: 2)
        defer { store.close() }
        let waiter = Task.detached { store.waitUntilReady(seconds: 5) }
        try await Task.sleep(nanoseconds: 100_000_000)
        try store.append(Data([1]), seconds: 2, initName: "init0.mp4", discontinuity: false)
        let began = ProcessInfo.processInfo.systemUptime
        let ready = await waiter.value
        XCTAssertTrue(ready)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1.5)
    }
    func testNativeFiniteShortTailIsReadyAndFailuresAreNotReady() throws {
        let store = try seeded(count: 1)
        XCTAssertFalse(store.ready); store.finish(); XCTAssertTrue(store.ready)
        XCTAssertTrue(store.waitUntilReady(seconds: 0))
        store.close(); XCTAssertFalse(store.ready)
        let failed = try seeded(); XCTAssertTrue(failed.ready)
        failed.close(failure: true); XCTAssertFalse(failed.ready)
        XCTAssertFalse(failed.waitUntilReady(seconds: 0))
    }
    @MainActor
    func testOriginalItemBecomesReadyBeforeOriginalAppRequestsPlay() async throws {
        _ = try await CKNativeFixtures.load("nativepreplayready")
        let item = AVPlayerItem(url: CKNativeFixtures.media("nativepreplayready"))
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        try await waitFor { item.status == .readyToPlay }
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(try XCTUnwrap(CKNativeItems.session(item)).store.ready)
        player.play(); try await waitFor { player.timeControlStatus == .playing && player.currentTime().seconds > 0.3 }
        XCTAssertTrue(player.currentItem === item); XCTAssertNil(CKRuntime.presentedController)
    }
    @MainActor
    func testOriginalItemIdentityStatusAndPlayPauseRemainNative() async throws {
        _ = try await CKNativeFixtures.load("nativeidentity")
        var item: AVPlayerItem? = AVPlayerItem(url: CKNativeFixtures.media("nativeidentity"))
        let player = AVPlayer(playerItem: item)
        XCTAssertTrue(player.currentItem === item)
        let session = try XCTUnwrap(CKNativeItems.session(item))
        XCTAssertEqual((item?.asset as? AVURLAsset)?.url.scheme, "mpclearkey")
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
