import Foundation

// This opt-in transport writes only owned diagnostic tokens,not app/source data.
enum CKM3UProbeEvidenceEvent: String, Codable { case started, sample, stopped }

struct CKM3UProbeEvidenceRecord: Codable {
    let event: CKM3UProbeEvidenceEvent
    let ticks: Int
    let foregroundSeconds: Double
    let branch: String?
    let nodes: Int?
    let limited: Bool?
    let tags: [String]
    let fields: [String]
    let limits: [String]

    init(event: CKM3UProbeEvidenceEvent, ticks: Int, seconds: Double, snapshot: CKM3UProbeSnapshot?) {
        self.event = event
        self.ticks = max(0, min(ticks, 300))
        foregroundSeconds = seconds.isFinite ? max(0, min(seconds, 240)) : 0
        let allowedTags = Set(CKM3UProbePolicy.names.values).union(CKM3UProbePolicy.cases.values)
        let tags = (snapshot?.tags ?? []).intersection(allowedTags)
        self.tags = tags.sorted()
        fields = (snapshot?.fields ?? []).intersection(CKM3UProbePolicy.fields).sorted()
        limits = (snapshot?.limits ?? []).intersection(CKM3UProbeReflection.limitNames).sorted()
        branch = snapshot.map { _ in CKM3UProbePolicy.branch(tags) }
        nodes = snapshot.map { max(0, min($0.visited, 256)) }
        limited = snapshot?.truncated
    }
}

struct CKM3UProbeEvidenceReport: Codable {
    let schema = 2
    let observationOnly = true
    var build = max(0, min(Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0, 999999999))
    var state = CKM3UProbeEvidenceEvent.started
    var ticks = 0
    var missingControllerTicks = 0
    var records: [CKM3UProbeEvidenceRecord] = []
}

final class CKM3UProbeEvidence {
    static let fileName = "CKM3URouteProbe-v2.json"
    static let maximumBytes = 65536
    static var defaultURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName, isDirectory: false)
    }
    private let url: URL
    private let queue = DispatchQueue(label: "me.bocphot.CKBridge.m3u-probe-evidence", qos: .utility)
    private var report = CKM3UProbeEvidenceReport()
    private var began = false, ended = false, samples = 0

    init(url: URL) { self.url = url }

    func update(_ event: CKM3UProbeEvidenceEvent?, ticks: Int, seconds: Double,
                missingControllerTicks: Int = 0, snapshot: CKM3UProbeSnapshot? = nil) {
        // Sanitize before enqueueing;the queue never owns a reflected app object.
        let record = event.map { CKM3UProbeEvidenceRecord(event: $0, ticks: ticks, seconds: seconds, snapshot: snapshot) }
        let safeTicks = max(0, min(ticks, 300))
        let safeMissing = max(0, min(missingControllerTicks, 300))
        queue.async { [self] in
            guard !ended else { return }
            if let record = record {
                switch record.event {
                case .started:
                    guard !began else { return }
                    began = true
                case .sample:
                    guard began, samples < 48 else { return }
                    samples += 1
                case .stopped:
                    guard began else { return }
                    ended = true
                }
                report.state = record.event
                report.records.append(record)
            } else if !began { return }
            report.ticks = safeTicks
            report.missingControllerTicks = safeMissing
            guard let data = try? JSONEncoder().encode(report), data.count <= Self.maximumBytes else { return }
            // Dedicated file reset each launch;failure cannot affect navigation/playback.
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    func drainForTesting() { queue.sync {} }
}
