import Foundation

@main
struct ResumeModelCheck {
    static func main() throws {
        let sample = WatchItem(
            id: UUID(),
            urlString: "https://example.com/video",
            title: "Test",
            author: "",
            duration: 600,
            addedAt: Date(),
            watchedAt: nil,
            state: .ready,
            progress: 1,
            progressLabel: "Ready offline",
            localFilePath: nil,
            errorMessage: nil,
            playbackPosition: 123.5,
            chapters: [VideoChapter(title: "Intro", startTime: 0, endTime: 60)],
            thumbnailFilePath: nil
        )
        let encoded = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(WatchItem.self, from: encoded)
        precondition(decoded.playbackPosition == 123.5)
        precondition(decoded.resumablePosition == 123.5)
        precondition(decoded.availableChapters.first?.title == "Intro")

        var older = sample
        older.title = "Older"
        older.addedAt = Date(timeIntervalSince1970: 100)
        var newer = sample
        newer.title = "Newer"
        newer.addedAt = Date(timeIntervalSince1970: 200)
        precondition(QueueOrderPolicy.newestFirst([older, newer]).map(\.title) == ["Newer", "Older"])

        let chapterJSON = #"[{"title":"Setup","start_time":65.25,"end_time":120},{"title":"Intro","start_time":0,"end_time":65.25}]"#
        let chapters = ChapterMetadata.decode(json: chapterJSON)
        precondition(chapters?.map(\.title) == ["Intro", "Setup"])
        precondition(chapters?.last?.startTime == 65.25)

        let timestampList = """
        0:00 Intro
        0:53 Family History & Identity
        7:03 Survival & Outsider Instinct
        18:53 Studying Exceptional People
        33:50 Self-Doubt & Success
        41:17 Steve Jobs & Obsession
        52:50 Joining Sequoia
        1:03:22 Leadership & Alex Ferguson
        1:08:25 Elon Musk & AI
        1:17:12 Becoming Who You Are
        """
        let expectedTimes: [Double] = [0, 53, 423, 1133, 2030, 2477, 3170, 3802, 4105, 4632]
        for separator in ["\n", "  "] {
            let text = timestampList.components(separatedBy: "\n").joined(separator: separator)
            let parsed = ChapterMetadata.resolve(json: "NA", description: text, duration: 5648.32)
            precondition(parsed.map(\.startTime) == expectedTimes)
            precondition(parsed[1].title == "Family History & Identity")
            precondition(parsed[7].title == "Leadership & Alex Ferguson")
            precondition(parsed.first?.endTime == 53 && parsed.last?.endTime == 5648.32)
        }
        let linked = timestampList.components(separatedBy: "\n").map { line -> String in
            let parts = line.split(separator: " ", maxSplits: 1)
            return "[\(parts[0])](https://x.com/patrick_oshag/status/2100213636706795949?t=0) \(parts[1])"
        }.joined(separator: "  ")
        precondition(ChapterMetadata.parseTimestamps(in: linked, duration: nil).map(\.startTime) == expectedTimes)
        precondition(ChapterMetadata.resolve(json: chapterJSON, description: timestampList, duration: 600) == chapters!)
        for invalid in ["Meet at 7:03 tomorrow", "0:00 Intro", "0:00 Intro\n0:99 Invalid", "1:00 Later\n0:00 Earlier", "0:00 Intro\n0:00 Duplicate"] {
            precondition(ChapterMetadata.parseTimestamps(in: invalid, duration: nil).isEmpty)
        }
        let bounded = ChapterMetadata.parseTimestamps(in: "0:00 Intro\n0:30 Middle\n1:00 Beyond", duration: 60)
        precondition(bounded.map(\.startTime) == [0, 30] && bounded.last?.endTime == 60)
        let publicURL = ChapterMetadata.publicPostURL(for: URL(string: "https://x.com/patrick_oshag/status/2100213636706795949?t=53")!)
        precondition(publicURL?.absoluteString == "https://api.fxtwitter.com/status/2100213636706795949")
        precondition(ChapterMetadata.publicPostURL(for: URL(string: "https://notx.com/name/status/123")!) == nil)
        let response = try JSONSerialization.data(withJSONObject: ["code": 200, "tweet": ["text": timestampList]])
        precondition(ChapterMetadata.publicPostText(from: response) == timestampList)
        precondition(ChapterMetadata.publicPostText(from: Data("{}".utf8)) == nil)


        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "playbackPosition")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let migrated = try JSONDecoder().decode(WatchItem.self, from: legacyData)
        precondition(migrated.playbackPosition == nil)

        if let queuePath = CommandLine.arguments.dropFirst().first,
           FileManager.default.fileExists(atPath: queuePath) {
            let queueData = try Data(contentsOf: URL(fileURLWithPath: queuePath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            _ = try decoder.decode([WatchItem].self, from: queueData)
        }

        print("resume_model_check=passed")
    }
}
