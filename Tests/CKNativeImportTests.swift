import AVFoundation
import Foundation
import ObjectiveC
import UIKit
import XCTest
@testable import CKBridge

enum CKNativeFixtures {
    static func asyncLoad(_ name: String, urlAPI: Bool = false) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:18761/native/\(name)/list.m3u")!
        if urlAPI { return try await session.data(from: url) }
        return try await session.data(for: URLRequest(url: url))
    }
    static func load(_ sessionName: String, mode: String = "list.m3u", requestAPI: Bool = false,
                     download: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "http://127.0.0.1:18761/native/\(sessionName)/\(mode)")!
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("native-original", forHTTPHeaderField: "X-Owned")
        return try await withCheckedThrowingContinuation { continuation in
            if download {
                let done: (URL?, URLResponse?, Error?) -> Void = { file, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    do {
                        let data = try Data(contentsOf: XCTUnwrap(file))
                        continuation.resume(returning: (data, try XCTUnwrap(response as? HTTPURLResponse)))
                    } catch { continuation.resume(throwing: error) }
                }
                let task = requestAPI ? session.downloadTask(with: request, completionHandler: done) :
                    session.downloadTask(with: url, completionHandler: done)
                task.resume()
            } else {
                let done: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    do { continuation.resume(returning: (try XCTUnwrap(data), try XCTUnwrap(response as? HTTPURLResponse))) }
                    catch { continuation.resume(throwing: error) }
                }
                let task = requestAPI ? session.dataTask(with: request, completionHandler: done) :
                    session.dataTask(with: url, completionHandler: done)
                task.resume()
            }
        }
    }
    static func media(_ session: String) -> URL {
        URL(string: "http://127.0.0.1:18761/live/\(session)/manifest.mpd")!
    }
}

// Ordinary app-owned delegates; their class names are not hard-coded by the bridge.
class CKNativeDataProbe: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate {
    var bytes = Data(), received = 0, completed = 0, downloads = 0
    var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bytes.append(data); received += 1
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        bytes = (try? Data(contentsOf: location)) ?? Data(); downloads += 1
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completed += 1
        let callback = continuation; continuation = nil
        if let error { callback?.resume(throwing: error) }
        else if let response = task.response as? HTTPURLResponse { callback?.resume(returning: (bytes, response)) }
        else { callback?.resume(throwing: CKFailure.network) }
    }
    func load(_ name: String, mode: String = "list.m3u", download: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.timeoutIntervalForResource = 10
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:18761/native/\(name)/\(mode)")!
        var request = URLRequest(url: url); request.setValue("native-original", forHTTPHeaderField: "X-Owned")
        return try await withCheckedThrowingContinuation { callback in
            continuation = callback
            let task: URLSessionTask = download ? session.downloadTask(with: request) : session.dataTask(with: request)
            task.resume()
        }
    }
}
final class CKNativeInheritedProbe: CKNativeDataProbe {}
final class CKNativeOverrideProbe: CKNativeDataProbe {
    var childReceived = 0, childCompleted = 0, childDownloads = 0
    override func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        childReceived += 1; super.urlSession(session, dataTask: dataTask, didReceive: data)
    }
    override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        childCompleted += 1; super.urlSession(session, task: task, didCompleteWithError: error)
    }
    override func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        childDownloads += 1; super.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
    }
}

final class CKNativeImportTests: XCTestCase {
    func testNativeFoundationAsyncRequestLearnsPlaylist() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var target: AnyClass? = type(of: session), methods: Set<String> = []
        while let current = target {
            var count: UInt32 = 0
            if let list = class_copyMethodList(current, &count) {
                for index in 0..<Int(count) {
                    let name = NSStringFromSelector(method_getName(list[index]))
                    if name.contains("dataTask") && name.contains("completion") { methods.insert(name) }
                }
                free(list)
            }
            target = class_getSuperclass(current)
        }
        print("OWNED FOUNDATION COMPLETION SELECTORS: \(methods.sorted())")
        let url = URL(string: "http://127.0.0.1:18761/native/nativeasync/list.m3u")!
        let (data, response) = try await session.data(for: URLRequest(url: url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("#EXTM3U\n"))
        XCTAssertNotNil(CKRegistry.shared.channel(CKNativeFixtures.media("nativeasync")))
    }

