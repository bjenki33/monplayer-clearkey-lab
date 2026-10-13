import Foundation

enum CKLicenseBody: Equatable {
    case challenge, template(String, modern: Bool)

    static func legacy(_ value: String) throws -> CKLicenseBody { try checked(value, modern: false) }
    static func modern(_ value: String) throws -> CKLicenseBody { try checked(value, modern: true) }
    private static func checked(_ value: String, modern: Bool) throws -> CKLicenseBody {
        guard !value.isEmpty, value.utf8.count <= 64 * 1024 else { throw CKFailure.invalidMetadata }
        let expression = try NSRegularExpression(pattern: #"\{[A-Z][A-Z0-9_-]*\}"#)
        let allowed = modern ? ["{CHA-RAW}","{CHA-B64}","{CHA-B64U}","{CHA-DEC}","{KID-HEX}","{KID-UUID}"] : ["{SSM}","{KID}"]
        let range = NSRange(value.startIndex..., in: value)
        for match in expression.matches(in: value, range: range) {
            guard let token = Range(match.range, in: value), allowed.contains(String(value[token])) else { throw CKFailure.unsupportedLicense }
            if !modern {
                guard token.lowerBound > value.startIndex else { throw CKFailure.unsupportedLicense }
                let prefix = value[value.index(before: token.lowerBound)]
                guard (String(value[token]) == "{SSM}" && "RbBD".contains(prefix)) ||
                      (String(value[token]) == "{KID}" && prefix == "H") else { throw CKFailure.unsupportedLicense }
            }
        }
        return .template(value, modern: modern)
    }
    var needsKeyIDs: Bool {
        switch self {
        case .challenge: return true
        case .template(let value, _): return value.contains("{CHA-") || value.contains("{SSM}") || value.contains("{KID")
        }
    }
    static func challengeData(kids: [String]) throws -> Data {
        guard !kids.isEmpty, kids.count <= 128 else { throw CKFailure.missingKeyIDs }
        let ids = try kids.map { value -> String in
            guard let id = CKKeys.normalized(value) else { throw CKFailure.missingKeyIDs }
            return id
        }
        let encoded = Set(ids).sorted().map { id -> String in
            let bytes = stride(from: 0, to: 32, by: 2).map { offset -> UInt8 in
                let start = id.index(id.startIndex, offsetBy: offset)
                return UInt8(id[start..<id.index(start, offsetBy: 2)], radix: 16)!
            }
            return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return try JSONSerialization.data(withJSONObject: ["kids":encoded,"type":"temporary"], options: .sortedKeys)
    }
    func data(kids: [String]) throws -> Data {
        if self == .challenge { return try Self.challengeData(kids: kids) }
        guard case .template(var text, let modern) = self else { throw CKFailure.unsupportedLicense }
        if needsKeyIDs {
            let challenge = try Self.challengeData(kids: kids)
            let raw = String(decoding: challenge, as: UTF8.self), base64 = challenge.base64EncodedString()
            let urlEncoded = base64.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
            let decimal = challenge.map(String.init).joined(separator: ",")
            let forms = modern ? ["{CHA-RAW}":raw,"{CHA-B64}":base64,"{CHA-B64U}":urlEncoded,"{CHA-DEC}":decimal] :
                ["R{SSM}":raw,"b{SSM}":base64,"B{SSM}":urlEncoded,"D{SSM}":decimal]
            for (token, value) in forms { text = text.replacingOccurrences(of: token, with: value) }
            if text.contains("{KID") {
                let ids = Set(kids.compactMap(CKKeys.normalized))
                guard ids.count == 1, let id = ids.first else { throw CKFailure.unsupportedLicense }
                let uuid = [0..<8,8..<12,12..<16,16..<20,20..<32].map { range in
                    String(id[id.index(id.startIndex, offsetBy: range.lowerBound)..<id.index(id.startIndex, offsetBy: range.upperBound)])
                }.joined(separator: "-")
                for (token, value) in ["{KID-HEX}":id,"{KID-UUID}":uuid,"H{KID}":id] {
                    text = text.replacingOccurrences(of: token, with: value)
                }
            }
        }
        guard text.utf8.count <= 128 * 1024 else { throw CKFailure.invalidMetadata }
        return Data(text.utf8)
    }
}

enum CKLicenseResponse: Equatable {
    case raw, base64, json(String, base64: Bool)
    static func legacy(_ value: String) throws -> CKLicenseResponse {
        if ["","R"].contains(value) { return .raw }
        if value == "B" { return .base64 }
        let encoded = value.hasPrefix("JB")
        guard encoded || value.hasPrefix("J") else { throw CKFailure.unsupportedLicense }
        let field = String(value.dropFirst(encoded ? 2 : 1))
        guard !field.isEmpty, field.utf8.count <= 128, field.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,95].contains($0)
        }) else { throw CKFailure.unsupportedLicense }
        return .json(field, base64: encoded)
    }
    func unwrap(_ data: Data) throws -> Data {
        guard data.count <= 1024 * 1024 else { throw CKFailure.responseTooLarge }
        switch self {
        case .raw: return data
        case .base64:
            guard let text = String(data: data, encoding: .utf8), let value = CKKeys.base64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CKFailure.invalidKey }
            return value
        case .json(let field, let encoded):
            guard let object = try CKJSON.object(data) as? [String:Any], let value = object[field] else { throw CKFailure.invalidKey }
            if let text = value as? String {
                if !encoded { return Data(text.utf8) }
                guard let decoded = CKKeys.base64(text) else { throw CKFailure.invalidKey }; return decoded
            }
            guard !encoded, let object = value as? [String:Any] else { throw CKFailure.invalidKey }
            return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        }
    }
}

extension CKLicenseSpec {
    func keys(from data: Data, requested: [String]) throws -> CKKeySet {
        let payload: Data
        do { payload = try response.unwrap(data) }
        catch CKFailure.invalidMetadata { throw CKFailure.invalidKey }
        if body != nil {
            if let object = try? CKJSON.object(payload) as? [String:Any], object["keys"] != nil {
                if let type = object["type"], (type as? String) != "temporary" { throw CKFailure.unsupportedLicense }
            }
            if body == .challenge {
                guard let object = (try? CKJSON.object(payload)) as? [String:Any],
                      object["keys"] is [[String:Any]] else { throw CKFailure.invalidKey }
            }
        }
        let keys = try CKKeys.parse(payload)
        for id in requested {
            guard let normalized = CKKeys.normalized(id), keys[normalized] != nil else { throw CKFailure.missingLicenseKey }
        }
        return try CKKeySet(keys)
    }
}
