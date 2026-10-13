import Foundation

enum CKStage: String { case key, manifest, playback }
enum CKOpenFailure: Error { case http(Int), invalidManifest, startupTimeout, unexpectedLiveEnd }

enum CKManifest {
    enum Kind { case dash, hls }
    static func validatedURL(_ data: Data, response: HTTPURLResponse, keySet: CKKeySet? = nil) throws -> URL {
        guard (200..<300).contains(response.statusCode) else { throw CKOpenFailure.http(response.statusCode) }
        guard data.count <= 2 * 1024 * 1024, let url = response.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw CKOpenFailure.invalidManifest }
        let kind = try kind(data)
        if keySet?.requiresKeyMap == true, kind != .dash { throw CKFailure.unsupportedMultiKeyManifest }
        return url
    }
    static func kind(_ data: Data) throws -> Kind {
        guard data.count <= 2 * 1024 * 1024 else { throw CKOpenFailure.invalidManifest }
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{feff}"))).hasPrefix("#EXTM3U") == true { return .hls }
        let xml = String(decoding: data, as: UTF8.self).uppercased()
        guard !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else { throw CKOpenFailure.invalidManifest }
        let reader = RootReader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.root == "MPD" else { throw CKOpenFailure.invalidManifest }
        return .dash
    }
    private final class RootReader: NSObject, XMLParserDelegate {
        var root: String?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            if root == nil { root = elementName.split(separator: ":").last.map(String.init) }
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
            case .unexpectedLiveEnd: return "Live source stopped unexpectedly. Tap Play to retry."
            }
        }
        if case CKFailure.multipleKeys = error { return "Provider key: one-key-only operation received multiple distinct keys." }
        if case CKFailure.unsupportedMultiKeyManifest = error { return "Manifest: multikey playback currently requires DASH/CENC. HLS multikey is not implemented." }
        if case CKFailure.invalidKey = error { return "Provider key: unsupported key map/JWKS response." }
        if case CKFailure.invalidMetadata = error { return "Playlist metadata: invalid/conflicting DRM declaration or unsafe header." }
        if case CKFailure.unsupportedMetadata = error { return "Playlist metadata: declared header/parameter scope is not implemented. It was not silently ignored." }
        if case CKFailure.unsupportedLicense = error { return "Provider key: unsupported request/body/response or persistent-session policy. No guessed GET, body or key was used." }
        if case CKFailure.missingKeyIDs = error { return "Manifest: no valid declared CENC key IDs for the license request." }
        if case CKFailure.missingLicenseKey = error { return "Provider key: response is missing a requested key ID." }
        if case CKFailure.responseTooLarge = error { return "\(step): response exceeds the safe size limit." }
        if case CKFailure.unsafeRedirect = error { return "\(step): unsafe or excessive redirect was blocked." }
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
    static func trace(_ message: String) { NSLog("[CKBridge CK12] %@", message) }
}
