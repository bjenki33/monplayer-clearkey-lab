import Foundation

enum CKHeaders {
    static func set(_ name: String, value: String, in headers: inout [String: String]) throws {
        let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard !name.isEmpty, name.count <= 256, name.allSatisfy({ allowed.contains($0) }),
              value.utf8.count <= 16 * 1024,
              value.unicodeScalars.allSatisfy({ $0.value == 9 ||
                  (!CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)) }) else {
            throw CKFailure.invalidMetadata
        }
        let canonical = ["user-agent": "User-Agent", "referer": "Referer", "origin": "Origin",
                         "authorization": "Authorization", "cookie": "Cookie", "content-type": "Content-Type",
                         "accept": "Accept", "accept-encoding": "Accept-Encoding"][name.lowercased()] ?? name
        for key in Array(headers.keys) where key.lowercased() == name.lowercased() { headers.removeValue(forKey: key) }
        headers[canonical] = value
        guard headers.count <= 64 else { throw CKFailure.invalidMetadata }
    }
    static func merge(_ text: String, into headers: inout [String: String]) throws {
        guard text.utf8.count <= 64 * 1024 else { throw CKFailure.invalidMetadata }
        if text.isEmpty { return }
        for field in text.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw CKFailure.invalidMetadata }
            func decode(_ text: Substring) throws -> String {
                guard let value = String(text).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { throw CKFailure.invalidMetadata }
                return value
            }
            try set(decode(parts[0]), value: decode(parts[1]), in: &headers)
        }
    }
    static func combining(_ base: [String: String], _ overrides: [String: String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in base { try set(name, value: value, in: &result) }
        for (name, value) in overrides { try set(name, value: value, in: &result) }
        return result
    }
}
