import Foundation

enum CKNativeStartup {
    struct Timeline: Equatable {
        let availability: String
        let periodID: String?
        let periodStart: String?
        let videoClocks: [String]
    }
    static func timeline(_ data: Data) -> Timeline? {
        guard data.count <= 2 * 1024 * 1024 else { return nil }
        let text = String(decoding: data, as: UTF8.self).uppercased()
        guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { return nil }
        let reader = Reader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.live, reader.periods == 1, !reader.invalidClock,
              !reader.videoClocks.isEmpty, let availability = reader.availability,
              availability.utf8.count <= 128,
              (reader.periodID?.utf8.count ?? 0) <= 128, (reader.periodStart?.utf8.count ?? 0) <= 128 else { return nil }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if dates.date(from: availability) == nil {
            dates.formatOptions = [.withInternetDateTime]
            guard dates.date(from: availability) != nil else { return nil }
        }
        return Timeline(availability: availability, periodID: reader.periodID, periodStart: reader.periodStart,
                        videoClocks: reader.videoClocks.sorted())
    }
    static func liveDelay(_ data: Data) -> Int {
        guard data.count <= 2 * 1024 * 1024 else { return 12 }
        let text = String(decoding: data, as: UTF8.self).uppercased()
        guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { return 12 }
        let reader = Reader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.live, let duration = reader.maximum else { return 12 }
        // Three output GOPs need the following input keyframe to close. Allow
        // one more source fragment for DASH's edge/rounding,not future media.
        let limit = reader.window.map { Int(min(30, max(1, floor($0)))) } ?? 30
        return min(limit, max(12, Int(ceil(duration * 5))))
    }

    private final class Reader: NSObject, XMLParserDelegate {
        struct Scope { var video = false; var timescale: Double? }
        var scopes: [Scope] = []
        var live = false
        var maximum: Double?
        var window: TimeInterval?
        var availability: String?, periodID: String?, periodStart: String?
        var periods = 0
        var videoClocks: Set<String> = []
        var invalidClock = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            guard scopes.count < 64 else { parser.abortParsing(); return }
            let local = name.split(separator: ":").last.map(String.init) ?? ""
            if scopes.isEmpty && local != "MPD" { parser.abortParsing(); return }
            var scope = scopes.last ?? Scope()
            if local == "MPD" {
                live = attributes["type"] == "dynamic"
                window = attributes["timeShiftBufferDepth"].flatMap(CKRotationCadence.seconds)
                availability = attributes["availabilityStartTime"]
            }
            if local == "Period" {
                guard scopes.count == 1 else { parser.abortParsing(); return }
                periods += 1; periodID = attributes["id"]; periodStart = attributes["start"]
            }
            if local == "AdaptationSet" || local == "Representation" {
                scope.video = scope.video || attributes["contentType"] == "video" ||
                    attributes["mimeType"]?.hasPrefix("video/") == true
            }
            if local == "SegmentTemplate" {
                scope.timescale = Double(attributes["timescale"] ?? "1").flatMap {
                    $0.isFinite && $0 > 0 && $0 <= 1_000_000_000_000 ? $0 : nil
                }
                if scope.video {
                    let scale = attributes["timescale"] ?? "1"
                    let offset = attributes["presentationTimeOffset"] ?? "0"
                    if scope.timescale == nil || scale.utf8.count > 32 || offset.utf8.count > 32 || UInt64(offset) == nil {
                        invalidClock = true
                    } else {
                        videoClocks.insert(scale + ":" + offset)
                        if videoClocks.count > 32 { invalidClock = true; parser.abortParsing() }
                    }
                }
                record(attributes["duration"], scope: scope)
            } else if local == "S" { record(attributes["d"], scope: scope) }
            scopes.append(scope)
        }
        private func record(_ value: String?, scope: Scope) {
            guard scope.video, let scale = scope.timescale, let value, value.utf8.count <= 32,
                  let units = Double(value), units.isFinite, units > 0 else { return }
            let duration = units / scale
            guard duration.isFinite, duration > 0, duration <= 12 else { return }
            maximum = max(maximum ?? 0, duration)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            _ = scopes.popLast()
        }
    }
}
