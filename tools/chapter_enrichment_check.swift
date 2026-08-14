import Foundation

@main
struct ChapterEnrichmentCheck {
    static func main() {
        checkEndTimeResolution()
        checkTranscriptSlicing()
        checkTruncation()
        checkJSONExtraction()
        checkOutputParsing()
        checkErrorSummary()
        checkMathRendering()
        checkRevisionPrompt()
        checkPersistenceRoundTrip()
        print("chapter_enrichment_check=passed")
    }

    static let chapters = [
        VideoChapter(title: "Intro", startTime: 0, endTime: nil),
        VideoChapter(title: "Main", startTime: 10, endTime: nil),
        VideoChapter(title: "Outro", startTime: 20, endTime: nil)
    ]

    static let cues = [
        VideoSubtitleCue(startTime: 0, endTime: 4, text: "welcome to the video"),
        VideoSubtitleCue(startTime: 4, endTime: 9, text: "today we cover queues"),
        VideoSubtitleCue(startTime: 9, endTime: 12, text: "first a definition"),
        VideoSubtitleCue(startTime: 12, endTime: 15, text: "first a definition"),
        VideoSubtitleCue(startTime: 15, endTime: 19, text: "a queue is FIFO"),
        VideoSubtitleCue(startTime: 21, endTime: 25, text: "thanks for watching")
    ]

    static func checkEndTimeResolution() {
        precondition(ChapterEnrichmentLogic.endTime(for: chapters[0], in: chapters, videoDuration: 30) == 10)
        precondition(ChapterEnrichmentLogic.endTime(for: chapters[2], in: chapters, videoDuration: 30) == 30)
        precondition(ChapterEnrichmentLogic.endTime(for: chapters[2], in: chapters, videoDuration: nil) == .greatestFiniteMagnitude)
        let explicit = VideoChapter(title: "X", startTime: 5, endTime: 8)
        precondition(ChapterEnrichmentLogic.endTime(for: explicit, in: [explicit], videoDuration: 30) == 8)
    }

    static func checkTranscriptSlicing() {
        let intro = ChapterEnrichmentLogic.transcript(for: chapters[0], in: chapters, cues: cues, videoDuration: 30)
        // The 9-12s cue overlaps the 0-10s chapter boundary and is included.
        precondition(intro == "welcome to the video today we cover queues first a definition")

        let main = ChapterEnrichmentLogic.transcript(for: chapters[1], in: chapters, cues: cues, videoDuration: 30)
        // Consecutive duplicate cue text is collapsed once.
        precondition(main == "first a definition a queue is FIFO")

        let outro = ChapterEnrichmentLogic.transcript(for: chapters[2], in: chapters, cues: cues, videoDuration: 30)
        precondition(outro == "thanks for watching")
    }

    static func checkTruncation() {
        let short = ChapterEnrichmentLogic.truncateMiddle("hello", limit: 100)
        precondition(short == "hello")
        let long = String(repeating: "a", count: 500) + String(repeating: "z", count: 500)
        let truncated = ChapterEnrichmentLogic.truncateMiddle(long, limit: 300)
        precondition(truncated.contains("[... transcript truncated ...]"))
        precondition(truncated.hasPrefix("aaa"))
        precondition(truncated.hasSuffix("zzz"))
        precondition(truncated.count < long.count)
    }

    static func checkJSONExtraction() {
        let fenced = """
        Here is the result:
        ```json
        {"summary": "S", "keyPoints": ["a {brace} inside"], "exercises": []}
        ```
        Done.
        """
        let extracted = ChapterEnrichmentLogic.extractJSONObject(from: fenced)
        precondition(extracted == "{\"summary\": \"S\", \"keyPoints\": [\"a {brace} inside\"], \"exercises\": []}")

        let withEscapes = "{\"summary\": \"quote \\\" and brace } in string\"}"
        precondition(ChapterEnrichmentLogic.extractJSONObject(from: withEscapes) == withEscapes)

        precondition(ChapterEnrichmentLogic.extractJSONObject(from: "no json here") == nil)
        precondition(ChapterEnrichmentLogic.extractJSONObject(from: "{ unbalanced") == nil)
    }

