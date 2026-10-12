import Foundation
import CoreFoundation

struct CKLicenseSpec {
    let source: String
    let headers: [String: String]

    static func legacy(_ text: String) throws -> CKLicenseSpec {
        let fields = text.components(separatedBy: "|")
        guard fields.count <= 4, let first = fields.first, !first.isEmpty else { throw CKFailure.invalidMetadata }
        if fields.count > 2, !fields[2].isEmpty { throw CKFailure.unsupportedLicense }
        if fields.count > 3, !["", "R"].contains(fields[3]) { throw CKFailure.unsupportedLicense }
        var headers: [String: String] = [:]
        if fields.count > 1 { try CKHeaders.merge(fields[1], into: &headers) }
        return CKLicenseSpec(source: first, headers: headers)
    }
    func equivalent(to other: CKLicenseSpec) -> Bool {
        let firstHeaders = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        let secondHeaders = other.headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        guard firstHeaders == secondHeaders else { return false }
        if source == other.source { return true }
        if let first = try? CKKeys.parse(Data(source.utf8)), let second = try? CKKeys.parse(Data(other.source.utf8)) { return first == second }
        return false
    }
}

enum CKDRMMetadata {
    static func clear(_ value: String) -> Bool { ["clearkey", "org.w3.clearkey"].contains(value.lowercased()) }

    static func recognizesClear(_ properties: [String: String]) -> Bool {
        if clear(properties["inputstream.adaptive.license_type"] ?? "") { return true }
        if clear(properties["inputstream.adaptive.drm"] ?? "") { return true }
        if let legacy = properties["inputstream.adaptive.drm_legacy"], clear(legacy.components(separatedBy: "|")[0]) { return true }
        if let modern = properties["inputstream.adaptive.drm"],
           let object = try? JSONSerialization.jsonObject(with: Data(modern.utf8)) as? [String: Any] {
            // Classification only:resolve() still rejects duplicate/ambiguous JSON.
            return object.keys.contains(where: clear)
        }
        return false
    }

    static func resolve(_ properties: [String: String]) throws -> CKLicenseSpec? {
        var specs: [CKLicenseSpec] = [], nonClear = false
        let oldType = properties["inputstream.adaptive.license_type"] ?? ""
        let modern = properties["inputstream.adaptive.drm"]
        let shorthand = modern.flatMap { $0.hasPrefix("{") ? nil : $0 }
        for type in [oldType, shorthand ?? ""] where !type.isEmpty { if !clear(type) { nonClear = true } }
        if clear(oldType) || clear(shorthand ?? ""), let key = properties["inputstream.adaptive.license_key"] {
            specs.append(try CKLicenseSpec.legacy(key))
        }
        if let legacy = properties["inputstream.adaptive.drm_legacy"] {
            let parts = legacy.components(separatedBy: "|")
            guard parts.count <= 3 else { throw CKFailure.invalidMetadata }
            if clear(parts[0]) {
                guard parts.count >= 2, !parts[1].isEmpty else { throw CKFailure.unsupportedLicense }
                let encoded = parts.dropFirst().joined(separator: "|")
                specs.append(try CKLicenseSpec.legacy(encoded))
            } else { nonClear = true }
        }
        if let modern, modern.hasPrefix("{") {
            guard let object = try CKJSON.object(Data(modern.utf8)) as? [String: Any] else { throw CKFailure.invalidMetadata }
            let clearNodes = object.keys.filter(clear)
            if clearNodes.isEmpty { nonClear = true }
            for name in clearNodes {
                guard let config = object[name] as? [String: Any] else { throw CKFailure.invalidMetadata }
                guard Set(config.keys).isSubset(of: ["license", "priority"]) else { throw CKFailure.unsupportedLicense }
                if let priority = config["priority"] {
                    guard let number = priority as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue >= 1, number.doubleValue.isFinite,
                          number.doubleValue.rounded() == number.doubleValue else { throw CKFailure.invalidMetadata }
                }
                guard let license = config["license"] as? [String: Any] else { throw CKFailure.unsupportedLicense }
                guard Set(license.keys).isSubset(of: ["keyids", "server_url", "req_headers"]) else { throw CKFailure.unsupportedLicense }
                var headers: [String: String] = [:]
                if let encoded = license["req_headers"] {
                    guard let text = encoded as? String else { throw CKFailure.invalidMetadata }
                    try CKHeaders.merge(text, into: &headers)
                }
                let source: String
                if let keys = license["keyids"] {
                    guard license["server_url"] == nil, keys is [String: String] else { throw CKFailure.invalidMetadata }
                    source = String(decoding: try JSONSerialization.data(withJSONObject: keys, options: .sortedKeys), as: UTF8.self)
                } else if let url = license["server_url"] as? String {
                    // Modern ClearKey remote licenses require a challenge flow.
                    // Stage1C owns that implementation;never pretend an arbitrary GET is equivalent.
                    guard url.lowercased().hasPrefix("data:application/json;base64,") else { throw CKFailure.unsupportedLicense }
                    source = url
                } else { throw CKFailure.unsupportedLicense }
                specs.append(CKLicenseSpec(source: source, headers: headers))
            }
        }
        if nonClear, !specs.isEmpty { throw CKFailure.invalidMetadata }
        guard let first = specs.first else {
            if recognizesClear(properties) { throw CKFailure.unsupportedLicense }
            return nil
        }
        for spec in specs.dropFirst() where !first.equivalent(to: spec) { throw CKFailure.invalidMetadata }
        for name in ["inputstream.adaptive.license_data", "inputstream.adaptive.license_flags", "inputstream.adaptive.server_certificate"] {
            if let value = properties[name], !value.isEmpty { throw CKFailure.unsupportedLicense }
        }
        for name in ["inputstream.adaptive.common_headers", "inputstream.adaptive.manifest_headers",
                     "inputstream.adaptive.stream_params", "inputstream.adaptive.manifest_params", "inputstream.adaptive.manifest_upd_params"] {
            if let value = properties[name], !value.isEmpty { throw CKFailure.unsupportedMetadata }
        }
        return first
    }
}
