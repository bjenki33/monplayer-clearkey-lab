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
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        task = session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil, let data, let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode) else { self.status.text = "Playlist request failed. Check access and retry."; return }
                guard let report = CKPlaylist.report(data, relativeTo: response.url) else {
                    self.status.text = "Source did not return a valid bounded M3U playlist."; return
                }
                self.channels = report.channels
                CKRegistry.shared.observe(data, source: response.url)
                self.input.text = nil
                self.status.text = "\(self.channels.count) ClearKey entries. \(report.metadataIssues) unsupported/invalid metadata entries. Tap to test."
                self.tableView.reloadData()
            }
        }; task?.resume()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { channels.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = channels[indexPath.row].title; cell.detailTextLabel?.text = "ClearKey / experimental"
        if channels[indexPath.row].metadataFailure != nil { cell.detailTextLabel?.text = "Unsupported/invalid ClearKey metadata" }
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
    private var resolutionTask: Task<Void, Never>?
    private var resolutionID = UUID()
    private var rotationTask: Task<Void, Never>?
    private var pendingRotation: CKRotationUpdate?
    private var userPaused = false
    private(set) var keyRebuilds = 0
    private(set) var keyAcquisitions = 0
    var watchdog: DispatchWorkItem?
    var openingStream = false
    var onClose: (() -> Void)?
    var finished = false
    var metrics = CKPlaybackMetrics(now: ProcessInfo.processInfo.systemUptime)
    var playerOptions: KSOptions?
    var makeLiveOptions: (CKDASHSelection) -> CKLiveOptions = { CKLiveOptions(declaredFrameRate: $0.frameRate) }
    private var idleBefore = false
    init(channel: CKChannel) { self.channel = channel; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = channel.title; view.backgroundColor = .black
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        let controls = UIStackView(); controls.axis = .vertical; controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(controls)
        status.textColor = .white; status.font = .systemFont(ofSize: 12); status.numberOfLines = 4
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
        resolutionTask?.cancel()
        resolutionID = UUID()
        let id = resolutionID
        metrics = CKPlaybackMetrics(now: ProcessInfo.processInfo.systemUptime)
        status.text = channel.license.body?.needsKeyIDs == true ? "CK11: preparing declared DASH license challenge..." : "CK11: resolving provider keys and source..."
        CKDiagnostic.trace("isolated source resolution started")
        resolutionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await CKSourceResolver.resolve(self.channel)
                guard !Task.isCancelled, !self.finished, self.resolutionID == id else { return }
                self.resolutionTask = nil
                self.metrics.keySeconds = result.keySeconds; self.metrics.manifestSeconds = result.manifestSeconds
                self.start(result.keys, url: result.url, selection: CKDASHSelection.plan(result.data))
                self.watchKeyChanges(result, id: id)
            } catch {
                guard !Task.isCancelled, !self.finished, self.resolutionID == id else { return }
                self.resolutionTask = nil
                if let failure = error as? CKResolutionError { self.fail(failure.underlying, stage: failure.stage) }
                else { self.fail(error, stage: .key) }
            }
        }
    }
    private func watchKeyChanges(_ source: CKResolvedSource, id: UUID) {
        rotationTask?.cancel(); pendingRotation = nil
        guard let initial = CKRotationState.begin(channel: channel, source: source) else { return }
        rotationTask = Task { [weak self] in
            var state = initial
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(state.interval * 1_000_000_000))
                    guard let self, !self.finished, self.resolutionID == id, self.layer != nil else { return }
                    guard !self.userPaused, self.pendingRotation == nil, !self.openingStream,
                          self.layer?.state != .paused else { continue }
                    let update = try await CKKeyRotation.refresh(self.channel, state: state)
                    guard !Task.isCancelled, !self.finished, self.resolutionID == id else { return }
                    state = update.state
                    if update.changed {
                        if self.userPaused || self.layer?.state == .paused { self.pendingRotation = update }
                        else { self.applyRotation(update) }
                    }
                }
            } catch {
                guard let self, !Task.isCancelled, !self.finished, self.resolutionID == id else { return }
                if let failure = error as? CKResolutionError { self.fail(failure.underlying, stage: failure.stage) }
                else { self.fail(error, stage: .key) }
            }
        }
    }
    private func applyRotation(_ update: CKRotationUpdate) {
        guard !finished, update.changed else { return }
        // Pinned set(url:same,options:new) skips replacement. Tear down the old
        // public player and create a fresh context that actually reads the map.
        let old = layer
        layer = nil; old?.delegate = nil; old?.pause(); old?.player.shutdown(); old?.removeFromSuperview()
        watchdog?.cancel(); watchdog = nil; playerOptions = nil
        keyRebuilds += 1; if update.fetched { keyAcquisitions += 1 }
        openingStream = true
        CKDiagnostic.trace("declared key change; decoder rebuild \(keyRebuilds); new acquisitions \(keyAcquisitions)")
        start(update.state.keys, url: update.url, selection: CKDASHSelection.plan(update.data))
    }
    func start(_ keys: CKKeySet, url: URL, selection: CKDASHSelection?) {
        guard !finished else { return }
        KSOptions.logLevel = .panic
        av_log_set_level(AV_LOG_QUIET)
        KSOptions.firstPlayerType = KSMEPlayer.self; KSOptions.secondPlayerType = nil
        let options: KSOptions
        if let selection {
            let live = makeLiveOptions(selection)
            if channel.license.body?.needsKeyIDs == true { live.useLicensedStartupReserve() }
            options = live
        }
        else { options = KSOptions() }
        options.isAutoPlay = false; options.hardwareDecode = true
        if let selection {
            options.formatContextOptions["ck_video_representation"] = selection.id
            CKDiagnostic.trace("single DASH video: \(selection.height)p / \(selection.bandwidth)bps / \(selection.renditionCount) declared variants")
        } else {
            options.preferredForwardBufferDuration = 3; options.maxBufferDuration = 12
        }
        playerOptions = options
        options.appendHeader(channel.headers)
        keys.formatOptions.forEach { options.formatContextOptions[$0.key] = $0.value }
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
        status.text = "CK11: opening ClearKey on-device (\(keys.distinctKeyCount) distinct keys)..."
        if !userPaused { armWatchdog(); player.play() }
    }
    private func armWatchdog() {
        watchdog?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.fail(CKOpenFailure.startupTimeout, stage: .playback) }
        watchdog = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }
    func fail(_ error: Error, stage: CKStage = .playback) {
        guard !finished else { return }
        resolutionID = UUID(); resolutionTask?.cancel(); resolutionTask = nil
        rotationTask?.cancel(); rotationTask = nil; pendingRotation = nil
        watchdog?.cancel(); watchdog = nil; openingStream = false
        let snapshot = (playerOptions as? CKLiveOptions)?.capacitySnapshot ?? ""
        let player = layer; layer = nil; playerOptions = nil
        player?.pause(); player?.player.shutdown(); player?.removeFromSuperview()
        status.text = CKDiagnostic.message(error, stage: stage) + "\n" + metrics.compact + "\n" + snapshot
        CKDiagnostic.trace(status.text ?? "playback error")
    }
    @objc func play() {
        userPaused = false
        if let update = pendingRotation { pendingRotation = nil; applyRotation(update); return }
        if let layer {
            if layer.state == .paused { metrics.resumedByUser() }
            if openingStream { armWatchdog() }
            layer.play()
        } else { resolve() }
    }
    @objc func pause() { userPaused = true; watchdog?.cancel(); watchdog = nil; layer?.pause() }
    @objc func close() {
        finished = true; resolutionID = UUID(); resolutionTask?.cancel(); resolutionTask = nil; watchdog?.cancel()
        rotationTask?.cancel(); rotationTask = nil; pendingRotation = nil
        layer?.pause(); layer?.player.shutdown(); layer?.removeFromSuperview(); layer = nil; playerOptions = nil
        UIApplication.shared.isIdleTimerDisabled = idleBefore
        dismiss(animated: true) { self.onClose?() }
    }
    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard layer === self.layer, !finished else { return }
        if state == .paused {
            userPaused = true; watchdog?.cancel(); watchdog = nil
        } else if state.isPlaying, userPaused {
            // The SDK's remote controls resume its layer directly,not Play here.
            userPaused = false; metrics.resumedByUser()
            if let update = pendingRotation { pendingRotation = nil; applyRotation(update); return }
            if openingStream { armWatchdog() }
        }
        if state == .bufferFinished { watchdog?.cancel(); watchdog = nil; openingStream = false }
        metrics.state(buffering: state == .buffering, playable: state == .bufferFinished,
                      now: ProcessInfo.processInfo.systemUptime)
        updateStatus(state)
        CKDiagnostic.trace("player state: \(state.description); \(metrics.summary)")
        if state == .readyToPlay, let options = playerOptions {
            let probe = max(0, options.findTime - options.openTime)
            CKDiagnostic.trace(String(format: "format probe %.2fs", probe))
        }
    }
    // Audio timestamps can advance while video is still buffering; only the
    // bufferFinished state above is allowed to disarm the startup deadline.
    private var lastStatusUpdate = TimeInterval(0)
    private func updateStatus(_ state: KSPlayerState) {
        let snapshot = (playerOptions as? CKLiveOptions)?.capacitySnapshot ?? ""
        let renewal = keyRebuilds == 0 ? "" : " / Keys \(keyRebuilds) (new \(keyAcquisitions))"
        status.text = "CK11: \(state.description).\n\(metrics.compact)\(renewal)\n\(snapshot)"
    }
    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard layer === self.layer, !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastStatusUpdate >= 1 {
            lastStatusUpdate = now
            updateStatus(layer.state)
        }
    }
    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard layer === self.layer, !finished else { return }
        if let error { fail(error) }
        else if playerOptions is CKLiveOptions, !userPaused { fail(CKOpenFailure.unexpectedLiveEnd) }
    }
    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        guard layer === self.layer, !finished, consumeTime.isFinite, consumeTime >= 0 else { return }
        CKDiagnostic.trace(String(format: "buffer event %d: %.2fs", bufferedCount, consumeTime))
    }
}