    static func checkOutputParsing() {
        let output = """
        {
          "summary": "  The chapter defines FIFO queues.  ",
          "keyPoints": ["Queues are FIFO", "  ", "Stacks are LIFO"],
          "exercises": [
            {"question": "Trace a FIFO queue through enqueue(A), enqueue(B), and dequeue().", "solution": "The queue becomes [A], then [A, B]; dequeue returns A and leaves [B]."},
            {"question": "   ", "solution": "ignored"},
            {"question": "Given jobs J1, J2, and J3 arriving in that order, compare FIFO execution with a LIFO stack.", "solution": "FIFO runs J1, J2, J3; LIFO runs J3, J2, J1, so the disciplines reverse the service order."}
          ]
        }
        """
        guard let parsed = ChapterEnrichmentLogic.parse(output: output, chapterID: "10.0-Main", chapterTitle: "Main") else {
            preconditionFailure("Expected parseable output")
        }
        precondition(parsed.chapterID == "10.0-Main")
        precondition(parsed.summary == "The chapter defines FIFO queues.")
        precondition(parsed.keyPoints == ["Queues are FIFO", "Stacks are LIFO"])
        precondition(parsed.exercises.count == 2)
        precondition(parsed.exercises[0].solution.contains("dequeue returns A"))
        precondition(parsed.exercises[1].solution.contains("reverse the service order"))

        let recallOnly = """
        {"summary":"S","exercises":[
          {"question":"What two capabilities did the speaker identify?","solution":"A and B."},
          {"question":"Describe the benchmark procedure.","solution":"Adapt and average."}
        ]}
        """
        precondition(ChapterEnrichmentLogic.parse(output: recallOnly, chapterID: "x", chapterTitle: "X") == nil)
        precondition(ChapterEnrichmentLogic.isRecallOnlyExercise("According to the speaker, what is VTAB?"))
        precondition(ChapterEnrichmentLogic.isRecallOnlyExercise("List the stages of CLIP training."))
        precondition(!ChapterEnrichmentLogic.isRecallOnlyExercise("Given a 3×3 similarity matrix, compute the CLIP loss."))
        precondition(!ChapterEnrichmentLogic.isRecallOnlyExercise("Design an ablation that isolates the effect of captioning loss."))

        precondition(ChapterEnrichmentLogic.parse(output: "not json", chapterID: "x", chapterTitle: "X") == nil)
        precondition(ChapterEnrichmentLogic.parse(output: "{\"summary\": \"  \"}", chapterID: "x", chapterTitle: "X") == nil)

        // Prompt sanity: contains the transcript and demands JSON.
        let prompt = ChapterEnrichmentLogic.prompt(
            videoTitle: "T",
            videoAuthor: "",
            chapter: chapters[1],
            chapterIndex: 1,
            chapterCount: 3,
            allChapterTitles: chapters.map(\.title),
            transcript: "TRANSCRIPT-SENTINEL"
        )
        precondition(prompt.contains("TRANSCRIPT-SENTINEL"))
        precondition(prompt.contains("Chapter 2 of 3: Main"))
        precondition(prompt.contains("single JSON object"))
        precondition(prompt.contains("Author: unknown"))
    }

    static func checkErrorSummary() {
        let providerError = """
        Warning: client version mismatch
        400 {"type":"error","error":{"type":"invalid_request_error","message":"You're out of extra usage. Add more at claude.ai/settings/usage and keep going."},"request_id":"req_x"}
        """
        let summary = ChapterEnrichmentLogic.errorSummary(fromStderr: providerError)
        precondition(summary == "You're out of extra usage. Add more at claude.ai/settings/usage and keep going.")

        let crash = """
        Warning: something
        error: Uncaught TypeError: Cannot assign to read only property
        at new Event (ext:deno_web/02_event.js:138:29)
        """
        precondition(ChapterEnrichmentLogic.errorSummary(fromStderr: crash) == "error: Uncaught TypeError: Cannot assign to read only property")

        precondition(ChapterEnrichmentLogic.errorSummary(fromStderr: "") == nil)
        precondition(ChapterEnrichmentLogic.errorSummary(fromStderr: "Warning: only warnings\n") == nil)
    }

    static func checkMathRendering() {
        let render = ChapterEnrichmentLogic.displayText

        // Plain text and dollar amounts are untouched.
        precondition(render("no math here") == "no math here")
        precondition(render("costs $2,000 and $5 per run") == "costs $2,000 and $5 per run")
        precondition(render("a batch of $2,000 tokens") == "a batch of $2,000 tokens")

        // Superscripts, subscripts, Greek, operators.
        precondition(render("needs $2^{10}$ tokens") == "needs 2\u{00B9}\u{2070} tokens")
        precondition(render("$x_i$ and $x_{max}$") == "x\u{1D62} and x\u{2098}\u{2090}\u{2093}")
        precondition(render("$x_{qd}$") == "x_qd")
        precondition(render("$\\alpha \\cdot \\beta$") == "\u{03B1} \u{00B7} \u{03B2}")
        precondition(render("$a \\times b \\leq c$") == "a \u{00D7} b \u{2264} c")
        precondition(render("$O(n \\log n)$") == "O(n log n)")

        // Fractions, roots, text unwrapping.
        precondition(render("$\\frac{a}{b}$") == "a/b")
        precondition(render("$\\frac{a+b}{2}$") == "(a+b)/2")
        precondition(render("$\\sqrt{2}$") == "\u{221A}2")
        precondition(render("$\\text{cost} = 4$") == "cost = 4")

        // \( \) and $$ $$ delimiters.
        precondition(render("then \\(k^2\\) grows") == "then k\u{00B2} grows")
        precondition(render("$$E = mc^2$$") == "E = mc\u{00B2}")

        // Unmappable scripts degrade gracefully and never loop.
        precondition(render("$W^{Q}$") == "W^Q")
        precondition(render("$x^T W_q$") == "x\u{1D40} W_q")

        // Single-token algebra like $n$ is treated as math (delimiters removed).
        precondition(render("pick $n$ samples") == "pick n samples")
    }

