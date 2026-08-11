import AVKit
import MediaPlayer
import SwiftUI

private final class FloatingVideoPlayerView: AVPlayerView {
    var onVolumeScroll: ((Double) -> Void)?
    private let volumeScrollInterpreter = PlayerVolumeScrollInterpreter()

    override func scrollWheel(with event: NSEvent) {
        let adjustment = volumeScrollInterpreter.adjustment(for: event)
        if adjustment != 0 { onVolumeScroll?(adjustment) }
    }

    override func swipe(with event: NSEvent) {
        // Consume swipe momentum for the same reason as scroll-wheel events.
    }
}

final class PictureInPicturePlayerView: NSView {
    let playerLayer = AVPlayerLayer()
    var onVolumeScroll: ((Double) -> Void)?
    private var scrollEventMonitor: Any?
    private let volumeScrollInterpreter = PlayerVolumeScrollInterpreter()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.needsDisplayOnBoundsChange = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.needsDisplayOnBoundsChange = true
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeScrollEventMonitor()
        guard window != nil else { return }
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window,
                  self.shouldConsumeScrollEvent(event, in: window) else { return event }
            self.handleVolumeScroll(event)
            return nil
        }
    }

    override func scrollWheel(with event: NSEvent) {
        handleVolumeScroll(event)
    }

    override func swipe(with event: NSEvent) {
        // Consume trackpad swipe phases over the video as well as scroll-wheel
        // phases so momentum cannot escape through SwiftUI's hosting wrapper.
    }

    private func shouldConsumeScrollEvent(_ event: NSEvent, in window: NSWindow) -> Bool {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint), let contentView = window.contentView else { return false }
        let contentPoint = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(contentPoint) else { return false }

        if hitView === self || hitView.isDescendant(of: self) { return true }

        // SwiftUI may report its transparent hosting wrapper as the hit target
        // instead of this representable. Consume that case, but leave sibling
        // controls such as the chapter scroll view alone.
        return self.isDescendant(of: hitView) && !(hitView is NSScrollView)
    }

    private func handleVolumeScroll(_ event: NSEvent) {
        let adjustment = volumeScrollInterpreter.adjustment(for: event)
        if adjustment != 0 { onVolumeScroll?(adjustment) }
    }

    private func removeScrollEventMonitor() {
        guard let scrollEventMonitor else { return }
        NSEvent.removeMonitor(scrollEventMonitor)
        self.scrollEventMonitor = nil
    }

    deinit {
        removeScrollEventMonitor()
    }
}

private final class PlayerVolumeScrollInterpreter {
    private enum Axis {
        case horizontal
        case vertical
    }

    private var lockedAxis: Axis?
    private var accumulatedX = 0.0
    private var accumulatedY = 0.0

    func adjustment(for event: NSEvent) -> Double {
        if event.phase.contains(.began) { reset() }

        let shouldReset = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        defer { if shouldReset { reset() } }

        guard event.momentumPhase.isEmpty else { return 0 }

        if event.phase.isEmpty {
            guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) * 0.8 else { return 0 }
            return PlayerVolumeScrollPolicy.adjustment(
                deltaX: 0,
                deltaY: event.scrollingDeltaY,
                isPrecise: event.hasPreciseScrollingDeltas,
                isMomentum: false
            )
        }

        if event.hasPreciseScrollingDeltas {
            accumulatedX += event.scrollingDeltaX
            accumulatedY += event.scrollingDeltaY
            if lockedAxis == nil {
                let largestDistance = max(abs(accumulatedX), abs(accumulatedY))
                guard largestDistance >= 0.75 else { return 0 }
                lockedAxis = abs(accumulatedY) >= abs(accumulatedX) * 0.8
                    ? .vertical
                    : .horizontal
            }
        } else {
            lockedAxis = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
                ? .vertical
                : .horizontal
        }

        guard lockedAxis == .vertical else { return 0 }
        return PlayerVolumeScrollPolicy.adjustment(
            deltaX: 0,
            deltaY: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas,
            isMomentum: false
        )
    }

    private func reset() {
        lockedAxis = nil
        accumulatedX = 0
        accumulatedY = 0
    }
}

enum PlayerVolumeScrollPolicy {
    static func adjustment(
        deltaX: Double,
        deltaY: Double,
        isPrecise: Bool,
        isMomentum: Bool
    ) -> Double {
        guard !isMomentum,
              deltaY.isFinite,
              abs(deltaY) > abs(deltaX),
              abs(deltaY) >= 0.05 else { return 0 }

        if isPrecise {
            return min(0.08, max(-0.08, deltaY * 0.006))
        }
        return deltaY > 0 ? 0.05 : -0.05
    }
}

