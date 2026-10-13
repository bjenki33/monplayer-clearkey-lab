import AVFoundation
import Foundation
import UIKit
import XCTest
@testable import CKBridge

enum CKNativeFixtures {
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

final class CKNativeImportTests: XCTestCase {
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
