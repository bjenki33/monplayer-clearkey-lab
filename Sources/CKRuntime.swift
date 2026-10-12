import AVFoundation
import Foundation
import KSPlayer
import Libavutil
import UIKit

@objc(CKRuntime) public final class CKRuntime: NSObject {
    private static var active: CKPlaybackController?
    private static var opening = false
    private static var panelButton: UIButton?
    @objc(observe:source:) public static func observe(_ data: Data, source: URL?) {
        CKRegistry.shared.observe(data, source: source)
    }
    @objc(route:) public static func route(_ item: AVPlayerItem) -> Bool {
        guard let asset = item.asset as? AVURLAsset else { return false }; return routeURL(asset.url)
    }
    @objc(routeURL:) public static func routeURL(_ url: URL) -> Bool {
        guard placeholderItem() != nil, let channel = CKRegistry.shared.channel(url) else { return false }
        DispatchQueue.main.async { open(channel) }
        return true
    }
    @objc public static func placeholderItem() -> AVPlayerItem? {
        guard let url = Bundle(for: CKRuntime.self).url(forResource: "CKPlaceholder", withExtension: "mp4") else { return nil }
        return AVPlayerItem(url: url)
    }
    static func top() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap { $0.windows }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first ?? UIApplication.shared.windows.first)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        if let navigation = top as? UINavigationController { return navigation.visibleViewController }
        return top
    }
    static func open(_ channel: CKChannel) {
        guard !opening, active == nil, let top = top() else { return }
        opening = true
        let controller = CKPlaybackController(channel: channel)
        controller.onClose = { active = nil; opening = false }
        active = controller
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .fullScreen
        top.present(navigation, animated: true) { opening = false }
    }
    @objc public static func installPanel() {
        guard panelButton == nil, let window = top()?.view.window else { return }
        let button = UIButton(type: .system)
        button.setTitle("CK TEST", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 11, weight: .bold)
        button.backgroundColor = .systemOrange; button.setTitleColor(.black, for: .normal)
        button.layer.cornerRadius = 14; button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(showPanel), for: .touchUpInside)
        window.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            button.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -90),
            button.widthAnchor.constraint(equalToConstant: 72), button.heightAnchor.constraint(equalToConstant: 32)
        ])
        panelButton = button
        CKDiagnostic.trace("panel installed")
    }
    @objc static func showPanel() {
        guard active == nil, let presenter = top() else { return }
        let navigation = UINavigationController(rootViewController: CKPlaylistController())
        navigation.modalPresentationStyle = .pageSheet
        presenter.present(navigation, animated: true)
    }
}

final class CKPlaylistController: UITableViewController {
    let input = UITextField()
    let status = UILabel()
    var channels = CKRegistry.shared.all()
    var task: URLSessionDataTask?
    override func viewDidLoad() {
        super.viewDidLoad(); title = "ClearKey Test"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        view.backgroundColor = .systemBackground
        let header = UIStackView(); header.axis = .vertical; header.spacing = 10
        header.frame = CGRect(x: 0, y: 0, width: 320, height: 162)
        header.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16); header.isLayoutMarginsRelativeArrangement = true
        input.placeholder = "Paste playlist URL (not saved)"; input.borderStyle = .roundedRect
        input.isSecureTextEntry = true; input.autocapitalizationType = .none; input.autocorrectionType = .no
        input.keyboardType = .URL; header.addArrangedSubview(input)
        let load = UIButton(type: .system); load.setTitle("Load ClearKey channels", for: .normal)
        load.addTarget(self, action: #selector(loadPlaylist), for: .touchUpInside); header.addArrangedSubview(load)
        status.font = .systemFont(ofSize: 12); status.numberOfLines = 2
        status.text = "\(channels.count) ClearKey entries observed. Widevine is not handled."
        header.addArrangedSubview(status); tableView.tableHeaderView = header
    }
    @objc func close() { task?.cancel(); dismiss(animated: true) }
    @objc func loadPlaylist() {
        guard let url = URL(string: input.text ?? ""), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            status.text = "Enter a valid HTTP(S) playlist URL."; return
        }
        input.resignFirstResponder(); task?.cancel(); status.text = "Loading playlist..."
        var request = URLRequest(url: url); request.timeoutInterval = 30
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        task = session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil, let data, let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode) else { self.status.text = "Playlist request failed. Check access and retry."; return }
                self.channels = CKPlaylist.parse(data, relativeTo: response.url)
                CKRegistry.shared.observe(data, source: response.url)
                self.input.text = nil
                self.status.text = "\(self.channels.count) ClearKey channels. Tap a channel to test."
                self.tableView.reloadData()
            }
        }; task?.resume()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { channels.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = channels[indexPath.row].title; cell.detailTextLabel?.text = "ClearKey / experimental"
        cell.accessoryType = .disclosureIndicator; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let channel = channels[indexPath.row]
        dismiss(animated: true) { CKRuntime.open(channel) }
    }
}

