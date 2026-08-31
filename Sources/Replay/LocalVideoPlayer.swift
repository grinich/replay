import AVKit
import MediaPlayer
import SwiftUI

private final class FloatingVideoPlayerView: AVPlayerView {
    var onVolumeScroll: ((Double) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onReturnToMainWindow: (() -> Void)?
    private let volumeScrollInterpreter = PlayerVolumeScrollInterpreter()
    private let returnButton = NSButton()
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureReturnButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureReturnButton()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHoverControlsVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoverControlsVisible(false)
    }

    override func scrollWheel(with event: NSEvent) {
        let adjustment = volumeScrollInterpreter.adjustment(for: event)
        if adjustment != 0 { onVolumeScroll?(adjustment) }
    }

    override func swipe(with event: NSEvent) {
        // Consume swipe momentum for the same reason as scroll-wheel events.
    }

    private func configureReturnButton() {
        let symbol = NSImage(systemSymbolName: "pip.exit", accessibilityDescription: "Return to Replay")
            ?? NSImage(systemSymbolName: "arrow.up.backward.and.arrow.down.forward", accessibilityDescription: "Return to Replay")
        returnButton.image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        )
        returnButton.imagePosition = .imageOnly
        returnButton.isBordered = false
        returnButton.contentTintColor = .white
        returnButton.toolTip = "Return to Replay"
        returnButton.setAccessibilityLabel("Return to Replay")
        returnButton.target = self
        returnButton.action = #selector(returnToMainWindow)
        returnButton.translatesAutoresizingMaskIntoConstraints = false
        returnButton.wantsLayer = true
        returnButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        returnButton.layer?.cornerRadius = 15
        returnButton.isHidden = true
        addSubview(returnButton, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            returnButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            returnButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            returnButton.widthAnchor.constraint(equalToConstant: 30),
            returnButton.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func setHoverControlsVisible(_ visible: Bool) {
        returnButton.isHidden = !visible
        onHoverChanged?(visible)
    }

    @objc private func returnToMainWindow() {
        onReturnToMainWindow?()
    }
}

final class PictureInPicturePlayerView: NSView {
    let playerLayer = AVPlayerLayer()
    var onVolumeScroll: ((Double) -> Void)?
    private var scrollEventMonitor: Any?
    private let volumeScrollInterpreter = PlayerVolumeScrollInterpreter()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configurePlayerLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePlayerLayer()
    }

    private func configurePlayerLayer() {
        wantsLayer = true
        layer?.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.needsDisplayOnBoundsChange = true
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull()
        ]
        updatePlayerLayerFrame()
    }

    override func layout() {
        super.layout()
        updatePlayerLayerFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePlayerLayerFrame()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updatePlayerLayerFrame()
    }

    private func updatePlayerLayerFrame() {
        // AVPlayerLayer otherwise applies Core Animation's implicit bounds and
        // position animation. During live window growth that makes the video
        // visibly chase its containing view. Update on every AppKit geometry
        // callback and commit the exact new bounds with no animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
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
    func adjustment(for event: NSEvent) -> Double {
        guard PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: event.hasPreciseScrollingDeltas,
            phase: event.phase,
            momentumPhase: event.momentumPhase
        ) else { return 0 }

        // Decide from the current finger-driven event instead of waiting for
        // an accumulated axis lock. That makes the first vertical delta take
        // effect immediately while horizontal gestures still pass through as
        // zero-volume changes.
        let directionScale = PlayerVolumeScrollDirection.scale(
            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice
        )
        return PlayerVolumeScrollPolicy.adjustment(
            deltaX: event.scrollingDeltaX * directionScale,
            deltaY: event.scrollingDeltaY * directionScale,
            isPrecise: event.hasPreciseScrollingDeltas,
            isMomentum: false
        )
    }
}

enum PlayerVolumeScrollEventPolicy {
    static func shouldAdjust(
        isPrecise: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase
    ) -> Bool {
        guard momentumPhase.isEmpty,
              !phase.contains(.ended),
              !phase.contains(.cancelled) else { return false }

        // `momentumPhase` is the macOS source of truth for inertia. Some
        // smooth-scrolling mice emit precise, phase-less events while the
        // wheel is actively moving, so dropping those would make direct input
        // feel delayed or intermittently unresponsive.
        return true
    }
}

