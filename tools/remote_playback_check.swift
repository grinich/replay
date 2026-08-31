import AVFoundation
import Foundation

@main
struct RemotePlaybackCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 2,
              let url = URL(string: CommandLine.arguments[1]) else {
            fputs("usage: remote_playback_check <combined-stream-url>\n", stderr)
            exit(2)
        }

        let asset = AVURLAsset(url: url)
        async let videoTracks = asset.loadTracks(withMediaType: .video)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)
        async let duration = asset.load(.duration)
        let (videos, audio, loadedDuration) = try await (videoTracks, audioTracks, duration)
        guard !videos.isEmpty,
              !audio.isEmpty,
              loadedDuration.isNumeric,
              loadedDuration > .zero else {
            fputs("remote_playback_check=failed\n", stderr)
            exit(1)
        }

        print("remote_playback_check=passed")
        print("duration_seconds=\(loadedDuration.seconds)")
    }
}
