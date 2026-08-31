import AppKit
import Foundation
import AVFoundation
import MediaPlayer

@main
struct PlaybackCommandCheck {
    static func main() {
        let resizingPlayerView = PictureInPicturePlayerView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360)
        )
        resizingPlayerView.setFrameSize(NSSize(width: 1_280, height: 720))
        precondition(resizingPlayerView.playerLayer.frame == resizingPlayerView.bounds)
        precondition(resizingPlayerView.playerLayer.autoresizingMask.contains(.layerWidthSizable))
        precondition(resizingPlayerView.playerLayer.autoresizingMask.contains(.layerHeightSizable))
        precondition(resizingPlayerView.playerLayer.actions?["bounds"] is NSNull)
        precondition(resizingPlayerView.playerLayer.actions?["position"] is NSNull)

        precondition(PlaybackRatePolicy.adjusted(1, by: -0.1) == 1)
        precondition(PlaybackRatePolicy.adjusted(1, by: 0.1) == 1.1)
        precondition(PlaybackRatePolicy.adjusted(2.4, by: 0.1) == 2.5)
        precondition(PlaybackRatePolicy.adjusted(2.5, by: 0.1) == 2.5)
        precondition(PlaybackRatePolicy.normalized(.infinity) == 1)
        precondition(PlaybackRatePolicy.supportedRates.first == 1)
        precondition(PlaybackRatePolicy.supportedRates.last == 2.5)
        precondition(PlaybackRatePolicy.supportedRates.count == 16)
        precondition(PlaybackAudioPolicy.timePitchAlgorithm == .timeDomain)
        precondition(!PlaybackAudioPolicy.waitsToMinimizeStalling)
        let pausedChapterSeek = PlayerSeekRequest(time: 60, shouldPlay: false)
        let playingChapterSeek = PlayerSeekRequest(time: 120, shouldPlay: true)
        precondition(!pausedChapterSeek.shouldPlay)
        precondition(playingChapterSeek.shouldPlay)
        precondition(abs(PlayerVolumeScrollPolicy.adjustment(
            deltaX: 0,
            deltaY: 0.5,
            isPrecise: true,
            isMomentum: false
        ) - 0.0005) < 0.000_001)
        precondition(PlayerVolumeScrollPolicy.adjustment(
            deltaX: 0,
            deltaY: 10,
            isPrecise: true,
            isMomentum: false
        ) == 0.01)
        precondition(PlayerVolumeScrollPolicy.adjustment(
            deltaX: 0,
            deltaY: 100,
            isPrecise: true,
            isMomentum: false
        ) == 0.015)
        precondition(PlayerVolumeScrollDirection.scale(isDirectionInvertedFromDevice: false) == 1)
        precondition(PlayerVolumeScrollDirection.scale(isDirectionInvertedFromDevice: true) == -1)
        precondition(PlayerVolumeScrollPolicy.adjustment(
            deltaX: 0,
            deltaY: -1,
            isPrecise: false,
            isMomentum: false
        ) == -0.02)
        precondition(PlayerVolumeScrollPolicy.adjustment(
            deltaX: 0,
            deltaY: 10,
            isPrecise: true,
            isMomentum: true
        ) == 0)
        precondition(PlayerVolumeScrollPolicy.adjustment(
            deltaX: 20,
            deltaY: 10,
            isPrecise: true,
            isMomentum: false
        ) == 0)
        precondition(PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: true,
            phase: .began,
            momentumPhase: []
        ))
        precondition(PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: true,
            phase: .changed,
            momentumPhase: []
        ))
        precondition(PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: true,
            phase: [],
            momentumPhase: []
        ))
        precondition(!PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: true,
            phase: .ended,
            momentumPhase: []
        ))
        precondition(!PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: true,
            phase: [],
            momentumPhase: .changed
        ))
        precondition(!PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: true,
            phase: .changed,
            momentumPhase: .began
        ))
        precondition(!PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: false,
            phase: [],
            momentumPhase: .ended
        ))
        precondition(PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: false,
            phase: [],
            momentumPhase: []
        ))
        precondition(PictureInPicturePolicy.shouldStart(
            isAppActive: false,
            isPlaying: true,
            reachedEnd: false,
            isAlreadyActive: false,
            isExternalPlaybackActive: false
        ))
        let mediaKeyDown = (16 << 16) | (0xA << 8)
        let mediaKeyUp = (16 << 16) | (0xB << 8)
        let mediaKeyRepeat = mediaKeyDown | 0x1
        precondition(HardwareMediaKeyEventPolicy.action(
            subtype: 8,
            data1: mediaKeyDown
        ) == .togglePlayback)
        precondition(HardwareMediaKeyEventPolicy.action(
            subtype: 8,
            data1: (17 << 16) | (0xA << 8)
        ) == .skip(10))
        precondition(HardwareMediaKeyEventPolicy.action(
            subtype: 8,
            data1: (18 << 16) | (0xA << 8)
        ) == .skip(-10))
        precondition(HardwareMediaKeyEventPolicy.action(subtype: 8, data1: mediaKeyUp) == nil)
        precondition(HardwareMediaKeyEventPolicy.action(subtype: 8, data1: mediaKeyRepeat) == nil)
        precondition(HardwareMediaKeyEventPolicy.action(subtype: 0, data1: mediaKeyDown) == nil)
        precondition(SystemMediaCommandDeduplicationPolicy.shouldAccept(
            previousSource: nil,
            previousFamily: nil,
            previousTime: nil,
            source: .hardwareKey,
            family: .playback,
            time: 10
        ))
        precondition(!SystemMediaCommandDeduplicationPolicy.shouldAccept(
            previousSource: .hardwareKey,
            previousFamily: .playback,
            previousTime: 10,
            source: .remoteCommandCenter,
            family: .playback,
            time: 10.2
        ))
        precondition(SystemMediaCommandDeduplicationPolicy.shouldAccept(
            previousSource: .hardwareKey,
            previousFamily: .playback,
            previousTime: 10,
            source: .hardwareKey,
            family: .playback,
            time: 10.2
        ))
        precondition(SystemMediaCommandDeduplicationPolicy.shouldAccept(
            previousSource: .hardwareKey,
            previousFamily: .playback,
            previousTime: 10,
            source: .remoteCommandCenter,
            family: .skipForward,
            time: 10.2
        ))
        precondition(SystemMediaCommandDeduplicationPolicy.shouldAccept(
            previousSource: .hardwareKey,
            previousFamily: .playback,
            previousTime: 10,
            source: .remoteCommandCenter,
            family: .playback,
            time: 10.5
        ))
        precondition(!PictureInPicturePolicy.shouldStart(
            isAppActive: true,
            isPlaying: true,
            reachedEnd: false,
            isAlreadyActive: false,
            isExternalPlaybackActive: false
        ))
        precondition(!PictureInPicturePolicy.shouldStart(
            isAppActive: false,
            isPlaying: false,
            reachedEnd: false,
            isAlreadyActive: false,
            isExternalPlaybackActive: false
        ))
        precondition(!PictureInPicturePolicy.shouldStart(
            isAppActive: false,
            isPlaying: true,
            reachedEnd: true,
            isAlreadyActive: false,
            isExternalPlaybackActive: false
        ))
        precondition(!PictureInPicturePolicy.shouldStart(
            isAppActive: false,
            isPlaying: true,
            reachedEnd: false,
            isAlreadyActive: true,
            isExternalPlaybackActive: false
        ))
        precondition(!PictureInPicturePolicy.shouldStart(
            isAppActive: false,
            isPlaying: true,
            reachedEnd: false,
            isAlreadyActive: false,
            isExternalPlaybackActive: true
        ))

        let screenFrame = NSRect(x: 100, y: 50, width: 1_200, height: 800)
        let floatingFrame = FloatingPlayerLayout.frame(in: screenFrame)
        precondition(floatingFrame.maxX == screenFrame.maxX - FloatingPlayerLayout.margin)
        precondition(floatingFrame.minY == screenFrame.minY + FloatingPlayerLayout.margin)

        let nowPlayingSnapshot = PlaybackSnapshot(
            currentTime: 42,
            duration: 120,
            isPlaying: true,
            playbackRate: 1.5
        )
        let nowPlayingInfo = NowPlayingInfoBuilder.make(
            title: "Test video",
            author: "Test author",
            snapshot: nowPlayingSnapshot
        )
        precondition(nowPlayingInfo[MPMediaItemPropertyTitle] as? String == "Test video")
        precondition(nowPlayingInfo[MPMediaItemPropertyArtist] as? String == "Test author")
        precondition(nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42)
        precondition(nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)

        let suiteName = "Replay.PlaybackCommandCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        precondition(PlaybackRatePreference.load(from: defaults) == 1)
        PlaybackRatePreference.save(1.7, to: defaults)
        precondition(PlaybackRatePreference.load(from: defaults) == 1.7)
        defaults.set(99, forKey: "playbackRate")
        precondition(PlaybackRatePreference.load(from: defaults) == 2.5)
        precondition(PlaybackVolumePreference.load(from: defaults) == 1)
        PlaybackVolumePreference.save(0.42, to: defaults)
        precondition(PlaybackVolumePreference.load(from: defaults) == 0.42)
        PlaybackVolumePreference.save(99, to: defaults)
        precondition(PlaybackVolumePreference.load(from: defaults) == 1)
        defaults.removePersistentDomain(forName: suiteName)

        var received: [Double] = []
        var toggleCount = 0
        var requestedPlayingStates: [Bool] = []
        var muteCount = 0
        var rateAdjustments: [Double] = []
        var selectedRates: [Double] = []
        var fullscreenToggleCount = 0
        var fullscreenExitCount = 0
        let routePlayer = AVPlayer()
        let token = PlaybackCommandCenter.shared.register(
            player: routePlayer,
            skip: { received.append($0) },
            toggle: { toggleCount += 1 },
            setPlaying: { requestedPlayingStates.append($0) },
            mute: { muteCount += 1 },
            adjustRate: { rateAdjustments.append($0) },
            setRate: { selectedRates.append($0) },
            toggleFullscreen: {
                fullscreenToggleCount += 1
                return true
            },
            exitFullscreen: {
                fullscreenExitCount += 1
                return true
            }
        )
        precondition(PlaybackCommandCenter.shared.hasActivePlayer)
        precondition(PlaybackCommandCenter.shared.isActive(token))
        precondition(PlaybackCommandCenter.shared.activeRoutePlayer === routePlayer)
        precondition(PlaybackCommandCenter.shared.skip(by: -10))
        precondition(PlaybackCommandCenter.shared.skip(by: 10))
        precondition(PlaybackCommandCenter.shared.togglePlayback())
        precondition(PlaybackCommandCenter.shared.play())
        precondition(PlaybackCommandCenter.shared.pause())
        precondition(PlaybackCommandCenter.shared.toggleMute())
        precondition(PlaybackCommandCenter.shared.adjustPlaybackRate(by: 0.1))
        precondition(PlaybackCommandCenter.shared.adjustPlaybackRate(by: -0.1))
        precondition(PlaybackCommandCenter.shared.setPlaybackRate(to: 1.7))
        precondition(PlaybackCommandCenter.shared.setPlaybackRate(to: 99))
        precondition(PlaybackCommandCenter.shared.toggleFullscreen())
        precondition(PlaybackCommandCenter.shared.exitFullscreen())
        precondition(received == [-10, 10])
        precondition(toggleCount == 1)
        precondition(requestedPlayingStates == [true, false])
        precondition(muteCount == 1)
        precondition(rateAdjustments == [0.1, -0.1])
        precondition(selectedRates == [1.7, 2.5])
        precondition(fullscreenToggleCount == 1)
        precondition(fullscreenExitCount == 1)
        PlaybackCommandCenter.shared.unregister(token)
        precondition(!PlaybackCommandCenter.shared.hasActivePlayer)
        precondition(!PlaybackCommandCenter.shared.isActive(token))
        precondition(PlaybackCommandCenter.shared.activeRoutePlayer == nil)
        precondition(!PlaybackCommandCenter.shared.skip(by: 10))
        precondition(!PlaybackCommandCenter.shared.togglePlayback())
        precondition(!PlaybackCommandCenter.shared.play())
        precondition(!PlaybackCommandCenter.shared.pause())
        precondition(!PlaybackCommandCenter.shared.toggleMute())
        precondition(!PlaybackCommandCenter.shared.adjustPlaybackRate(by: 0.1))
        precondition(!PlaybackCommandCenter.shared.setPlaybackRate(to: 1.5))
        precondition(!PlaybackCommandCenter.shared.toggleFullscreen())
        precondition(!PlaybackCommandCenter.shared.exitFullscreen())
        print("playback_command_check=passed")
    }
}
