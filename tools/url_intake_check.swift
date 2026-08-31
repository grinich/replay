import Foundation

@main
struct URLIntakeCheck {
    static func main() {
        let block = """
        Things to watch:
        - First: https://www.youtube.com/watch?v=abc123&t=45
        - A post (https://twitter.com/example/status/987654321?s=20).
        - Duplicate form: https://youtu.be/abc123
        - Background reading at www.example.com/watch/list.
        Contact person@example.com if anything is missing.
        """

        let extracted = URLIntake.webURLs(from: block).map(\.absoluteString)
        precondition(extracted == [
            "https://www.youtube.com/watch?v=abc123",
            "https://x.com/example/status/987654321",
            "http://www.example.com/watch/list"
        ], "Unexpected extraction: \(extracted)")

        let markdown = "[One](https://example.com/one), [Two](https://example.com/two)."
        let markdownLinks = URLIntake.webURLs(from: markdown).map(\.absoluteString)
        precondition(markdownLinks == ["https://example.com/one", "https://example.com/two"])

        precondition(URLIntake.webURLs(from: "No links in this paragraph.").isEmpty)
        precondition(URLIntake.webURL(from: "https://example.com/single")?.absoluteString == "https://example.com/single")
        precondition(
            URLIntake.foregroundVideoURL(from: "Copied https://youtu.be/abc123?t=12")?.absoluteString
                == "https://www.youtube.com/watch?v=abc123"
        )
        precondition(
            URLIntake.foregroundVideoURL(from: "https://x.com/example/status/987654321?s=20")?.absoluteString
                == "https://x.com/example/status/987654321"
        )
        precondition(URLIntake.foregroundVideoURL(from: "https://example.com/video") == nil)
        precondition(URLIntake.youtubeVideoID(from: URL(string: "https://youtu.be/abc123?t=4")!) == "abc123")
        precondition(URLIntake.youtubeVideoID(from: URL(string: "https://www.youtube.com/watch?v=abc123&t=4")!) == "abc123")
        precondition(URLIntake.youtubeVideoID(from: URL(string: "https://www.youtube.com/shorts/short-id")!) == "short-id")
        precondition(URLIntake.youtubeVideoID(from: URL(string: "https://x.com/example/status/123")!) == nil)

        let largeBlock = (0..<250)
            .map { "Item \($0): https://example.com/watch/\($0)" }
            .joined(separator: "\n")
        let largeBatch = URLIntake.webURLs(from: largeBlock)
        precondition(largeBatch.count == 250)
        precondition(largeBatch.first?.absoluteString == "https://example.com/watch/0")
        precondition(largeBatch.last?.absoluteString == "https://example.com/watch/249")

        print("url_intake_check=passed")
    }
}
