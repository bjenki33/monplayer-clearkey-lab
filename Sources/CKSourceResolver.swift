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

enum CKHTTPRetry {
    static let maxAttempts = 3
    static func delay(request: URLRequest, role: CKHTTPRole, error: Error,
                      response: HTTPURLResponse?, failedAttempt: Int, remaining: TimeInterval,
                      now: Date = Date()) -> TimeInterval? {
        guard role == .manifest, request.httpMethod == "GET", request.httpBody == nil,
              request.httpBodyStream == nil, request.value(forHTTPHeaderField: "Range") == nil,
              (1..<maxAttempts).contains(failedAttempt) else { return nil }
        if let failure = error as? CKOpenFailure, case .http(let status) = failure {
            guard [408,429,502,503,504].contains(status) else { return nil }
        } else {
            let failure = error as NSError
            guard failure.domain == NSURLErrorDomain,
                  [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(failure.code) else { return nil }
        }
        var delay: TimeInterval = failedAttempt == 1 ? 0.25 : 0.75
        if let value = response?.value(forHTTPHeaderField: "Retry-After") {
            // Never shorten a server's requested wait or guess a malformed value.
            guard let requested = retryAfter(value, now: now), requested <= 2 else { return nil }
            delay = max(delay, requested)
        }
        guard delay + 0.1 < remaining else { return nil }
        return delay
    }
    static func retryAfter(_ value: String, now: Date) -> TimeInterval? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
        if value.utf8.allSatisfy({ (48...57).contains($0) }) {
            guard let seconds = TimeInterval(value), seconds.isFinite else { return nil }
            return seconds
        }
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT: 0)
            parser.dateFormat = format; parser.isLenient = false
            if let date = parser.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }
}

enum CKHTTP {
    private struct AttemptFailure: Error { let underlying: Error; let response: HTTPURLResponse }
    static func read(_ request: URLRequest, role: CKHTTPRole, limit: Int) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard limit > 0, let url = request.url, url.host != nil,
              ["http","https"].contains(url.scheme?.lowercased() ?? "") else { throw CKFailure.invalidMetadata }
        let budget = min(role == .license ? 25.0 : 20.0,
                         request.timeoutInterval > 0 && request.timeoutInterval.isFinite ? request.timeoutInterval : 20)
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw URLError(.timedOut) }
            do {
                let result = try await once(request, role: role, limit: limit, timeout: remaining)
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
                return result
            }
            catch {
                try Task.checkCancellation()
                let failure = error as? AttemptFailure
                let underlying = failure?.underlying ?? error
                guard let delay = CKHTTPRetry.delay(request: request, role: role, error: underlying,
                                                   response: failure?.response, failedAttempt: attempt,
                                                   remaining: deadline - ProcessInfo.processInfo.systemUptime) else { throw underlying }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }
    }
    private static func once(_ request: URLRequest, role: CKHTTPRole, limit: Int,
                             timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let policy = CKHTTPRedirectPolicy(request: request, role: role)
        let session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do { return try await withTaskCancellationHandler(operation: {
            let (bytes, response) = try await session.bytes(for: request)
            guard !policy.wasDenied else { throw CKFailure.unsafeRedirect }
            guard let response = response as? HTTPURLResponse else { throw CKFailure.network }
            guard (200..<300).contains(response.statusCode) else {
                throw AttemptFailure(underlying: CKOpenFailure.http(response.statusCode), response: response)
            }
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
        }, onCancel: { session.invalidateAndCancel() }) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            // URLSession may fail its async continuation before yielding the
            // rejected redirect response; preserve the policy's safe taxonomy.
            if policy.wasDenied { throw CKFailure.unsafeRedirect }
            throw error
        }
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
    static func manifest(_ channel: CKChannel, timeout: TimeInterval = 20) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: channel.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        channel.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let result = try await CKHTTP.read(request, role: .manifest, limit: 2 * 1024 * 1024)
        _ = try CKManifest.validatedURL(result.0, response: result.1)
        return result
    }

    static func keys(_ channel: CKChannel, ids: [String], timeout: TimeInterval = 25) async throws -> CKKeySet {
        if var request = try channel.keyRequest(kids: ids) {
            request.timeoutInterval = timeout
            let result = try await CKHTTP.read(request, role: .license, limit: 1024 * 1024)
            return try channel.license.keys(from: result.0, requested: ids)
        }
        return try CKKeySet(CKKeys.parse(Data(channel.license.source.utf8)))
    }

    static func resolve(_ channel: CKChannel, timeout: TimeInterval = 45) async throws -> CKResolvedSource {
        let budget = timeout.isFinite ? max(0, min(timeout, 45)) : 45
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        var lastFailure: CKResolutionError?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                return try await resolveOnce(channel, deadline: deadline)
            } catch let failure as CKResolutionError {
                try Task.checkCancellation()
                guard isKidDesync(failure.underlying),
                      let licenseURL = URL(string: channel.license.source), licenseURL.host != nil,
                      ["http", "https"].contains(licenseURL.scheme?.lowercased() ?? "") else { throw failure }
                lastFailure = failure
                if attempt < 2 {
                    guard deadline - ProcessInfo.processInfo.systemUptime > 0.5 else {
                        throw CKResolutionError(stage: failure.stage, underlying: URLError(.timedOut))
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            } catch {
                throw error
            }
        }
        throw lastFailure ?? CKResolutionError(stage: .key, underlying: CKFailure.missingLicenseKey)
    }

    private static func isKidDesync(_ error: Error) -> Bool {
        if case CKFailure.missingLicenseKey = error { return true }
        return false
    }

    private static func requestTimeout(_ deadline: TimeInterval, maximum: TimeInterval) throws -> TimeInterval {
        try Task.checkCancellation()
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw URLError(.timedOut) }
        return min(remaining, maximum)
    }

    private static func resolveOnce(_ channel: CKChannel, deadline: TimeInterval) async throws -> CKResolvedSource {
        var stage = CKStage.key
        do {
            if let failure = channel.metadataFailure { throw failure }
            let spec = channel.license
            var manifest: (Data,HTTPURLResponse)?, manifestSeconds = TimeInterval(0), ids: [String] = []
            func fetchManifest() async throws -> (Data,HTTPURLResponse,TimeInterval) {
                let began = ProcessInfo.processInfo.systemUptime
                let result = try await Self.manifest(channel, timeout: requestTimeout(deadline, maximum: 20))
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
            let keys = try await Self.keys(channel, ids: ids, timeout: requestTimeout(deadline, maximum: 25))
            let keySeconds = ProcessInfo.processInfo.systemUptime - began
            if manifest == nil {
                stage = .manifest
                let result = try await fetchManifest()
                manifest = (result.0,result.1); manifestSeconds = result.2
            }
            stage = .manifest
            guard let manifest else { throw CKFailure.network }
            // Single-key playback intentionally tolerates stale declared MPD KIDs.
            if keys.requiresKeyMap, let freshIDs = try? CKManifestKeyIDs.read(manifest.0),
               !freshIDs.isEmpty, !keys.contains(freshIDs) {
                throw CKFailure.missingLicenseKey
            }
            let url = try CKManifest.validatedURL(manifest.0, response: manifest.1, keySet: keys)
            try Task.checkCancellation()
            _ = try requestTimeout(deadline, maximum: 45)
            return CKResolvedSource(keys: keys, data: manifest.0, url: url, keySeconds: keySeconds, manifestSeconds: manifestSeconds)
        } catch { throw CKResolutionError(stage: stage, underlying: error) }
    }
}
