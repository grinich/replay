import Foundation

enum ChapterMetadata {
    static func publicPostURL(for source: URL) -> URL? {
        guard let host = source.host?.lowercased(),
              ["x.com", "twitter.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        let parts = source.pathComponents
        guard let status = parts.firstIndex(of: "status"), status + 1 < parts.count else { return nil }
        let id = parts[status + 1]
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return URL(string: "https://api.fxtwitter.com/status/\(id)")
    }

    static func publicPostText(from data: Data) -> String? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["code"] as? Int == 200,
              let tweet = response["tweet"] as? [String: Any] else { return nil }
        return tweet["text"] as? String
    }

    /// Creator-supplied chapters take precedence over timestamp lists in post text.
    static func resolve(json: String, description: String?, duration: Double?) -> [VideoChapter] {
        if let chapters = decode(json: json), !chapters.isEmpty { return chapters }
        return parseTimestamps(in: description ?? "", duration: duration)
    }

    static func parseTimestamps(in text: String, duration: Double?) -> [VideoChapter] {
        // Accept plain timestamps and copied Markdown timestamp links. A list
        // entry begins on a new line or after a repeated-space inline separator.
        let pattern = #"(?m)(?:^|[\t ]{2,})[\t ]*(?:[-•*][\t ]+)?(?:\[(\d{1,3}:\d{2}(?::\d{2})?)\]\(https?://[^\s)]+\)|\(?(\d{1,3}:\d{2}(?::\d{2})?)\)?)(?=[\t ]|$)[\t ]*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
        var chapters: [VideoChapter] = []
        for (index, match) in matches.enumerated() {
            let timeRange = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            let parts = source.substring(with: timeRange).split(separator: ":").compactMap { Double($0) }
            guard parts.count >= 2, parts.dropFirst().allSatisfy({ $0 < 60 }) else { continue }
            let start = parts.reduce(0) { $0 * 60 + $1 }
            guard duration.map({ start < $0 }) ?? true else { continue }
            let titleStart = NSMaxRange(match.range)
            let titleEnd = index + 1 < matches.count ? matches[index + 1].range.location : source.length
            // Don't include prose or links following the timestamp list.
            let title = source.substring(with: NSRange(location: titleStart, length: titleEnd - titleStart))
                .components(separatedBy: .newlines).first?
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—|"))) ?? ""
            guard !title.isEmpty else { continue }
            // A chronological list avoids interpreting unrelated times as chapters.
            if let previous = chapters.last, start <= previous.startTime { return [] }
            chapters.append(VideoChapter(title: title, startTime: start, endTime: nil))
        }
        guard chapters.count >= 2 else { return [] }
        for index in chapters.indices {
            chapters[index].endTime = index + 1 < chapters.count ? chapters[index + 1].startTime : duration
        }
        return chapters
    }

    static func decode(json value: String) -> [VideoChapter]? {
        guard let data = value.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let records = raw as? [[String: Any]] else { return nil }

        return records.enumerated().compactMap { index, record in
            guard let startTime = number(from: record["start_time"]), startTime >= 0 else { return nil }
            let rawTitle = (record["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle?.isEmpty == false ? rawTitle! : "Chapter \(index + 1)"
            return VideoChapter(
                title: title,
                startTime: startTime,
                endTime: number(from: record["end_time"])
            )
        }
        .sorted { $0.startTime < $1.startTime }
    }

    private static func number(from value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
