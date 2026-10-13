import AVFoundation
import Foundation
import KSPlayer

struct CKDASHSelection {
    let id: String
    let renditionCount: Int
    let bandwidth: Int64
    let height: Int

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
                               bandwidth: best.bandwidth, height: best.height)
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
                                               height: Int(values["height"] ?? "") ?? 0))
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

final class CKLiveOptions: KSOptions {
    private let startup = KSOptions()
    private let snapshotLock = NSLock()
    private var snapshot = ""
    var capacitySnapshot: String {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return snapshot
    }
    override init() {
        super.init()
        startup.preferredForwardBufferDuration = 1.5; startup.isSecondOpen = false
        preferredForwardBufferDuration = 4; maxBufferDuration = 20
        isSecondOpen = false; videoAdaptable = false
    }
    override func playable(capacitys: [CapacityProtocol], isFirst: Bool, isSeek: Bool) -> LoadingState {
        let summary = capacitys.prefix(2).map {
            let kind = $0.mediaType == .video ? "V" : "A"
            return "\(kind) f\($0.frameCount)/\($0.frameMaxCount) p\($0.packetCount) fps\(Int($0.fps.isFinite ? $0.fps : 0))"
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
