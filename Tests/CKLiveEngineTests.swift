import AVFoundation
import CoreVideo
import KSPlayer
import UIKit
import XCTest
@testable import CKBridge

final class CKLiveEngineTests: XCTestCase {
    @MainActor
    func testActualLivePlayerAdvancesClockAndRenderedMovingFrames() async throws {
        let url = "http://127.0.0.1:18761/live/engineprogress/manifest.mpd"
        let tags = """
        #EXTM3U
        #EXTINF:-1,Owned live moving video and stereo
        #KODIPROP:inputstream.adaptive.license_type=clearkey
        #KODIPROP:inputstream.adaptive.license_key=000102030405060708090a0b0c0d0e0f:101112131415161718191a1b1c1d1e1f,202122232425262728292a2b2c2d2e2f:303132333435363738393a3b3c3d3e3f
        \(url)
        """
        let channel = try XCTUnwrap(CKPlaylist.parse(Data(tags.utf8), relativeTo: nil).first)
        let window = try XCTUnwrap(UIApplication.shared.windows.first)
        let previous = window.rootViewController
        let controller = CKPlaybackController(channel: channel)
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
            if let buffer = player.videoOutput?.pixelBuffer { fingerprints.insert(fingerprint(buffer)) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        print("OWNED LIVE RESULT: advance \(player.currentPlaybackTime-clock)s; distinct frames \(fingerprints.count); \(controller.metrics.summary)")
        XCTAssertGreaterThan(player.currentPlaybackTime - clock, 4, "audio-driven media clock must advance")
        XCTAssertGreaterThan(fingerprints.count, 3, "decoded/displayed moving frames must change across segments")
        XCTAssertGreaterThan(player.dynamicInfo?.displayFPS ?? 0, 0)
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
                hash = (hash ^ UInt64(bytes[y * stride + x])) &* 1099511628211
            }
        }
        return hash
    }
}
