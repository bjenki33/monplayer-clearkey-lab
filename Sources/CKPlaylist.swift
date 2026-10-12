import Foundation

enum CKFailure: Error {
    case invalidPlaylist, invalidKey, unsupportedDRM, multipleKeys, network, unsupportedLicense
}

struct CKChannel {
    let url: URL
    let title: String
    let keySource: String
    let headers: [String: String]
}

enum CKPlaylist {
    static func parse(_ data: Data, relativeTo base: URL?) -> [CKChannel] {
        guard data.count <= 4 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return [] }
        var channels: [CKChannel] = []
        var title = "ClearKey", type = "", key = "", headers: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                if let comma = line.firstIndex(of: ",") { title = String(line[line.index(after: comma)...]) }
            } else if line.hasPrefix("#KODIPROP:") {
                let fields = line.dropFirst(10).split(separator: "=", maxSplits: 1).map(String.init)
                guard fields.count == 2 else { continue }
                switch fields[0].lowercased() {
                case "inputstream.adaptive.license_type", "inputstream.adaptive.drm": type = fields[1].lowercased()
                case "inputstream.adaptive.license_key": key = fields[1]
                case "inputstream.adaptive.stream_headers": mergeHeaders(fields[1], into: &headers)
                default: break
                }
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let fields = line.dropFirst(11).split(separator: "=", maxSplits: 1).map(String.init)
                guard fields.count == 2 else { continue }
                let names = ["http-user-agent": "User-Agent", "http-referrer": "Referer",
                             "http-referer": "Referer", "http-origin": "Origin"]
                if let name = names[fields[0].lowercased()], safe(fields[1]) { headers[name] = fields[1] }
            } else if line.hasPrefix("#EXTHTTP:") {
                if let json = String(line.dropFirst(9)).data(using: .utf8),
                   let values = try? JSONSerialization.jsonObject(with: json) as? [String: String] {
                    for (name, value) in values where safe(name) && safe(value) { headers[name] = value }
                }
            } else if !line.isEmpty && !line.hasPrefix("#") {
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2 { mergeHeaders(parts[1], into: &headers) }
                let clear = ["clearkey", "org.w3.clearkey"].contains(type)
                if clear, !key.isEmpty, let url = URL(string: parts[0], relativeTo: base)?.absoluteURL,
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    channels.append(CKChannel(url: url, title: title, keySource: key, headers: headers))
                }
                title = "ClearKey"; type = ""; key = ""; headers = [:]
            }
        }
        return channels
    }

    static func mergeHeaders(_ text: String, into headers: inout [String: String]) {
        for field in text.split(separator: "&") {
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0].removingPercentEncoding ?? parts[0]
            let value = parts[1].removingPercentEncoding ?? parts[1]
            if safe(name) && safe(value) { headers[name] = value }
        }
    }
    static func safe(_ text: String) -> Bool { !text.contains("\r") && !text.contains("\n") && !text.contains("\0") }
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
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let entries = object["keys"] as? [[String: Any]] {
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
            for (kid, value) in object {
                guard let key = value as? String, let id = normalized(kid), let normalizedKey = normalized(key) else { throw CKFailure.invalidKey }
                result[id] = normalizedKey
            }
            guard !result.isEmpty else { throw CKFailure.invalidKey }; return result
        }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { throw CKFailure.invalidKey }
        var result: [String: String] = [:]
        for pair in text.split(separator: ",") {
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
    private var entries: [String: (CKChannel, Date)] = [:]
    func observe(_ data: Data, source: URL?) {
        let channels = CKPlaylist.parse(data, relativeTo: source)
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.1.timeIntervalSinceNow > -3600 }
        for channel in channels.prefix(2000) { entries[channel.url.absoluteString] = (channel, Date()) }
        if entries.count > 2000 { entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.1 > $1.value.1 }.prefix(2000)) }
    }
    func channel(_ url: URL) -> CKChannel? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[url.absoluteString], entry.1.timeIntervalSinceNow > -3600 else { return nil }
        return entry.0
    }
    func all() -> [CKChannel] { lock.lock(); defer { lock.unlock() }; return entries.values.map { $0.0 }.sorted { $0.title < $1.title } }
}
