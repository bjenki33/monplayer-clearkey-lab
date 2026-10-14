import AVFoundation
import Foundation
import ObjectiveC

final class CKNativePlayback {
    let store = CKNativeStore()
    let http: CKNativeHTTP
    let channel: CKChannel
    private let lock = NSLock()
    private var resolution: Task<Void, Never>?
    private var worker: CKNativeRemux?
    private var stopped = false, wantsPlaying = false
    private var changes = 0, acquisitions = 0
    init(channel: CKChannel) throws { self.channel = channel; http = try CKNativeHTTP(store: store) }
    var stats: [String: Int] {
        lock.lock(); let counts = ["key_changes": changes, "new_acquisitions": acquisitions]; lock.unlock()
        return store.stats.merging(counts) { _, new in new }
    }
    func start() {
        resolution = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await CKSourceResolver.resolve(channel)
                try Task.checkCancellation()
                let remux = CKNativeRemux(source: source, headers: channel.headers, store: store)
                guard install(remux) else { return }
                remux.start()
                guard var state = CKRotationState.begin(channel: channel, source: source) else { return }
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(state.interval * 1_000_000_000))
                    guard !remux.finished else { return }
                    if remux.paused { continue }
                    let update = try await CKKeyRotation.refresh(channel, state: state)
                    try Task.checkCancellation()
                    state = update.state
                    if update.changed {
                        remux.update(CKResolvedSource(keys: state.keys, data: update.data, url: update.url,
                                                      keySeconds: 0, manifestSeconds: 0))
                        changed(fetched: update.fetched)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                fail()
            }
        }
    }
    private func install(_ value: CKNativeRemux) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        worker = value; value.playing(wantsPlaying); return true
    }
    private func changed(fetched: Bool) {
        lock.lock(); defer { lock.unlock() }
        changes += 1; if fetched { acquisitions += 1 }
    }
    private func fail() {
        lock.lock(); let current = worker; lock.unlock()
        current?.stop(); store.close(failure: true)
        CKDiagnostic.trace("native media source failed; original player owns the error UI")
    }
    func playing(_ value: Bool) {
        lock.lock(); wantsPlaying = value; let current = worker; lock.unlock()
        current?.playing(value)
    }
    func stop() {
        lock.lock(); guard !stopped else { lock.unlock(); return }
        stopped = true; let task = resolution, current = worker; resolution = nil; worker = nil; lock.unlock()
        task?.cancel(); current?.stop(); http.stop()
    }
}

@objc(CKNativeAssetContext) final class CKNativeAssetContext: NSObject {
    let session: CKNativePlayback
    let loader: CKNativeWarmRedirect
    init(_ session: CKNativePlayback) {
        self.session = session; loader = CKNativeWarmRedirect(store: session.store, httpURL: session.http.url)
    }
    @objc var url: URL { loader.url }
    @objc(attach:) func attach(_ asset: AVAsset) {
        if let asset = asset as? AVURLAsset { loader.attach(asset) }
        CKNativeItems.attach(self, to: asset)
        session.start()
    }
    deinit { session.stop() }
}

enum CKNativeItems {
    private static var association: UInt8 = 0
    static func prepare(_ channel: CKChannel) throws -> CKNativeAssetContext {
        let session = try CKNativePlayback(channel: channel)
        return CKNativeAssetContext(session)
    }
    static func attach(_ context: CKNativeAssetContext, to asset: AVAsset) {
        objc_setAssociatedObject(asset, &association, context, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    static func session(_ item: AVPlayerItem?) -> CKNativePlayback? {
        guard let item else { return nil }
        return (objc_getAssociatedObject(item.asset, &association) as? CKNativeAssetContext)?.session
    }
}
