import Foundation

/// Generates chapter outlines, summaries, and exercises by running the pi
/// coding agent through the bundled Deno runtime (`deno run npm:...`). Videos
/// without source chapters get one planning subprocess first; guide generation
/// then uses one subprocess per chapter with bounded concurrency. Results are
/// persisted by the caller; this engine only orchestrates and parses.
final class EnrichmentEngine {
    struct Progress {
        let completedChapters: Int
        let totalChapters: Int
    }

    struct Outcome {
        let enrichment: VideoEnrichment
        let failedChapterTitles: [String]
    }

    enum EngineError: LocalizedError {
        case missingTool(String)
        case missingSubtitles
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingTool(let tool):
                return "\(tool) is not available. Reinstall Replay or install it with Homebrew."
            case .missingSubtitles:
                return "This video has no offline subtitles to summarize."
            case .cancelled:
                return "Enrichment cancelled."
            case .failed(let message):
                return message
            }
        }
    }



    /// Runtime knobs, overridable per machine without a rebuild:
    /// `defaults write com.mg.replay <key> <value>` or environment variables.
    enum Configuration {
        /// Pinned pi package for reproducible runs.
        static let defaultPiPackage = "npm:@earendil-works/pi-coding-agent@0.84.1"
        /// Verified working under the bundled Deno (v2.9.5+). Note: the
        /// Codex provider opens a WebSocket, which crashes on Deno < 2.9
        /// (undici MessageEvent incompatibility) — keep the bundled Deno
        /// current.
        static let defaultProvider = "openai-codex"
        /// Without an explicit model, pi keeps its configured default model,
        /// which may belong to a different provider. Always pin a model when
        /// using the default provider.
        static let defaultModel = "gpt-5.6-sol"

        static func value(key: String, environment: String) -> String? {
            if let fromDefaults = UserDefaults.standard.string(forKey: key), !fromDefaults.isEmpty {
                return fromDefaults
            }
            if let fromEnvironment = ProcessInfo.processInfo.environment[environment], !fromEnvironment.isEmpty {
                return fromEnvironment
            }
            return nil
        }

        static var piPackage: String {
            value(key: "enrichmentPiPackage", environment: "REPLAY_PI_PACKAGE") ?? defaultPiPackage
        }

        static var provider: String? {
            value(key: "enrichmentPiProvider", environment: "REPLAY_PI_PROVIDER") ?? defaultProvider
        }

        static var model: String? {
            if let override = value(key: "enrichmentPiModel", environment: "REPLAY_PI_MODEL") {
                return override
            }
            // Only apply the pinned default model when the provider is also
            // the default; a custom provider needs a matching custom model.
            return provider == defaultProvider ? defaultModel : nil
        }
    }

    private static let maximumConcurrentChapters = 2
    private static let chapterTimeout: TimeInterval = 420

    private let processLock = NSLock()
    private var processes: [UUID: [Process]] = [:]
    private var cancelledItems: Set<UUID> = []

    func enrich(
        item: WatchItem,
        existing: VideoEnrichment?,
        guidance: String? = nil,
        workDirectory: URL,
        denoCacheDirectory: URL,
        onProgress: @escaping (Progress) -> Void,
        completion: @escaping (Result<Outcome, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let outcome = try self.performEnrichment(
                    item: item,
                    existing: existing,
                    guidance: guidance,
                    workDirectory: workDirectory,
                    denoCacheDirectory: denoCacheDirectory,
                    onProgress: onProgress
                )
                completion(.success(outcome))
            } catch {
                completion(.failure(error))
            }
            self.clear(itemID: item.id)
        }
    }

    func cancel(itemID: UUID) {
        processLock.lock()
        cancelledItems.insert(itemID)
        let running = processes[itemID] ?? []
        processLock.unlock()
        running.forEach { $0.terminate() }
    }

    // MARK: - Orchestration

    private func performEnrichment(
        item: WatchItem,
        existing: VideoEnrichment?,
        guidance: String?,
        workDirectory: URL,
        denoCacheDirectory: URL,
        onProgress: @escaping (Progress) -> Void
    ) throws -> Outcome {
        let trimmedGuidance = guidance?.trimmingCharacters(in: .whitespacesAndNewlines)
        let revisionGuidance = (trimmedGuidance?.isEmpty ?? true) ? nil : trimmedGuidance
        processLock.lock()
        cancelledItems.remove(item.id)
        processLock.unlock()

        guard let subtitleURL = item.subtitleFileURL,
              let track = VideoSubtitleTrack(contentsOf: subtitleURL) else {
            throw EngineError.missingSubtitles
        }
        let deno = try requiredTool(named: "deno")

        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: denoCacheDirectory, withIntermediateDirectories: true)

        let generatedChapters: [VideoChapter]?
        let chapters: [VideoChapter]
        if item.availableChapters.isEmpty {
            if let persisted = existing?.generatedChapters, !persisted.isEmpty {
                generatedChapters = persisted
                chapters = persisted
            } else {
                let planned = generateChapterOutline(
                    item: item,
                    cues: track.cues,
                    deno: deno,
                    workDirectory: workDirectory,
                    denoCacheDirectory: denoCacheDirectory
                )
                generatedChapters = planned
                chapters = planned
            }
        } else {
            generatedChapters = nil
            chapters = item.availableChapters
        }
        guard !chapters.isEmpty else {
            throw EngineError.failed("The subtitle track was too short to create chapters.")
        }

        let totalChapters = chapters.count
        onProgress(Progress(completedChapters: 0, totalChapters: totalChapters))
        let stateLock = NSLock()
        var results: [Int: ChapterEnrichment] = [:]
        var failures: [Int: String] = [:]
        var completedCount = 0

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = Self.maximumConcurrentChapters
        queue.qualityOfService = .utility

        for (index, chapter) in chapters.enumerated() {
            // Reuse chapters that were already generated in a previous run —
            // unless the user gave revision guidance, in which case every
            // chapter is re-run with its previous version as context.
            if revisionGuidance == nil, let reused = existing?.enrichment(forChapterID: chapter.id) {
                stateLock.lock()
                results[index] = reused
                completedCount += 1
                let progress = Progress(completedChapters: completedCount, totalChapters: totalChapters)
                stateLock.unlock()
                onProgress(progress)
                continue
            }

            queue.addOperation { [weak self] in
                guard let self, !self.isCancelled(itemID: item.id) else { return }
                let result = self.enrichChapter(
                    itemID: item.id,
                    item: item,
                    chapter: chapter,
                    chapterIndex: index,
                    chapters: chapters,
                    cues: track.cues,
                    previous: existing?.enrichment(forChapterID: chapter.id),
                    guidance: revisionGuidance,
                    deno: deno,
                    workDirectory: workDirectory,
                    denoCacheDirectory: denoCacheDirectory
                )
                stateLock.lock()
                switch result {
                case .success(let enrichment): results[index] = enrichment
                case .failure(let error): failures[index] = error.localizedDescription
                }
                completedCount += 1
                let progress = Progress(completedChapters: completedCount, totalChapters: totalChapters)
                stateLock.unlock()
                onProgress(progress)
            }
        }

        queue.waitUntilAllOperationsAreFinished()

        if isCancelled(itemID: item.id) { throw EngineError.cancelled }

        let ordered = results.keys.sorted().compactMap { results[$0] }
        guard !ordered.isEmpty else {
            let detail = failures.values.first ?? "The pi sub-agents produced no usable output."
            throw EngineError.failed(detail)
        }
        let failedTitles = failures.keys.sorted().map { chapters[$0].title }
        let enrichment = VideoEnrichment(
            version: VideoEnrichment.currentVersion,
            itemID: item.id,
            generatedAt: Date(),
            chapters: ordered,
            generatedChapters: generatedChapters
        )
        return Outcome(enrichment: enrichment, failedChapterTitles: failedTitles)
    }

    private func generateChapterOutline(
        item: WatchItem,
        cues: [VideoSubtitleCue],
        deno: URL,
        workDirectory: URL,
        denoCacheDirectory: URL
    ) -> [VideoChapter] {
        let prompt = ChapterEnrichmentLogic.chapterPlanningPrompt(
            videoTitle: item.title,
            videoAuthor: item.author,
            cues: cues,
            videoDuration: item.duration
        )
        let result = runPi(
            prompt: prompt,
            itemID: item.id,
            slug: "chapter-plan",
            deno: deno,
            workDirectory: workDirectory,
            denoCacheDirectory: denoCacheDirectory
        )
        if case .success(let output) = result,
           let chapters = ChapterEnrichmentLogic.parseGeneratedChapters(
               output: output,
               cues: cues,
               videoDuration: item.duration
           ) {
            return chapters
        }
        return ChapterEnrichmentLogic.fallbackGeneratedChapters(
            cues: cues,
            videoDuration: item.duration
        )
    }

    private func enrichChapter(
        itemID: UUID,
        item: WatchItem,
        chapter: VideoChapter,
        chapterIndex: Int,
        chapters: [VideoChapter],
        cues: [VideoSubtitleCue],
        previous: ChapterEnrichment?,
        guidance: String?,
        deno: URL,
        workDirectory: URL,
        denoCacheDirectory: URL
    ) -> Result<ChapterEnrichment, Error> {
        let transcript = ChapterEnrichmentLogic.transcript(
            for: chapter,
            in: chapters,
            cues: cues,
            videoDuration: item.duration
        )
        guard transcript.count >= 40 else {
            return .failure(EngineError.failed("Chapter “\(chapter.title)” has too little transcript text."))
        }

        let prompt = ChapterEnrichmentLogic.prompt(
            videoTitle: item.title,
            videoAuthor: item.author,
            chapter: chapter,
            chapterIndex: chapterIndex,
            chapterCount: chapters.count,
            allChapterTitles: chapters.map(\.title),
            transcript: transcript,
            previous: guidance != nil ? previous : nil,
            guidance: guidance
        )
        let slug = String(format: "chapter-%02d", chapterIndex + 1)
        switch runPi(
            prompt: prompt,
            itemID: itemID,
            slug: slug,
            deno: deno,
            workDirectory: workDirectory,
            denoCacheDirectory: denoCacheDirectory
        ) {
        case .success(let output):
            guard let enrichment = ChapterEnrichmentLogic.parse(
                output: output,
                chapterID: chapter.id,
                chapterTitle: chapter.title
            ) else {
                return .failure(EngineError.failed("Could not parse the model output for “\(chapter.title)”. See \(slug).stdout.txt."))
            }
            return .success(enrichment)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Runs one headless, hermetic pi subprocess and records its prompt and
    /// streams beside the enrichment output for diagnosis.
    private func runPi(
        prompt: String,
        itemID: UUID,
        slug: String,
        deno: URL,
        workDirectory: URL,
        denoCacheDirectory: URL
    ) -> Result<String, Error> {
        let promptFile = workDirectory.appendingPathComponent("\(slug).prompt.md")
        let stderrFile = workDirectory.appendingPathComponent("\(slug).stderr.txt")
        let stdoutFile = workDirectory.appendingPathComponent("\(slug).stdout.txt")
        do {
            try prompt.write(to: promptFile, atomically: true, encoding: .utf8)
        } catch {
            return .failure(error)
        }

        let process = Process()
        process.executableURL = deno
        // No session, extensions, skills, context, or tools. The subprocess
        // only transforms the supplied transcript into structured JSON.
        var arguments = [
            "run", "-A", "--quiet", Configuration.piPackage,
            "-p", "--no-session", "-ne", "--no-skills",
            "--no-prompt-templates", "--no-context-files", "--no-tools"
        ]
        if let provider = Configuration.provider {
            arguments += ["--provider", provider]
        }
        if let model = Configuration.model {
            arguments += ["--model", model]
        }
        arguments.append("@\(promptFile.path)")
        process.arguments = arguments
        process.currentDirectoryURL = workDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["DENO_DIR"] = denoCacheDirectory.path
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .failure(error)
        }
        register(process, for: itemID)

        let watchdog = DispatchWorkItem { [weak process] in process?.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.chapterTimeout,
            execute: watchdog
        )
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        unregister(process, for: itemID)

        let output = String(decoding: stdoutData, as: UTF8.self)
        let stderrText = String(decoding: stderrData, as: UTF8.self)
        try? output.write(to: stdoutFile, atomically: true, encoding: .utf8)
        try? stderrText.write(to: stderrFile, atomically: true, encoding: .utf8)

        if isCancelled(itemID: itemID) { return .failure(EngineError.cancelled) }
        guard process.terminationStatus == 0 else {
            let detail = ChapterEnrichmentLogic.errorSummary(fromStderr: stderrText)
                ?? "pi exited with status \(process.terminationStatus)"
            return .failure(EngineError.failed(detail))
        }
        return .success(output)
    }

    // MARK: - Helpers

    private func isCancelled(itemID: UUID) -> Bool {
        processLock.lock()
        defer { processLock.unlock() }
        return cancelledItems.contains(itemID)
    }

    private func register(_ process: Process, for itemID: UUID) {
        processLock.lock()
        processes[itemID, default: []].append(process)
        processLock.unlock()
    }

    private func unregister(_ process: Process, for itemID: UUID) {
        processLock.lock()
        processes[itemID]?.removeAll { $0 === process }
        processLock.unlock()
    }

    private func clear(itemID: UUID) {
        processLock.lock()
        processes[itemID] = nil
        cancelledItems.remove(itemID)
        processLock.unlock()
    }

    private func requiredTool(named name: String) throws -> URL {
        guard let tool = findTool(named: name) else { throw EngineError.missingTool(name) }
        return tool
    }

    private func findTool(named name: String) -> URL? {
        var candidates: [String] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Tools/\(name)").path)
        }
        candidates += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
