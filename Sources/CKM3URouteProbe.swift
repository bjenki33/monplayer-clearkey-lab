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
    static let focusedTags: Set<String> = ["focused-root", "focused-router", "focused-path", "focused-route"]
    static var allowedTags: Set<String> { Set(names.values).union(cases.values).union(focusedTags) }
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
    static func exactTags(typeName: String) -> Set<String> {
        guard typeName.hasPrefix("MonPlayer."), !typeName.dropFirst("MonPlayer.".count).contains(".") else { return [] }
        let name = String(typeName.dropFirst("MonPlayer.".count))
        if let tag = names[name] { return [tag] }
        return []
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
    var limits: Set<String> = []
    var visited = 0, truncated = false
    var summary: String {
        "branch=\(CKM3UProbePolicy.branch(tags)) nodes=\(visited) limited=\(truncated ? 1 : 0) " +
            "tags=\(tags.sorted().joined(separator: ",")) fields=\(fields.sorted().joined(separator: ","))"
    }
    mutating func merge(_ other: CKM3UProbeSnapshot) {
        tags.formUnion(other.tags); fields.formUnion(other.fields); limits.formUnion(other.limits)
        visited = min(256, visited + other.visited)
        truncated = truncated || other.truncated
    }
}

struct CKM3UProbeScanResult {
    let snapshot: CKM3UProbeSnapshot
    // Retained only for the current tick so the focused walker can start at the
    // exact router already proven by the bounded generic traversal.
    let focusedRouter: Any?
}

