import AVFoundation
import Foundation

final class CKNativeWarmRedirect: NSObject, AVAssetResourceLoaderDelegate {
    let store: CKNativeStore
    let httpURL: URL
    let url: URL
    private let queue = DispatchQueue(label: "CKNativeWarmRedirect")
    private var jobs: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(store: CKNativeStore, httpURL: URL) {
        self.store = store; self.httpURL = httpURL
        url = URL(string: "mpclearkey://\(store.token)/index.m3u8")!
    }
    func attach(_ asset: AVURLAsset) { asset.resourceLoader.setDelegate(self, queue: queue) }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url == url else { return false }
        let id = ObjectIdentifier(request)
        jobs[id] = Task.detached { [weak self] in
            guard let self else { return }
            let ready = self.store.waitUntilReady(seconds: 25, interrupted: { Task.isCancelled })
            self.queue.async {
                self.jobs.removeValue(forKey: id)
                guard !request.isCancelled, !request.isFinished else { return }
                if ready {
                    request.redirect = URLRequest(url: self.httpURL)
                    request.response = HTTPURLResponse(url: self.httpURL, statusCode: 302, httpVersion: "HTTP/1.1",
                                                       headerFields: ["Location": self.httpURL.absoluteString])
                    request.finishLoading()
                } else {
                    request.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData))
                }
            }
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        jobs.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }
    deinit { jobs.values.forEach { $0.cancel() } }
}