final class CKPlaybackController: UIViewController, KSPlayerLayerDelegate {
    let channel: CKChannel
    let status = UILabel()
    var layer: KSPlayerLayer?
    var keyTask: URLSessionDataTask?
    var manifestTask: URLSessionDataTask?
    var watchdog: DispatchWorkItem?
    var openingStream = false
    var onClose: (() -> Void)?
    var finished = false
    private var idleBefore = false
    init(channel: CKChannel) { self.channel = channel; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = channel.title; view.backgroundColor = .black
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        let controls = UIStackView(); controls.axis = .vertical; controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(controls)
        status.textColor = .white; status.font = .systemFont(ofSize: 13); status.numberOfLines = 3
        status.text = "ClearKey test: resolving provider-supplied key..."; controls.addArrangedSubview(status)
        let buttons = UIStackView(); buttons.distribution = .fillEqually
        for (title, selector) in [("Play", #selector(play)), ("Pause", #selector(pause))] {
            let button = UIButton(type: .system); button.setTitle(title, for: .normal)
            button.addTarget(self, action: selector, for: .touchUpInside); buttons.addArrangedSubview(button)
        }; controls.addArrangedSubview(buttons)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            controls.heightAnchor.constraint(equalToConstant: 104)
        ])
        idleBefore = UIApplication.shared.isIdleTimerDisabled
        resolve()
    }
    func resolve() {
        guard !finished, !openingStream else { return }
        openingStream = true
        status.text = "CK2: resolving provider-supplied key..."
        CKDiagnostic.trace("key request started")
        let source = channel.keySource.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let url = URL(string: source[0]), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            do { openManifest(key: try CKKeys.defaultKey(CKKeys.parse(Data(source[0].utf8)))) }
            catch { fail(error, stage: .key) }; return
        }
        var headers = channel.headers
        if source.count == 2 { CKPlaylist.mergeHeaders(source[1], into: &headers) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        keyTask = session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                if let error { self.fail(error, stage: .key); return }
                guard let data, data.count <= 1024 * 1024, let response = response as? HTTPURLResponse else {
                    self.fail(CKFailure.network, stage: .key); return
                }
                guard (200..<300).contains(response.statusCode) else { self.fail(CKOpenFailure.http(response.statusCode), stage: .key); return }
                do { self.openManifest(key: try CKKeys.defaultKey(CKKeys.parse(data))) }
                catch { self.fail(error, stage: .key) }
            }
        }; keyTask?.resume()
    }
    func openManifest(key: String) {
        status.text = "CK2: checking DASH/HLS and source redirects..."
        CKDiagnostic.trace("manifest request started")
        var request = URLRequest(url: channel.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        channel.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        manifestTask = session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                if let error { self.fail(error, stage: .manifest); return }
                guard let data, let response = response as? HTTPURLResponse else { self.fail(CKFailure.network, stage: .manifest); return }
                do {
                    let url = try CKManifest.validatedURL(data, response: response)
                    self.start(key, url: url)
                } catch { self.fail(error, stage: .manifest) }
            }
        }; manifestTask?.resume()
    }
    func start(_ key: String, url: URL) {
        guard !finished else { return }
        KSOptions.logLevel = .panic
        av_log_set_level(AV_LOG_QUIET)
        KSOptions.firstPlayerType = KSMEPlayer.self; KSOptions.secondPlayerType = nil
        let options = KSOptions(); options.isAutoPlay = false; options.hardwareDecode = true
        options.preferredForwardBufferDuration = 3; options.maxBufferDuration = 12
        options.appendHeader(channel.headers)
        options.formatContextOptions["cenc_decryption_key"] = key
        options.formatContextOptions["decryption_key"] = key
        options.formatContextOptions["rw_timeout"] = 20_000_000
        options.formatContextOptions["tls_verify"] = 1
        CKDiagnostic.trace("validated manifest; player starting")
        let player = KSPlayerLayer(url: url, options: options, delegate: self)
        layer = player; player.translatesAutoresizingMaskIntoConstraints = false; view.insertSubview(player, at: 0)
        NSLayoutConstraint.activate([
            player.leadingAnchor.constraint(equalTo: view.leadingAnchor), player.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            player.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            player.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -126)
        ])
        status.text = "CK2: opening DASH/ClearKey on-device..."
        watchdog?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.fail(CKOpenFailure.startupTimeout, stage: .playback) }
        watchdog = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        player.play()
    }
    func fail(_ error: Error, stage: CKStage = .playback) {
        guard !finished else { return }
        watchdog?.cancel(); watchdog = nil; openingStream = false
        let player = layer; layer = nil
        player?.pause(); player?.player.shutdown(); player?.removeFromSuperview()
        status.text = CKDiagnostic.message(error, stage: stage)
        CKDiagnostic.trace(status.text ?? "playback error")
    }
    @objc func play() { if let layer { layer.play() } else { resolve() } }
    @objc func pause() { layer?.pause() }
    @objc func close() {
        finished = true; keyTask?.cancel(); manifestTask?.cancel(); watchdog?.cancel()
        layer?.pause(); layer?.player.shutdown(); layer?.removeFromSuperview(); layer = nil
        UIApplication.shared.isIdleTimerDisabled = idleBefore
        dismiss(animated: true) { self.onClose?() }
    }
    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard layer === self.layer, !finished else { return }
        if state == .bufferFinished { watchdog?.cancel(); watchdog = nil; openingStream = false }
        status.text = "CK2: \(state.description)."
        CKDiagnostic.trace("player state: \(state.description)")
    }
    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        if layer === self.layer, currentTime > 0 { watchdog?.cancel(); watchdog = nil }
    }
    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard layer === self.layer, !finished else { return }
        if let error { fail(error) }
    }
    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
}