enum CKM3UProbeReflection {
    static let limitNames: Set<String> = Set(["roots", "nodes", "time", "depth", "children", "ancestors", "queue", "types"])
        .union(CKM3UFocusedRouteReflection.limitNames)
    private static func priority(label: String?, typeName: String) -> Int {
        if ["rootView", "_rootView", "root", "appRouter", "_appRouter", "router", "_router",
            "path", "_path", "route", "routes", "currentRoute", "navigationCoordinator"].contains(label ?? "") { return 0 }
        if ["storage", "_storage", "content", "base", "value", "_value", "object", "_object", "inner"].contains(label ?? "") { return 1 }
        if typeName.hasPrefix("Swift.Optional<") || typeName.hasPrefix("MonPlayer.") { return 2 }
        return 3
    }
    static func snapshot(_ roots: [Any], nodes: Int = 256, depth: Int = 18,
                         seconds: TimeInterval = 0.012,
                         typeNameFor: ((Any) -> String)? = nil,
                         clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> CKM3UProbeSnapshot {
        scan(roots, nodes: nodes, depth: depth, seconds: seconds,
             typeNameFor: typeNameFor, clock: clock).snapshot
    }
    static func scan(_ roots: [Any], nodes: Int = 256, depth: Int = 18,
                     seconds: TimeInterval = 0.012,
                     typeNameFor: ((Any) -> String)? = nil,
                     clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> CKM3UProbeScanResult {
        var result = CKM3UProbeSnapshot(), pending = roots.prefix(64).reversed().map { ($0, 0) }
        var focusedRouter: Any?
        var scheduled = pending.count, objects: Set<ObjectIdentifier> = []
        var typeNames: [ObjectIdentifier: String] = [:]
        func limit(_ reason: String) { result.truncated = true; result.limits.insert(reason) }
        func name(_ value: Any) -> String {
            let identity = ObjectIdentifier(type(of: value))
            if typeNameFor == nil, let cached = typeNames[identity] { return cached }
            let raw = typeNameFor?(value) ?? String(reflecting: type(of: value))
            let bounded: String
            if raw.utf8.count <= 8192 { bounded = raw } else { limit("types"); bounded = "" }
            if typeNameFor == nil, typeNames.count < 256 { typeNames[identity] = bounded }
            return bounded
        }
        if roots.count > 64 { limit("roots") }
        let began = clock()
        while !pending.isEmpty {
            guard result.visited < max(0, min(nodes, 256)) else { limit("nodes"); break }
            guard clock() - began < max(0, min(seconds, 0.012)) else { limit("time"); break }
            let (value, level) = pending.removeLast(); result.visited += 1
            let typeName = name(value)
            if focusedRouter == nil, typeName == "MonPlayer.AppRouter" { focusedRouter = value }
            result.tags.formUnion(CKM3UProbePolicy.tags(typeName: typeName))
            guard CKM3UProbePolicy.traversable(typeName) else { continue }
            guard level < max(0, min(depth, 18)) else { limit("depth"); continue }
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .class {
                guard objects.insert(ObjectIdentifier(value as AnyObject)).inserted else { continue }
            }
            var current: Mirror? = mirror
            var ancestors = 0
            var children: [(value: Any, priority: Int, order: Int)] = []
            while let reflected = current, ancestors < 4 {
                for (index, child) in reflected.children.prefix(33).enumerated() {
                    if index == 32 { limit("children"); break }
                    guard clock() - began < max(0, min(seconds, 0.012)) else { limit("time"); break }
                    if let name = child.label {
                        if CKM3UProbePolicy.fields.contains(name) { result.fields.insert(name) }
                        if reflected.displayStyle == .enum, let tag = CKM3UProbePolicy.cases[name],
                           typeName.hasPrefix("MonPlayer.AppRoute") { result.tags.insert(tag) }
                    }
                    let childType = name(child.value)
                    if CKM3UProbePolicy.traversable(childType) {
                        children.append((child.value, priority(label: child.label, typeName: childType), children.count))
                    }
                }
                current = reflected.superclassMirror; ancestors += 1
                if result.limits.contains("time") { break }
            }
            if ancestors == 4 && current != nil { limit("ancestors") }
            let ordered = children.sorted { ($0.priority, $0.order) < ($1.priority, $1.order) }
            let available = max(0, 512 - scheduled)
            if ordered.count > available { limit("queue") }
            let next = ordered.prefix(available)
            scheduled += next.count
            // Descend the selected root/router chain before unrelated sibling views.
            pending.append(contentsOf: next.reversed().map { ($0.value, level + 1) })
        }
        return CKM3UProbeScanResult(snapshot: result, focusedRouter: focusedRouter)
    }
}

// This narrow walker follows only the known SwiftUI root/router/path chain. It
// never formats payload values and cannot invoke navigation or player methods.
enum CKM3UFocusedRouteReflection {
    static let maximumNodes = 64
    static let maximumDepth = 28
    static let maximumSeconds: TimeInterval = 0.006
    static let limitNames: Set<String> = [
        "focus-roots", "focus-nodes", "focus-time", "focus-depth", "focus-children",
        "focus-ancestors", "focus-queue", "focus-types"
    ]
    private enum Stage: Equatable { case root, router, path }
    private struct Pending { let value: Any; let level: Int; let stage: Stage }
    private static let rootLabels: Set<String> = [
        "rootView", "_rootView", "root", "host", "content", "storage", "_storage",
        "view", "base", "value", "_value", "object", "_object", "subject", "inner",
        "some", "modifier", "first", "second", "trueContent", "falseContent"
    ]
    private static let routerLabels: Set<String> = ["appRouter", "_appRouter", "router", "_router"]
    private static let pathLabels: Set<String> = ["path", "_path", "routes", "route", "currentRoute"]

    private static func wrapper(_ typeName: String) -> Bool {
        ["Swift.Optional<", "Swift.Array<", "Swift.ContiguousArray<", "SwiftUI.", "Combine.Published<"]
            .contains { typeName.hasPrefix($0) }
    }

    static func snapshot(_ roots: [Any], nodes: Int = 64, depth: Int = 28,
                         seconds: TimeInterval = 0.006,
                         typeNameFor: ((Any) -> String)? = nil,
                         clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> CKM3UProbeSnapshot {
        var result = CKM3UProbeSnapshot()
        var pending = roots.prefix(16).reversed().map { Pending(value: $0, level: 0, stage: .root) }
        var scheduled = pending.count, objects: Set<ObjectIdentifier> = []
        var typeNames: [ObjectIdentifier: String] = [:]
        func limit(_ reason: String) { result.truncated = true; result.limits.insert(reason) }
        func name(_ value: Any) -> String {
            let identity = ObjectIdentifier(type(of: value))
            if typeNameFor == nil, let cached = typeNames[identity] { return cached }
            let raw = typeNameFor?(value) ?? String(reflecting: type(of: value))
            let bounded: String
            if raw.utf8.count <= 4096 { bounded = raw } else { limit("focus-types"); bounded = "" }
            if typeNameFor == nil, typeNames.count < 64 { typeNames[identity] = bounded }
            return bounded
        }
        if roots.count > 16 { limit("focus-roots") }
        let began = clock()
        while !pending.isEmpty {
            guard result.visited < max(0, min(nodes, maximumNodes)) else { limit("focus-nodes"); break }
            guard clock() - began < max(0, min(seconds, maximumSeconds)) else { limit("focus-time"); break }
            var item = pending.removeLast(); result.visited += 1
            let typeName = name(item.value)
            result.tags.formUnion(CKM3UProbePolicy.exactTags(typeName: typeName))
            if typeName == "MonPlayer.AppRouter" {
                item = Pending(value: item.value, level: item.level, stage: .router)
                result.tags.formUnion(["router", "focused-router"])
            } else if typeName == "MonPlayer.AppRoute" {
                item = Pending(value: item.value, level: item.level, stage: .path)
                result.tags.formUnion(["route", "focused-route"])
            }
            let traversable: Bool
            switch item.stage {
            case .root:
                traversable = wrapper(typeName) || typeName.hasPrefix("UIKit.") || typeName.hasPrefix("MonPlayer.")
            case .router:
                traversable = typeName == "MonPlayer.AppRouter" || wrapper(typeName)
            case .path:
                traversable = typeName == "MonPlayer.AppRoute" || wrapper(typeName)
            }
            guard traversable else { continue }
            guard item.level < max(0, min(depth, maximumDepth)) else { limit("focus-depth"); continue }
            let mirror = Mirror(reflecting: item.value)
            if mirror.displayStyle == .class {
                guard objects.insert(ObjectIdentifier(item.value as AnyObject)).inserted else { continue }
            }
            var current: Mirror? = mirror, ancestors = 0
            var children: [(Pending, Int, Int)] = []
            while let reflected = current, ancestors < 4 {
                for (index, child) in reflected.children.prefix(17).enumerated() {
                    if index == 16 { limit("focus-children"); break }
                    guard clock() - began < max(0, min(seconds, maximumSeconds)) else { limit("focus-time"); break }
                    let label = child.label
                    if let label, CKM3UProbePolicy.fields.contains(label) { result.fields.insert(label) }
                    if typeName == "MonPlayer.AppRoute", reflected.displayStyle == .enum,
                       let label, let tag = CKM3UProbePolicy.cases[label] { result.tags.insert(tag) }
                    let childType = name(child.value)
                    let exactRouter = childType == "MonPlayer.AppRouter"
                    let exactRoute = childType == "MonPlayer.AppRoute"
                    let nextStage: Stage?
                    let priority: Int
                    if exactRouter || routerLabels.contains(label ?? "") {
                        nextStage = .router; priority = 0
                    } else if item.stage == .router && pathLabels.contains(label ?? "") {
                        nextStage = .path; priority = 0
                        result.tags.insert("focused-path")
                    } else if item.stage == .path && (exactRoute || wrapper(childType) || reflected.displayStyle == .collection) {
                        nextStage = .path; priority = exactRoute ? 0 : 1
                    } else if item.stage == .root && rootLabels.contains(label ?? "") {
                        nextStage = .root; priority = 1
                        if ["rootView", "_rootView"].contains(label ?? "") { result.tags.insert("focused-root") }
                    } else {
                        nextStage = nil; priority = 3
                    }
                    if let nextStage {
                        children.append((Pending(value: child.value, level: item.level + 1, stage: nextStage),
                                         priority, children.count))
                    }
                }
                current = reflected.superclassMirror; ancestors += 1
                if result.limits.contains("focus-time") { break }
            }
            if ancestors == 4 && current != nil { limit("focus-ancestors") }
            let ordered = children.sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            let available = max(0, 128 - scheduled)
            if ordered.count > available { limit("focus-queue") }
            let next = ordered.prefix(available)
            scheduled += next.count
            pending.append(contentsOf: next.reversed().map { $0.0 })
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
    private let evidenceURL: URL?
    private var evidence: CKM3UProbeEvidence?
    private var missingControllerTicks = 0
    init(evidenceURL: URL? = CKM3UProbeEvidence.defaultURL) { self.evidenceURL = evidenceURL }
    var isRunning: Bool { timer != nil }
    func start(info: [String: Any]) {
        guard CKM3UProbePolicy.enabled(info), timer == nil, ticks == 0 else { return }
        if let url = evidenceURL {
            evidence = CKM3UProbeEvidence(url: url)
            evidence?.update(.started, ticks: 0, seconds: 0)
        }
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
        if ticks % 15 == 0 {
            evidence?.update(nil, ticks: ticks, seconds: foregroundSeconds, missingControllerTicks: missingControllerTicks)
        }
        guard let controller = CKRuntime.top() else { missingControllerTicks += 1; return }
        var roots: [Any] = [controller]
        var views: [UIView] = controller.viewIfLoaded.map { [$0] } ?? [], cursor = 0
        while cursor < views.count, cursor < 64 {
            let view = views[cursor]; cursor += 1
            guard !view.isHidden, view.window != nil else { continue }
            let name = String(reflecting: type(of: view))
            if name.hasPrefix("SwiftUI.") || name.hasPrefix("MonPlayer.") { roots.append(view) }
            for child in view.subviews.prefix(16) where views.count < 128 { views.append(child) }
        }
        let scan = CKM3UProbeReflection.scan(roots)
        var snapshot = scan.snapshot
        if let router = scan.focusedRouter {
            snapshot.merge(CKM3UFocusedRouteReflection.snapshot([router]))
        }
        if previous?.tags != snapshot.tags || previous?.fields != snapshot.fields || previous == nil {
            previous = snapshot; emitted += 1
            evidence?.update(.sample, ticks: ticks, seconds: foregroundSeconds,
                             missingControllerTicks: missingControllerTicks, snapshot: snapshot)
            CKDiagnostic.trace("m3u-probe state \(snapshot.summary)")
        }
    }
    func stop() {
        guard timer != nil else { return }
        timer?.invalidate(); timer = nil
        evidence?.update(.stopped, ticks: ticks, seconds: foregroundSeconds, missingControllerTicks: missingControllerTicks)
        CKDiagnostic.trace("m3u-probe stop observation-only")
    }
}