enum PlayerVolumeScrollDirection {
    static func scale(isDirectionInvertedFromDevice: Bool) -> Double {
        // AppKit automatically applies the user's natural-scrolling setting
        // to scrollingDeltaX/Y. Volume is a physical gesture, not content
        // scrolling, so compensate for that preference: fingers moving up
        // always yield a positive adjustment and fingers down a negative one.
        isDirectionInvertedFromDevice ? -1 : 1
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
              deltaX.isFinite,
              abs(deltaY) >= abs(deltaX),
              abs(deltaY) >= 0.01 else { return 0 }

        if isPrecise {
            // Precise devices report many small points per gesture. Map each
            // point directly to 0.1% volume and cap a single event at 1.5% so
            // short movements remain useful for fine adjustment.
            return min(0.015, max(-0.015, deltaY * 0.001))
        }
        // One physical wheel notch is a small, predictable 2% adjustment.
        return deltaY > 0 ? 0.02 : -0.02
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
            MPMediaItemPropertyTitle: title.isEmpty ? "Replay" : title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
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

enum HardwareMediaKeyAction: Equatable {
    case togglePlayback
    case skip(Double)
}

enum HardwareMediaKeyEventPolicy {
    private static let auxiliaryControlButtonsSubtype = 8
    private static let keyDownState = 0xA

    static func action(subtype: Int, data1: Int) -> HardwareMediaKeyAction? {
        guard subtype == auxiliaryControlButtonsSubtype else { return nil }

        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0x0000FF00) >> 8
        let isRepeat = (keyFlags & 0x1) != 0
        guard keyState == keyDownState, !isRepeat else { return nil }

        switch keyCode {
        case 16:
            return .togglePlayback
        case 17, 19:
            return .skip(10)
        case 18, 20:
            return .skip(-10)
        default:
            return nil
        }
    }
}

enum SystemMediaCommandSource: Equatable {
    case hardwareKey
    case remoteCommandCenter
}

enum SystemMediaCommandFamily: Equatable {
    case playback
    case skipForward
    case skipBackward
}

enum SystemMediaCommandDeduplicationPolicy {
    static let crossSourceWindow: TimeInterval = 0.35

    static func shouldAccept(
        previousSource: SystemMediaCommandSource?,
        previousFamily: SystemMediaCommandFamily?,
        previousTime: TimeInterval?,
        source: SystemMediaCommandSource,
        family: SystemMediaCommandFamily,
        time: TimeInterval
    ) -> Bool {
        guard let previousSource,
              let previousFamily,
              let previousTime,
              previousSource != source,
              previousFamily == family else { return true }
        let elapsed = time - previousTime
        return elapsed < 0 || elapsed > crossSourceWindow
    }
}

final class SystemMediaController {
    static let shared = SystemMediaController()

    private var isStarted = false
    private var title = "Replay"
    private var author = ""
    private var snapshot = PlaybackSnapshot.empty
    private weak var activePlayer: AVPlayer?
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var lastCommandSource: SystemMediaCommandSource?
    private var lastCommandFamily: SystemMediaCommandFamily?
    private var lastCommandTime: TimeInterval?

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
    }

    func activate(player: AVPlayer) {
        guard isStarted else { return }
        if activePlayer === player, !commandTargets.isEmpty {
            publish()
            return
        }

        tearDownSession(clearNowPlayingInfo: true)
        activePlayer = player
        // macOS exposes the process-wide command center rather than
        // MPNowPlayingSession. Install the handlers only once there is a real
        // AVPlayer to command, then publish its matching playback state.
        installCommands(on: MPRemoteCommandCenter.shared())
        publish()
    }

    func deactivate(player: AVPlayer) {
        guard activePlayer === player else { return }
        tearDownSession(clearNowPlayingInfo: true)
    }

    private func installCommands(on commands: MPRemoteCommandCenter) {
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = true
        commands.previousTrackCommand.isEnabled = true
        commands.skipForwardCommand.isEnabled = true
        commands.skipBackwardCommand.isEnabled = true
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.preferredIntervals = [10]

        addTarget(to: commands.playCommand, family: .playback) {
            PlaybackCommandCenter.shared.play()
        }
        addTarget(to: commands.pauseCommand, family: .playback) {
            PlaybackCommandCenter.shared.pause()
        }
        addTarget(to: commands.togglePlayPauseCommand, family: .playback) {
            PlaybackCommandCenter.shared.togglePlayback()
        }
        // Mac keyboards report the previous/next media buttons as track
        // commands, while Control Center can report explicit skip commands.
        addTarget(to: commands.previousTrackCommand, family: .skipBackward) {
            PlaybackCommandCenter.shared.skip(by: -10)
        }
        addTarget(to: commands.nextTrackCommand, family: .skipForward) {
            PlaybackCommandCenter.shared.skip(by: 10)
        }
        addTarget(to: commands.skipBackwardCommand, family: .skipBackward) {
            PlaybackCommandCenter.shared.skip(by: -10)
        }
        addTarget(to: commands.skipForwardCommand, family: .skipForward) {
            PlaybackCommandCenter.shared.skip(by: 10)
        }
    }

    private func addTarget(
        to command: MPRemoteCommand,
        family: SystemMediaCommandFamily,
        action: @escaping () -> Void
    ) {
        let target = command.addTarget { [weak self] _ in
            // Media-key handlers may arrive off the main thread. Consume the
            // command immediately, then perform AVPlayer work on the main queue.
            DispatchQueue.main.async {
                guard self?.acceptCommand(source: .remoteCommandCenter, family: family) == true else {
                    return
                }
                action()
            }
            return .success
        }
        commandTargets.append((command, target))
    }

