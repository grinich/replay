import Foundation

enum YouTubePreviewMetadata {
    struct OEmbed: Equatable {
        let title: String
        let author: String
        let thumbnailURL: URL?
    }

    static func parseOEmbed(_ data: Data) -> OEmbed? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String,
              !title.isEmpty else { return nil }
        return OEmbed(
            title: title,
            author: object["author_name"] as? String ?? "",
            thumbnailURL: (object["thumbnail_url"] as? String).flatMap(URL.init(string:))
        )
    }

    static func duration(fromWatchPage data: Data) -> Double? {
        guard let page = String(data: data, encoding: .utf8) else { return nil }
        if let seconds = firstNumber(in: page, pattern: #"\"lengthSeconds\":\"([0-9]+)\""#) {
            return seconds
        }
        if let milliseconds = firstNumber(in: page, pattern: #"\"approxDurationMs\":\"([0-9]+)\""#) {
            return milliseconds / 1_000
        }
        return nil
    }

    private static func firstNumber(in text: String, pattern: String) -> Double? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }
}
