import Foundation

struct CKKeySet {
    private let keys: [String: String]
    let distinctKeyCount: Int

    init(_ values: [String: String]) throws {
        guard !values.isEmpty, values.count <= 128 else { throw CKFailure.invalidKey }
        var normalized: [String: String] = [:]
        for (kid, key) in values {
            guard let id = CKKeys.normalized(kid), let value = CKKeys.normalized(key) else { throw CKFailure.invalidKey }
            if let previous = normalized[id], previous != value { throw CKFailure.invalidKey }
            normalized[id] = value
        }
        keys = normalized
        distinctKeyCount = Set(normalized.values).count
    }

    var requiresKeyMap: Bool { distinctKeyCount > 1 }

    func contains(_ ids: [String]) -> Bool { ids.allSatisfy { keys[$0] != nil } }

    func including(_ other: CKKeySet) throws -> CKKeySet {
        var merged = keys
        for (id, value) in other.keys {
            if let previous = merged[id], previous != value { throw CKFailure.invalidKey }
            merged[id] = value
        }
        return try CKKeySet(merged)
    }

    var formatOptions: [String: String] {
        // Preserve CK2's proven single-key path, including inconsistent MPD KIDs.
        if !requiresKeyMap, let key = keys.values.first {
            return ["cenc_decryption_key": key, "decryption_key": key]
        }
        let map = keys.keys.sorted().map { "\($0)=\(keys[$0]!)" }.joined(separator: ":")
        return ["cenc_decryption_keys": map, "decryption_keys": map]
    }
}
