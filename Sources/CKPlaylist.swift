import Foundation

enum CKFailure: Error, Equatable {
    case invalidPlaylist, invalidKey, invalidMetadata, unsupportedMetadata, unsupportedDRM, multipleKeys, network, unsupportedLicense, unsupportedMultiKeyManifest
}

struct CKChannel {
    let url: URL
    let title: String
    let keySource: String
    let headers: [String: String]
    let licenseHeaders: [String: String]
    let metadataFailure: CKFailure?

    func keyRequest() throws -> URLRequest? {
        if let metadataFailure { throw metadataFailure }
        guard let url = URL(string: keySource), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        let headers = try CKHeaders.combining(self.headers, licenseHeaders)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return request
    }
}

enum CKPlaylist {
    struct Report {
        let channels: [CKChannel]
        let observedURLs: Set<String>
        let metadataIssues: Int
    }
    static func parse(_ data: Data, relativeTo base: URL?) -> [CKChannel] {
        report(data, relativeTo: base)?.channels ?? []
    }
    static func report(_ data: Data, relativeTo base: URL?) -> Report? {
        guard data.count <= 4 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))).hasPrefix("#EXTM3U") else { return nil }
        guard !text.components(separatedBy: .newlines).contains(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXT-X-")
        }) else { return nil }
        var channels: [CKChannel] = []
        var title = "ClearKey", properties: [String: String] = [:], headers: [String: String] = [:]
        var failure: CKFailure?, observed: Set<String> = [], issues = 0, seenInfo = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
            if line.hasPrefix("#EXTINF:") {
                if seenInfo { properties = [:]; headers = [:]; failure = nil; issues += 1 }
                seenInfo = true
                if let comma = line.firstIndex(of: ",") { title = String(line[line.index(after: comma)...]) }
            } else if line.hasPrefix("#KODIPROP:") {
                let fields = line.dropFirst(10).split(separator: "=", maxSplits: 1).map(String.init)
                guard fields.count == 2 else { continue }
                let name = fields[0].lowercased(), value = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if name == "inputstream.adaptive.stream_headers" {
                    do { try CKHeaders.merge(value, into: &headers) } catch { failure = .invalidMetadata }
                } else {
                    if let previous = properties[name], previous != value { failure = .invalidMetadata }
                    else { properties[name] = value }
                }
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let fields = line.dropFirst(11).split(separator: "=", maxSplits: 1).map(String.init)
                guard fields.count == 2 else { continue }
                let names = ["http-user-agent": "User-Agent", "http-referrer": "Referer",
                             "http-referer": "Referer", "http-origin": "Origin"]
                if let name = names[fields[0].lowercased()] {
                    do { try CKHeaders.set(name, value: fields[1], in: &headers) } catch { failure = .invalidMetadata }
                }
            } else if line.hasPrefix("#EXTHTTP:") {
                do {
                    guard let values = try CKJSON.object(Data(line.dropFirst(9).utf8)) as? [String: String] else { throw CKFailure.invalidMetadata }
                    var names: Set<String> = []
                    for (name, value) in values {
                        guard names.insert(name.lowercased()).inserted else { throw CKFailure.invalidMetadata }
                        try CKHeaders.set(name, value: value, in: &headers)
                    }
                } catch { failure = .invalidMetadata }
            } else if !line.isEmpty && !line.hasPrefix("#") {
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    do { try CKHeaders.merge(parts[1], into: &headers) } catch { failure = .invalidMetadata }
                }
                if let url = URL(string: parts[0], relativeTo: base)?.absoluteURL,
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    observed.insert(url.absoluteString)
                    do {
                        if let failure { throw failure }
                        if let spec = try CKDRMMetadata.resolve(properties) {
                            channels.append(CKChannel(url: url, title: title, keySource: spec.source, headers: headers,
                                                      licenseHeaders: spec.headers, metadataFailure: nil))
                        }
                    } catch {
                        issues += 1
                        if CKDRMMetadata.recognizesClear(properties) {
                            channels.append(CKChannel(url: url, title: title, keySource: "", headers: headers,
                                                      licenseHeaders: [:], metadataFailure: (error as? CKFailure) ?? .invalidMetadata))
                        }
                    }
                }
                title = "ClearKey"; properties = [:]; headers = [:]; failure = nil; seenInfo = false
            }
        }
        return Report(channels: channels, observedURLs: observed, metadataIssues: issues)
    }

    static func mergeHeaders(_ text: String, into headers: inout [String: String]) {
        try? CKHeaders.merge(text, into: &headers)
    }
    static func safe(_ text: String) -> Bool { text.unicodeScalars.allSatisfy { ![0, 10, 13].contains($0.value) } }
}