    func testNativeFoundationAsyncURLLearnsPlaylist() async throws {
        let (data, response) = try await CKNativeFixtures.asyncLoad("nativeasyncurl", urlAPI: true)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("#EXTM3U\n"))
        XCTAssertNotNil(CKRegistry.shared.channel(CKNativeFixtures.media("nativeasyncurl")))
    }

    func testNativeDelegateWithoutKnownClassNameLearnsBeforeOriginalCompletion() async throws {
        let probe = CKNativeDataProbe()
        let (data, response) = try await probe.load("nativedelegate")
        XCTAssertEqual(response.value(forHTTPHeaderField: "X-Owned-Header"), "native-original")
        XCTAssertGreaterThan(probe.received, 0); XCTAssertEqual(probe.completed, 1)
        XCTAssertEqual(data, probe.bytes)
        XCTAssertNotNil(CKRegistry.shared.channel(CKNativeFixtures.media("nativedelegate")))
    }

    func testNativeInheritedDelegateRemainsIdempotentAcrossSessions() async throws {
        _ = try await CKNativeDataProbe().load("nativeparent")
        let probe = CKNativeInheritedProbe()
        for name in ["nativeinheritedone", "nativeinheritedtwo"] {
            probe.bytes = Data(); probe.completed = 0
            let (_, response) = try await probe.load(name)
            XCTAssertEqual(response.statusCode, 200); XCTAssertEqual(probe.completed, 1)
            XCTAssertNotNil(CKRegistry.shared.channel(CKNativeFixtures.media(name)))
        }
    }

    func testNativeOverrideCallingSuperPreservesBothOriginalCallbacks() async throws {
        _ = try await CKNativeDataProbe().load("nativeparentoverride")
        let probe = CKNativeOverrideProbe()
        let (data, response) = try await probe.load("nativeoverride")
        XCTAssertGreaterThan(probe.received, 0); XCTAssertEqual(probe.childReceived, probe.received)
        XCTAssertEqual(probe.childCompleted, 1); XCTAssertEqual(probe.completed, 1)
        XCTAssertEqual(CKPlaylist.parse(data, relativeTo: response.url).count, 1)
        let channel = try XCTUnwrap(CKRegistry.shared.channel(CKNativeFixtures.media("nativeoverride")))
        XCTAssertEqual(try CKKeys.parse(Data(channel.keySource.utf8)).count, 2)
    }

    func testNativeDelegatedRedirectUsesFinalResponseURL() async throws {
        let (_, response) = try await CKNativeDataProbe().load("nativedelegateredirect", mode: "redirect")
        XCTAssertEqual(response.url?.path, "/native/nativedelegateredirect/list.m3u")
        XCTAssertNotNil(CKRegistry.shared.channel(CKNativeFixtures.media("nativedelegateredirect")))
    }

    func testNativeDelegatedDownloadKeepsOriginalFileAndCompletion() async throws {
        let probe = CKNativeOverrideProbe()
        let (data, response) = try await probe.load("nativedelegatedownload", download: true)
        XCTAssertEqual(response.statusCode, 200); XCTAssertEqual(probe.downloads, 1)
        XCTAssertEqual(probe.childDownloads, 1); XCTAssertEqual(probe.completed, 1)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("#EXTM3U\n"))
        XCTAssertNotNil(CKRegistry.shared.channel(CKNativeFixtures.media("nativedelegatedownload")))
    }

    func testNativeDelegatedFailedAndOrdinaryResponsesDoNotRoute() async throws {
        for (name, mode, status) in [("nativedelegatefailed", "denied", 403), ("nativedelegateplain", "plain", 200)] {
            let probe = CKNativeDataProbe()
            let (data, response) = try await probe.load(name, mode: mode)
            XCTAssertEqual(response.statusCode, status); XCTAssertFalse(data.isEmpty)
            XCTAssertEqual(probe.completed, 1)
            XCTAssertNil(CKRegistry.shared.channel(CKNativeFixtures.media(name)))
            XCTAssertFalse(CKRuntime.routeURL(CKNativeFixtures.media(name)))
        }
    }

    func testOfficialModeIsExplicitAndDoesNotChangeExperimentalDefault() {
        XCTAssertFalse(CKPresentation.usesNativeLinks([:]))
        XCTAssertFalse(CKPresentation.usesNativeLinks(["CKNativeLinkMode":false]))
        XCTAssertTrue(CKPresentation.usesNativeLinks(["CKNativeLinkMode":true]))
    }

    @MainActor
    func testOfficialHostCannotInstallOrOpenSeparateTestInputPanel() {
        XCTAssertTrue(CKPresentation.nativeLinks)
        XCTAssertEqual(CKPresentation.playbackLabel, "ClearKey")
        let top = CKRuntime.top()
        CKRuntime.installPanel(); CKRuntime.showPanel()
        XCTAssertTrue(CKRuntime.top() === top)
        func containsTestButton(_ view: UIView) -> Bool {
            (view as? UIButton)?.title(for: .normal) == "CK TEST" || view.subviews.contains(where: containsTestButton)
        }
        XCTAssertFalse(UIApplication.shared.windows.contains { containsTestButton($0) })
    }

    func testNativeURLCompletionLearnsPlaylistBeforeDeliveringOriginalData() async throws {
        let (data, response) = try await CKNativeFixtures.load("nativeurl")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("#EXTM3U\n"))
        let channel = try XCTUnwrap(CKRegistry.shared.channel(CKNativeFixtures.media("nativeurl")))
        XCTAssertEqual(channel.title, "Owned native import")
        XCTAssertEqual(try CKKeys.parse(Data(channel.keySource.utf8)).count, 2)
    }

    func testNativeRequestCompletionPreservesHeadersAndResponse() async throws {
        let (_, response) = try await CKNativeFixtures.load("nativerequest", requestAPI: true)
        XCTAssertEqual(response.value(forHTTPHeaderField: "X-Owned-Header"), "native-original")
        XCTAssertNotNil(CKRegistry.shared.channel(CKNativeFixtures.media("nativerequest")))
    }

    func testNativeRedirectUsesFinalPlaylistURLForRelativeMedia() async throws {
        let (_, response) = try await CKNativeFixtures.load("nativeredirect", mode: "redirect")
        XCTAssertEqual(response.url?.path, "/native/nativeredirect/list.m3u")
        XCTAssertNotNil(CKRegistry.shared.channel(CKNativeFixtures.media("nativeredirect")))
    }

    func testNativeDownloadURLAndRequestLearnBeforeOriginalTempFileCallback() async throws {
        for (name, request) in [("nativedownloadurl", false), ("nativedownloadrequest", true)] {
            let (data, response) = try await CKNativeFixtures.load(name, requestAPI: request, download: true)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("#EXTM3U\n"))
            XCTAssertNotNil(CKRegistry.shared.channel(CKNativeFixtures.media(name)))
        }
    }

    func testNativeFailedResponseAndOrdinaryPlaylistPassThroughWithoutRouting() async throws {
        let (denied, response) = try await CKNativeFixtures.load("nativedenied", mode: "denied")
        XCTAssertEqual(response.statusCode, 403); XCTAssertFalse(denied.isEmpty)
        XCTAssertNil(CKRegistry.shared.channel(CKNativeFixtures.media("nativedenied")))
        let (plain, _) = try await CKNativeFixtures.load("nativeplain", mode: "plain")
        XCTAssertTrue(String(decoding: plain, as: UTF8.self).contains("Owned native import"))
        XCTAssertNil(CKRegistry.shared.channel(CKNativeFixtures.media("nativeplain")))
        XCTAssertFalse(CKRuntime.routeURL(CKNativeFixtures.media("nativeplain")))
    }
}
