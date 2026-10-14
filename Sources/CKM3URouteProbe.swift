import Foundation
import UIKit

// Gate0 is observation only. These tags never authorize a screen replacement
// or invoke an original app route/player method.
enum CKM3UProbePolicy {
    static let names: [String: String] = [
        "ProviderM3UDetailScreen": "m3u-provider", "GroupM3UDetailScreen": "m3u-group",
        "ChannelM3UModel": "m3u-channel-model", "GroupM3UModel": "m3u-group-model",
        "ProviderJsonDetailScreen": "json-provider", "GroupJsonDetailScreen": "json-group",
        "ChannelJsonDetailScreen": "json-channel", "ChannelJsonModel": "json-channel-model",
        "PlayerScreen": "player-screen", "PlayerScreen_iPad": "player-screen-ipad",
        "PlayerViewController": "player-controller", "PlayerViewModel": "player-model",
        "AppRouter": "router", "AppRoute": "route", "AppRouteName": "route-name",
        "NavigationCoordinator": "coordinator", "Source": "source"
    ]
    static let cases: [String: String] = [
        "providerM3UDetail": "case-m3u-provider", "groupM3UDetail": "case-m3u-group",
        "providerJsonDetail": "case-json-provider", "groupJsonDetail": "case-json-group",
        "channelJsonDetail": "case-json-channel", "player": "case-player", "streamLoading": "case-stream-loading"
    ]
    static let fields: Set<String> = [
        "rootView", "_rootView", "root", "host", "content", "storage", "_storage",
        "view", "base", "value", "_value", "object", "_object", "subject", "inner",
        "appRouter", "_appRouter", "router", "_router", "path", "_path", "routes",
        "route", "currentRoute", "navigationCoordinator", "navigationController",
        "currentSource", "_currentSource", "channelSelected", "_channelSelected",
        "channelViewModel", "_channelViewModel", "playerViewModel", "_playerViewModel"
    ]
    static func enabled(_ info: [String: Any]) -> Bool {
        (info["CKM3URouteProbeMode"] as? Bool) == true &&
            (info["CKNativeLinkMode"] as? Bool) == true &&
            (info["CKOriginalPlayerMode"] as? Bool) == true
    }
    static func tags(typeName: String) -> Set<String> {
        guard typeName.utf8.count <= 8192 else { return [] }
        let tokens = typeName.split { "<>, ()&".contains($0) }.map(String.init)
        return Set(names.compactMap { name, tag in tokens.contains("MonPlayer." + name) ? tag : nil })
    }
    static func traversable(_ typeName: String) -> Bool {
        guard typeName.utf8.count <= 8192 else { return false }
        return ["MonPlayer.", "SwiftUI.", "Combine.", "Swift.Optional<", "Swift.Array<",
                "Swift.ContiguousArray<", "Swift._", "UIKit."].contains { typeName.hasPrefix($0) } ||
            typeName.hasPrefix("(")
    }
    static func branch(_ tags: Set<String>) -> String {
        let m3u = tags.contains("m3u-provider") || tags.contains("m3u-group") ||
            tags.contains("case-m3u-provider") || tags.contains("case-m3u-group")
        let json = tags.contains("json-provider") || tags.contains("json-group") || tags.contains("json-channel") ||
            tags.contains("case-json-provider") || tags.contains("case-json-group") || tags.contains("case-json-channel")
        if m3u && json { return "ambiguous" }
        if tags.contains("player-screen") || tags.contains("player-screen-ipad") || tags.contains("player-controller") ||
            tags.contains("case-player") || tags.contains("case-stream-loading") {
            return "player-candidate"
        }
        return m3u ? "m3u-candidate" : json ? "json-candidate" : "unknown"
    }
}

struct CKM3UProbeSnapshot: Equatable {
    var tags: Set<String> = [], fields: Set<String> = []
    var visited = 0, truncated = false
    var summary: String {
        "branch=\(CKM3UProbePolicy.branch(tags)) nodes=\(visited) limited=\(truncated ? 1 : 0) " +
            "tags=\(tags.sorted().joined(separator: ",")) fields=\(fields.sorted().joined(separator: ","))"
    }
}