struct PlayerSeekRequest: Equatable {
    let id = UUID()
    let time: Double
    let shouldPlay: Bool
}

struct PlaybackSnapshot: Equatable {
    var currentTime: Double = 0
    var duration: Double = 0
    var isPlaying = false
    var isMuted = false
    var volume: Double = PlaybackVolumePreference.load()
    var playbackRate: Double = 1
    var isExternalPlaybackActive = false

    static var empty: PlaybackSnapshot {
        PlaybackSnapshot(playbackRate: PlaybackRatePreference.load())
    }
}

enum NowPlayingInfoBuilder {
    static func make(
        title: String,
        author: String,
        snapshot: PlaybackSnapshot
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "Rewatch" : title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? snapshot.playbackRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.playbackRate
        ]
        if !author.isEmpty {
            info[MPMediaItemPropertyArtist] = author
        }
        if snapshot.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
        }
        return info
    }
}

final class SystemMediaController {
    static let shared = SystemMediaController()

    private var isStarted = false
    private var title = "Rewatch"
    private var author = ""
    private var snapshot = PlaybackSnapshot.empty

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = true
        commands.previousTrackCommand.isEnabled = true
        commands.skipForwardCommand.isEnabled = true
        commands.skipBackwardCommand.isEnabled = true
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.preferredIntervals = [10]

        // Media-key handlers may arrive off the main thread. Consume the
        // command immediately, then perform AVPlayer work on the main queue.
        commands.playCommand.addTarget { _ in
            DispatchQueue.main.async {
                PlaybackCommandCenter.shared.play()
            }
            return .success
        }
        commands.pauseCommand.addTarget { _ in
            DispatchQueue.main.async {
                PlaybackCommandCenter.shared.pause()
            }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { _ in
            DispatchQueue.main.async {
                PlaybackCommandCenter.shared.togglePlayback()
            }
            return .success
        }
        // Mac keyboards report the previous/next media buttons as track
        // commands, while Control Center can report explicit skip commands.
        // Route both forms through the same ten-second seek used by the arrow
        // keys and custom playback controls.
        commands.previousTrackCommand.addTarget { _ in
            DispatchQueue.main.async {
                PlaybackCommandCenter.shared.skip(by: -10)
            }
            return .success
        }
        commands.nextTrackCommand.addTarget { _ in
            DispatchQueue.main.async {
                PlaybackCommandCenter.shared.skip(by: 10)
            }
            return .success
        }
        commands.skipBackwardCommand.addTarget { _ in
            DispatchQueue.main.async {
                PlaybackCommandCenter.shared.skip(by: -10)
            }
            return .success
        }
        commands.skipForwardCommand.addTarget { _ in
            DispatchQueue.main.async {
                PlaybackCommandCenter.shared.skip(by: 10)
            }
            return .success
        }

        publish()
    }

    func setItem(title: String, author: String) {
        self.title = title
        self.author = author
        publish()
    }

    func update(_ snapshot: PlaybackSnapshot) {
        self.snapshot = snapshot
        publish()
    }

    func stop() {
        snapshot.isPlaying = false
        isStarted = false
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = .stopped
        center.nowPlayingInfo = nil
    }

    private func publish() {
        guard isStarted else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = NowPlayingInfoBuilder.make(
            title: title,
            author: author,
            snapshot: snapshot
        )
        center.playbackState = snapshot.isPlaying ? .playing : .paused
    }
}

enum PlaybackRatePolicy {
    static let minimum = 1.0
    static let maximum = 2.5
    static let supportedRates = (10...25).map { Double($0) / 10 }

    static func normalized(_ rate: Double) -> Double {
        guard rate.isFinite else { return minimum }
        let tenths = Int((rate * 10).rounded())
        return Double(min(max(tenths, Int(minimum * 10)), Int(maximum * 10))) / 10
    }

    static func adjusted(_ current: Double, by amount: Double) -> Double {
        normalized(current + amount)
    }
}

enum PlaybackRatePreference {
    private static let key = "playbackRate"

