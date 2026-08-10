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