    static func checkRevisionPrompt() {
        let previous = ChapterEnrichment(
            chapterID: "10.0-Main",
            chapterTitle: "Main",
            summary: "Old summary",
            keyPoints: ["old point"],
            exercises: [
                ChapterExercise(question: "Design an experiment using the old idea.", solution: "Run the experiment and compare outcomes."),
                ChapterExercise(question: "Given an edge case, diagnose the old method.", solution: "Trace the edge case and identify the failure.")
            ],
            generatedAt: Date()
        )
        let prompt = ChapterEnrichmentLogic.prompt(
            videoTitle: "T",
            videoAuthor: "A",
            chapter: chapters[1],
            chapterIndex: 1,
            chapterCount: 3,
            allChapterTitles: chapters.map(\.title),
            transcript: "TRANSCRIPT",
            previous: previous,
            guidance: "add more exercises"
        )
        precondition(prompt.contains("USER GUIDANCE (HIGH PRIORITY)"))
        precondition(prompt.contains("add more exercises"))
        precondition(prompt.contains("PREVIOUS VERSION OF THIS CHAPTER'S GUIDE"))
        precondition(prompt.contains("Old summary"))
        precondition(prompt.contains("Design an experiment using the old idea."))

        // Without guidance/previous, no revision blocks appear.
        let plain = ChapterEnrichmentLogic.prompt(
            videoTitle: "T",
            videoAuthor: "A",
            chapter: chapters[1],
            chapterIndex: 1,
            chapterCount: 3,
            allChapterTitles: chapters.map(\.title),
            transcript: "TRANSCRIPT"
        )
        precondition(!plain.contains("USER GUIDANCE"))
        precondition(!plain.contains("PREVIOUS VERSION"))

        // The previous-version JSON matches the model output schema.
        let json = ChapterEnrichmentLogic.previousVersionJSON(previous)
        let reparsed = ChapterEnrichmentLogic.parse(output: json, chapterID: "x", chapterTitle: "X")
        precondition(reparsed?.summary == "Old summary")
        precondition(reparsed?.exercises.first?.question == "Design an experiment using the old idea.")
    }

    static func checkPersistenceRoundTrip() {
        let enrichment = VideoEnrichment(
            version: VideoEnrichment.currentVersion,
            itemID: UUID(),
            generatedAt: Date(),
            chapters: [
                ChapterEnrichment(
                    chapterID: "0.0-Intro",
                    chapterTitle: "Intro",
                    summary: "S",
                    keyPoints: ["k"],
                    exercises: [ChapterExercise(question: "q", solution: "a")],
                    generatedAt: Date()
                )
            ]
        )
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enrichment-check-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("enrichment.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        try! ChapterEnrichmentLogic.save(enrichment, to: file)
        guard let loaded = ChapterEnrichmentLogic.load(from: file) else {
            preconditionFailure("Expected round-trip load")
        }
        precondition(loaded.itemID == enrichment.itemID)
        // ISO8601 encoding drops sub-second precision, so compare content fields.
        precondition(loaded.chapters.map(\.chapterID) == enrichment.chapters.map(\.chapterID))
        precondition(loaded.chapters.map(\.exercises) == enrichment.chapters.map(\.exercises))
        precondition(loaded.chapters.map(\.keyPoints) == enrichment.chapters.map(\.keyPoints))
        precondition(loaded.enrichment(forChapterID: "0.0-Intro")?.summary == "S")
        precondition(loaded.enrichment(forChapterID: "missing") == nil)

        // Unknown versions are rejected rather than misread.
        var future = enrichment
        future.version = 99
        try! ChapterEnrichmentLogic.save(future, to: file)
        precondition(ChapterEnrichmentLogic.load(from: file) == nil)

        precondition(ChapterEnrichmentLogic.load(from: dir.appendingPathComponent("absent.json")) == nil)
    }
}