enum CKKeys {
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func normalized(_ text: String) -> String? {
        let clean = text.replacingOccurrences(of: "-", with: "").lowercased()
        return clean.count == 32 && clean.allSatisfy({ "0123456789abcdef".contains($0) }) ? clean : nil
    }
    static func base64(_ text: String) -> Data? {
        let value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    static func parse(_ data: Data) throws -> [String: String] {
        guard data.count <= 1024 * 1024 else { throw CKFailure.invalidKey }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{feff}"))) else { throw CKFailure.invalidKey }
        var payload = Data(text.utf8)
        let prefix = "data:application/json;base64,"
        if text.lowercased().hasPrefix(prefix) {
            guard let decoded = base64(String(text.dropFirst(prefix.count))) else { throw CKFailure.invalidKey }
            payload = decoded
        } else if !text.hasPrefix("{"), !text.hasPrefix("["), !text.contains(":") {
            guard let decoded = base64(text) else { throw CKFailure.invalidKey }
            payload = decoded
        }
        let decodedText = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{feff}"))) ?? ""
        if decodedText.hasPrefix("{") || decodedText.hasPrefix("[") {
            let object: [String: Any]
            do {
                guard let value = try CKJSON.object(payload) as? [String: Any] else { throw CKFailure.invalidKey }
                object = value
            } catch { throw CKFailure.invalidKey }
            if let entries = object["keys"] as? [[String: Any]] {
                guard entries.count <= 128 else { throw CKFailure.invalidKey }
                var result: [String: String] = [:]
                for entry in entries {
                    guard (entry["kty"] as? String) == "oct", let kid = entry["kid"] as? String,
                          let key = entry["k"] as? String, let kidData = base64(kid), kidData.count == 16,
                          let keyData = base64(key), keyData.count == 16 else { throw CKFailure.invalidKey }
                    if let previous = result[hex(kidData)], previous != hex(keyData) { throw CKFailure.invalidKey }
                    result[hex(kidData)] = hex(keyData)
                }
                guard !result.isEmpty else { throw CKFailure.invalidKey }; return result
            }
            var result: [String: String] = [:]
            guard object.count <= 128 else { throw CKFailure.invalidKey }
            for (kid, value) in object {
                guard let key = value as? String, let id = normalized(kid), let normalizedKey = normalized(key) else { throw CKFailure.invalidKey }
                if let previous = result[id], previous != normalizedKey { throw CKFailure.invalidKey }
                result[id] = normalizedKey
            }
            guard !result.isEmpty else { throw CKFailure.invalidKey }; return result
        }
        guard payload == Data(text.utf8) else { throw CKFailure.invalidKey }
        var result: [String: String] = [:]
        let pairs = text.split(separator: ",", omittingEmptySubsequences: false)
        guard pairs.count <= 128 else { throw CKFailure.invalidKey }
        for pair in pairs {
            let parts = pair.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let kid = normalized(parts[0]), let key = normalized(parts[1]) else { throw CKFailure.invalidKey }
            if let previous = result[kid], previous != key { throw CKFailure.invalidKey }; result[kid] = key
        }
        guard !result.isEmpty else { throw CKFailure.invalidKey }; return result
    }
    static func defaultKey(_ keys: [String: String]) throws -> String {
        let values = Set(keys.values)
        guard values.count == 1, let key = values.first else { throw CKFailure.multipleKeys }
        return key
    }
}

final class CKRegistry {
    static let shared = CKRegistry()
    private let lock = NSLock()
    private var entries: [String: (CKChannel, Date, String?)] = [:]
    func observe(_ data: Data, source: URL?) {
        guard let report = CKPlaylist.report(data, relativeTo: source) else { return }
        let channels = report.channels, owner = source?.absoluteString
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.1.timeIntervalSinceNow > -3600 &&
            !report.observedURLs.contains($0.key) && (owner == nil || $0.value.2 != owner) }
        for channel in channels.prefix(2000) { entries[channel.url.absoluteString] = (channel, Date(), owner) }
        if entries.count > 2000 { entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.1 > $1.value.1 }.prefix(2000).map { ($0.key, $0.value) }) }
    }
    func channel(_ url: URL) -> CKChannel? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[url.absoluteString], entry.1.timeIntervalSinceNow > -3600 else { return nil }
        return entry.0
    }
    func all() -> [CKChannel] { lock.lock(); defer { lock.unlock() }; return entries.values.filter { $0.1.timeIntervalSinceNow > -3600 }.map { $0.0 }.sorted { $0.title < $1.title } }
}
