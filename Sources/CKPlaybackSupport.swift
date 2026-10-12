import Foundation

enum CKStage: String { case key, manifest, playback }
enum CKOpenFailure: Error { case http(Int), invalidManifest, startupTimeout }

enum CKManifest {
    static func validatedURL(_ data: Data, response: HTTPURLResponse) throws -> URL {
        guard (200..<300).contains(response.statusCode) else { throw CKOpenFailure.http(response.statusCode) }
        guard data.count <= 2 * 1024 * 1024, let url = response.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw CKOpenFailure.invalidManifest }
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{feff}"))).hasPrefix("#EXTM3U") == true { return url }
        let reader = RootReader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.root == "MPD" else { throw CKOpenFailure.invalidManifest }
        return url
    }
    private final class RootReader: NSObject, XMLParserDelegate {
        var root: String?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            if root == nil { root = elementName }
        }
    }
}

enum CKDiagnostic {
    static func message(_ error: Error, stage: CKStage) -> String {
        let step = [CKStage.key: "Provider key", .manifest: "Manifest", .playback: "Video playback"][stage]!
        if let error = error as? CKOpenFailure {
            switch error {
            case .http(let status): return "\(step): HTTP \(status). Check source access."
            case .invalidManifest: return "Manifest: source did not return valid DASH/HLS."
            case .startupTimeout: return "Video startup timed out after 30 seconds. Tap Play to retry."
            }
        }
        if case CKFailure.multipleKeys = error { return "Provider key: multiple distinct keys are not supported in CK2." }
        if case CKFailure.invalidKey = error { return "Provider key: unsupported key map/JWKS response." }
        let code = (error as NSError).code
        if (error as NSError).domain == NSURLErrorDomain {
            switch code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "\(step): cannot resolve source host (\(code))."
            case NSURLErrorTimedOut: return "\(step): source request timed out (\(code))."
            case NSURLErrorNotConnectedToInternet: return "\(step): no internet connection (\(code))."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return "\(step): TLS/certificate check failed (\(code))."
            default: break
            }
        }
        // Never expose localized errors, userInfo, headers, URLs or provider keys.
        var codes = [code], nested = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        for _ in 0..<3 {
            guard let current = nested else { break }
            let underlying = current as NSError
            codes.append(underlying.code); nested = underlying.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return "\(step) failed (codes \(codes.map(String.init).joined(separator: "/"))). Check source access and stream format."
    }
    static func trace(_ message: String) { NSLog("[CKBridge CK2] %@", message) }
}
