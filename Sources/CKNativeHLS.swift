import Foundation
import Network

enum CKNativeFailure: Error { case transport, unsupportedCodec, mux(Int32), closed, tooLarge }

final class CKNativeStore {
    struct Segment { let name: String; let data: Data; let seconds: Double; let initName: String; let discontinuity: Bool }
    let token = UUID().uuidString.lowercased()
    private let condition = NSCondition()
    private var initializations: [String: Data] = [:]
    private var segments: [Segment] = []
    private var sequence = 0, discardedDiscontinuities = 0, nextNumber = 0, requestedThrough = -1
    private var terminal = false, failed = false, cancelled = false
    private var targetDuration: Int?
    private var manifestRequests = 0, initRequests = 0, mediaRequests = 0
    private var bandwidth: Int64 = 4_000_000
    private var codecs: String?
    private(set) var videoPackets = 0, audioPackets = 0
    static let segmentLimit = 16 * 1024 * 1024
    static let memoryLimit = 64 * 1024 * 1024
    static let startupSegments = 6
    var count: Int { condition.lock(); defer { condition.unlock() }; return segments.count }
    var closed: Bool { condition.lock(); defer { condition.unlock() }; return cancelled }
    var stats: [String: Int] {
        condition.lock(); defer { condition.unlock() }
        return ["video_packets": videoPackets, "audio_packets": audioPackets, "segments": segments.count,
                "bytes": segments.reduce(0, { $0 + $1.data.count }), "initializations": initializations.count]
            .merging(["manifest_requests": manifestRequests, "init_requests": initRequests, "media_requests": mediaRequests]) { _, new in new }
    }
    func waitForDemand() {
        condition.lock(); defer { condition.unlock() }
        if !terminal && nextNumber - requestedThrough >= 7 { condition.wait(until: Date(timeIntervalSinceNow: 0.2)) }
    }
    var ahead: Int { condition.lock(); defer { condition.unlock() }; return nextNumber - requestedThrough }
    func describe(bandwidth: Int64, codecs: String?) {
        condition.lock(); defer { condition.unlock() }
        if bandwidth > 0, bandwidth <= 1_000_000_000 { self.bandwidth = bandwidth }
        if let codecs, codecs.utf8.count <= 128,
           codecs.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [44, 45, 46].contains($0) }) {
            self.codecs = codecs
        }
    }
    func initialize(_ data: Data, generation: Int) throws -> String {
        guard !data.isEmpty, data.count <= 1024 * 1024 else { throw CKNativeFailure.tooLarge }
        condition.lock(); defer { condition.unlock() }
        guard !terminal else { throw CKNativeFailure.closed }
        let name = "init\(generation).mp4"; initializations[name] = data; return name
    }
    func append(_ data: Data, seconds: Double, initName: String, discontinuity: Bool) throws {
        guard !data.isEmpty, data.count <= Self.segmentLimit, seconds.isFinite, seconds > 0, seconds <= 12 else { throw CKNativeFailure.tooLarge }
        condition.lock(); defer { condition.unlock() }
        guard !terminal else { throw CKNativeFailure.closed }
        let target = targetDuration ?? max(1, Int(ceil(seconds)))
        guard seconds.rounded() <= Double(target) else { throw CKNativeFailure.transport }
        targetDuration = target
        let name = "segment\(nextNumber).m4s"; nextNumber += 1
        segments.append(Segment(name: name, data: data, seconds: seconds, initName: initName, discontinuity: discontinuity))
        while segments.count > 18 || segments.reduce(0, { $0 + $1.data.count }) > Self.memoryLimit {
            let removed = segments.removeFirst(); sequence += 1
            if removed.discontinuity { discardedDiscontinuities += 1 }
        }
        let needed = Set(segments.map(\.initName)).union([initName])
        initializations = initializations.filter { needed.contains($0.key) }
        condition.broadcast()
    }
    func packet(video: Bool) {
        condition.lock(); defer { condition.unlock() }
        if video { videoPackets += 1 } else { audioPackets += 1 }
    }
    func close(failure: Bool = false) {
        condition.lock(); defer { condition.unlock() }
        terminal = true; failed = failure; cancelled = !failure
        if !failure { segments.removeAll(); initializations.removeAll() }
        condition.broadcast()
    }
    func finish() { condition.lock(); terminal = true; condition.broadcast(); condition.unlock() }
    func response(path: String, wait: TimeInterval = 25, recordRequest: Bool = true) -> (Int, String, Data) {
        guard path.hasPrefix("/\(token)/"), !path.contains("%"), !path.contains("?"), !path.contains("..") else {
            return (404, "text/plain", Data())
        }
        let name = String(path.dropFirst(token.count + 2))
        condition.lock(); defer { condition.unlock() }
        if name == "index.m3u8" {
            if recordRequest { manifestRequests += 1 }
            guard !failed, !cancelled else { return (410, "text/plain", Data()) }
            // Classify as HLS immediately;media preparation may legitimately wait.
            // The single variant's startup bandwidth is an estimate,not an ABR ladder.
            let detail = codecs.map { ",CODECS=\"\($0)\"" } ?? ""
            let text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth)\(detail)\nmedia.m3u8\n"
            return (200, "application/vnd.apple.mpegurl", Data(text.utf8))
        }
        if name == "media.m3u8" {
            if recordRequest { manifestRequests += 1 }
            let deadline = Date(timeIntervalSinceNow: wait)
            while segments.count < Self.startupSegments && !terminal { if !condition.wait(until: deadline) { break } }
            guard terminal || segments.count >= Self.startupSegments else { return (503, "text/plain", Data()) }
            guard !failed, !segments.isEmpty else { return (terminal ? 410 : 503, "text/plain", Data()) }
            let target = targetDuration ?? 2
            var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(sequence)\n#EXT-X-DISCONTINUITY-SEQUENCE:\(discardedDiscontinuities)\n#EXT-X-INDEPENDENT-SEGMENTS\n"
            var previous: String?
            for segment in segments {
                if segment.discontinuity { text += "#EXT-X-DISCONTINUITY\n" }
                if previous != segment.initName { text += "#EXT-X-MAP:URI=\"\(segment.initName)\"\n"; previous = segment.initName }
                text += String(format: "#EXTINF:%.6f,\n%@\n", locale: Locale(identifier: "en_US_POSIX"), segment.seconds, segment.name)
            }
            if terminal { text += "#EXT-X-ENDLIST\n" }
            return (200, "application/vnd.apple.mpegurl", Data(text.utf8))
        }
        if let data = initializations[name] { initRequests += 1; return (200, "video/mp4", data) }
        if let segment = segments.first(where: { $0.name == name }) {
            mediaRequests += 1
            if let number = Int(name.dropFirst(7).dropLast(4)) { requestedThrough = max(requestedThrough, number); condition.broadcast() }
            return (200, "video/iso.segment", segment.data)
        }
        return (404, "text/plain", Data())
    }
}

