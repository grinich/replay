import Foundation

struct ChapterExercise: Codable, Hashable {
    var question: String
    var solution: String
}

struct ChapterEnrichment: Codable, Hashable, Identifiable {
    var chapterID: String
    var chapterTitle: String
    var summary: String
    var keyPoints: [String]
    var exercises: [ChapterExercise]
    var generatedAt: Date

    var id: String { chapterID }
}

struct VideoEnrichment: Codable, Hashable {
    static let currentVersion = 1

    var version: Int
    var itemID: UUID
    var generatedAt: Date
    var chapters: [ChapterEnrichment]

    func enrichment(forChapterID chapterID: String) -> ChapterEnrichment? {
        chapters.first { $0.chapterID == chapterID }
    }
}

/// Pure logic for chapter enrichment: transcript slicing, prompt building,
/// and model-output parsing. Kept free of process/UI concerns so it can be
/// exercised by `tools/chapter_enrichment_check.swift`.
enum ChapterEnrichmentLogic {
    /// Maximum transcript characters sent to the model per chapter. Longer
    /// transcripts keep the head and tail, which usually carry the chapter's
    /// setup and conclusion.
    static let transcriptCharacterBudget = 14_000

    // MARK: Transcript slicing

    /// Returns the effective end time of a chapter, falling back to the next
    /// chapter's start or the video duration.
    static func endTime(
        for chapter: VideoChapter,
        in chapters: [VideoChapter],
        videoDuration: Double?
    ) -> Double {
        if let end = chapter.endTime, end > chapter.startTime { return end }
        if let index = chapters.firstIndex(of: chapter), index + 1 < chapters.count {
            return chapters[index + 1].startTime
        }
        if let videoDuration, videoDuration > chapter.startTime { return videoDuration }
        return .greatestFiniteMagnitude
    }

