import Foundation

struct CKRotationState {
    let keys: CKKeySet
    let ids: [String]
    let interval: TimeInterval

    static func begin(channel: CKChannel, source: CKResolvedSource) -> CKRotationState? {
        guard let interval = CKRotationCadence.read(source.data),
              let ids = try? CKManifestKeyIDs.read(source.data), source.keys.contains(ids) else { return nil }
        // Remote legacy GETs keep their accepted no-poll/single-key behavior.
        guard channel.license.body?.needsKeyIDs == true ||
              (source.keys.requiresKeyMap && (try? channel.keyRequest()) == nil) else { return nil }
        return CKRotationState(keys: source.keys, ids: ids, interval: interval)
    }
}

struct CKRotationUpdate {
    let state: CKRotationState
    let data: Data
    let url: URL
    let changed: Bool
    let fetched: Bool
}

enum CKKeyRotation {
    static func refresh(_ channel: CKChannel, state: CKRotationState) async throws -> CKRotationUpdate {
        var stage = CKStage.manifest
        do {
            let (data, response) = try await CKSourceResolver.manifest(channel)
            guard let interval = CKRotationCadence.read(data) else { throw CKFailure.unsupportedLicense }
            let ids = try CKManifestKeyIDs.read(data)
            let changed = ids != state.ids
            let fetched = !state.keys.contains(ids)
            var keys = state.keys
            if fetched {
                stage = .key
                guard channel.license.body?.needsKeyIDs == true else { throw CKFailure.missingLicenseKey }
                keys = try keys.including(await CKSourceResolver.keys(channel, ids: ids))
            }
            guard keys.contains(ids) else { throw CKFailure.missingLicenseKey }
            stage = .manifest
            let url = try CKManifest.validatedURL(data, response: response, keySet: keys)
            try Task.checkCancellation()
            return CKRotationUpdate(state: CKRotationState(keys: keys, ids: ids, interval: interval),
                                    data: data, url: url, changed: changed, fetched: fetched)
        } catch { throw CKResolutionError(stage: stage, underlying: error) }
    }
}

enum CKRotationCadence {
    static func read(_ data: Data) -> TimeInterval? {
        guard (try? CKManifest.kind(data)) == .dash else { return nil }
        let reader = Reader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), !reader.invalid, reader.dynamic, reader.periods == 1, let value = reader.interval else { return nil }
        return min(60, max(2, value))
    }

    static func seconds(_ text: String) -> TimeInterval? {
        guard text.utf8.count <= 48,
              let match = text.range(of: #"^PT(?:[0-9]+(?:\.[0-9]+)?H)?(?:[0-9]+(?:\.[0-9]+)?M)?(?:[0-9]+(?:\.[0-9]+)?S)?$"#, options: .regularExpression),
              match == text.startIndex..<text.endIndex, text != "PT" else { return nil }
        let expression = try! NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)([HMS])"#)
        let source = text as NSString
        var total = TimeInterval(0)
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let number = Double(source.substring(with: match.range(at: 1))) else { return nil }
            let unit = source.substring(with: match.range(at: 2))
            total += number * (unit == "H" ? 3600 : unit == "M" ? 60 : 1)
        }
        return total.isFinite && total > 0 ? total : nil
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var dynamic = false, invalid = false, interval: TimeInterval?, periods = 0, depth = 0
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String:String]) {
            if depth == 0 {
                dynamic = attributes["type"] == "dynamic"
                interval = attributes["minimumUpdatePeriod"].flatMap(CKRotationCadence.seconds)
            }
            if name.split(separator: ":").last == "Period" {
                if depth != 1 { invalid = true }
                periods += 1
            }
            depth += 1
            if depth > 64 { invalid = true; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            depth -= 1
        }
    }
}
