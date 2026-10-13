import AVFoundation
import Foundation
import KSPlayer

struct CKDASHSelection {
    let id: String
    let renditionCount: Int
    let bandwidth: Int64
    let height: Int
    let frameRate: Float?

    static func plan(_ data: Data) -> CKDASHSelection? {
        guard data.count <= 2 * 1024 * 1024 else { return nil }
        let reader = Reader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.live, reader.periods == 1,
              reader.groups.count == 1, let videos = reader.groups.first,
              videos.count > 1, videos.count <= 32,
              Set(videos.map(\.id)).count == videos.count,
              videos.allSatisfy({ safeID($0.id) && $0.bandwidth > 0 && $0.height > 0 }),
              let best = videos.max(by: { ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth) }) else { return nil }
        return CKDASHSelection(id: best.id, renditionCount: videos.count,
                               bandwidth: best.bandwidth, height: best.height, frameRate: best.frameRate)
    }

    static func parseFrameRate(_ value: String?) -> Float? {
        guard let value, value.utf8.count <= 32 else { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        }), let numerator = UInt32(parts[0]), numerator > 0 else { return nil }
        let denominator: UInt32
        if parts.count == 2 {
            guard let number = UInt32(parts[1]), number > 0 else { return nil }
            denominator = number
        } else { denominator = 1 }
        let rate = Float(numerator) / Float(denominator)
        return rate.isFinite && (1...120).contains(rate) ? rate : nil
    }

    static func safeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 61, 95].contains($0)
        }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var live = false, periods = 0
        var groups: [[CKDASHSelection]] = []
        var inherited: [String: String]?
        var current: [CKDASHSelection] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            switch name.split(separator: ":").last.map(String.init) {
            case "MPD": live = attributes["type"] == "dynamic"
            case "Period": periods += 1
            case "AdaptationSet": inherited = attributes; current = []
            case "Representation":
                guard let inherited else { return }
                let values = inherited.merging(attributes) { _, new in new }
                guard values["contentType"] == "video" || values["mimeType"]?.hasPrefix("video/") == true else { return }
                current.append(CKDASHSelection(id: attributes["id"] ?? "", renditionCount: 0,
                                               bandwidth: Int64(values["bandwidth"] ?? "") ?? 0,
                                               height: Int(values["height"] ?? "") ?? 0,
                                               frameRate: CKDASHSelection.parseFrameRate(values["frameRate"])))
                if current.count > 32 { parser.abortParsing() }
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name.split(separator: ":").last == "AdaptationSet" {
                if !current.isEmpty { groups.append(current) }
                inherited = nil; current = []
            }
        }
    }
}

class CKLiveOptions: KSOptions {
    private let startup = KSOptions()
    private let snapshotLock = NSLock()
    private var snapshot = ""
    private var rateSnapshot = ""
    let declaredFrameRate: Float?
    var capacitySnapshot: String {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return [snapshot, rateSnapshot].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    init(declaredFrameRate: Float? = nil) {
        self.declaredFrameRate = declaredFrameRate.flatMap { $0.isFinite && (1...120).contains($0) ? $0 : nil }
        super.init()
        startup.preferredForwardBufferDuration = 1.5; startup.isSecondOpen = false
        preferredForwardBufferDuration = 4; maxBufferDuration = 20
        isSecondOpen = false; videoAdaptable = false
        formatContextOptions["ck_live_delay"] = 6
    }
    func useLicensedStartupReserve() {
        // Manifest-first license opens favor a real3s reserve. Keep the accepted
        // legacy1.5s startup/refill policy unchanged for existing GET/inline sources.
        startup.preferredForwardBufferDuration = 3
    }
    override func process(assetTrack: some MediaPlayerTrack) {
        if assetTrack.mediaType == .video, let declaredFrameRate {
            let probed = assetTrack.nominalFrameRate
            // Bad live probe rates otherwise turn many seconds of packets into
            // less than the startup reserve. Correct before queues/decoders exist.
            if !probed.isFinite || probed <= 0 || probed > max(240, declaredFrameRate * 4) {
                assetTrack.nominalFrameRate = declaredFrameRate
                let original = probed.isFinite ? String(format: "%.2f", probed) : "invalid"
                snapshotLock.lock()
                rateSnapshot = String(format: "Rate %@ -> %.2f (MPD)", original, declaredFrameRate)
                snapshotLock.unlock()
                CKDiagnostic.trace(String(format: "video rate %@ -> %.2f from declared MPD", original, declaredFrameRate))
            }
        }
        // Preserve the upstream field-order/filter policy and its doubled output
        // rate for interlaced video rather than forcing every track to25fps.
        super.process(assetTrack: assetTrack)
    }
    override func playable(capacitys: [CapacityProtocol], isFirst: Bool, isSeek: Bool) -> LoadingState {
        let summary = capacitys.prefix(2).map {
            let kind = $0.mediaType == .video ? "V" : "A"
            let fps = Int(min(1000, max(0, $0.fps.isFinite ? $0.fps : 0)))
            return "\(kind) f\($0.frameCount)/\($0.frameMaxCount) p\($0.packetCount) fps\(fps)"
        }.joined(separator: " ")
        snapshotLock.lock(); snapshot = summary; snapshotLock.unlock()
        // First playback still needs decoded frames AND a real reserve.
        if isFirst { return startup.playable(capacitys: capacitys, isFirst: true, isSeek: isSeek) }
        return super.playable(capacitys: capacitys, isFirst: false, isSeek: isSeek)
    }
}

struct CKPlaybackMetrics {
    let began: TimeInterval
    var keySeconds: TimeInterval?
    var manifestSeconds: TimeInterval?
    var playableSeconds: TimeInterval?
    var rebufferCount = 0
    private var waiting = false
    private var manualResume = false
    init(now: TimeInterval) { began = now }
    mutating func resumedByUser() { manualResume = true }
    mutating func state(buffering: Bool, playable: Bool, now: TimeInterval) {
        if buffering, !waiting, playableSeconds != nil, !manualResume { rebufferCount += 1 }
        if buffering || playable { manualResume = false }
        waiting = buffering
        if playable, playableSeconds == nil { playableSeconds = max(0, now - began) }
    }
    var summary: String {
        func seconds(_ value: TimeInterval?) -> String {
            guard let value, value.isFinite, value >= 0 else { return "--" }
            return String(format: "%.1fs", value)
        }
        return "Key \(seconds(keySeconds)) / MPD \(seconds(manifestSeconds)) / Ready \(seconds(playableSeconds)) / Stalls \(rebufferCount)"
    }
    var compact: String {
        func time(_ value: TimeInterval?) -> String {
            guard let value, value.isFinite, value >= 0 else { return "--" }
            return String(format: "%.1f", value)
        }
        return "Key \(time(keySeconds)) / MPD \(time(manifestSeconds)) / Ready \(time(playableSeconds)) / Stalls \(rebufferCount)"
    }
}