    static func load(from defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: key) != nil else { return PlaybackRatePolicy.minimum }
        return PlaybackRatePolicy.normalized(defaults.double(forKey: key))
    }

    static func save(_ rate: Double, to defaults: UserDefaults = .standard) {
        defaults.set(PlaybackRatePolicy.normalized(rate), forKey: key)
    }
}

enum PlaybackAudioPolicy {
    // Rewatch is primarily speech, and AVFoundation documents time-domain
    // processing as the lower-cost voice algorithm. Unlike the spectral music
    // processor, it can follow interactive rate changes without rebuilding a
    // large analysis window and creating an audible hole.
    static let timePitchAlgorithm: AVAudioTimePitchAlgorithm = .timeDomain

    // Every playable asset is already on disk. Waiting for AVPlayer's network
    // stall predictor after a rate change only adds latency and cannot improve
    // buffering for these local files.
    static let waitsToMinimizeStalling = false
}

enum PlaybackVolumePreference {
    private static let key = "playbackVolume"

    static func normalized(_ volume: Double) -> Double {
        guard volume.isFinite else { return 1 }
        return min(1, max(0, volume))
    }

    static func load(from defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: key) != nil else { return 1 }
        return normalized(defaults.double(forKey: key))
    }

    static func save(_ volume: Double, to defaults: UserDefaults = .standard) {
        defaults.set(normalized(volume), forKey: key)
    }
}

enum PictureInPicturePolicy {
    static func shouldStart(
        isAppActive: Bool,
        isPlaying: Bool,
        reachedEnd: Bool,
        isAlreadyActive: Bool,
        isExternalPlaybackActive: Bool
    ) -> Bool {
        !isAppActive
            && isPlaying
            && !reachedEnd
            && !isAlreadyActive
            && !isExternalPlaybackActive
    }
}

enum FloatingPlayerLayout {
    static let size = NSSize(width: 420, height: 236.25)
    static let margin: CGFloat = 24

    static func frame(in visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.maxX - size.width - margin,
            y: visibleFrame.minY + margin,
            width: size.width,
            height: size.height
        )
    }
}

final class PlaybackCommandCenter {
    static let shared = PlaybackCommandCenter()

    private var activeToken: UUID?
    private weak var routePlayer: AVPlayer?
    private var skipHandler: ((Double) -> Void)?
    private var toggleHandler: (() -> Void)?
    private var setPlayingHandler: ((Bool) -> Void)?
    private var muteHandler: (() -> Void)?
    private var rateHandler: ((Double) -> Void)?
    private var rateSelectionHandler: ((Double) -> Void)?
    private var fullscreenHandler: (() -> Bool)?
    private var fullscreenExitHandler: (() -> Bool)?

    var hasActivePlayer: Bool { activeToken != nil }
    var activeRoutePlayer: AVPlayer? { routePlayer }

    func isActive(_ token: UUID?) -> Bool {
        guard let token else { return false }
        return activeToken == token
    }

    private init() {}

    func register(
        player: AVPlayer? = nil,
        skip: @escaping (Double) -> Void,
        toggle: @escaping () -> Void,
        setPlaying: @escaping (Bool) -> Void,
        mute: @escaping () -> Void,
        adjustRate: @escaping (Double) -> Void,
        setRate: @escaping (Double) -> Void,
        toggleFullscreen: @escaping () -> Bool,
        exitFullscreen: @escaping () -> Bool
    ) -> UUID {
        let token = UUID()
        activeToken = token
        routePlayer = player
        skipHandler = skip
        toggleHandler = toggle
        setPlayingHandler = setPlaying
        muteHandler = mute
        rateHandler = adjustRate
        rateSelectionHandler = setRate
        fullscreenHandler = toggleFullscreen
        fullscreenExitHandler = exitFullscreen
        return token
    }

    func unregister(_ token: UUID) {
        guard token == activeToken else { return }
        activeToken = nil
        routePlayer = nil
        skipHandler = nil
        toggleHandler = nil
        setPlayingHandler = nil
        muteHandler = nil
        rateHandler = nil
        rateSelectionHandler = nil
        fullscreenHandler = nil
        fullscreenExitHandler = nil
    }

    @discardableResult
    func skip(by seconds: Double) -> Bool {
        guard let skipHandler else { return false }
        skipHandler(seconds)
        return true
    }

    @discardableResult
    func togglePlayback() -> Bool {
        guard let toggleHandler else { return false }
        toggleHandler()
        return true
    }

    @discardableResult
    func play() -> Bool {
        guard let setPlayingHandler else { return false }
        setPlayingHandler(true)
        return true
    }

