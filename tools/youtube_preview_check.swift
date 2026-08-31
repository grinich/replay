import Foundation

@main
struct YouTubePreviewCheck {
    static func main() {
        let oEmbed = Data(#"{"title":"A fast preview","author_name":"Replay Tester","thumbnail_url":"https://example.com/thumb.jpg"}"#.utf8)
        let parsed = YouTubePreviewMetadata.parseOEmbed(oEmbed)
        precondition(parsed?.title == "A fast preview")
        precondition(parsed?.author == "Replay Tester")
        precondition(parsed?.thumbnailURL?.absoluteString == "https://example.com/thumb.jpg")

        let watchPage = Data(#"<script>{"videoDetails":{"lengthSeconds":"2760"}}</script>"#.utf8)
        precondition(YouTubePreviewMetadata.duration(fromWatchPage: watchPage) == 2760)

        let fallbackPage = Data(#"{"approxDurationMs":"1500"}"#.utf8)
        precondition(YouTubePreviewMetadata.duration(fromWatchPage: fallbackPage) == 1.5)
        print("youtube_preview_check=passed")
    }
}
