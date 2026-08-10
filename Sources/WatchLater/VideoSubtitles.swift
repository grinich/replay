import Foundation

struct VideoSubtitleCue: Equatable, Sendable {
    let startTime: Double
    let endTime: Double
    let text: String
}

struct VideoSubtitleTrack: Equatable, Sendable {
    let cues: [VideoSubtitleCue]

    init(cues: [VideoSubtitleCue]) {
        self.cues = cues
    }

    init?(contentsOf url: URL) {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parsed = Self.parse(source)
        guard !parsed.isEmpty else { return nil }
        cues = parsed
    }

    func text(at time: Double) -> String? {
        guard time.isFinite else { return nil }
        var seen: Set<String> = []
        let active = cues.compactMap { cue -> String? in
            guard cue.startTime <= time, time < cue.endTime, seen.insert(cue.text).inserted else { return nil }
            return cue.text
        }
        return active.isEmpty ? nil : active.joined(separator: "\n")
    }

    static func parse(_ source: String) -> [VideoSubtitleCue] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n[ \\t]*\n", with: "\n\n", options: .regularExpression)

        return normalized.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = parseTimestamp(timing[0]),
                  let end = parseTimestamp(timing[1]),
                  end > start else { return nil }

            let caption = cleanCaption(lines.dropFirst(timingIndex + 1).joined(separator: "\n"))
            guard !caption.isEmpty else { return nil }
            return VideoSubtitleCue(startTime: start, endTime: end, text: caption)
        }
        .sorted { lhs, rhs in
            lhs.startTime == rhs.startTime ? lhs.endTime < rhs.endTime : lhs.startTime < rhs.startTime
        }
    }

    private static func parseTimestamp(_ rawValue: String) -> Double? {
        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .first?
            .replacingOccurrences(of: ",", with: ".") ?? ""
        let fields = token.split(separator: ":").compactMap { Double($0) }
        switch fields.count {
        case 3:
            return fields[0] * 3_600 + fields[1] * 60 + fields[2]
        case 2:
            return fields[0] * 60 + fields[1]
        default:
            return nil
        }
    }

    private static func cleanCaption(_ rawValue: String) -> String {
        var value = rawValue
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]+\}"#, with: "", options: .regularExpression)
        let entities = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&#x27;": "'",
            "&nbsp;": " ",
            "&lrm;": "",
            "&rlm;": ""
        ]
        for (entity, replacement) in entities {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        return value.components(separatedBy: "\n")
            .map {
                $0.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