    @discardableResult
    func pause() -> Bool {
        guard let setPlayingHandler else { return false }
        setPlayingHandler(false)
        return true
    }

    @discardableResult
    func toggleMute() -> Bool {
        guard let muteHandler else { return false }
        muteHandler()
        return true
    }

    @discardableResult
    func adjustPlaybackRate(by amount: Double) -> Bool {
        guard let rateHandler else { return false }
        rateHandler(amount)
        return true
    }

    @discardableResult
    func setPlaybackRate(to rate: Double) -> Bool {
        guard let rateSelectionHandler else { return false }
        rateSelectionHandler(PlaybackRatePolicy.normalized(rate))
        return true
    }

    @discardableResult
    func toggleFullscreen() -> Bool {
        fullscreenHandler?() ?? false
    }

    @discardableResult
    func exitFullscreen() -> Bool {
        fullscreenExitHandler?() ?? false
    }
}

struct AirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(.secondaryLabelColor, for: .normal)
        picker.setRoutePickerButtonColor(.labelColor, for: .normalHighlighted)
        picker.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        picker.setRoutePickerButtonColor(.controlAccentColor, for: .activeHighlighted)
        picker.player = PlaybackCommandCenter.shared.activeRoutePlayer
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        if picker.player !== PlaybackCommandCenter.shared.activeRoutePlayer {
            picker.player = PlaybackCommandCenter.shared.activeRoutePlayer
        }
    }
}

