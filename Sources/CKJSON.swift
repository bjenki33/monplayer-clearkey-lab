import Foundation

enum CKJSON {
    static func object(_ data: Data) throws -> Any {
        guard data.count <= 1024 * 1024 else { throw CKFailure.invalidMetadata }
        let content = data.starts(with: [239, 187, 191]) ? Data(data.dropFirst(3)) : data
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: content) }
        catch { throw CKFailure.invalidMetadata }
        var scanner = Scanner(bytes: [UInt8](content))
        try scanner.value(depth: 0)
        scanner.spaces()
        guard scanner.index == scanner.bytes.count else { throw CKFailure.invalidMetadata }
        return value
    }

    // Foundation accepts repeated JSON keys using the last value. Reject that
    // ambiguity before accepting a key map, license URL or authorization header.
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        mutating func spaces() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func consume(_ byte: UInt8) throws {
            spaces()
            guard index < bytes.count, bytes[index] == byte else { throw CKFailure.invalidMetadata }
            index += 1
        }
        mutating func string() throws -> String {
            spaces()
            let start = index
            try consume(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 { index += 1 }
                else if byte == 34 {
                    let fragment = Data(bytes[start..<index])
                    guard let text = try? JSONSerialization.jsonObject(with: fragment, options: .fragmentsAllowed) as? String else {
                        throw CKFailure.invalidMetadata
                    }
                    return text
                }
            }
            throw CKFailure.invalidMetadata
        }
        mutating func value(depth: Int) throws {
            guard depth <= 32 else { throw CKFailure.invalidMetadata }
            spaces()
            guard index < bytes.count else { throw CKFailure.invalidMetadata }
            switch bytes[index] {
            case 123:
                index += 1; spaces()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                var names: Set<String> = []
                while true {
                    let key = try string()
                    guard names.insert(key).inserted else { throw CKFailure.invalidMetadata }
                    try consume(58); try value(depth: depth + 1); spaces()
                    guard index < bytes.count else { throw CKFailure.invalidMetadata }
                    if bytes[index] == 125 { index += 1; return }
                    try consume(44)
                }
            case 91:
                index += 1; spaces()
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); spaces()
                    guard index < bytes.count else { throw CKFailure.invalidMetadata }
                    if bytes[index] == 93 { index += 1; return }
                    try consume(44)
                }
            case 34: _ = try string()
            default:
                let start = index
                while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw CKFailure.invalidMetadata }
            }
        }
    }
}
