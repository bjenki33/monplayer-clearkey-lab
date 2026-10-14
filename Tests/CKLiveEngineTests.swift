import AVFoundation
import CoreVideo
import CoreMedia
import KSPlayer
import Libavformat
import Libavutil
import UIKit
import XCTest
@testable import CKBridge

final class CKLiveEngineTests: XCTestCase {
    @MainActor
    func testNativeImportedPlaylistAndOriginalAVPlayerRouteStartMovingStereoEngine() async throws {
        try await exerciseNativeImport(name: "nativeengine", delegated: false)
    }

    @MainActor
    func testNativeDelegatedPlaylistAndOriginalAVPlayerRouteStartMovingStereoEngine() async throws {
        try await exerciseNativeImport(name: "nativedelegateengine", delegated: true)
    }

    @MainActor
    func testNativeAsyncPlaylistAndOriginalAVPlayerRouteStartMovingStereoEngine() async throws {
        try await exerciseNativeImport(name: "nativeasyncengine", delegated: false, asynchronous: true)
    }

    @MainActor
    private func exerciseNativeImport(name: String, delegated: Bool, asynchronous: Bool = false) async throws {
        if asynchronous { _ = try await CKNativeFixtures.asyncLoad(name) }
        else if delegated { _ = try await CKNativeDataProbe().load(name, mode: "redirect") }
        else { _ = try await CKNativeFixtures.load(name, mode: "redirect") }
        let url = CKNativeFixtures.media(name)
        XCTAssertNotNil(CKRegistry.shared.channel(url))
        XCTAssertNil(CKRuntime.presentedController)
        XCTAssertTrue(CKPresentation.originalPlayer)
        let root = CKRuntime.top()
        let native = AVPlayer(url: url)
        let item = try XCTUnwrap(native.currentItem)
        let media = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(media)
        let rendering = AVPlayerLayer(player: native)
        rendering.frame = root?.view.bounds ?? CGRect(x: 0, y: 0, width: 640, height: 360)
        root?.view.layer.addSublayer(rendering)
        defer { native.pause(); native.replaceCurrentItem(with: nil); rendering.removeFromSuperlayer() }
        native.play()
        try await waitFor { item.status == .readyToPlay && native.timeControlStatus == .playing }
        if item.status != .readyToPlay || native.timeControlStatus != .playing {
            originalDiagnostics(item, label: name)
            return
        }
        XCTAssertNotEqual((native.currentItem?.asset as? AVURLAsset)?.url, url,
                          "genuine AVPlayer receives the actual on-device media endpoint")
        XCTAssertEqual((item.asset as? AVURLAsset)?.url.scheme, "mpclearkey")
        XCTAssertTrue(CKRuntime.top() === root); XCTAssertNil(CKRuntime.presentedController)
        // Inspect the actual playing HLS rendition,not the logical master asset.
        let audioTracks = item.tracks.filter { $0.isEnabled && $0.assetTrack?.mediaType == .audio }
        XCTAssertFalse(audioTracks.isEmpty, "genuine native player must enable an audio rendition")
        let formats = audioTracks.compactMap(\.assetTrack).flatMap(\.formatDescriptions)
        let stereo = formats.contains {
            CMAudioFormatDescriptionGetStreamBasicDescription($0 as! CMAudioFormatDescription)?.pointee.mChannelsPerFrame == 2
        }
        XCTAssertTrue(stereo, "actual native audio format must retain the owned stereo fixture")
        print("OWNED NATIVE AUDIO: enabled tracks \(audioTracks.count); stereo \(stereo)")
        let clock = native.currentTime().seconds
        var frames: Set<UInt64> = []
        for _ in 0..<40 {
            if let buffer = media.copyPixelBuffer(forItemTime: native.currentTime(), itemTimeForDisplay: nil) { frames.insert(fingerprint(buffer)) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let label = asynchronous ? "OWNED ASYNC IMPORT RESULT" :
            delegated ? "OWNED DELEGATED IMPORT RESULT" : "OWNED NATIVE IMPORT RESULT"
        print("\(label): advance \(native.currentTime().seconds-clock)s; distinct frames \(frames.count); genuine AVPlayer,no prototype UI")
        XCTAssertGreaterThan(native.currentTime().seconds-clock, 7); XCTAssertGreaterThan(frames.count, 30)
        XCTAssertGreaterThan(CKNativeItems.session(item)?.stats["audio_packets"] ?? 0, 0)
        XCTAssertTrue(rendering.player === native); XCTAssertNil(CKRuntime.presentedController)
    }

    @MainActor
    func testActualLivePlayerAdvancesClockAndRenderedMovingFrames() async throws {
        try await exerciseLivePlayer(session: "engineprogress")
    }

    @MainActor
    func testActualRecoveredManifestStartsMovingVideoAndStereoEngine() async throws {
        try await exerciseLivePlayer(session: "transportengine")
        let url = URL(string: "http://127.0.0.1:18761/transport/transportengine/stats")!
        let (data, _) = try await CKHTTP.read(URLRequest(url: url), role: .license, limit: 4096)
        let stats = try XCTUnwrap(try CKJSON.object(data) as? [String:Int])
        XCTAssertEqual(stats["failures"], 2)
        XCTAssertGreaterThanOrEqual(stats["attempts"] ?? 0, 3)
    }

    @MainActor
    func testActualMidPlayFragmentDisconnectRecoversSameVideoAndStereo() async throws {
        let session = "segmentengine"
        let window = try XCTUnwrap(UIApplication.shared.windows.first), previous = window.rootViewController
        let controller = CKPlaybackController(channel: try ownedChannel(session: session))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible(); controller.loadViewIfNeeded()
        defer { controller.close(); window.rootViewController = previous }
        try await waitFor { controller.metrics.playableSeconds != nil }
        let old = try XCTUnwrap(controller.layer)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18761/fault/\(session)/arm")!)
        request.httpMethod = "POST"
        _ = try await CKHTTP.read(request, role: .license, limit: 1024)
        let player = try XCTUnwrap(old.player as? KSMEPlayer), clock = player.currentPlaybackTime
        var frames: Set<UInt64> = []
        for _ in 0..<60 {
            if let buffer = player.videoOutput?.pixelBuffer?.cvPixelBuffer { frames.insert(fingerprint(buffer)) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let stats = try await CKFragmentFixtures.stats(session)
        print("OWNED FRAGMENT RESULT: advance \(player.currentPlaybackTime-clock)s; distinct frames \(frames.count); stats \(stats)")
        XCTAssertTrue(controller.layer === old, "fragment transport recovery must not replay a license or replace the player")
        XCTAssertGreaterThan(player.currentPlaybackTime - clock, 10)
        XCTAssertGreaterThan(frames.count, 40)
        XCTAssertEqual(stats["fault_attempts"], 3); XCTAssertEqual(stats["fault_failures"], 2)
        XCTAssertEqual(stats["fault_successes"], 1)
        XCTAssertEqual(stats["fault_offset_changed"], 0); XCTAssertEqual(stats["fault_wrong_headers"], 0)
        XCTAssertEqual(stats["future_requests"] ?? 0, 0); XCTAssertEqual(stats["expired_requests"] ?? 0, 0)
        XCTAssertEqual(controller.keyRebuilds, 0); XCTAssertEqual(controller.keyAcquisitions, 0)
        XCTAssertEqual(controller.layer?.state, .bufferFinished)
        XCTAssertGreaterThan(player.dynamicInfo?.displayFPS ?? 0, 0)
    }

    @MainActor
    func testCloseDuringFragmentRecoveryCannotAttachOrKeepRequesting() async throws {
        try await cancelHeldFragment("segmentinitcancelalways", attempt: 1)
    }

    @MainActor
    func testCloseDuringHeldFragmentRetryNeverStartsThirdRequest() async throws {
        try await cancelHeldFragment("segmentinitretrycancelalways", attempt: 2)
    }

    @MainActor
    private func cancelHeldFragment(_ session: String, attempt: Double) async throws {
        let controller = CKPlaybackController(channel: try ownedChannel(session: session))
        controller.loadViewIfNeeded()
        defer { if !controller.finished { controller.close() } }
        var initial: [String: Double] = [:]
        let began = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - began < 4 {
            initial = try await CKFragmentFixtures.stats(session)
            if (initial["fault_attempts"] ?? 0) >= attempt { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Close immediately on the observed held request,without another
        // async stats fetch racing the250ms retry backoff.
        controller.close(); let status = controller.status.text
        let gateAge = Date().timeIntervalSince1970 - (try XCTUnwrap(initial["fault_gate_wall"]))
        XCTAssertEqual(initial["fault_attempts"], attempt)
        XCTAssertGreaterThanOrEqual(gateAge, 0)
        XCTAssertLessThan(gateAge, 4, "close must happen while the existing5s retry budget is live")
        var release = URLRequest(url: URL(string: "http://127.0.0.1:18761/fault/\(session)/release")!)
        release.httpMethod = "POST"
        _ = try await CKHTTP.read(release, role: .license, limit: 1024)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let final = try await CKFragmentFixtures.stats(session)
        print("OWNED HELD FRAGMENT CANCEL [\(session)]: close age \(gateAge)s; requests \(final["fault_attempts"] ?? 0)")
        XCTAssertEqual(final["fault_attempts"], attempt)
        XCTAssertNil(controller.layer); XCTAssertNil(controller.playerOptions)
        XCTAssertEqual(controller.status.text, status)
    }

    @MainActor
    func testActualMidBodyResumeKeepsSameMovingVideoAndStereoPlayer() async throws {
        let session = "bodyengine"
        let window = try XCTUnwrap(UIApplication.shared.windows.first), previous = window.rootViewController
        let controller = CKPlaybackController(channel: try ownedChannel(session: session))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible(); controller.loadViewIfNeeded()
        defer { controller.close(); window.rootViewController = previous }
        try await waitFor { controller.metrics.playableSeconds != nil }
        let old = try XCTUnwrap(controller.layer)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18761/fault/\(session)/arm")!)
        request.httpMethod = "POST"
        _ = try await CKHTTP.read(request, role: .license, limit: 1024)
        let player = try XCTUnwrap(old.player as? KSMEPlayer), clock = player.currentPlaybackTime
        var frames: Set<UInt64> = []
        for _ in 0..<60 {
            if let buffer = player.videoOutput?.pixelBuffer?.cvPixelBuffer { frames.insert(fingerprint(buffer)) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let stats = try await CKFragmentFixtures.stats(session)
        print("OWNED BODY RESULT: advance \(player.currentPlaybackTime-clock)s; distinct frames \(frames.count); stats \(stats)")
        XCTAssertTrue(controller.layer === old)
        XCTAssertGreaterThan(player.currentPlaybackTime - clock, 10); XCTAssertGreaterThan(frames.count, 40)
        XCTAssertEqual(stats["body_attempts"], 3); XCTAssertEqual(stats["body_cuts"], 2)
        XCTAssertEqual(stats["body_successes"], 1); XCTAssertEqual(stats["body_positive_offsets"], 2)
        XCTAssertEqual(stats["body_wrong_offset"], 0); XCTAssertEqual(stats["body_wrong_validator"], 0)
        XCTAssertEqual(stats["body_wrong_headers"], 0); XCTAssertEqual(stats["body_initial_range"], 0)
        XCTAssertEqual(stats["body_delivered"], stats["body_total"])
        XCTAssertEqual(stats["future_requests"] ?? 0, 0); XCTAssertEqual(stats["expired_requests"] ?? 0, 0)
        XCTAssertEqual(controller.keyRebuilds, 0); XCTAssertEqual(controller.keyAcquisitions, 0)
        XCTAssertEqual(controller.layer?.state, .bufferFinished)
        XCTAssertGreaterThan(player.dynamicInfo?.displayFPS ?? 0, 0)
    }

    @MainActor
    func testMidBodyChangedEntityStopsInsteadOfSkippingForever() async throws {
        let session = "bodyenginechanged"
        let window = try XCTUnwrap(UIApplication.shared.windows.first), previous = window.rootViewController
        let controller = CKPlaybackController(channel: try ownedChannel(session: session))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible(); controller.loadViewIfNeeded()
        defer { controller.close(); window.rootViewController = previous }
        try await waitFor { controller.metrics.playableSeconds != nil }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18761/fault/\(session)/arm")!)
        request.httpMethod = "POST"
        _ = try await CKHTTP.read(request, role: .license, limit: 1024)
        try await waitFor { controller.layer == nil }
        let stats = try await CKFragmentFixtures.stats(session)
        XCTAssertEqual(stats["body_attempts"], 2); XCTAssertEqual(stats["body_successes"], 0)
        XCTAssertNil(controller.playerOptions)
        XCTAssertFalse(controller.status.text?.contains("buffering.") ?? true)
    }

    @MainActor
    func testCloseDuringMidBodyRecoveryCancelsWithoutLaterAttachment() async throws {
        let session = "bodyenginecancelslow"
        let window = try XCTUnwrap(UIApplication.shared.windows.first), previous = window.rootViewController
        let controller = CKPlaybackController(channel: try ownedChannel(session: session))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible(); controller.loadViewIfNeeded()
        defer { controller.close(); window.rootViewController = previous }
        try await waitFor { controller.metrics.playableSeconds != nil }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18761/fault/\(session)/arm")!)
        request.httpMethod = "POST"
        _ = try await CKHTTP.read(request, role: .license, limit: 1024)
        for _ in 0..<300 {
            if try await CKFragmentFixtures.stats(session)["body_attempts"] == 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let initial = try await CKFragmentFixtures.stats(session)
        XCTAssertEqual(initial["body_attempts"], 2)
        controller.close(); let status = controller.status.text
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let final = try await CKFragmentFixtures.stats(session)
        XCTAssertEqual(final["body_attempts"], 2)
        XCTAssertNil(controller.layer); XCTAssertNil(controller.playerOptions)
        XCTAssertEqual(controller.status.text, status)
    }

    @MainActor
    func testUnrecoverableMidPlayAuthAndTransportStopWithoutEndlessSkipping() async throws {
        for (session, expected) in [("segmentdeny", 1), ("segmentexhaustalways", 3)] {
            let window = try XCTUnwrap(UIApplication.shared.windows.first), previous = window.rootViewController
            let controller = CKPlaybackController(channel: try ownedChannel(session: session))
            window.rootViewController = UINavigationController(rootViewController: controller)
            window.makeKeyAndVisible(); controller.loadViewIfNeeded()
            defer { controller.close(); window.rootViewController = previous }
            try await waitFor { controller.metrics.playableSeconds != nil }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18761/fault/\(session)/arm")!)
            request.httpMethod = "POST"
            _ = try await CKHTTP.read(request, role: .license, limit: 1024)
            try await waitFor { controller.layer == nil }
            let stats = try await CKFragmentFixtures.stats(session)
            XCTAssertEqual(stats["fault_attempts"], Double(expected))
            XCTAssertEqual(stats["fault_offset_changed"], 0); XCTAssertEqual(stats["fault_wrong_headers"], 0)
            XCTAssertNil(controller.playerOptions)
            XCTAssertFalse(controller.status.text?.contains("buffering.") ?? true)
        }
    }

    final class InflatedProbeOptions: CKLiveOptions {
        override func process(assetTrack: some MediaPlayerTrack) {
            if assetTrack.mediaType == .video { assetTrack.nominalFrameRate = 600 }
            super.process(assetTrack: assetTrack)
        }
    }

    final class LegacyInflatedProbeOptions: CKLiveOptions {
        override func process(assetTrack: some MediaPlayerTrack) {
            super.process(assetTrack: assetTrack)
            if assetTrack.mediaType == .video { assetTrack.nominalFrameRate = 600 }
        }
    }

    @MainActor
    func testActualLiveEngineCorrectsInflatedProbeAndKeepsMoving() async throws {
        try await exerciseLivePlayer(session: "inflatedprobe", options: { InflatedProbeOptions(declaredFrameRate: $0.frameRate) })
    }

    @MainActor
    func testActualModernLicensePOSTFeedsMovingVideoAndStereoEngine() async throws {
        try await exerciseLivePlayer(session: "licensedengine", licensed: true)
    }

    @MainActor
    func testActualPreloadedKeyChangeRebuildsAndKeepsMoving() async throws {
        try await exerciseRotation(session: "rotationpreloadedengine", preloaded: true)
    }

    @MainActor
    func testActualNewLicenseKeyRebuildsAndKeepsMoving() async throws {
        try await exerciseRotation(session: "rotationlicensedengine", preloaded: false)
    }

    @MainActor
    func testOriginalAVPlayerPreloadedKeyChangeKeepsItemAndMovingFrames() async throws {
        try await exerciseOriginalRotation(session: "rotationnativepreloaded", preloaded: true)
    }

    @MainActor
    func testOriginalAVPlayerLicensedKeyChangeKeepsItemAndMovingFrames() async throws {
        try await exerciseOriginalRotation(session: "rotationnativelicensed", preloaded: false)
    }

    @MainActor
    private func exerciseOriginalRotation(session: String, preloaded: Bool) async throws {
        let context = try CKNativeItems.prepare(CKRotationFixtures.channel(session, preloaded: preloaded))
        let asset = AVURLAsset(url: context.url); context.attach(asset)
        let item = AVPlayerItem(asset: asset), native = AVPlayer(playerItem: item)
        let media = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(media)
        defer { native.pause(); native.replaceCurrentItem(with: nil); context.session.stop() }
        native.play()
        try await waitFor { item.status == .readyToPlay && native.timeControlStatus == .playing }
        if item.status != .readyToPlay || native.timeControlStatus != .playing {
            originalDiagnostics(item, label: session)
            return
        }
        try await CKRotationFixtures.advance(session)
        try await waitFor { context.session.stats["key_changes"] == 1 }
        let clock = native.currentTime().seconds
        var frames: Set<UInt64> = []
        for _ in 0..<60 {
            if let buffer = media.copyPixelBuffer(forItemTime: native.currentTime(), itemTimeForDisplay: nil) { frames.insert(fingerprint(buffer)) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let stats = try await CKRotationFixtures.stats(session)
        print("OWNED ORIGINAL ROTATION RESULT [\(session)]: advance \(native.currentTime().seconds-clock)s; distinct frames \(frames.count); changes \(context.session.stats["key_changes"] ?? -1); acquisitions \(context.session.stats["new_acquisitions"] ?? -1); replayed packets dropped \(context.session.stats["replayed_video_packets_dropped"] ?? -1)")
        XCTAssertTrue(native.currentItem === item); XCTAssertTrue(item.asset === asset)
        XCTAssertGreaterThan(native.currentTime().seconds-clock, 10); XCTAssertGreaterThan(frames.count, 40)
        XCTAssertGreaterThan(stats["rotated_requests"] ?? 0, 0)
        XCTAssertEqual(context.session.stats["key_changes"], 1)
        XCTAssertEqual(context.session.stats["new_acquisitions"], preloaded ? 0 : 1)
        XCTAssertGreaterThan(context.session.stats["replayed_video_packets_dropped"] ?? 0, 0,
                             "same-epoch key update must not append historical frames again")
        XCTAssertEqual(stats["new_key_requests"] ?? 0, preloaded ? 0 : 1)
        XCTAssertNil(CKRuntime.presentedController)
    }

    @MainActor
    private func waitFor(_ predicate: () -> Bool, seconds: TimeInterval = 22) async throws {
        let began = ProcessInfo.processInfo.systemUptime
        while !predicate(), ProcessInfo.processInfo.systemUptime - began < seconds {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(predicate(), "owned engine condition must complete within the bounded deadline")
    }

    @MainActor
    private func exerciseRotation(session: String, preloaded: Bool) async throws {
        let window = try XCTUnwrap(UIApplication.shared.windows.first), previous = window.rootViewController
        let controller = CKPlaybackController(channel: try CKRotationFixtures.channel(session, preloaded: preloaded))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible(); controller.loadViewIfNeeded()
        defer { controller.close(); window.rootViewController = previous }
        try await waitFor { controller.metrics.playableSeconds != nil }
        let old = try XCTUnwrap(controller.layer)
        try await CKRotationFixtures.advance(session)
        try await waitFor { controller.keyRebuilds == 1 && controller.layer?.state == .bufferFinished }
        let next = try XCTUnwrap(controller.layer)
        XCTAssertFalse(next === old, "same-URL set must not masquerade as a decoder rebuild")
        XCTAssertNil(old.delegate)
        XCTAssertEqual(controller.keyAcquisitions, preloaded ? 0 : 1)
        let player = try XCTUnwrap(next.player as? KSMEPlayer), clock = player.currentPlaybackTime
        var frames: Set<UInt64> = []
        for _ in 0..<40 {
            if let buffer = player.videoOutput?.pixelBuffer?.cvPixelBuffer { frames.insert(fingerprint(buffer)) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let stats = try await CKRotationFixtures.stats(session)
        print("OWNED ROTATION RESULT [\(session)]: advance \(player.currentPlaybackTime-clock)s; distinct frames \(frames.count); rebuilds \(controller.keyRebuilds); new acquisitions \(controller.keyAcquisitions); stats \(stats)")
        XCTAssertGreaterThan(player.currentPlaybackTime - clock, 7, "audio-driven clock must keep progressing after key change")
        XCTAssertGreaterThan(frames.count, 30, "new encrypted fragments must render moving frames after rebuild")
        XCTAssertGreaterThan(stats["rotated_requests"] ?? 0, 0)
        XCTAssertEqual(stats["license_requests"] ?? 0, preloaded ? 0 : 2)
        XCTAssertEqual(stats["new_key_requests"] ?? 0, preloaded ? 0 : 1)
        XCTAssertEqual(controller.keyRebuilds, 1, "unchanged IDs must not rebuild every manifest refresh")
        XCTAssertEqual(stats["future_requests"] ?? 0, 0); XCTAssertEqual(stats["expired_requests"] ?? 0, 0)
    }

    @MainActor
    func testPauseDuringNewLicenseDefersRebuildUntilUserResumes() async throws {
        try await exercisePausedRenewal(session: "rotationpauseslow", remote: false)
    }

    @MainActor
    func testSDKLayerResumeConsumesDeferredLicenseWithoutGhostPlay() async throws {
        try await exercisePausedRenewal(session: "rotationremoteslow", remote: true)
    }

    @MainActor
    private func exercisePausedRenewal(session: String, remote: Bool) async throws {
        let window = try XCTUnwrap(UIApplication.shared.windows.first), previous = window.rootViewController
        let controller = CKPlaybackController(channel: try CKRotationFixtures.channel(session))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible(); controller.loadViewIfNeeded()
        defer { controller.close(); window.rootViewController = previous }
        try await waitFor { controller.metrics.playableSeconds != nil }
        let old = try XCTUnwrap(controller.layer)
        try await CKRotationFixtures.advance(session)
        for _ in 0..<30 {
            if try await CKRotationFixtures.stats(session)["new_key_requests"] == 1 { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let stats = try await CKRotationFixtures.stats(session)
        XCTAssertEqual(stats["new_key_requests"], 1)
        controller.pause()
        try await Task.sleep(nanoseconds: 6_500_000_000)
        XCTAssertTrue(controller.layer === old); XCTAssertEqual(controller.keyRebuilds, 0)
        XCTAssertEqual(controller.layer?.state, .paused)
        if remote { controller.layer?.play() } else { controller.play() }
        try await waitFor { controller.keyRebuilds == 1 && controller.layer?.state == .bufferFinished }
        XCTAssertFalse(controller.layer === old)
    }

    @MainActor
    func testCloseDuringNewLicenseCannotReattachOrChangeStatus() async throws {
        let session = "rotationcloseslow"
        let window = try XCTUnwrap(UIApplication.shared.windows.first), previous = window.rootViewController
        let controller = CKPlaybackController(channel: try CKRotationFixtures.channel(session))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible(); controller.loadViewIfNeeded()
        defer { window.rootViewController = previous }
        try await waitFor { controller.metrics.playableSeconds != nil }
        try await CKRotationFixtures.advance(session)
        for _ in 0..<30 {
            if try await CKRotationFixtures.stats(session)["new_key_requests"] == 1 { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let stats = try await CKRotationFixtures.stats(session)
        XCTAssertEqual(stats["new_key_requests"], 1)
        controller.close(); let status = controller.status.text
        try await Task.sleep(nanoseconds: 6_500_000_000)
        XCTAssertNil(controller.layer); XCTAssertNil(controller.playerOptions)
        XCTAssertEqual(controller.keyRebuilds, 0); XCTAssertEqual(controller.status.text, status)
    }

    @MainActor
    func testActualLegacyInflatedProbeCannotStartDespiteBufferedPackets() async throws {
        let channel = try ownedChannel(session: "legacyinflated")
        let window = try XCTUnwrap(UIApplication.shared.windows.first)
        let previous = window.rootViewController
        let controller = CKPlaybackController(channel: channel)
        controller.makeLiveOptions = { _ in LegacyInflatedProbeOptions() }
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible(); controller.loadViewIfNeeded()
        defer { controller.close(); window.rootViewController = previous }
        let began = ProcessInfo.processInfo.systemUptime
        var snapshot = ""
        // Cold Simulator network/audio setup is not the buffer-starvation
        // assertion. Keep its wait below the unchanged30s engine watchdog.
        while ProcessInfo.processInfo.systemUptime - began < 24 {
            snapshot = (controller.playerOptions as? CKLiveOptions)?.capacitySnapshot ?? ""
            if let packets = snapshot.split(separator: " ").first(where: { $0.hasPrefix("p") }),
               let count = Int(packets.dropFirst()), count > 100,
               let frames = snapshot.split(separator: " ").first(where: { $0.hasPrefix("f") && $0.contains("/") }),
               let decoded = Int(frames.dropFirst().split(separator: "/")[0]), decoded >= 2,
               snapshot.contains("fps600") { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        print("OWNED INFLATED LEGACY BLOCKED: \(snapshot); \(controller.metrics.summary)")
        XCTAssertTrue(snapshot.contains("fps600"), "actual legacy engine must exercise the600fps queue")
        let packets = snapshot.split(separator: " ").first(where: { $0.hasPrefix("p") }).flatMap { Int($0.dropFirst()) } ?? 0
        XCTAssertGreaterThan(packets, 100, "legacy stall must have real compressed video data,not a network failure")
        let frames = snapshot.split(separator: " ").first(where: { $0.hasPrefix("f") && $0.contains("/") })
            .flatMap { Int($0.dropFirst().split(separator: "/")[0]) } ?? 0
        XCTAssertGreaterThanOrEqual(frames, 2, "negative control must also have decoded video,not just unread packets")
        XCTAssertNil(controller.metrics.playableSeconds, "inflated FPS must reproduce the startup gate failure")
    }

    private func ownedChannel(session: String, licensed: Bool = false) throws -> CKChannel {
        let url = "http://127.0.0.1:18761/live/\(session)/manifest.mpd"
        if licensed { return try CKLicenseFixtures.channel(manifest: url) }
        let tags = """
        #EXTM3U
        #EXTINF:-1,Owned live moving video and stereo
        #KODIPROP:inputstream.adaptive.license_type=clearkey
        #KODIPROP:inputstream.adaptive.license_key=000102030405060708090a0b0c0d0e0f:101112131415161718191a1b1c1d1e1f,202122232425262728292a2b2c2d2e2f:303132333435363738393a3b3c3d3e3f
        \((session.hasPrefix("segment") || session.hasPrefix("body")) ? "#KODIPROP:inputstream.adaptive.stream_headers=X-Stream=owned-stream" : "")
        \(url)
        """
        return try XCTUnwrap(CKPlaylist.parse(Data(tags.utf8), relativeTo: nil).first)
    }

    @MainActor
    private func exerciseLivePlayer(session: String, options: ((CKDASHSelection) -> CKLiveOptions)? = nil, licensed: Bool = false) async throws {
        let channel = try ownedChannel(session: session, licensed: licensed)
        let window = try XCTUnwrap(UIApplication.shared.windows.first)
        let previous = window.rootViewController
        let controller = CKPlaybackController(channel: channel)
        if let options { controller.makeLiveOptions = options }
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible(); controller.loadViewIfNeeded()
        defer { controller.close(); window.rootViewController = previous }
        let start = ProcessInfo.processInfo.systemUptime
        var nextReport = start
        while controller.metrics.playableSeconds == nil && ProcessInfo.processInfo.systemUptime - start < 22 {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextReport {
                print("OWNED LIVE PROGRESS: \(controller.status.text ?? "") / \((controller.playerOptions as? CKLiveOptions)?.capacitySnapshot ?? "")")
                nextReport = now + 2
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertNotNil(controller.metrics.playableSeconds, "actual live engine must become playable,not freeze a primed first frame")
        guard let player = controller.layer?.player as? KSMEPlayer, controller.metrics.playableSeconds != nil else { return }
        let clock = player.currentPlaybackTime
        var fingerprints: Set<UInt64> = []
        for _ in 0..<40 {
            if let buffer = player.videoOutput?.pixelBuffer?.cvPixelBuffer { fingerprints.insert(fingerprint(buffer)) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        print("OWNED LIVE RESULT [\(session)]: advance \(player.currentPlaybackTime-clock)s; distinct frames \(fingerprints.count); \(controller.metrics.summary)")
        XCTAssertGreaterThan(player.currentPlaybackTime - clock, 7, "media must progress steadily across the8second observation")
        XCTAssertGreaterThan(fingerprints.count, 30, "moving frames must keep changing,not freeze across segments")
        XCTAssertGreaterThan(player.dynamicInfo?.displayFPS ?? 0, 0)
        if options != nil {
            let snapshot = try XCTUnwrap((controller.playerOptions as? CKLiveOptions)?.capacitySnapshot)
            XCTAssertTrue(snapshot.contains("Rate 600.00 -> 25.00 (MPD)"), "the actual decode pipeline must correct the injected probe before creating queues")
            XCTAssertTrue(snapshot.contains("fps25")); XCTAssertFalse(snapshot.contains("fps600"))
        }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18761/live/\(session)/stats")!)
        let ages = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Double])
        print("OWNED LIVE INITIAL AGES: \(ages)")
        XCTAssertLessThan(try XCTUnwrap(ages["video"]), 10, "selected video must start near live,not at the expiring DVR edge")
        XCTAssertLessThan(try XCTUnwrap(ages["audio"]), 10, "audio must start near the same live position")
        XCTAssertEqual(ages["future_requests"] ?? 0, 0, "player must wait instead of requesting unpublished segments")
        XCTAssertEqual(ages["expired_requests"] ?? 0, 0, "player must avoid expired DVR segments")
    }

    @MainActor
    func testLegacySixtySecondStartFallsAtOldEdgeOfThirtySecondWindow() async throws {
        var context: UnsafeMutablePointer<AVFormatContext>?, options: OpaquePointer?
        let keys = try CKKeySet(["000102030405060708090a0b0c0d0e0f":"101112131415161718191a1b1c1d1e1f",
                                 "202122232425262728292a2b2c2d2e2f":"303132333435363738393a3b3c3d3e3f"])
        keys.formatOptions.forEach { av_dict_set(&options, $0.key, $0.value, 0) }
        av_dict_set(&options, "ck_video_representation", "live-selected", 0)
        av_dict_set(&options, "ck_live_delay", "0", 0)
        av_dict_set(&options, "rw_timeout", "10000000", 0)
        let opened = avformat_open_input(&context, "http://127.0.0.1:18761/live/legacyedge/manifest.mpd", nil, &options)
        av_dict_free(&options)
        XCTAssertEqual(opened, 0)
        avformat_close_input(&context)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18761/live/legacyedge/stats")!)
        let ages = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Double])
        print("OWNED LEGACY INITIAL AGES: \(ages)")
        XCTAssertGreaterThan(try XCTUnwrap(ages["video"]), 20, "legacy60s behavior must demonstrate its old-edge selection")
    }

    private func fingerprint(_ buffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let pointer = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytes = pointer.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 1469598103934665603
        for y in Swift.stride(from: 0, to: height, by: max(1, height / 12)) {
            for x in Swift.stride(from: 0, to: width, by: max(1, width / 16)) {
                hash = (hash ^ UInt64(bytes[y * stride + x * (planar ? 1 : 4)])) &* 1099511628211
            }
        }
        return hash
    }

    // Only owned synthetic fixtures enter these tests and attachments.
    @MainActor
    private func originalDiagnostics(_ item: AVPlayerItem, label: String) {
        guard let session = CKNativeItems.session(item) else { return }
        print("OWNED ORIGINAL DIAGNOSTIC [\(label)]: status \(item.status.rawValue); error \((item.error as NSError?)?.code ?? 0); stats \(session.stats)")
        for event in item.errorLog()?.events ?? [] {
            print("OWNED ORIGINAL ERROR: \(event.errorDomain)/\(event.errorStatusCode) \(event.errorComment ?? "")")
        }
        let store = session.store
        let playlist = store.response(path: "/\(store.token)/media.m3u8", wait: 0)
        print("OWNED ORIGINAL PLAYLIST: \(playlist.0) \(String(decoding: playlist.2, as: UTF8.self))")
        var data = store.response(path: "/\(store.token)/init0.mp4", wait: 0).2
        for index in 0..<3 { data.append(store.response(path: "/\(store.token)/segment\(index).m4s", wait: 0).2) }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.mpeg-4")
        attachment.name = "owned-original-\(label).mp4"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