struct LocalVideoPlayer: NSViewRepresentable {
    let url: URL
    let title: String
    let author: String
    let resumeAt: Double
    let seekRequest: PlayerSeekRequest?
    let onProgress: (Double) -> Void
    let onStateChange: (PlaybackSnapshot) -> Void
    let onVolumeChange: (Double) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onProgress: onProgress,
            onStateChange: onStateChange,
            onVolumeChange: onVolumeChange,
            onEnded: onEnded
        )
    }

    func makeNSView(context: Context) -> PictureInPicturePlayerView {
        let view = PictureInPicturePlayerView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleVideoClick(_:))
        )
        view.addGestureRecognizer(click)
        context.coordinator.load(url: url, title: title, author: author, resumeAt: resumeAt, into: view)
        return view
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: PictureInPicturePlayerView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: max(0, proposal.width ?? 640),
            height: max(0, proposal.height ?? 360)
        )
    }

    func updateNSView(_ view: PictureInPicturePlayerView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.load(url: url, title: title, author: author, resumeAt: resumeAt, into: view)
            return
        }
        context.coordinator.updateMetadata(title: title, author: author)
        if let seekRequest {
            context.coordinator.seek(to: seekRequest)
        }
    }

    static func dismantleNSView(_ view: PictureInPicturePlayerView, coordinator: Coordinator) {
        coordinator.stop()
        view.playerLayer.player = nil
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        private var player: AVPlayer?
        private weak var playerView: PictureInPicturePlayerView?
        private var backgroundPanel: NSPanel?
        private var backgroundPlayerView: FloatingVideoPlayerView?
        private var applicationObservers: [NSObjectProtocol] = []
        private var backgroundOverlayDismissed = false
        private var endObserver: NSObjectProtocol?
        private var persistenceObserver: Any?
        private var stateObserver: Any?
        private var externalPlaybackObserver: NSKeyValueObservation?
        private var reachedEnd = false
        private let onProgress: (Double) -> Void
        private let onStateChange: (PlaybackSnapshot) -> Void
        private let onVolumeChange: (Double) -> Void
        private let onEnded: () -> Void
        private var lastSeekRequestID: UUID?
        private var commandToken: UUID?
        private var preferredRate: Double = 1
        private var currentTitle = ""
        private var currentAuthor = ""
        fileprivate var currentURL: URL?

        init(
            onProgress: @escaping (Double) -> Void,
            onStateChange: @escaping (PlaybackSnapshot) -> Void,
            onVolumeChange: @escaping (Double) -> Void,
            onEnded: @escaping () -> Void
        ) {
            self.onProgress = onProgress
            self.onStateChange = onStateChange
            self.onVolumeChange = onVolumeChange
            self.onEnded = onEnded
            super.init()
        }

        func load(
            url: URL,
            title: String,
            author: String,
            resumeAt: Double,
            into view: PictureInPicturePlayerView
        ) {
            stop()
            currentURL = url
            currentTitle = title
            currentAuthor = author
            reachedEnd = false
            lastSeekRequestID = nil
            preferredRate = PlaybackRatePreference.load()
            let playerItem = AVPlayerItem(url: url)
            playerItem.audioTimePitchAlgorithm = PlaybackAudioPolicy.timePitchAlgorithm
            let player = AVPlayer(playerItem: playerItem)
            player.allowsExternalPlayback = true
            player.automaticallyWaitsToMinimizeStalling = PlaybackAudioPolicy.waitsToMinimizeStalling
            player.volume = Float(PlaybackVolumePreference.load())
            self.player = player
            playerView = view
            view.playerLayer.player = player
            view.onVolumeScroll = { [weak self] adjustment in
                self?.adjustVolume(by: adjustment)
            }
            backgroundOverlayDismissed = false
            observeApplicationActivation()
            commandToken = PlaybackCommandCenter.shared.register(
                player: player,
                skip: { [weak self] seconds in self?.skip(by: seconds) },
                toggle: { [weak self] in self?.togglePlayback() },
                setPlaying: { [weak self] shouldPlay in self?.setPlayback(shouldPlay) },
                mute: { [weak self] in self?.toggleMute() },
                adjustRate: { [weak self] amount in self?.adjustPlaybackRate(by: amount) },
                setRate: { [weak self] rate in self?.setPlaybackRate(rate) },
                toggleFullscreen: { [weak self] in self?.toggleFullscreen() ?? false },
                exitFullscreen: { [weak self] in self?.exitFullscreen() ?? false }
            )
            SystemMediaController.shared.setItem(title: title, author: author)
            externalPlaybackObserver = player.observe(
                \.isExternalPlaybackActive,
                options: [.initial, .new]
            ) { [weak self] player, _ in
                DispatchQueue.main.async {
                    self?.externalPlaybackChanged(isActive: player.isExternalPlaybackActive)
                }
            }
            persistenceObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 2, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self?.onProgress(seconds)
            }
            stateObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] _ in
                self?.publishSnapshot()
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                self?.reachedEnd = true
                self?.publishSnapshot()
                self?.onEnded()
            }
            if resumeAt > 0 {
                let time = CMTime(seconds: resumeAt, preferredTimescale: 600)
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    self?.publishSnapshot()
                }
            } else {
                publishSnapshot()
            }
        }

        func updateMetadata(title: String, author: String) {
            guard title != currentTitle || author != currentAuthor else { return }
            currentTitle = title
            currentAuthor = author
            if PlaybackCommandCenter.shared.isActive(commandToken) {
                SystemMediaController.shared.setItem(title: title, author: author)
            }
        }

        func seek(to request: PlayerSeekRequest) {
            guard lastSeekRequestID != request.id, let player else { return }
            lastSeekRequestID = request.id
            reachedEnd = false
            let time = CMTime(seconds: max(0, request.time), preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                if request.shouldPlay { self?.startPlayback(player) }
                self?.publishSnapshot()
            }
        }

        private func skip(by seconds: Double) {
            guard let player else { return }
            let current = player.currentTime().seconds
            guard current.isFinite else { return }
            var target = max(0, current + seconds)
            let duration = player.currentItem?.duration.seconds ?? .nan
            if duration.isFinite { target = min(target, duration) }
            let shouldKeepPlaying = player.timeControlStatus != .paused
            reachedEnd = false
            let time = CMTime(seconds: target, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                if shouldKeepPlaying { self?.startPlayback(player) }
                self?.publishSnapshot()
            }
            onProgress(target)
        }

        private func togglePlayback() {
            guard let player else { return }
            setPlayback(player.timeControlStatus == .paused)
        }

        private func setPlayback(_ shouldPlay: Bool) {
            guard let player else { return }
            if !shouldPlay {
                player.pause()
                let seconds = player.currentTime().seconds
                if seconds.isFinite { onProgress(seconds) }
            } else if player.timeControlStatus == .paused {
                if reachedEnd {
                    reachedEnd = false
                    player.seek(to: .zero)
                }
                startPlayback(player)
            }
            publishSnapshot()
        }

        private func toggleMute() {
            guard let player else { return }
            player.isMuted.toggle()
            publishSnapshot()
            onVolumeChange(player.isMuted ? 0 : Double(player.volume))
        }

        private func adjustVolume(by amount: Double) {
            guard let player else { return }
            let volume = PlaybackVolumePreference.normalized(Double(player.volume) + amount)
            player.volume = Float(volume)
            if volume > 0, player.isMuted { player.isMuted = false }
            PlaybackVolumePreference.save(volume)
            publishSnapshot()
            onVolumeChange(volume)
        }

        private func adjustPlaybackRate(by amount: Double) {
            setPlaybackRate(PlaybackRatePolicy.adjusted(preferredRate, by: amount))
        }

        private func setPlaybackRate(_ rate: Double) {
            preferredRate = PlaybackRatePolicy.normalized(rate)
            PlaybackRatePreference.save(preferredRate)
            if let player {
                let shouldKeepPlaying = player.timeControlStatus != .paused
                if shouldKeepPlaying {
                    // `rate` is AVFoundation's instantaneous clock adjustment.
                    // Do not call play, pause, seek, or preroll here: each can
                    // restart part of the media pipeline and create an audio gap.
                    player.rate = Float(preferredRate)
                }
            }
            publishSnapshot()
        }

        private func startPlayback(_ player: AVPlayer) {
            player.playImmediately(atRate: Float(preferredRate))
        }

        private func toggleFullscreen() -> Bool {
            guard let playerView else { return false }
            if playerView.isInFullScreenMode {
                playerView.exitFullScreenMode()
                return true
            }

            guard let screen = playerView.window?.screen ?? NSScreen.main else { return false }
            let presentationOptions = NSApp.presentationOptions.union([.autoHideDock, .autoHideMenuBar])
            return playerView.enterFullScreenMode(
                screen,
                withOptions: [
                    .fullScreenModeApplicationPresentationOptions: NSNumber(
                        value: presentationOptions.rawValue
                    )
                ]
            )
        }

        private func exitFullscreen() -> Bool {
            guard let playerView, playerView.isInFullScreenMode else { return false }
            playerView.exitFullScreenMode()
            return true
        }

        private func observeApplicationActivation() {
            applicationObservers = [
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: NSApp,
                    queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self?.showBackgroundPlayerIfAppropriate()
                    }
                },
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: NSApp,
                    queue: .main
                ) { [weak self] _ in
                    self?.backgroundOverlayDismissed = false
                    self?.hideBackgroundPlayer(animated: true, restoreInline: true)
                }
            ]
        }

        private func externalPlaybackChanged(isActive: Bool) {
            if isActive {
                hideBackgroundPlayer(animated: true, restoreInline: true)
            } else if !NSApp.isActive {
                showBackgroundPlayerIfAppropriate()
            }
            publishSnapshot()
        }

        private func showBackgroundPlayerIfAppropriate() {
            guard let player,
                  !backgroundOverlayDismissed,
                  PictureInPicturePolicy.shouldStart(
                    isAppActive: NSApp.isActive,
                    isPlaying: player.timeControlStatus != .paused,
                    reachedEnd: reachedEnd,
                    isAlreadyActive: backgroundPanel != nil,
                    isExternalPlaybackActive: player.isExternalPlaybackActive
                  ) else { return }

            let floatingView = FloatingVideoPlayerView()
            floatingView.onVolumeScroll = { [weak self] adjustment in
                self?.adjustVolume(by: adjustment)
            }
            floatingView.controlsStyle = .floating
            floatingView.videoGravity = .resizeAspect
            floatingView.showsFullScreenToggleButton = false
            floatingView.allowsPictureInPicturePlayback = false
            floatingView.wantsLayer = true
            floatingView.layer?.cornerRadius = 16
            floatingView.layer?.masksToBounds = true

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: FloatingPlayerLayout.size),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.delegate = self
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.contentAspectRatio = NSSize(width: 16, height: 9)
            panel.minSize = NSSize(width: 280, height: 157.5)
            panel.backgroundColor = .black
            panel.isOpaque = false
            panel.hasShadow = true
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false
            panel.contentView = floatingView

            let visibleFrame = playerView?.window?.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(origin: .zero, size: FloatingPlayerLayout.size)
            panel.setFrame(FloatingPlayerLayout.frame(in: visibleFrame), display: false)

            // Move the existing player output only after the panel is fully
            // configured. The panel is shown at its final location, so the sole
            // transition is opacity—there is never a position animation.
            playerView?.playerLayer.player = nil
            floatingView.player = player
            backgroundPanel = panel
            backgroundPlayerView = floatingView
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            guard duration > 0 else {
                panel.alphaValue = 1
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }

        private func hideBackgroundPlayer(animated: Bool, restoreInline: Bool) {
            guard let panel = backgroundPanel else {
                if restoreInline, let player {
                    playerView?.playerLayer.player = player
                }
                return
            }

            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            guard animated, !reduceMotion else {
                finishHidingBackgroundPlayer(panel, restoreInline: restoreInline)
                return
            }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak panel] in
                guard let self, let panel, self.backgroundPanel === panel else { return }
                self.finishHidingBackgroundPlayer(panel, restoreInline: restoreInline)
            })
        }

        private func finishHidingBackgroundPlayer(_ panel: NSPanel, restoreInline: Bool) {
            guard backgroundPanel === panel else { return }
            backgroundPlayerView?.player = nil
            backgroundPlayerView?.onVolumeScroll = nil
            if restoreInline, let player {
                playerView?.playerLayer.player = player
            }
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
            backgroundPlayerView = nil
            backgroundPanel = nil
        }

        @objc func handleVideoClick(_ gesture: NSClickGestureRecognizer) {
            guard gesture.state == .ended else { return }
            togglePlayback()
        }

        func windowWillClose(_ notification: Notification) {
            guard let panel = notification.object as? NSPanel,
                  backgroundPanel === panel else { return }
            backgroundOverlayDismissed = true
            backgroundPlayerView?.player = nil
            backgroundPlayerView = nil
            backgroundPanel = nil
            if let player {
                player.pause()
                playerView?.playerLayer.player = player
                let seconds = player.currentTime().seconds
                if seconds.isFinite { onProgress(seconds) }
            }
            publishSnapshot()
        }

        private func publishSnapshot() {
            guard let player else { return }
            let rawCurrent = player.currentTime().seconds
            let rawDuration = player.currentItem?.duration.seconds ?? .nan
            let snapshot = PlaybackSnapshot(
                currentTime: rawCurrent.isFinite ? max(0, rawCurrent) : 0,
                duration: rawDuration.isFinite ? max(0, rawDuration) : 0,
                isPlaying: player.timeControlStatus != .paused,
                isMuted: player.isMuted,
                volume: Double(player.volume),
                playbackRate: preferredRate,
                isExternalPlaybackActive: player.isExternalPlaybackActive
            )
            DispatchQueue.main.async { [onStateChange] in
                onStateChange(snapshot)
            }
            if PlaybackCommandCenter.shared.isActive(commandToken) {
                SystemMediaController.shared.update(snapshot)
            }
        }

        func stop() {
            _ = exitFullscreen()
            hideBackgroundPlayer(animated: false, restoreInline: false)
            for observer in applicationObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            applicationObservers.removeAll()
            if let player {
                player.pause()
                if !reachedEnd {
                    let seconds = player.currentTime().seconds
                    if seconds.isFinite { onProgress(seconds) }
                }
                if let persistenceObserver {
                    player.removeTimeObserver(persistenceObserver)
                }
                if let stateObserver {
                    player.removeTimeObserver(stateObserver)
                }
                let rawCurrent = player.currentTime().seconds
                let rawDuration = player.currentItem?.duration.seconds ?? .nan
                if PlaybackCommandCenter.shared.isActive(commandToken) {
                    SystemMediaController.shared.update(PlaybackSnapshot(
                        currentTime: rawCurrent.isFinite ? max(0, rawCurrent) : 0,
                        duration: rawDuration.isFinite ? max(0, rawDuration) : 0,
                        isPlaying: false,
                        isMuted: player.isMuted,
                        volume: Double(player.volume),
                        playbackRate: preferredRate,
                        isExternalPlaybackActive: player.isExternalPlaybackActive
                    ))
                }
            }
            persistenceObserver = nil
            stateObserver = nil
            externalPlaybackObserver = nil
            player = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil
            if let commandToken {
                PlaybackCommandCenter.shared.unregister(commandToken)
            }
            commandToken = nil
            playerView?.playerLayer.player = nil
            playerView?.onVolumeScroll = nil
            playerView = nil
            currentURL = nil
            currentTitle = ""
            currentAuthor = ""
        }

        deinit {
            if let player, let persistenceObserver {
                player.removeTimeObserver(persistenceObserver)
            }
            if let player, let stateObserver {
                player.removeTimeObserver(stateObserver)
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            if let commandToken {
                PlaybackCommandCenter.shared.unregister(commandToken)
            }
            for observer in applicationObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