    /// Joins the cue text overlapping a chapter's time range into one
    /// transcript string. Consecutive duplicate cue lines (an artifact of
    /// YouTube auto-captions) are collapsed.
    static func transcript(
        for chapter: VideoChapter,
        in chapters: [VideoChapter],
        cues: [VideoSubtitleCue],
        videoDuration: Double?
    ) -> String {
        let end = endTime(for: chapter, in: chapters, videoDuration: videoDuration)
        var lines: [String] = []
        for cue in cues where cue.endTime > chapter.startTime && cue.startTime < end {
            for rawLine in cue.text.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, line != lines.last else { continue }
                lines.append(line)
            }
        }
        return truncateMiddle(lines.joined(separator: " "), limit: transcriptCharacterBudget)
    }

    /// Keeps the head and tail of overly long text, marking the elision.
    static func truncateMiddle(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 64 else { return text }
        let headCount = (limit * 2) / 3
        let tailCount = limit - headCount
        let head = text.prefix(headCount)
        let tail = text.suffix(tailCount)
        return "\(head)\n[... transcript truncated ...]\n\(tail)"
    }

    // MARK: Prompt

    static func prompt(
        videoTitle: String,
        videoAuthor: String,
        chapter: VideoChapter,
        chapterIndex: Int,
        chapterCount: Int,
        allChapterTitles: [String],
        transcript: String,
        previous: ChapterEnrichment? = nil,
        guidance: String? = nil
    ) -> String {
        let outline = allChapterTitles.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let author = videoAuthor.isEmpty ? "unknown" : videoAuthor
        var revisionBlock = ""
        if let guidance, !guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            revisionBlock += """

            --- USER GUIDANCE (HIGH PRIORITY) ---
            The person studying this video asked for the following change:

            \(guidance.trimmingCharacters(in: .whitespacesAndNewlines))

            Decide for yourself whether this needs a full rewrite or just a \
            targeted modification of the previous version below. Keep whatever \
            already serves the reader well. Either way, respond with the \
            complete JSON object in the required shape.
            --- END USER GUIDANCE ---

            """
        }
        if let previous {
            revisionBlock += """

            --- PREVIOUS VERSION OF THIS CHAPTER'S GUIDE ---
            \(previousVersionJSON(previous))
            --- END PREVIOUS VERSION ---

            """
        }
        return """
        You are generating study material for ONE chapter of a video, based on \
        its transcript. Work only from the transcript below. Do not use tools, \
        do not browse, and do not invent facts the transcript does not support.

        Video: \(videoTitle)
        Author: \(author)
        Chapter \(chapterIndex + 1) of \(chapterCount): \(chapter.title)

        Full chapter outline of the video (for context only — summarize ONLY \
        the current chapter):
        \(outline)

        Respond with a single JSON object and nothing else. No prose before or \
        after, no Markdown fences. Exact shape:

        {
          "summary": "3-5 sentence plain-language summary of THIS chapter",
          "keyPoints": ["2-5 short bullet strings with the concrete takeaways"],
          "exercises": [
            {
              "question": "a concrete application or problem-solving task",
              "solution": "a worked, technically precise solution or model answer"
            }
          ]
        }

        Exercise quality rules (HIGH PRIORITY):
        - 2 to 4 exercises, ordered from a focused application to a harder synthesis or design task.
        - NEVER ask the learner to recall the talk: no "what did the speaker say", "list/name/identify", "according to the speaker", or "describe the procedure" questions.
        - Every exercise must require the learner to DO something with the chapter's ideas, not merely restate them.
        - Silently classify the chapter before writing exercises. If it contains algorithms, code, mathematics, model architectures, training objectives, benchmarks, experimental methodology, systems, scientific mechanisms, or engineering trade-offs, treat it as TECHNICAL.
        - For a TECHNICAL chapter, every exercise must be technical. Use tasks such as: trace a concrete example; derive or compute a result; write pseudocode; design an experiment or ablation; diagnose a failure; predict behavior after changing a variable; compare methods under a stated constraint; critique a benchmark; or design a system using the mechanism taught.
        - Ground technical exercises in the actual named methods, quantities, equations, objectives, data flows, or failure modes in this transcript. Include enough scenario detail that the task can be solved without rewatching the talk.
        - When the transcript lacks an explicit numeric example, invent only harmless exercise inputs or hypothetical scenarios; do not invent factual claims about the talk.
        - Solutions should show the reasoning or intermediate steps, not just state the answer.
        - For nontechnical material, still require transfer, analysis, or decision-making—never speaker recall.
        - Exercises must be answerable using this chapter's content alone.
        - Mathematical notation is welcome where it helps: use simple inline \
        LaTeX delimited by $...$ (for example $2^{10}$ or $\\frac{a}{b}$). \
        Keep it simple; prefer plain text when math adds nothing.
        - Keep the summary specific: name the actual ideas, not just topics.
        - Valid JSON only: escape newlines inside strings as \\n.

        \(revisionBlock)
        --- CHAPTER TRANSCRIPT ---
        \(transcript)
        """
    }

    /// Serializes an existing chapter guide into the same JSON shape the
    /// model is asked to produce, for revision prompts.
    static func previousVersionJSON(_ enrichment: ChapterEnrichment) -> String {
        let payload: [String: Any] = [
            "summary": enrichment.summary,
            "keyPoints": enrichment.keyPoints,
            "exercises": enrichment.exercises.map { ["question": $0.question, "solution": $0.solution] }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: Output parsing

    private struct ModelOutput: Decodable {
        struct ModelExercise: Decodable {
            let question: String
            let solution: String?
        }

        let summary: String
        let keyPoints: [String]?
        let exercises: [ModelExercise]?
    }

    /// Parses a pi sub-agent's stdout into a `ChapterEnrichment`. Tolerates
    /// Markdown fences and stray prose around the JSON object.
    static func parse(
        output: String,
        chapterID: String,
        chapterTitle: String,
        generatedAt: Date = Date()
    ) -> ChapterEnrichment? {
        guard let json = extractJSONObject(from: output),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ModelOutput.self, from: data) else {
            return nil
        }
        let summary = decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        let keyPoints = (decoded.keyPoints ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let exercises = (decoded.exercises ?? []).compactMap { exercise -> ChapterExercise? in
            let question = exercise.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty, !isRecallOnlyExercise(question) else { return nil }
            let solution = (exercise.solution ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !solution.isEmpty else { return nil }
            return ChapterExercise(question: question, solution: solution)
        }
        // It is better to retry a chapter than persist a quiz made entirely of
        // recall prompts. The model contract requires at least two substantive
        // exercises, and this also catches truncated output.
        guard exercises.count >= 2 else { return nil }
        return ChapterEnrichment(
            chapterID: chapterID,
            chapterTitle: chapterTitle,
            summary: summary,
            keyPoints: keyPoints,
            exercises: exercises,
            generatedAt: generatedAt
        )
    }

    /// Rejects obvious lecture-recall prompts. This is deliberately narrow:
    /// causal "why" questions can still demand real understanding, while
    /// speaker-reporting, enumeration, and bare fact questions cannot.
    static func isRecallOnlyExercise(_ question: String) -> Bool {
        let normalized = question
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appliedSignals = [
            "given ", "suppose ", "consider ", "scenario", "would ",
            "calculate", "compute", "derive", "design", "predict", "diagnose",
            "debug", "trace", "construct", "implement", "pseudocode", "ablation",
            "experiment", "compare", "evaluate", "critique", "modify", "trade-off"
        ]
        if appliedSignals.contains(where: normalized.contains) { return false }

        let speakerRecall = [
            "did the speaker", "does the speaker", "speaker's view", "speaker’s view",
            "according to the speaker", "the speaker recommend", "the speaker mean"
        ]
        if speakerRecall.contains(where: normalized.contains) { return true }

        let recallPrefixes = [
            "what ", "who ", "when ", "where ", "which ", "list ", "name ",
            "identify ", "state ", "recall ", "describe the ", "summarize the "
        ]
        return recallPrefixes.contains(where: normalized.hasPrefix)
    }

    /// Extracts the first balanced top-level JSON object from mixed output,
    /// respecting string literals and escapes.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if inString {
                if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: Display text (lightweight math rendering)

    /// Converts inline LaTeX math (`$...$`, `$$...$$`, `\(...\)`) into plain
    /// Unicode so guide text renders nicely in SwiftUI without a web view.
    /// Handles the notation small models actually emit: Greek letters, common
    /// operators, fractions, roots, and super/subscripts. Dollar amounts like
    /// "$2,000 and $5" are left untouched (a span only counts as math when it
    /// contains math-ish structure).
    static func displayText(_ text: String) -> String {
        var result = replaceDelimitedMath(in: text, open: "\\(", close: "\\)")
        result = replaceDelimitedMath(in: result, open: "$$", close: "$$")
        result = replaceDollarMath(in: result)
        return result
    }

    private static func replaceDelimitedMath(in text: String, open: String, close: String) -> String {
        var result = ""
        var remainder = Substring(text)
        while let openRange = remainder.range(of: open) {
            let afterOpen = remainder[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: close) else { break }
            result += remainder[..<openRange.lowerBound]
            result += unicodeMath(String(afterOpen[..<closeRange.lowerBound]))
            remainder = afterOpen[closeRange.upperBound...]
        }
        result += remainder
        return result
    }

    private static func replaceDollarMath(in text: String) -> String {
        var result = ""
        var remainder = Substring(text)
        while let openIndex = remainder.firstIndex(of: "$") {
            let afterOpen = remainder[remainder.index(after: openIndex)...]
            guard let closeIndex = afterOpen.firstIndex(of: "$") else { break }
            let body = String(afterOpen[..<closeIndex])
            let consumed = remainder[..<openIndex]
            let rest = afterOpen[afterOpen.index(after: closeIndex)...]
            if looksLikeMath(body) {
                result += consumed
                result += unicodeMath(body)
                remainder = rest
            } else {
                // Not math (e.g. a dollar amount): keep the opening `$`
                // literally and rescan from the second `$`.
                result += consumed
                result += "$"
                result += body
                remainder = afterOpen[closeIndex...]
            }
        }
        result += remainder
        return result
    }

    /// A `$...$` span counts as math only when it has math-ish structure, so
    /// prose like "costs $2,000 and $5" survives untouched.
    private static func looksLikeMath(_ body: String) -> Bool {
        guard !body.isEmpty, !body.contains("\n") else { return false }
        if body.contains("\\") || body.contains("^") || body.contains("_") { return true }
        if body.contains("=") || body.contains("{") { return true }
        // Single-token algebra such as $x$, $n$, $O(n)$.
        let compact = body.replacingOccurrences(of: " ", with: "")
        if compact.count <= 8, compact.range(of: #"^[A-Za-z][A-Za-z0-9()+\-*/]*$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static let superscriptMap: [Character: Character] = [
        "0": "\u{2070}", "1": "\u{00B9}", "2": "\u{00B2}", "3": "\u{00B3}", "4": "\u{2074}",
        "5": "\u{2075}", "6": "\u{2076}", "7": "\u{2077}", "8": "\u{2078}", "9": "\u{2079}",
        "+": "\u{207A}", "-": "\u{207B}", "=": "\u{207C}", "(": "\u{207D}", ")": "\u{207E}",
        "a": "\u{1D43}", "b": "\u{1D47}", "c": "\u{1D9C}", "d": "\u{1D48}", "e": "\u{1D49}",
        "f": "\u{1DA0}", "g": "\u{1D4D}", "h": "\u{02B0}", "i": "\u{2071}", "j": "\u{02B2}",
        "k": "\u{1D4F}", "l": "\u{02E1}", "m": "\u{1D50}", "n": "\u{207F}", "o": "\u{1D52}",
        "p": "\u{1D56}", "r": "\u{02B3}", "s": "\u{02E2}", "t": "\u{1D57}", "u": "\u{1D58}",
        "v": "\u{1D5B}", "w": "\u{02B7}", "x": "\u{02E3}", "y": "\u{02B8}", "z": "\u{1DBB}",
        "T": "\u{1D40}", "N": "\u{1D3A}", "L": "\u{1D38}", "K": "\u{1D37}", "D": "\u{1D30}"
    ]

    private static let subscriptMap: [Character: Character] = [
        "0": "\u{2080}", "1": "\u{2081}", "2": "\u{2082}", "3": "\u{2083}", "4": "\u{2084}",
        "5": "\u{2085}", "6": "\u{2086}", "7": "\u{2087}", "8": "\u{2088}", "9": "\u{2089}",
        "+": "\u{208A}", "-": "\u{208B}", "=": "\u{208C}", "(": "\u{208D}", ")": "\u{208E}",
        "a": "\u{2090}", "e": "\u{2091}", "h": "\u{2095}", "i": "\u{1D62}", "j": "\u{2C7C}",
        "k": "\u{2096}", "l": "\u{2097}", "m": "\u{2098}", "n": "\u{2099}", "o": "\u{2092}",
        "p": "\u{209A}", "r": "\u{1D63}", "s": "\u{209B}", "t": "\u{209C}", "u": "\u{1D64}",
        "v": "\u{1D65}", "x": "\u{2093}"
    ]

    private static let mathSymbols: [(String, String)] = [
        ("varepsilon", "\u{03B5}"), ("varphi", "\u{03C6}"), ("epsilon", "\u{03B5}"),
        ("upsilon", "\u{03C5}"), ("Upsilon", "\u{03A5}"), ("lambda", "\u{03BB}"),
        ("Lambda", "\u{039B}"), ("alpha", "\u{03B1}"), ("gamma", "\u{03B3}"),
        ("Gamma", "\u{0393}"), ("delta", "\u{03B4}"), ("Delta", "\u{0394}"),
        ("theta", "\u{03B8}"), ("Theta", "\u{0398}"), ("kappa", "\u{03BA}"),
        ("sigma", "\u{03C3}"), ("Sigma", "\u{03A3}"), ("omega", "\u{03C9}"),
        ("Omega", "\u{03A9}"), ("beta", "\u{03B2}"), ("zeta", "\u{03B6}"),
        ("eta", "\u{03B7}"), ("iota", "\u{03B9}"), ("mu", "\u{03BC}"), ("nu", "\u{03BD}"),
        ("xi", "\u{03BE}"), ("Xi", "\u{039E}"), ("rho", "\u{03C1}"), ("tau", "\u{03C4}"),
        ("phi", "\u{03C6}"), ("Phi", "\u{03A6}"), ("chi", "\u{03C7}"), ("psi", "\u{03C8}"),
        ("Psi", "\u{03A8}"), ("pi", "\u{03C0}"), ("Pi", "\u{03A0}"),
        ("rightarrow", "\u{2192}"), ("leftarrow", "\u{2190}"), ("Rightarrow", "\u{21D2}"),
        ("Leftarrow", "\u{21D0}"), ("mapsto", "\u{21A6}"), ("to", "\u{2192}"),
        ("cdots", "\u{22EF}"), ("ldots", "\u{2026}"), ("dots", "\u{2026}"),
        ("approx", "\u{2248}"), ("propto", "\u{221D}"), ("simeq", "\u{2243}"),
        ("sim", "\u{223C}"), ("times", "\u{00D7}"), ("cdot", "\u{00B7}"),
        ("div", "\u{00F7}"), ("pm", "\u{00B1}"), ("mp", "\u{2213}"),
        ("leq", "\u{2264}"), ("geq", "\u{2265}"), ("le", "\u{2264}"), ("ge", "\u{2265}"),
        ("neq", "\u{2260}"), ("ne", "\u{2260}"), ("infty", "\u{221E}"),
        ("partial", "\u{2202}"), ("nabla", "\u{2207}"), ("sum", "\u{2211}"),
        ("prod", "\u{220F}"), ("int", "\u{222B}"), ("in", "\u{2208}"),
        ("notin", "\u{2209}"), ("subset", "\u{2282}"), ("supset", "\u{2283}"),
        ("cup", "\u{222A}"), ("cap", "\u{2229}"), ("forall", "\u{2200}"),
        ("exists", "\u{2203}"), ("ell", "\u{2113}"), ("hbar", "\u{210F}"),
        ("circ", "\u{2218}"), ("bullet", "\u{2022}"), ("star", "\u{22C6}"),
        ("degree", "\u{00B0}")
    ]

    /// Converts one math span's body to plain Unicode.
    static func unicodeMath(_ body: String) -> String {
        var math = body

        // \frac{a}{b} → a/b, parenthesizing multi-character operands.
        while let converted = convertFirst(
            pattern: #"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#,
            in: math,
            transform: { groups in
                let numerator = groups[0].count > 1 ? "(\(groups[0]))" : groups[0]
                let denominator = groups[1].count > 1 ? "(\(groups[1]))" : groups[1]
                return "\(numerator)/\(denominator)"
            }
        ) { math = converted }

        // \sqrt{x} → √(x)
        while let converted = convertFirst(pattern: #"\\sqrt\{([^{}]*)\}"#, in: math, transform: { groups in
            groups[0].count > 1 ? "\u{221A}(\(groups[0]))" : "\u{221A}\(groups[0])"
        }) { math = converted }

        // Unwrap text-style commands: \text{x}, \mathrm{x}, \operatorname{x}, ...
        while let converted = convertFirst(
            pattern: #"\\(?:text|textrm|textit|textbf|mathrm|mathit|mathbf|mathsf|mathcal|operatorname)\{([^{}]*)\}"#,
            in: math,
            transform: { $0[0] }
        ) { math = converted }

        // Named symbols (word-boundary aware).
        for (name, symbol) in mathSymbols {
            math = math.replacingOccurrences(
                of: "\\\\\(name)(?![A-Za-z])",
                with: symbol,
                options: .regularExpression
            )
        }

        // Spacing commands and grouping fences.
        for token in ["\\,", "\\;", "\\:", "\\!", "\\left", "\\right"] {
            math = math.replacingOccurrences(of: token, with: token == "\\!" ? "" : " ")
        }

        // Super/subscripts: ^{...} / ^x and _{...} / _x. Single pass, left
        // to right (the fallback can leave `^x` unchanged, so re-scanning
        // would never terminate).
        math = convertAll(pattern: #"\^\{([^{}]+)\}|\^([A-Za-z0-9+\-=()])"#, in: math) { groups in
            scriptText(groups.first(where: { !$0.isEmpty }) ?? "", using: superscriptMap, prefix: "^")
        }
        math = convertAll(pattern: #"_\{([^{}]+)\}|_([A-Za-z0-9+\-=()])"#, in: math) { groups in
            scriptText(groups.first(where: { !$0.isEmpty }) ?? "", using: subscriptMap, prefix: "_")
        }

        // Remaining commands become bare words (\log → log); drop stray braces.
        math = math.replacingOccurrences(of: #"\\([A-Za-z]+)"#, with: "$1", options: .regularExpression)
        math = math.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        math = math.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return math.trimmingCharacters(in: .whitespaces)
    }

    /// Maps script text to Unicode super/subscript characters, falling back
    /// to `^body` / `_body` when any character has no Unicode form.
    private static func scriptText(_ body: String, using map: [Character: Character], prefix: String) -> String {
        var mapped = ""
        for character in body {
            if character == " " { continue }
            guard let replacement = map[character] else { return prefix + body }
            mapped.append(replacement)
        }
        return mapped
    }

    /// Replaces every match of `pattern` in one left-to-right pass, handing
    /// capture groups to `transform`.
    private static func convertAll(
        pattern: String,
        in text: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            var groups: [String] = []
            for index in 1..<match.numberOfRanges {
                if let range = Range(match.range(at: index), in: text) {
                    groups.append(String(text[range]))
                } else {
                    groups.append("")
                }
            }
            result += text[cursor..<matchRange.lowerBound]
            result += transform(groups)
            cursor = matchRange.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// Replaces the first match of `pattern`, handing capture groups to
    /// `transform`. Returns nil when there is no match.
    private static func convertFirst(
        pattern: String,
        in text: String,
        transform: ([String]) -> String
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let matchRange = Range(match.range, in: text) else { return nil }
        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) {
                groups.append(String(text[range]))
            } else {
                groups.append("")
            }
        }
        return text.replacingCharacters(in: matchRange, with: transform(groups))
    }

    // MARK: Error reporting

    /// Distills a pi/deno stderr dump into one human-readable line. Provider
    /// errors often arrive as JSON blobs containing a `message` field; other
    /// failures are summarized by their last meaningful line.
    static func errorSummary(fromStderr stderr: String) -> String? {
        // Prefer an embedded provider error message, e.g.
        // {"type":"error","error":{"message":"You're out of extra usage..."}}
        if let range = stderr.range(of: #""message"\s*:\s*"((?:[^"\\]|\\.)*)""#, options: .regularExpression) {
            let match = String(stderr[range])
            if let valueStart = match.range(of: #":\s*"#, options: .regularExpression) {
                var value = String(match[valueStart.upperBound...])
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                value = value
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\n", with: " ")
                if !value.isEmpty { return String(value.prefix(220)) }
            }
        }
        let lines = stderr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Download ") && !$0.hasPrefix("Warning:") && !$0.hasPrefix("at ") }
        return lines.first.map { String($0.prefix(220)) }
    }

    // MARK: Persistence

    static func load(from url: URL) -> VideoEnrichment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let enrichment = try? decoder.decode(VideoEnrichment.self, from: data),
              enrichment.version == VideoEnrichment.currentVersion else { return nil }
        return enrichment
    }

    static func save(_ enrichment: VideoEnrichment, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(enrichment)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
