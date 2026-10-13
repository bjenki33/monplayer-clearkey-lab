import Foundation

enum CKHTTPRole: Equatable { case license, manifest }

final class CKHTTPRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let original: URLRequest
    private let role: CKHTTPRole
    private let lock = NSLock()
    private var redirects = 0
    private var denied = false
    init(request: URLRequest, role: CKHTTPRole) { original = request; self.role = role }
    var wasDenied: Bool { lock.lock(); defer { lock.unlock() }; return denied }
    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased() &&
            first.host?.lowercased() == second.host?.lowercased() && port(first) == port(second)
    }
    func follow(_ response: HTTPURLResponse, proposed request: URLRequest) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        redirects += 1
        guard redirects <= 5, let first = original.url, let next = request.url,
              ["http","https"].contains(next.scheme?.lowercased() ?? ""),
              !(first.scheme?.lowercased() == "https" && next.scheme?.lowercased() == "http") else {
            denied = true; return nil
        }
        if role == .license {
            guard Self.sameOrigin(first, next), original.httpMethod != "POST" || [307,308].contains(response.statusCode) else {
                denied = true; return nil
            }
            var result = request
            result.httpMethod = original.httpMethod; result.httpBody = original.httpBody
            result.allHTTPHeaderFields = original.allHTTPHeaderFields
            return result
        }
        return request
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(follow(response, proposed: request))
    }
}

enum CKHTTP {
    static func read(_ request: URLRequest, role: CKHTTPRole, limit: Int) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url, url.host != nil,
              ["http","https"].contains(url.scheme?.lowercased() ?? "") else { throw CKFailure.invalidMetadata }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = role == .license ? 25 : 20
        configuration.timeoutIntervalForResource = configuration.timeoutIntervalForRequest
        let policy = CKHTTPRedirectPolicy(request: request, role: role)
        let session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler(operation: {
            let (bytes, response) = try await session.bytes(for: request)
            guard !policy.wasDenied else { throw CKFailure.unsafeRedirect }
            guard let response = response as? HTTPURLResponse else { throw CKFailure.network }
            guard (200..<300).contains(response.statusCode) else { throw CKOpenFailure.http(response.statusCode) }
            guard response.expectedContentLength <= Int64(limit) else { throw CKFailure.responseTooLarge }
            var data = Data()
            data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < limit else { throw CKFailure.responseTooLarge }
                data.append(byte)
                if data.count % 4096 == 0 { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return (data, response)
        }, onCancel: { session.invalidateAndCancel() })
    }
}

enum CKManifestKeyIDs {
    static func read(_ data: Data) throws -> [String] {
        guard data.count <= 2 * 1024 * 1024,
              !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE"),
              !String(decoding: data, as: UTF8.self).uppercased().contains("<!ENTITY") else { throw CKOpenFailure.invalidManifest }
        let reader = Reader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.root == "MPD", !reader.invalid else { throw CKOpenFailure.invalidManifest }
        guard !reader.ids.isEmpty else { throw CKFailure.missingKeyIDs }
        return reader.ids.sorted()
    }
    private final class Reader: NSObject, XMLParserDelegate {
        var root: String?, invalid = false, ids: Set<String> = []
        var scopes: [[String:String]] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
            guard scopes.count < 64 else { invalid = true; parser.abortParsing(); return }
            var scope = scopes.last ?? [:]
            for (key, value) in attributes where key == "xmlns" || key.hasPrefix("xmlns:") {
                scope[key == "xmlns" ? "" : String(key.dropFirst(6))] = value
            }
            scopes.append(scope)
            let parts = name.split(separator: ":").map(String.init), local = parts.last ?? ""
            let namespace = scope[parts.count == 2 ? parts[0] : ""] ?? ""
            if root == nil {
                root = local
                if !["","urn:mpeg:dash:schema:mpd:2011"].contains(namespace) { invalid = true }
            }
            guard local == "ContentProtection", ["","urn:mpeg:dash:schema:mpd:2011"].contains(namespace) else { return }
            for (key, value) in attributes {
                let attr = key.split(separator: ":").map(String.init)
                guard attr.count == 2, attr[1] == "default_KID", scope[attr[0]] == "urn:mpeg:cenc:2013" else { continue }
                let tokens = value.split(whereSeparator: { $0.isWhitespace })
                guard !tokens.isEmpty, tokens.count <= 128 else { invalid = true; parser.abortParsing(); return }
                for token in tokens {
                    let value = String(token)
                    if value.count == 36 {
                        let characters = Array(value)
                        guard [8,13,18,23].allSatisfy({ characters[$0] == "-" }) else { invalid = true; parser.abortParsing(); return }
                    } else if value.count != 32 { invalid = true; parser.abortParsing(); return }
                    guard let id = CKKeys.normalized(value) else { invalid = true; parser.abortParsing(); return }
                    ids.insert(id)
                    guard ids.count <= 128 else { invalid = true; parser.abortParsing(); return }
                }
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = scopes.popLast() }
    }
}

struct CKResolvedSource {
    let keys: CKKeySet
    let data: Data
    let url: URL
    let keySeconds: TimeInterval
    let manifestSeconds: TimeInterval
}
struct CKResolutionError: Error { let stage: CKStage; let underlying: Error }

enum CKSourceResolver {
    static func resolve(_ channel: CKChannel) async throws -> CKResolvedSource {
        var stage = CKStage.key
        do {
            if let failure = channel.metadataFailure { throw failure }
            let spec = channel.license
            var manifest: (Data,HTTPURLResponse)?, manifestSeconds = TimeInterval(0), ids: [String] = []
            func fetchManifest() async throws -> (Data,HTTPURLResponse,TimeInterval) {
                var request = URLRequest(url: channel.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                channel.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                let began = ProcessInfo.processInfo.systemUptime
                let result = try await CKHTTP.read(request, role: .manifest, limit: 2 * 1024 * 1024)
                _ = try CKManifest.validatedURL(result.0, response: result.1)
                return (result.0,result.1,ProcessInfo.processInfo.systemUptime - began)
            }
            if spec.body?.needsKeyIDs == true {
                stage = .manifest
                let result = try await fetchManifest()
                manifest = (result.0,result.1); manifestSeconds = result.2
                ids = try CKManifestKeyIDs.read(result.0)
            }
            stage = .key
            let began = ProcessInfo.processInfo.systemUptime
            let keys: CKKeySet
            if let request = try channel.keyRequest(kids: ids) {
                let result = try await CKHTTP.read(request, role: .license, limit: 1024 * 1024)
                keys = try spec.keys(from: result.0, requested: ids)
            } else { keys = try CKKeySet(CKKeys.parse(Data(spec.source.utf8))) }
            let keySeconds = ProcessInfo.processInfo.systemUptime - began
            if manifest == nil {
                stage = .manifest
                let result = try await fetchManifest()
                manifest = (result.0,result.1); manifestSeconds = result.2
            }
            stage = .manifest
            guard let manifest else { throw CKFailure.network }
            let url = try CKManifest.validatedURL(manifest.0, response: manifest.1, keySet: keys)
            try Task.checkCancellation()
            return CKResolvedSource(keys: keys, data: manifest.0, url: url, keySeconds: keySeconds, manifestSeconds: manifestSeconds)
        } catch { throw CKResolutionError(stage: stage, underlying: error) }
    }
}