    @discardableResult
    func handleHardwareMediaKey(_ action: HardwareMediaKeyAction) -> Bool {
        let family: SystemMediaCommandFamily
        switch action {
        case .togglePlayback:
            family = .playback
        case .skip(let seconds):
            family = seconds < 0 ? .skipBackward : .skipForward
        }
        guard acceptCommand(source: .hardwareKey, family: family) else { return true }

        switch action {
        case .togglePlayback:
            return PlaybackCommandCenter.shared.togglePlayback()
        case .skip(let seconds):
            return PlaybackCommandCenter.shared.skip(by: seconds)
        }
    }

    private func acceptCommand(
        source: SystemMediaCommandSource,
        family: SystemMediaCommandFamily,
        time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard SystemMediaCommandDeduplicationPolicy.shouldAccept(
            previousSource: lastCommandSource,
            previousFamily: lastCommandFamily,
            previousTime: lastCommandTime,
            source: source,
            family: family,
            time: time
        ) else { return false }
        lastCommandSource = source
        lastCommandFamily = family
        lastCommandTime = time
        return true
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
        tearDownSession(clearNowPlayingInfo: true)
    }

    private func publish() {
        guard isStarted, activePlayer != nil else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = NowPlayingInfoBuilder.make(
            title: title,
            author: author,
            snapshot: snapshot
        )
        center.playbackState = snapshot.isPlaying ? .playing : .paused
    }

