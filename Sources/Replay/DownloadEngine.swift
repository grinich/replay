import Foundation

final class DownloadEngine {
    static var logsFolderURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Replay", isDirectory: true)
    }

    static func logFileURL(for itemID: UUID) -> URL {
        logsFolderURL.appendingPathComponent("\(itemID.uuidString).log")
    }

    struct Metadata {
        let title: String
        let author: String
        let duration: Double?
        let chapters: [VideoChapter]
    }

    struct Result {
        let fileURL: URL
        let thumbnailFileURL: URL?
        let subtitleFileURL: URL?
        let metadata: Metadata
    }

    struct Preview {
        let title: String
        let author: String
        let duration: Double?
        let thumbnailData: Data?
    }

    enum Event {
        case metadata(Metadata)
        case progress(Double, String)
        case playbackSource(VideoPlaybackSource)
        case subtitleFile(URL)
    }

    enum EngineError: LocalizedError {
        case missingTool(String)
        case failed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .missingTool(let tool): return "\(tool) is not installed. Install it with Homebrew and retry."
            case .failed(let message): return message
            case .cancelled: return "Download cancelled."
            }
        }
    }

    private let processLock = NSLock()
    private var processes: [UUID: Process] = [:]
    private let metadataQueue = DispatchQueue(label: "com.mg.replay.metadata", qos: .utility)
    private let previewQueue = DispatchQueue(label: "com.mg.replay.preview", qos: .userInitiated)
    private let playbackQueue = DispatchQueue(
        label: "com.mg.replay.progressive-playback",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let downloadFormat = "bv*[height<=1080][ext=mp4][protocol^=http]+ba[ext=m4a][protocol^=http]/b[height<=1080][ext=mp4][protocol^=http]/b[height<=1080]/best"
    // Prefer a single progressive stream for immediate playback. YouTube's
    // 1080p representation is normally split into separate video and audio
    // files; AVFoundation can take a long time to index those through a remote
    // composition. The combined stream starts directly while downloadFormat
    // continues fetching the full-quality offline copy in parallel.
    private static let progressiveFormat = "b[height<=720][ext=mp4][vcodec!=none][acodec!=none][protocol^=http]/b[height<=720][vcodec!=none][acodec!=none]/best"

    private final class PreviewResponseBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func store(_ data: Data, for key: String) {
            lock.lock()
            values[key] = data
            lock.unlock()
        }

        func value(for key: String) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }
    }

    func start(
        itemID: UUID,
        sourceURL: URL,
        destination: URL,
        onEvent: @escaping (Event) -> Void,
        completion: @escaping (Swift.Result<DownloadEngine.Result, Error>) -> Void
    ) {
        // Resolve a directly playable source independently of the offline
        // download. The direct combined stream can start without waiting for
        // yt-dlp to finish downloading and merging the high-quality local copy.
        playbackQueue.async { [weak self] in
            guard let self,
                  let source = try? self.resolvePlaybackSource(sourceURL: sourceURL) else { return }
            onEvent(.playbackSource(source))
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let logURL = Self.logFileURL(for: itemID)
            var logHandle: FileHandle?
            do {
                let ytDlp = try self.requiredTool(named: "yt-dlp")
                let ffmpeg = try self.requiredTool(named: "ffmpeg")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

                let process = Process()
                let output = Pipe()
                process.executableURL = ytDlp
                process.standardOutput = output
                process.standardError = output
                process.currentDirectoryURL = destination
                process.environment = self.processEnvironment()

                var arguments = [
                    "--ignore-config",
                    "--no-playlist",
                    "--continue",
                    "--part",
                    "--newline",
                    "--no-color",
                    "--paths", destination.path,
                    "--output", "\(itemID.uuidString).%(ext)s",
                    "--format", Self.downloadFormat,
                    "--merge-output-format", "mp4",
                    "--write-thumbnail",
                    "--convert-thumbnails", "jpg",
                    "--write-subs",
                    "--write-auto-subs",
                    "--sub-langs", "en.*,-live_chat",
                    "--sub-format", "vtt/best",
                    "--convert-subs", "srt",
                    "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
                    "--progress-template", "download:WL_PROGRESS\t%(progress._percent_str)s\t%(progress._speed_str)s\t%(progress._eta_str)s",
                    "--print", "before_dl:WL_META\t%(title)j\t%(uploader)j\t%(duration)j\t%(chapters)j",
                    "--print", "after_move:WL_DONE\t%(filepath)j\t%(title)j\t%(uploader)j\t%(duration)j\t%(chapters)j"
                ]
                if let deno = self.findTool(named: "deno") {
                    arguments += ["--js-runtimes", "deno:\(deno.path)"]
                }
                arguments.append(sourceURL.absoluteString)
                process.arguments = arguments

                logHandle = try self.prepareLog(
                    at: logURL,
                    sourceURL: sourceURL,
                    executable: ytDlp,
                    arguments: arguments
                )
                defer { try? logHandle?.close() }

                self.setProcess(process, for: itemID)
                try process.run()

                var pending = ""
                var recentLines: [String] = []
                var latestMetadata = Metadata(
                    title: sourceURL.host ?? "Video",
                    author: "",
                    duration: nil,
                    chapters: []
                )
                var finishedFile: URL?
                var announcedSubtitleURL: URL?

                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    try? logHandle?.write(contentsOf: data)
                    pending += String(decoding: data, as: UTF8.self)
                    let lines = pending.components(separatedBy: .newlines)
                    pending = lines.last ?? ""
                    for line in lines.dropLast() {
                        self.parse(
                            line: line,
                            metadata: &latestMetadata,
                            finishedFile: &finishedFile,
                            recentLines: &recentLines,
                            onEvent: onEvent
                        )
                    }
                    if announcedSubtitleURL == nil,
                       let subtitleURL = self.discoverSubtitle(for: itemID, in: destination),
                       subtitleURL.pathExtension.lowercased() == "srt" {
                        announcedSubtitleURL = subtitleURL
                        onEvent(.subtitleFile(subtitleURL))
                    }
                }
                if !pending.isEmpty {
                    self.parse(
                        line: pending,
                        metadata: &latestMetadata,
                        finishedFile: &finishedFile,
                        recentLines: &recentLines,
                        onEvent: onEvent
                    )
                }
                process.waitUntilExit()
                self.removeProcess(for: itemID)

                if process.terminationReason == .uncaughtSignal {
                    throw EngineError.cancelled
                }
                guard process.terminationStatus == 0 else {
                    let useful = recentLines.suffix(10).joined(separator: "\n")
                    throw EngineError.failed(useful.isEmpty ? "yt-dlp exited with status \(process.terminationStatus)." : useful)
                }
                guard let fileURL = finishedFile ?? self.discoverFile(for: itemID, in: destination) else {
                    throw EngineError.failed("The download finished, but its local file could not be found.")
                }
                completion(.success(Result(
                    fileURL: fileURL,
                    thumbnailFileURL: self.discoverThumbnail(for: itemID, in: destination),
                    subtitleFileURL: self.discoverSubtitle(for: itemID, in: destination),
                    metadata: latestMetadata
                )))
            } catch {
                self.appendLog("\nReplay error: \(error.localizedDescription)\n", to: logURL)
                self.removeProcess(for: itemID)
                completion(.failure(error))
            }
        }
    }

    func cancel(itemID: UUID) {
        processLock.lock()
        let process = processes[itemID]
        processLock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func resolvePlaybackSource(sourceURL: URL) throws -> VideoPlaybackSource {
        let ytDlp = try requiredTool(named: "yt-dlp")
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = ytDlp
        process.standardOutput = output
        process.standardError = errors
        process.environment = processEnvironment()
        var arguments = [
            "--ignore-config",
            "--no-playlist",
            "--no-color",
            "--no-warnings",
            // The Android client still exposes YouTube's progressive format 18
            // on videos where the default client only offers separate tracks.
            // This applies only to the early-playback resolver; the offline
            // download keeps its normal high-quality format/client selection.
            "--extractor-args", "youtube:player_client=android",
            "--format", Self.progressiveFormat,
            "--get-url"
        ]
        if let deno = findTool(named: "deno") {
            arguments += ["--js-runtimes", "deno:\(deno.path)"]
        }
        arguments.append(sourceURL.absoluteString)
        process.arguments = arguments

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError.failed(message.isEmpty ? "Could not prepare progressive playback." : message)
        }

        let urls = String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .compactMap { line -> URL? in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.hasPrefix("http://") || value.hasPrefix("https://") else { return nil }
                return URL(string: value)
            }
        guard let videoURL = urls.first else {
            throw EngineError.failed("The video service did not provide a playable stream.")
        }
        return VideoPlaybackSource(videoURL: videoURL)
    }

    func fetchMetadata(
        sourceURL: URL,
        completion: @escaping (Swift.Result<Metadata, Error>) -> Void
    ) {
        metadataQueue.async { [weak self] in
            guard let self else { return }
            do {
                let ytDlp = try self.requiredTool(named: "yt-dlp")
                let process = Process()
                let output = Pipe()
                process.executableURL = ytDlp
                process.standardOutput = output
                process.standardError = output
                process.environment = self.processEnvironment()
                var arguments = [
                    "--ignore-config",
                    "--no-playlist",
                    "--skip-download",
                    "--no-color",
                    "--print", "WL_META\t%(title)j\t%(uploader)j\t%(duration)j\t%(chapters)j"
                ]
                if let deno = self.findTool(named: "deno") {
                    arguments += ["--js-runtimes", "deno:\(deno.path)"]
                }
                arguments.append(sourceURL.absoluteString)
                process.arguments = arguments

                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw EngineError.failed("Could not refresh video chapter metadata.")
                }

                var metadata = Metadata(
                    title: sourceURL.host ?? "Video",
                    author: "",
                    duration: nil,
                    chapters: []
                )
                var finishedFile: URL?
                var recentLines: [String] = []
                for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
                    self.parse(
                        line: line,
                        metadata: &metadata,
                        finishedFile: &finishedFile,
                        recentLines: &recentLines,
                        onEvent: { _ in }
                    )
                }
                completion(.success(metadata))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func fetchPreview(
        sourceURL: URL,
        completion: @escaping (Swift.Result<Preview, Error>) -> Void
    ) {
        previewQueue.async { [weak self] in
            guard let self else { return }
            if URLIntake.youtubeVideoID(from: sourceURL) != nil,
               let preview = try? self.fetchFastYouTubePreview(sourceURL: sourceURL) {
                // Render title/author/thumbnail as soon as the lightweight
                // oEmbed request returns. Duration comes from the watch page
                // and is allowed to enrich the already-visible card later.
                completion(.success(preview))
                if let duration = self.fetchFastYouTubeDuration(sourceURL: sourceURL) {
                    completion(.success(Preview(
                        title: preview.title,
                        author: preview.author,
                        duration: duration,
                        thumbnailData: preview.thumbnailData
                    )))
                }
                return
            }
            do {
                let ytDlp = try self.requiredTool(named: "yt-dlp")
                let process = Process()
                let output = Pipe()
                process.executableURL = ytDlp
                process.standardOutput = output
                process.standardError = output
                process.environment = self.processEnvironment()
                var arguments = [
                    "--ignore-config",
                    "--no-playlist",
                    "--skip-download",
                    "--no-color",
                    "--print", "WL_PREVIEW\t%(title)j\t%(uploader)j\t%(duration)j\t%(thumbnail)j"
                ]
                if let deno = self.findTool(named: "deno") {
                    arguments += ["--js-runtimes", "deno:\(deno.path)"]
                }
                arguments.append(sourceURL.absoluteString)
                process.arguments = arguments

                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw EngineError.failed("Could not load this video's details.")
                }

                guard let line = String(decoding: data, as: UTF8.self)
                    .components(separatedBy: .newlines)
                    .first(where: { $0.hasPrefix("WL_PREVIEW\t") }) else {
                    throw EngineError.failed("The video service did not return any details.")
                }
                let fields = line.components(separatedBy: "\t")
                let title: String = fields.count > 1 ? self.decodeJSON(fields[1]) ?? "Video" : "Video"
                let author: String = fields.count > 2 ? self.decodeJSON(fields[2]) ?? "" : ""
                let duration: Double? = fields.count > 3 ? self.decodeJSON(fields[3]) : nil
                let thumbnailString: String? = fields.count > 4 ? self.decodeJSON(fields[4]) : nil
                let thumbnailData = thumbnailString
                    .flatMap(URL.init(string:))
                    .flatMap(self.fetchPreviewThumbnail)
                completion(.success(Preview(
                    title: title,
                    author: author,
                    duration: duration,
                    thumbnailData: thumbnailData
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func fetchFastYouTubePreview(sourceURL: URL) throws -> Preview {
        guard let videoID = URLIntake.youtubeVideoID(from: sourceURL),
              let canonicalURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)"),
              var oEmbedComponents = URLComponents(string: "https://www.youtube.com/oembed"),
              let fallbackThumbnailURL = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg") else {
            throw EngineError.failed("Could not identify this YouTube video.")
        }
        oEmbedComponents.queryItems = [
            URLQueryItem(name: "url", value: canonicalURL.absoluteString),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let oEmbedURL = oEmbedComponents.url else {
            throw EngineError.failed("Could not prepare the YouTube preview request.")
        }

        let requests: [(String, URL)] = [
            ("oembed", oEmbedURL),
            ("thumbnail", fallbackThumbnailURL)
        ]
        let responses = PreviewResponseBuffer()
        let group = DispatchGroup()
        var tasks: [URLSessionDataTask] = []
        for (key, url) in requests {
            group.enter()
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.cachePolicy = .returnCacheDataElseLoad
            let task = URLSession.shared.dataTask(with: request) { data, response, _ in
                defer { group.leave() }
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let data else { return }
                responses.store(data, for: key)
            }
            tasks.append(task)
            task.resume()
        }
        if group.wait(timeout: .now() + 3.5) == .timedOut {
            tasks.forEach { $0.cancel() }
        }

        guard let oEmbedData = responses.value(for: "oembed"),
              let metadata = YouTubePreviewMetadata.parseOEmbed(oEmbedData) else {
            throw EngineError.failed("Could not load this video's details.")
        }
        let thumbnailData = responses.value(for: "thumbnail")
            ?? metadata.thumbnailURL.flatMap(fetchPreviewThumbnail)
        return Preview(
            title: metadata.title,
            author: metadata.author,
            duration: nil,
            thumbnailData: thumbnailData
        )
    }

    private func fetchFastYouTubeDuration(sourceURL: URL) -> Double? {
        guard let videoID = URLIntake.youtubeVideoID(from: sourceURL),
              let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)"),
              let data = fetchPreviewData(from: url, timeout: 5, maximumBytes: 4_000_000) else {
            return nil
        }
        return YouTubePreviewMetadata.duration(fromWatchPage: data)
    }

    func fetchThumbnail(
        itemID: UUID,
        sourceURL: URL,
        destination: URL,
        completion: @escaping (Swift.Result<URL?, Error>) -> Void
    ) {
        metadataQueue.async { [weak self] in
            guard let self else { return }
            do {
                let ytDlp = try self.requiredTool(named: "yt-dlp")
                let ffmpeg = try self.requiredTool(named: "ffmpeg")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

                let process = Process()
                let output = Pipe()
                process.executableURL = ytDlp
                process.standardOutput = output
                process.standardError = output
                process.environment = self.processEnvironment()
                var arguments = [
                    "--ignore-config",
                    "--no-playlist",
                    "--skip-download",
                    "--write-thumbnail",
                    "--convert-thumbnails", "jpg",
                    "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
                    "--paths", destination.path,
                    "--output", "\(itemID.uuidString).%(ext)s"
                ]
                if let deno = self.findTool(named: "deno") {
                    arguments += ["--js-runtimes", "deno:\(deno.path)"]
                }
                arguments.append(sourceURL.absoluteString)
                process.arguments = arguments

                try process.run()
                _ = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw EngineError.failed("Could not cache the video thumbnail.")
                }
                completion(.success(self.discoverThumbnail(for: itemID, in: destination)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func fetchSubtitle(
        itemID: UUID,
        sourceURL: URL,
        destination: URL,
        completion: @escaping (Swift.Result<URL?, Error>) -> Void
    ) {
        metadataQueue.async { [weak self] in
            guard let self else { return }
            do {
                let ytDlp = try self.requiredTool(named: "yt-dlp")
                let ffmpeg = try self.requiredTool(named: "ffmpeg")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

                let process = Process()
                let output = Pipe()
                process.executableURL = ytDlp
                process.standardOutput = output
                process.standardError = output
                process.environment = self.processEnvironment()
                var arguments = [
                    "--ignore-config",
                    "--no-playlist",
                    "--skip-download",
                    "--no-color",
                    "--write-subs",
                    "--write-auto-subs",
                    "--sub-langs", "en.*,-live_chat",
                    "--sub-format", "vtt/best",
                    "--convert-subs", "srt",
                    "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
                    "--paths", destination.path,
                    "--output", "\(itemID.uuidString).%(ext)s"
                ]
                if let deno = self.findTool(named: "deno") {
                    arguments += ["--js-runtimes", "deno:\(deno.path)"]
                }
                arguments.append(sourceURL.absoluteString)
                process.arguments = arguments

                try process.run()
                _ = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw EngineError.failed("Could not cache subtitles for this video.")
                }
                completion(.success(self.discoverSubtitle(for: itemID, in: destination)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func parse(
        line: String,
        metadata: inout Metadata,
        finishedFile: inout URL?,
        recentLines: inout [String],
        onEvent: (Event) -> Void
    ) {
        if line.hasPrefix("WL_PROGRESS\t") {
            let fields = line.components(separatedBy: "\t")
            let rawPercent = fields.count > 1 ? fields[1] : ""
            let numeric = rawPercent.replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces)
            let fraction = min(max((Double(numeric) ?? 0) / 100, 0), 1)
            let speed = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
            let eta = fields.count > 3 ? fields[3].trimmingCharacters(in: .whitespaces) : ""
            let label = [rawPercent.trimmingCharacters(in: .whitespaces), speed, eta.isEmpty ? "" : "ETA \(eta)"]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            onEvent(.progress(fraction, label))
            return
        }

        if line.hasPrefix("WL_META\t") || line.hasPrefix("WL_DONE\t") {
            let fields = line.components(separatedBy: "\t")
            let offset = line.hasPrefix("WL_DONE\t") ? 2 : 1
            if line.hasPrefix("WL_DONE\t"), fields.count > 1,
               let path: String = decodeJSON(fields[1]), !path.isEmpty {
                finishedFile = URL(fileURLWithPath: path)
            }
            let title: String = fields.count > offset ? decodeJSON(fields[offset]) ?? metadata.title : metadata.title
            let author: String = fields.count > offset + 1 ? decodeJSON(fields[offset + 1]) ?? metadata.author : metadata.author
            let duration: Double? = fields.count > offset + 2 ? decodeJSON(fields[offset + 2]) : metadata.duration
            let chapters = fields.count > offset + 3
                ? ChapterMetadata.decode(json: fields[offset + 3]) ?? metadata.chapters
                : metadata.chapters
            metadata = Metadata(title: title, author: author, duration: duration, chapters: chapters)
            onEvent(.metadata(metadata))
            return
        }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            recentLines.append(trimmed)
            if recentLines.count > 30 { recentLines.removeFirst() }
        }
    }

    private func decodeJSON<T>(_ value: String) -> T? {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if decoded is NSNull { return nil }
        return decoded as? T
    }

    private func fetchPreviewThumbnail(from url: URL) -> Data? {
        fetchPreviewData(from: url, timeout: 10, maximumBytes: 12_000_000)
    }

    private func fetchPreviewData(
        from url: URL,
        timeout: TimeInterval,
        maximumBytes: Int
    ) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .returnCacheDataElseLoad
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let response = response as? HTTPURLResponse,
               (200..<300).contains(response.statusCode),
               let data,
               data.count <= maximumBytes {
                result = data
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 0.5) == .timedOut {
            task.cancel()
        }
        return result
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

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let bundledTools = Bundle.main.resourceURL?.appendingPathComponent("Tools").path
        environment["PATH"] = [
            bundledTools,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        .compactMap { $0 }
        .joined(separator: ":")
        return environment
    }

    private func prepareLog(
        at url: URL,
        sourceURL: URL,
        executable: URL,
        arguments: [String]
    ) throws -> FileHandle {
        try FileManager.default.createDirectory(
            at: Self.logsFolderURL,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        let header = """
        Replay download log
        Started: \(ISO8601DateFormatter().string(from: Date()))
        Source: \(sourceURL.absoluteString)
        Tool: \(executable.path)
        Arguments: \(arguments.joined(separator: " "))

        """
        try handle.write(contentsOf: Data(header.utf8))
        return handle
    }

    private func appendLog(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { }
    }

    private func discoverFile(for itemID: UUID, in folder: URL) -> URL? {
        let prefix = itemID.uuidString + "."
        let supported = Set(["mp4", "webm", "mkv", "mov", "m4v"])
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && supported.contains($0.pathExtension.lowercased()) }
            .max { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left < right
            }
    }

    private func discoverThumbnail(for itemID: UUID, in folder: URL) -> URL? {
        let prefix = itemID.uuidString + "."
        let supported = Set(["jpg", "jpeg", "png", "webp"])
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter {
            $0.lastPathComponent.hasPrefix(prefix) && supported.contains($0.pathExtension.lowercased())
        }
        .max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
    }

    private func discoverSubtitle(for itemID: UUID, in folder: URL) -> URL? {
        let prefix = itemID.uuidString + "."
        let supported = Set(["srt", "vtt"])
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter {
                $0.lastPathComponent.hasPrefix(prefix) && supported.contains($0.pathExtension.lowercased())
            }
            .sorted { lhs, rhs in
                let leftRank = self.subtitleRank(lhs)
                let rightRank = self.subtitleRank(rhs)
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.lastPathComponent.count < rhs.lastPathComponent.count
            }
            .first
    }

    private func subtitleRank(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if name.hasSuffix(".en") { return 0 }
        if name.hasSuffix(".en-orig") { return 1 }
        if name.range(of: #"\.en[-_]"#, options: .regularExpression) != nil { return 2 }
        return 3
    }

    private func setProcess(_ process: Process, for itemID: UUID) {
        processLock.lock()
        processes[itemID] = process
        processLock.unlock()
    }

    private func removeProcess(for itemID: UUID) {
        processLock.lock()
        processes.removeValue(forKey: itemID)
        processLock.unlock()
    }
}
