import Foundation

final class DownloadEngine {
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

    enum Event {
        case metadata(Metadata)
        case progress(Double, String)
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
    private let metadataQueue = DispatchQueue(label: "com.mg.watchlater.metadata", qos: .utility)

    func start(
        itemID: UUID,
        sourceURL: URL,
        destination: URL,
        onEvent: @escaping (Event) -> Void,
        completion: @escaping (Swift.Result<DownloadEngine.Result, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
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
                    "--format", "bv*[height<=1080][ext=mp4]+ba[ext=m4a]/b[height<=1080][ext=mp4]/b[height<=1080]/best",
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

                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
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