    private func tearDownSession(clearNowPlayingInfo: Bool) {
        for entry in commandTargets {
            entry.command.removeTarget(entry.target)
        }
        commandTargets.removeAll()

        if clearNowPlayingInfo {
            let center = MPNowPlayingInfoCenter.default()
            center.playbackState = .stopped
            center.nowPlayingInfo = nil
        }
        activePlayer = nil
        lastCommandSource = nil
        lastCommandFamily = nil
        lastCommandTime = nil
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
    // Replay is primarily speech, and AVFoundation documents time-domain
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

private final class FullscreenPlaybackControlsState: ObservableObject {
    @Published var snapshot: PlaybackSnapshot

    init(snapshot: PlaybackSnapshot) {
        self.snapshot = snapshot
    }
}

private struct FullscreenPlaybackControlsOverlay: View {
    @ObservedObject var state: FullscreenPlaybackControlsState
    let togglePlayback: () -> Void
    let skip: (Double) -> Void
    let seek: (Double) -> Void
    let toggleMute: () -> Void
    let setPlaybackRate: (Double) -> Void
    @State private var scrubTime: Double?

    var body: some View {
        HStack(spacing: 10) {
            controlButton(
                systemImage: state.snapshot.isPlaying ? "pause.fill" : "play.fill",
                help: state.snapshot.isPlaying ? "Pause (Space)" : "Play (Space)",
                prominent: true,
                action: togglePlayback
            )
            controlButton(systemImage: "gobackward.10", help: "Back 10 seconds") {
                skip(-10)
            }
            controlButton(systemImage: "goforward.10", help: "Forward 10 seconds") {
                skip(10)
            }

            Text(formatTime(displayTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.82))
                .frame(minWidth: 46, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { min(displayTime, effectiveDuration) },
                    set: { scrubTime = $0 }
                ),
                in: 0...effectiveDuration,
                onEditingChanged: { editing in
                    guard !editing, let scrubTime else { return }
                    seek(scrubTime)
                    self.scrubTime = nil
                }
            )
            .tint(.accentColor)
            .disabled(rawDuration <= 0)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(formatTime(displayTime)) of \(formatTime(effectiveDuration))")

            Text("−\(formatTime(max(0, effectiveDuration - displayTime)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.82))
                .frame(minWidth: 52, alignment: .leading)

            Menu {
                ForEach(PlaybackRatePolicy.supportedRates, id: \.self) { rate in
                    Button {
                        setPlaybackRate(rate)
                    } label: {
                        if rate == PlaybackRatePolicy.normalized(state.snapshot.playbackRate) {
                            Label(rateLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(rateLabel(rate))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                    Text(rateLabel(state.snapshot.playbackRate))
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(Color.white.opacity(0.1), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose playback speed")

            AirPlayRoutePicker()
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.08), in: Circle())
                .help("Choose an AirPlay device")

            controlButton(
                systemImage: state.snapshot.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                help: state.snapshot.isMuted ? "Unmute" : "Mute",
                action: toggleMute
            )
        }
        .frame(maxWidth: 1100)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16))
        }
        .shadow(color: .black.opacity(0.42), radius: 18, y: 6)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .bottom)
    }

    private func controlButton(
        systemImage: String,
        help: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 17 : 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: prominent ? 40 : 34, height: prominent ? 40 : 34)
                .background(
                    prominent ? Color.accentColor : Color.white.opacity(0.1),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var effectiveDuration: Double {
        max(0.001, rawDuration)
    }

    private var rawDuration: Double {
        max(0, state.snapshot.duration)
    }

    private var displayTime: Double {
        scrubTime ?? state.snapshot.currentTime
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }

    private func rateLabel(_ rate: Double) -> String {
        String(format: "%.1f×", PlaybackRatePolicy.normalized(rate))
    }
}

struct LocalVideoPlayer: NSViewRepresentable {
    let source: VideoPlaybackSource
    let title: String
    let author: String
    let resumeAt: Double
    let seekRequest: PlayerSeekRequest?
    let onProgress: (Double) -> Void
    let onStateChange: (PlaybackSnapshot) -> Void
    let onVolumeChange: (Double) -> Void
    let onEnded: () -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onProgress: onProgress,
            onStateChange: onStateChange,
            onVolumeChange: onVolumeChange,
            onEnded: onEnded,
            onUnavailable: onUnavailable
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
        context.coordinator.load(source: source, title: title, author: author, resumeAt: resumeAt, into: view)
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
        if context.coordinator.currentSource != source {
            // Persist the outgoing video's position through its original
            // callbacks before retargeting this retained coordinator.
            context.coordinator.stop()
            context.coordinator.updateCallbacks(
                onProgress: onProgress,
                onStateChange: onStateChange,
                onVolumeChange: onVolumeChange,
                onEnded: onEnded,
                onUnavailable: onUnavailable
            )
            context.coordinator.load(source: source, title: title, author: author, resumeAt: resumeAt, into: view)
            return
        }
        context.coordinator.updateCallbacks(
            onProgress: onProgress,
            onStateChange: onStateChange,
            onVolumeChange: onVolumeChange,
            onEnded: onEnded,
            onUnavailable: onUnavailable
        )
        context.coordinator.updateMetadata(title: title, author: author)
        if let seekRequest {
            context.coordinator.seek(to: seekRequest)
        }
    }

    static func dismantleNSView(_ view: PictureInPicturePlayerView, coordinator: Coordinator) {
        coordinator.stop()
        view.playerLayer.player = nil
    }

    final class Coordinator: NSObject, NSWindowDelegate, NSGestureRecognizerDelegate {
        private var player: AVPlayer?
        private weak var playerView: PictureInPicturePlayerView?
        private var backgroundPanel: NSPanel?
        private var backgroundPlayerView: FloatingVideoPlayerView?
        private weak var fullscreenWindow: NSWindow?
        private weak var fullscreenContainerView: NSView?
        private var fullscreenPlayerView: PictureInPicturePlayerView?
        private var fullscreenControlsHost: NSHostingView<AnyView>?
        private var fullscreenControlsState: FullscreenPlaybackControlsState?
        private var fullscreenControlsHideWorkItem: DispatchWorkItem?
        private var fullscreenPointerEventMonitor: Any?
        private var fullscreenWindowAcceptedMouseMovedEvents: Bool?
        private var fullscreenMenuIsTracking = false
        private var fullscreenToolbarWasVisible: Bool?
        private var fullscreenApplicationPresentationOptions: NSApplication.PresentationOptions?
        private var fullscreenTransitionShouldKeepPlaying: Bool?
        private var fullscreenObservers: [NSObjectProtocol] = []
        private var isVideoFullscreen = false
        private var shouldExitAfterEnteringFullscreen = false
        private var applicationObservers: [NSObjectProtocol] = []
        private var backgroundOverlayDismissed = false
        private var endObserver: NSObjectProtocol?
        private var persistenceObserver: Any?
        private var stateObserver: Any?
        private var itemStatusObserver: NSKeyValueObservation?
        private var externalPlaybackObserver: NSKeyValueObservation?
        private var reachedEnd = false
        private var onProgress: (Double) -> Void
        private var onStateChange: (PlaybackSnapshot) -> Void
        private var onVolumeChange: (Double) -> Void
        private var onEnded: () -> Void
        private var onUnavailable: () -> Void
        private var lastSeekRequestID: UUID?
        private var commandToken: UUID?
        private var preferredRate: Double = 1
        private var currentTitle = ""
        private var currentAuthor = ""
        private var pendingVolumeSave: DispatchWorkItem?
        fileprivate var currentSource: VideoPlaybackSource?

        init(
            onProgress: @escaping (Double) -> Void,
            onStateChange: @escaping (PlaybackSnapshot) -> Void,
            onVolumeChange: @escaping (Double) -> Void,
            onEnded: @escaping () -> Void,
            onUnavailable: @escaping () -> Void
        ) {
            self.onProgress = onProgress
            self.onStateChange = onStateChange
            self.onVolumeChange = onVolumeChange
            self.onEnded = onEnded
            self.onUnavailable = onUnavailable
            super.init()
        }

        func updateCallbacks(
            onProgress: @escaping (Double) -> Void,
            onStateChange: @escaping (PlaybackSnapshot) -> Void,
            onVolumeChange: @escaping (Double) -> Void,
            onEnded: @escaping () -> Void,
            onUnavailable: @escaping () -> Void
        ) {
            self.onProgress = onProgress
            self.onStateChange = onStateChange
            self.onVolumeChange = onVolumeChange
            self.onEnded = onEnded
            self.onUnavailable = onUnavailable
        }

        func load(
            source: VideoPlaybackSource,
            title: String,
            author: String,
            resumeAt: Double,
            into view: PictureInPicturePlayerView
        ) {
            stop()
            currentSource = source
            currentTitle = title
            currentAuthor = author
            reachedEnd = false
            lastSeekRequestID = nil
            preferredRate = PlaybackRatePreference.load()
            playerView = view
            view.onVolumeScroll = { [weak self] adjustment in
                self?.adjustVolume(by: adjustment)
            }

            installPlayerItem(
                AVPlayerItem(asset: AVURLAsset(url: source.videoURL)),
                title: title,
                author: author,
                resumeAt: resumeAt,
                into: view
            )
        }

        private func installPlayerItem(
            _ playerItem: AVPlayerItem,
            title: String,
            author: String,
            resumeAt: Double,
            into view: PictureInPicturePlayerView
        ) {
            playerItem.audioTimePitchAlgorithm = PlaybackAudioPolicy.timePitchAlgorithm
            let player = AVPlayer(playerItem: playerItem)
            player.allowsExternalPlayback = true
            player.automaticallyWaitsToMinimizeStalling = PlaybackAudioPolicy.waitsToMinimizeStalling
            player.volume = Float(PlaybackVolumePreference.load())
            self.player = player
            playerView = view
            view.playerLayer.player = player
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
            SystemMediaController.shared.activate(player: player)
            SystemMediaController.shared.setItem(title: title, author: author)
            itemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                DispatchQueue.main.async { self?.onUnavailable() }
            }
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

            // Audio and the HUD are the interactive path: update both before
            // doing persistence or media-center work. Publishing now-playing
            // state for every trackpad delta can block AppKit long enough for
            // later scroll events to visibly catch up.
            onVolumeChange(volume)
            scheduleVolumeSave(volume)
        }

        private func scheduleVolumeSave(_ volume: Double) {
            pendingVolumeSave?.cancel()
            let workItem = DispatchWorkItem {
                PlaybackVolumePreference.save(volume)
            }
            pendingVolumeSave = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
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
            if isVideoFullscreen {
                return exitFullscreen()
            }
            guard let player,
                  let window = playerView?.window else { return false }
            let shouldKeepPlaying = player.timeControlStatus != .paused
            guard
                  beginFullscreenPresentation(in: window) else { return false }

            // If the user already put the window in a native full-screen
            // Space with the green button, F only switches to video-only
            // presentation. Otherwise use NSWindow's native transition so
            // Mission Control and trackpad Space switching work normally.
            if !window.styleMask.contains(.fullScreen) {
                fullscreenTransitionShouldKeepPlaying = shouldKeepPlaying
                window.toggleFullScreen(nil)
            }
            return true
        }

        private func exitFullscreen() -> Bool {
            guard let window = fullscreenWindow ?? playerView?.window else { return false }

            if isVideoFullscreen {
                if window.styleMask.contains(.fullScreen) {
                    fullscreenTransitionShouldKeepPlaying = player.map {
                        $0.timeControlStatus != .paused
                    }
                    window.toggleFullScreen(nil)
                } else {
                    // The native transition has not reached didEnter yet.
                    // Finish entering, then immediately request the matching
                    // native exit rather than stranding the app in that Space.
                    shouldExitAfterEnteringFullscreen = true
                }
                return true
            }

            guard window.styleMask.contains(.fullScreen) else { return false }
            window.toggleFullScreen(nil)
            return true
        }

        private func beginFullscreenPresentation(in window: NSWindow) -> Bool {
            guard let player,
                  let contentView = window.contentView,
                  let containerView = contentView.superview else { return false }
            let shouldKeepPlaying = player.timeControlStatus != .paused

            hideBackgroundPlayer(animated: false, restoreInline: true)
            fullscreenToolbarWasVisible = window.toolbar?.isVisible
            window.toolbar?.isVisible = false
            fullscreenApplicationPresentationOptions = NSApp.presentationOptions
            var presentationOptions = NSApp.presentationOptions
            presentationOptions.insert(.autoHideMenuBar)
            presentationOptions.insert(.autoHideDock)
            NSApp.presentationOptions = presentationOptions

            // Install above the window's frame view, not inside SwiftUI's
            // hosting view. NavigationSplitView can reorder hosting subviews
            // during the native full-screen transition, which would otherwise
            // put this surface behind the sidebar and detail content.
            let fullscreenView = PictureInPicturePlayerView(frame: containerView.bounds)
            fullscreenView.wantsLayer = true
            fullscreenView.layer?.backgroundColor = NSColor.black.cgColor
            fullscreenView.playerLayer.videoGravity = .resizeAspect
            fullscreenView.onVolumeScroll = { [weak self] adjustment in
                self?.adjustVolume(by: adjustment)
            }
            let fullscreenClick = NSClickGestureRecognizer(
                target: self,
                action: #selector(handleVideoClick(_:))
            )
            fullscreenClick.delegate = self
            fullscreenView.addGestureRecognizer(fullscreenClick)

            playerView?.playerLayer.player = nil
            fullscreenView.playerLayer.player = player
            // Reparenting an AVPlayer between layers can transiently restore a
            // nonzero rate. Reassert a paused state immediately instead of
            // letting the native full-screen animation resume the video.
            if !shouldKeepPlaying { player.pause() }
            let controlsState = FullscreenPlaybackControlsState(
                snapshot: currentSnapshot(for: player)
            )
            let controls = FullscreenPlaybackControlsOverlay(
                state: controlsState,
                togglePlayback: { [weak self] in self?.togglePlayback() },
                skip: { [weak self] seconds in self?.skip(by: seconds) },
                seek: { [weak self] time in self?.seekFromFullscreen(to: time) },
                toggleMute: { [weak self] in self?.toggleMute() },
                setPlaybackRate: { [weak self] rate in self?.setPlaybackRate(rate) }
            )
            let controlsHost = NSHostingView(rootView: AnyView(controls))
            controlsHost.translatesAutoresizingMaskIntoConstraints = false
            controlsHost.wantsLayer = true
            controlsHost.layer?.backgroundColor = NSColor.clear.cgColor
            fullscreenView.addSubview(controlsHost, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                controlsHost.leadingAnchor.constraint(equalTo: fullscreenView.leadingAnchor),
                controlsHost.trailingAnchor.constraint(equalTo: fullscreenView.trailingAnchor),
                controlsHost.bottomAnchor.constraint(equalTo: fullscreenView.bottomAnchor)
            ])
            installFullscreenView(fullscreenView, in: containerView)

            fullscreenWindow = window
            fullscreenContainerView = containerView
            fullscreenPlayerView = fullscreenView
            fullscreenControlsState = controlsState
            fullscreenControlsHost = controlsHost
            isVideoFullscreen = true
            shouldExitAfterEnteringFullscreen = false
            observeFullscreenTransitions(for: window)
            startFullscreenControlsAutoHide(in: window)
            return true
        }

        private func observeFullscreenTransitions(for window: NSWindow) {
            removeFullscreenObservers()
            let center = NotificationCenter.default
            fullscreenObservers = [
                center.addObserver(
                    forName: NSWindow.didEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self, weak window] _ in
                    guard let self, let window, self.isVideoFullscreen else { return }

                    // AppKit reconstructs and reorders parts of NSThemeFrame
                    // while entering a native full-screen Space. Reattach the
                    // video to that final frame so a newly-created title-bar
                    // surface cannot remain above it as a thin white strip.
                    if let fullscreenView = self.fullscreenPlayerView,
                       let containerView = window.contentView?.superview {
                        self.installFullscreenView(fullscreenView, in: containerView)
                    }
                    self.restorePlaybackStateAfterFullscreenTransition()
                    // Give the user the full idle interval after the native
                    // Space animation finishes, not from when it began.
                    self.revealFullscreenControls()

                    guard self.shouldExitAfterEnteringFullscreen else { return }
                    self.shouldExitAfterEnteringFullscreen = false
                    self.fullscreenTransitionShouldKeepPlaying = self.player.map {
                        $0.timeControlStatus != .paused
                    }
                    window.toggleFullScreen(nil)
                },
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.finishFullscreenPresentation(restoreInline: true)
                },
                center.addObserver(
                    forName: NSMenu.didBeginTrackingNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.fullscreenMenuIsTracking = true
                    self?.revealFullscreenControls()
                },
                center.addObserver(
                    forName: NSMenu.didEndTrackingNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.fullscreenMenuIsTracking = false
                    self?.scheduleFullscreenControlsHide()
                },
            ]
        }

        private func startFullscreenControlsAutoHide(in window: NSWindow) {
            fullscreenWindowAcceptedMouseMovedEvents = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true

            fullscreenPointerEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [
                    .mouseMoved,
                    .leftMouseDown,
                    .leftMouseDragged,
                    .rightMouseDown,
                    .rightMouseDragged,
                    .scrollWheel,
                ]
            ) { [weak self, weak window] event in
                if let self, let window, event.window === window, self.isVideoFullscreen {
                    self.revealFullscreenControls()
                }
                return event
            }

            revealFullscreenControls()
        }

        private func revealFullscreenControls() {
            guard isVideoFullscreen, let controlsHost = fullscreenControlsHost else { return }
            fullscreenControlsHideWorkItem?.cancel()
            NSCursor.setHiddenUntilMouseMoves(false)
            controlsHost.isHidden = false

            if controlsHost.alphaValue < 0.999 {
                let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
                guard duration > 0 else {
                    controlsHost.alphaValue = 1
                    scheduleFullscreenControlsHide()
                    return
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    controlsHost.animator().alphaValue = 1
                }
            }

            scheduleFullscreenControlsHide()
        }

        private func scheduleFullscreenControlsHide() {
            fullscreenControlsHideWorkItem?.cancel()
            guard isVideoFullscreen, !fullscreenMenuIsTracking else { return }

            let workItem = DispatchWorkItem { [weak self] in
                self?.hideFullscreenControls()
            }
            fullscreenControlsHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
        }

        private func hideFullscreenControls() {
            guard isVideoFullscreen,
                  !fullscreenMenuIsTracking,
                  let controlsHost = fullscreenControlsHost else { return }
            fullscreenControlsHideWorkItem = nil

            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            guard duration > 0 else {
                controlsHost.alphaValue = 0
                controlsHost.isHidden = true
                NSCursor.setHiddenUntilMouseMoves(true)
                return
            }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                controlsHost.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak controlsHost] in
                guard let self, let controlsHost,
                      self.fullscreenControlsHost === controlsHost,
                      controlsHost.alphaValue <= 0.001 else { return }
                controlsHost.isHidden = true
                NSCursor.setHiddenUntilMouseMoves(true)
            })
        }

        private func stopFullscreenControlsAutoHide(window: NSWindow?) {
            fullscreenControlsHideWorkItem?.cancel()
            fullscreenControlsHideWorkItem = nil
            if let fullscreenPointerEventMonitor {
                NSEvent.removeMonitor(fullscreenPointerEventMonitor)
                self.fullscreenPointerEventMonitor = nil
            }
            if let fullscreenWindowAcceptedMouseMovedEvents {
                window?.acceptsMouseMovedEvents = fullscreenWindowAcceptedMouseMovedEvents
            }
            self.fullscreenWindowAcceptedMouseMovedEvents = nil
            fullscreenMenuIsTracking = false
            NSCursor.setHiddenUntilMouseMoves(false)
        }

        private func installFullscreenView(
            _ fullscreenView: PictureInPicturePlayerView,
            in containerView: NSView
        ) {
            fullscreenView.removeFromSuperview()

            // Frame-based sizing is intentional here. NSThemeFrame changes
            // size several times during the native transition; autoresizing
            // follows those changes immediately without waiting for an Auto
            // Layout pass and avoids transient invalid constraint geometry.
            fullscreenView.translatesAutoresizingMaskIntoConstraints = true
            fullscreenView.frame = containerView.bounds
            fullscreenView.autoresizingMask = [.width, .height]
            containerView.addSubview(fullscreenView, positioned: .above, relativeTo: nil)
            fullscreenContainerView = containerView
            fullscreenView.needsLayout = true
            fullscreenView.layoutSubtreeIfNeeded()
        }

        private func finishFullscreenPresentation(restoreInline: Bool) {
            let window = fullscreenWindow
            stopFullscreenControlsAutoHide(window: window)
            fullscreenControlsHost?.removeFromSuperview()
            fullscreenControlsHost = nil
            fullscreenControlsState = nil
            fullscreenPlayerView?.playerLayer.player = nil
            fullscreenPlayerView?.onVolumeScroll = nil
            fullscreenPlayerView?.removeFromSuperview()
            fullscreenPlayerView = nil
            fullscreenContainerView = nil
            if let fullscreenToolbarWasVisible {
                window?.toolbar?.isVisible = fullscreenToolbarWasVisible
            }
            self.fullscreenToolbarWasVisible = nil
            if let fullscreenApplicationPresentationOptions {
                NSApp.presentationOptions = fullscreenApplicationPresentationOptions
            }
            self.fullscreenApplicationPresentationOptions = nil
            fullscreenWindow = nil
            isVideoFullscreen = false
            shouldExitAfterEnteringFullscreen = false
            removeFullscreenObservers()

            if restoreInline, backgroundPanel == nil, let player {
                playerView?.playerLayer.player = player
            }
            restorePlaybackStateAfterFullscreenTransition()
        }

        private func restorePlaybackStateAfterFullscreenTransition() {
            guard let shouldKeepPlaying = fullscreenTransitionShouldKeepPlaying,
                  let player else { return }
            fullscreenTransitionShouldKeepPlaying = nil

            if shouldKeepPlaying {
                if player.timeControlStatus == .paused { startPlayback(player) }
            } else {
                player.pause()
            }
            publishSnapshot()
        }

        private func removeFullscreenObservers() {
            for observer in fullscreenObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            fullscreenObservers.removeAll()
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
            panel.standardWindowButton(.closeButton)?.isHidden = true
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
            floatingView.onHoverChanged = { [weak panel] isHovering in
                panel?.standardWindowButton(.closeButton)?.isHidden = !isHovering
            }
            floatingView.onReturnToMainWindow = { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.returnToMainWindow(from: panel)
            }

            let visibleFrame = playerView?.window?.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(origin: .zero, size: FloatingPlayerLayout.size)
            panel.setFrame(FloatingPlayerLayout.frame(in: visibleFrame), display: false)

            // Move the existing player output only after the panel is fully
            // configured. The panel is shown at its final location, so the sole
            // transition is opacity—there is never a position animation.
            playerView?.playerLayer.player = nil
            fullscreenPlayerView?.playerLayer.player = nil
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
                    attachPlayerToPrimarySurface(player)
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
            backgroundPlayerView?.onHoverChanged = nil
            backgroundPlayerView?.onReturnToMainWindow = nil
            if restoreInline, let player {
                attachPlayerToPrimarySurface(player)
            }
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
            backgroundPlayerView = nil
            backgroundPanel = nil
        }

        private func returnToMainWindow(from panel: NSPanel) {
            guard backgroundPanel === panel else { return }
            let mainWindow = NSApp.windows.first { window in
                window !== panel && !(window is NSPanel) && window.canBecomeMain
            }
            backgroundOverlayDismissed = false
            hideBackgroundPlayer(animated: false, restoreInline: true)
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
        }

        @objc func handleVideoClick(_ gesture: NSClickGestureRecognizer) {
            guard gesture.state == .ended else { return }
            togglePlayback()
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            guard let fullscreenPlayerView,
                  gestureRecognizer.view === fullscreenPlayerView else { return true }
            let point = fullscreenPlayerView.convert(event.locationInWindow, from: nil)
            return fullscreenPlayerView.hitTest(point) === fullscreenPlayerView
        }

        func windowWillClose(_ notification: Notification) {
            guard let panel = notification.object as? NSPanel,
                  backgroundPanel === panel else { return }
            backgroundOverlayDismissed = true
            backgroundPlayerView?.player = nil
            backgroundPlayerView?.onVolumeScroll = nil
            backgroundPlayerView?.onHoverChanged = nil
            backgroundPlayerView?.onReturnToMainWindow = nil
            backgroundPlayerView = nil
            backgroundPanel = nil
            if let player {
                player.pause()
                attachPlayerToPrimarySurface(player)
                let seconds = player.currentTime().seconds
                if seconds.isFinite { onProgress(seconds) }
            }
            publishSnapshot()
        }

        private func attachPlayerToPrimarySurface(_ player: AVPlayer) {
            if isVideoFullscreen, let fullscreenPlayerView {
                fullscreenPlayerView.playerLayer.player = player
            } else {
                playerView?.playerLayer.player = player
            }
        }

        private func publishSnapshot(updateMediaCenter: Bool = true) {
            guard let player else { return }
            let snapshot = currentSnapshot(for: player)
            DispatchQueue.main.async { [weak self, onStateChange] in
                self?.fullscreenControlsState?.snapshot = snapshot
                onStateChange(snapshot)
            }
            if updateMediaCenter, PlaybackCommandCenter.shared.isActive(commandToken) {
                SystemMediaController.shared.update(snapshot)
            }
        }

        private func currentSnapshot(for player: AVPlayer) -> PlaybackSnapshot {
            let rawCurrent = player.currentTime().seconds
            let rawDuration = player.currentItem?.duration.seconds ?? .nan
            return PlaybackSnapshot(
                currentTime: rawCurrent.isFinite ? max(0, rawCurrent) : 0,
                duration: rawDuration.isFinite ? max(0, rawDuration) : 0,
                isPlaying: player.timeControlStatus != .paused,
                isMuted: player.isMuted,
                volume: Double(player.volume),
                playbackRate: preferredRate,
                isExternalPlaybackActive: player.isExternalPlaybackActive
            )
        }

        private func seekFromFullscreen(to time: Double) {
            let shouldKeepPlaying = player?.timeControlStatus != .paused
            seek(to: PlayerSeekRequest(time: time, shouldPlay: shouldKeepPlaying))
        }

        func stop() {
            _ = exitFullscreen()
            hideBackgroundPlayer(animated: false, restoreInline: false)
            finishFullscreenPresentation(restoreInline: false)
            pendingVolumeSave?.cancel()
            pendingVolumeSave = nil
            for observer in applicationObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            applicationObservers.removeAll()
            if let player {
                PlaybackVolumePreference.save(Double(player.volume))
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
                SystemMediaController.shared.deactivate(player: player)
            }
            persistenceObserver = nil
            stateObserver = nil
            itemStatusObserver = nil
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
            currentSource = nil
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
            removeFullscreenObservers()
        }
    }
}
