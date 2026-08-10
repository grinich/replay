import Foundation

@main
struct SubtitleParserCheck {
    static func main() {
        let srt = """
        1
        00:00:01,250 --> 00:00:03,500
        Hello <i>offline</i> world &amp; friends.

        2
        00:00:03,500 --> 00:00:05,000
        Second line
        continues here.
        """
        let srtCues = VideoSubtitleTrack.parse(srt)
        precondition(srtCues.count == 2)
        precondition(srtCues[0].startTime == 1.25)
        precondition(srtCues[0].text == "Hello offline world & friends.")
        let srtTrack = VideoSubtitleTrack(cues: srtCues)
        precondition(srtTrack.text(at: 0.5) == nil)
        precondition(srtTrack.text(at: 2) == "Hello offline world & friends.")
        precondition(srtTrack.text(at: 4) == "Second line\ncontinues here.")

        let vtt = """
        WEBVTT

        cue-1
        00:06.000 --> 00:08.250 align:middle
        A WebVTT caption
        """
        let vttCues = VideoSubtitleTrack.parse(vtt)
        precondition(vttCues.count == 1)
        precondition(vttCues[0].startTime == 6)
        precondition(vttCues[0].endTime == 8.25)

        if CommandLine.arguments.count > 1 {
            let downloadedURL = URL(fileURLWithPath: CommandLine.arguments[1])
            guard let downloadedTrack = VideoSubtitleTrack(contentsOf: downloadedURL) else {
                preconditionFailure("Could not parse the downloaded subtitle fixture")
            }
            precondition(downloadedTrack.cues.count > 10)
            print("downloaded_subtitle_cues=\(downloadedTrack.cues.count)")
        }

        print("subtitle_parser_check=passed")
    }
}