enum CKM3UProbeReflection {
    static func snapshot(_ roots: [Any], nodes: Int = 256, depth: Int = 18,
                         seconds: TimeInterval = 0.012,
                         typeNameFor: (Any) -> String = { String(reflecting: type(of: $0)) }) -> CKM3UProbeSnapshot {
        var result = CKM3UProbeSnapshot(), queue = roots.prefix(64).map { ($0, 0) }
        var cursor = 0, objects: Set<ObjectIdentifier> = []
        let began = ProcessInfo.processInfo.systemUptime
        while cursor < queue.count {
            guard result.visited < max(0, min(nodes, 256)),
                  ProcessInfo.processInfo.systemUptime - began < max(0, min(seconds, 0.012)) else {
                result.truncated = true; break
            }
            let (value, level) = queue[cursor]; cursor += 1; result.visited += 1
            let typeName = typeNameFor(value)
            result.tags.formUnion(CKM3UProbePolicy.tags(typeName: typeName))
            guard CKM3UProbePolicy.traversable(typeName), level < max(0, min(depth, 18)) else { continue }
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .class {
                guard objects.insert(ObjectIdentifier(value as AnyObject)).inserted else { continue }
            }
            var current: Mirror? = mirror
            var ancestors = 0
            while let reflected = current, ancestors < 4 {
                for child in reflected.children.prefix(32) {
                    if let name = child.label {
                        if CKM3UProbePolicy.fields.contains(name) { result.fields.insert(name) }
                        if reflected.displayStyle == .enum, let tag = CKM3UProbePolicy.cases[name],
                           typeName.hasPrefix("MonPlayer.AppRoute") { result.tags.insert(tag) }
                    }
                    let childType = typeNameFor(child.value)
                    if CKM3UProbePolicy.traversable(childType), queue.count < 512 {
                        queue.append((child.value, level + 1))
                    }
                }
                current = reflected.superclassMirror; ancestors += 1
            }
        }
        return result
    }
}

@MainActor
final class CKM3URouteProbe {
    static let shared = CKM3URouteProbe()
    private var timer: Timer?
    private var ticks = 0, emitted = 0
    private var previous: CKM3UProbeSnapshot?
    private var foregroundSeconds: TimeInterval = 0
    private var lastTick: TimeInterval?
    var isRunning: Bool { timer != nil }
    func start(info: [String: Any]) {
        guard CKM3UProbePolicy.enabled(info), timer == nil, ticks == 0 else { return }
        CKDiagnostic.trace("m3u-probe start observation-only")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }
    private func tick() {
        guard timer != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastTick = now }
        guard UIApplication.shared.applicationState == .active else { return }
        foregroundSeconds += min(1, max(0, now - (lastTick ?? now)))
        ticks += 1
        guard foregroundSeconds < 240, ticks <= 300, emitted < 48 else { stop(); return }
        guard let controller = CKRuntime.top() else { return }
        var roots: [Any] = [controller]
        var views: [UIView] = controller.viewIfLoaded.map { [$0] } ?? [], cursor = 0
        while cursor < views.count, cursor < 64 {
            let view = views[cursor]; cursor += 1
            guard !view.isHidden, view.window != nil else { continue }
            let name = String(reflecting: type(of: view))
            if name.hasPrefix("SwiftUI.") || name.hasPrefix("MonPlayer.") { roots.append(view) }
            for child in view.subviews.prefix(16) where views.count < 128 { views.append(child) }
        }
        let snapshot = CKM3UProbeReflection.snapshot(roots)
        if previous?.tags != snapshot.tags || previous?.fields != snapshot.fields || previous == nil {
            previous = snapshot; emitted += 1
            CKDiagnostic.trace("m3u-probe state \(snapshot.summary)")
        }
    }
    func stop() {
        guard timer != nil else { return }
        timer?.invalidate(); timer = nil
        CKDiagnostic.trace("m3u-probe stop observation-only")
    }
}