final class CKNativeHTTP {
    let store: CKNativeStore
    private let listener: NWListener
    private let queue = DispatchQueue(label: "CKNativeHTTP")
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var endpoint: URL?
    private var playlistReplies = 0
    var url: URL { endpoint! }
    init(store: CKNativeStore) throws {
        self.store = store
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state { case .ready, .failed, .cancelled: ready.signal(); default: break }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, let port = listener.port else {
            listener.cancel(); throw CKNativeFailure.transport
        }
        endpoint = URL(string: "http://127.0.0.1:\(port.rawValue)/\(store.token)/index.m3u8")!
        listener.stateUpdateHandler = nil
    }
    func stop() {
        listener.cancel()
        lock.lock(); let active = Array(connections.values); connections.removeAll(); lock.unlock()
        active.forEach { $0.cancel() }
        store.close()
    }
    private func accept(_ connection: NWConnection) {
        lock.lock()
        guard connections.count < 12, !store.closed else { lock.unlock(); connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection; lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state, let self, let connection {
                self.lock.lock(); self.connections.removeValue(forKey: ObjectIdentifier(connection)); self.lock.unlock()
            }
        }
        connection.start(queue: queue)
        read(connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + 30) { [weak connection] in connection?.cancel() }
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] bytes, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var data = buffer; if let bytes { data.append(bytes) }
            guard data.count <= 16 * 1024 else { connection.cancel(); return }
            if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                DispatchQueue.global(qos: .userInitiated).async { self.respond(connection, request: data) }
            } else if complete { connection.cancel() }
            else { self.read(connection, buffer: data) }
        }
    }
    private func respond(_ connection: NWConnection, request: Data) {
        guard let text = String(data: request, encoding: .utf8) else { connection.cancel(); return }
        let lines = text.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
        guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])) else { connection.cancel(); return }
        let path = String(first[1])
        var (status, mime, body) = store.response(path: path, wait: 0)
        if status == 503, first[0] == "GET", path.hasSuffix("/media.m3u8") {
            warmPlaylist(connection, path: path)
            return
        }
        var extra = ""
        let ranges = lines.dropFirst().filter { $0.lowercased().hasPrefix("range:") }
        if status == 200, !String(first[1]).hasSuffix(".m3u8"), let range = ranges.first {
            let total = body.count
            let field = range.dropFirst(6).trimmingCharacters(in: .whitespaces)
            let pieces = field.hasPrefix("bytes=") ? field.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false) : []
            if ranges.count == 1, pieces.count == 2, total > 0 {
                let suffix = pieces[0].isEmpty ? Int(pieces[1]) : nil
                let start = suffix.map { $0 > 0 ? total - min(total, $0) : -1 } ?? Int(pieces[0]) ?? -1
                let end = pieces[1].isEmpty || suffix != nil ? total - 1 : Int(pieces[1]) ?? -1
                let last = min(total - 1, end)
                if start >= 0, start < total, last >= start, suffix == nil || suffix! > 0 {
                    extra = "Content-Range: bytes \(start)-\(last)/\(total)\r\n"
                    body = body.subdata(in: start..<(last + 1)); status = 206
                } else { status = 416; body = Data() }
            } else { status = 416; body = Data() }
            if status == 416 { extra = "Content-Range: bytes */\(total)\r\n" }
        }
        let phrase = [200: "OK", 206: "Partial Content", 404: "Not Found", 410: "Gone", 416: "Range Not Satisfiable", 503: "Service Unavailable"][status] ?? "Error"
        var data = Data("HTTP/1.1 \(status) \(phrase)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nAccept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n".utf8)
        if first[0] != "HEAD" { data.append(body) }
        if String(first[1]).hasSuffix(".m3u8") {
            lock.lock(); playlistReplies += 1; let report = playlistReplies <= 4; lock.unlock()
            if report { CKDiagnostic.trace("native playlist reply head=\(first[0] == "HEAD") range=\(!ranges.isEmpty) status=\(status) bytes=\(body.count)") }
        }
        // Send a TCP end-of-stream instead of resetting a just-written response.
        finish(connection, data: data)
    }
    private func finish(_ connection: NWConnection, data: Data) {
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            if error != nil { connection.cancel(); return }
            self?.queue.asyncAfter(deadline: .now() + 0.5) { connection.cancel() }
        })
    }
    private func warmPlaylist(_ connection: NWConnection, path: String) {
        let prefix = Data("#EXTM3U\n#EXT-X-VERSION:7\n".utf8)
        var header = Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        header.append(chunk(prefix))
        connection.send(content: header, completion: .contentProcessed { error in if error != nil { connection.cancel() } })
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while ProcessInfo.processInfo.systemUptime < deadline {
            if case .cancelled = connection.state { return }
            let (status, _, body) = store.response(path: path, wait: 0.8, recordRequest: false)
            if status == 200, body.starts(with: prefix) {
                var final = chunk(Data(body.dropFirst(prefix.count)))
                final.append(Data("0\r\n\r\n".utf8)); finish(connection, data: final)
                return
            }
            guard status == 503 else { connection.cancel(); return }
            // Legal HLS comments keep progress alive;never invent media segments.
            connection.send(content: chunk(Data("# preparing\n".utf8)), completion: .contentProcessed { error in
                if error != nil { connection.cancel() }
            })
        }
        connection.cancel()
    }
    private func chunk(_ body: Data) -> Data {
        var result = Data("\(String(body.count, radix: 16))\r\n".utf8)
        result.append(body); result.append(Data("\r\n".utf8)); return result
    }
    deinit { listener.cancel() }
}
