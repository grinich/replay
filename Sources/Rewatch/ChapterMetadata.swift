import Foundation

enum ChapterMetadata {
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
