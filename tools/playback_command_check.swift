import Foundation
import AVFoundation
import MediaPlayer

@main
struct PlaybackCommandCheck {
    static func main() {
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
        precondition(PlayerVolumeScrollPolicy.adjustment(
            deltaX: 0,
            deltaY: 10,
            isPrecise: true,
            isMomentum: false
        ) == 0.06)
        precondition(PlayerVolumeScrollPolicy.adjustment(
            deltaX: 0,
            deltaY: -1,
            isPrecise: false,
            isMomentum: false
        ) == -0.05)
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
        precondition(PictureInPicturePolicy.shouldStart(
            isAppActive: false,
            isPlaying: true,
            reachedEnd: false,
            isAlreadyActive: false,
            isExternalPlaybackActive: false
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

        let suiteName = "WatchLater.PlaybackCommandCheck.\(UUID().uuidString)"
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
