import AppKit
import Combine
import CryptoKit
import Foundation

@MainActor
final class AppUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading(String)
        case ready(String)
        case installing
        case failed(String)
    }

    struct Configuration {
        let releaseAPIURL: URL
        let updatesDirectory: URL
        let installedAppURL: URL
        let helperURL: URL
        let logURL: URL
        let currentVersion: UpdateVersion

        static func live() -> Configuration {
            let environment = ProcessInfo.processInfo.environment
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
            let currentVersionString = environment["REPLAY_UPDATE_CURRENT_VERSION"]
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "0.0.0"

            return Configuration(
                releaseAPIURL: URL(string: environment["REPLAY_UPDATE_RELEASE_API_URL"]
                    ?? "https://api.github.com/repos/grinich/replay/releases/latest")!,
                updatesDirectory: URL(fileURLWithPath: environment["REPLAY_UPDATE_ROOT"]
                    ?? applicationSupport
                        .appendingPathComponent("Replay", isDirectory: true)
                        .appendingPathComponent("Updates", isDirectory: true).path),
                installedAppURL: URL(fileURLWithPath: environment["REPLAY_UPDATE_INSTALL_TARGET"]
                    ?? bundleURL.path),
                helperURL: URL(fileURLWithPath: environment["REPLAY_UPDATE_HELPER_PATH"]
                    ?? bundleURL
                        .appendingPathComponent("Contents", isDirectory: true)
                        .appendingPathComponent("Helpers", isDirectory: true)
                        .appendingPathComponent("ReplayUpdater").path),
                logURL: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Logs", isDirectory: true)
                    .appendingPathComponent("Replay", isDirectory: true)
                    .appendingPathComponent("updater.log"),
                currentVersion: UpdateVersion(currentVersionString) ?? UpdateVersion("0.0.0")!
            )
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
        }
    }

    private struct StagedUpdate: Codable {
        let version: String
        let stagedAppPath: String
        let installedAppPath: String
        let archiveSHA256: String
        let downloadedAt: Date
    }

    @Published private(set) var phase: Phase = .idle

    private let configuration: Configuration
    private var stagedUpdate: StagedUpdate?
    private var stagedUpdateWasPresentAtLaunch = false
    private var automaticCheckTimer: Timer?

    init(configuration: Configuration = .live()) {
        self.configuration = configuration
        if let staged = Self.readStagedUpdate(at: Self.manifestURL(for: configuration)) {
            let stagedVersion = UpdateVersion(staged.version)
            let stagedAppURL = URL(fileURLWithPath: staged.stagedAppPath)
            let expectedInstallPath = configuration.installedAppURL.standardizedFileURL.path
            let stagedPath = stagedAppURL.standardizedFileURL.path
            let updatesPath = configuration.updatesDirectory.standardizedFileURL.path + "/"
            if stagedVersion.map({ $0 > configuration.currentVersion }) == true,
               URL(fileURLWithPath: staged.installedAppPath).standardizedFileURL.path == expectedInstallPath,
               stagedPath.hasPrefix(updatesPath),
               FileManager.default.fileExists(atPath: stagedAppURL.path) {
                stagedUpdate = staged
                stagedUpdateWasPresentAtLaunch = true
                phase = .ready(staged.version)
            } else {
                try? FileManager.default.removeItem(at: Self.manifestURL(for: configuration))
            }
        }
    }

    deinit {
        automaticCheckTimer?.invalidate()
    }

    var menuTitle: String {
        switch phase {
        case .checking:
            return "Checking for Updates…"
        case .downloading:
            return "Downloading Update…"
        case .ready:
            return "Restart App to Update"
        case .installing:
            return "Installing Update…"
        case .idle, .failed:
            return "Check for Updates…"
        }
    }

    var menuItemIsEnabled: Bool {
        switch phase {
        case .checking, .downloading, .installing:
            return false
        case .idle, .ready, .failed:
            return true
        }
    }

    @discardableResult
    func installStagedUpdateFromPreviousLaunchIfNeeded() -> Bool {
        guard stagedUpdateWasPresentAtLaunch else { return false }
        restartAndInstall()
        return true
    }

    func startAutomaticChecks() {
        guard stagedUpdate == nil else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.beginCheck(manual: false)
        }

        automaticCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.beginCheck(manual: false)
            }
        }
    }

    func performMenuAction() {
        if case .ready = phase {
            restartAndInstall()
        } else {
            beginCheck(manual: true)
        }
    }

    private func beginCheck(manual: Bool) {
        guard menuItemIsEnabled, stagedUpdate == nil else { return }
        guard configuration.installedAppURL.pathExtension == "app" else {
            if manual {
                presentAlert(
                    title: "Updates are available in the installed app",
                    message: "Open Replay from your Applications folder, then check again."
                )
            }
            return
        }

        phase = .checking
        log("Checking for updates at \(configuration.releaseAPIURL.absoluteString)")
        Task { [weak self] in
            await self?.checkForUpdates(manual: manual)
        }
    }

    private func checkForUpdates(manual: Bool) async {
        do {
            let release = try await fetchLatestRelease()
            guard let latestVersion = UpdateVersion(release.tagName) else {
                throw UpdaterError.invalidRelease("The latest release has an invalid version tag.")
            }

            guard latestVersion > configuration.currentVersion else {
                phase = .idle
                log("Replay \(configuration.currentVersion) is current; latest release is \(latestVersion)")
                if manual {
                    presentAlert(
                        title: "Replay is up to date",
                        message: "You’re using the latest version of Replay."
                    )
                }
                return
            }

            guard let archive = release.assets.first(where: { $0.name == "Replay-macOS.zip" }) else {
                throw UpdaterError.invalidRelease("The release does not include Replay-macOS.zip.")
            }

            phase = .downloading(latestVersion.description)
            log("Downloading Replay \(latestVersion)")
            let staged = try await downloadAndStage(
                release: release,
                archive: archive,
                version: latestVersion
            )
            stagedUpdate = staged
            stagedUpdateWasPresentAtLaunch = false
            phase = .ready(latestVersion.description)
            log("Replay \(latestVersion) is staged and ready to install")
        } catch {
            let message = Self.userFacingMessage(for: error)
            phase = .failed(message)
            log("Update failed: \(error.localizedDescription)")
            if manual {
                presentAlert(title: "Couldn’t update Replay", message: message)
            }
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: configuration.releaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Replay/\(configuration.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validateHTTPResponse(response)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func downloadAndStage(
        release: GitHubRelease,
        archive: GitHubAsset,
        version: UpdateVersion
    ) async throws -> StagedUpdate {
        let expectedChecksum = try await expectedChecksum(for: archive, in: release)
        let versionDirectory = configuration.updatesDirectory
            .appendingPathComponent("Replay-\(version)", isDirectory: true)
        let archiveURL = versionDirectory.appendingPathComponent("Replay-macOS.zip")
        let expandedDirectory = versionDirectory.appendingPathComponent("Expanded", isDirectory: true)
        let stagedAppURL = expandedDirectory.appendingPathComponent("Replay.app", isDirectory: true)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: versionDirectory.path) {
            try fileManager.removeItem(at: versionDirectory)
        }
        try fileManager.createDirectory(at: versionDirectory, withIntermediateDirectories: true)

        do {
            var request = URLRequest(url: archive.browserDownloadURL)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("Replay/\(configuration.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            try Self.validateHTTPResponse(response)
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)

            let actualChecksum = try await Task.detached(priority: .utility) {
                try Self.sha256(of: archiveURL)
            }.value
            guard actualChecksum.caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
                throw UpdaterError.checksumMismatch
            }

            try fileManager.createDirectory(at: expandedDirectory, withIntermediateDirectories: true)
            try await Self.runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archiveURL.path, expandedDirectory.path]
            )
            try await Self.validateStagedApp(stagedAppURL, expectedVersion: version)
            try? fileManager.removeItem(at: archiveURL)

            let staged = StagedUpdate(
                version: version.description,
                stagedAppPath: stagedAppURL.path,
                installedAppPath: configuration.installedAppURL.path,
                archiveSHA256: actualChecksum,
                downloadedAt: Date()
            )
            try Self.write(stagedUpdate: staged, to: Self.manifestURL(for: configuration))
            return staged
        } catch {
            try? fileManager.removeItem(at: versionDirectory)
            throw error
        }
    }

    private func expectedChecksum(for archive: GitHubAsset, in release: GitHubRelease) async throws -> String {
        if let digest = archive.digest?.lowercased(), digest.hasPrefix("sha256:") {
            let checksum = String(digest.dropFirst("sha256:".count))
            if Self.isSHA256(checksum) {
                return checksum
            }
        }

        guard let checksumAsset = release.assets.first(where: { $0.name == "Replay-macOS.zip.sha256" }) else {
            throw UpdaterError.invalidRelease("The release does not include a SHA-256 checksum.")
        }
        var request = URLRequest(url: checksumAsset.browserDownloadURL)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("Replay/\(configuration.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validateHTTPResponse(response)
        guard let text = String(data: data, encoding: .utf8),
              let checksum = text.split(whereSeparator: \.isWhitespace).first.map(String.init),
              Self.isSHA256(checksum) else {
            throw UpdaterError.invalidRelease("The release checksum is invalid.")
        }
        return checksum.lowercased()
    }

    private func restartAndInstall() {
        guard let stagedUpdate else { return }
        let installedURL = URL(fileURLWithPath: stagedUpdate.installedAppPath)
        let installedParent = installedURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: installedParent.path) else {
            presentAlert(
                title: "Replay can’t install this update",
                message: "Move Replay to a writable Applications folder, such as the Applications folder in your home folder, and try again."
            )
            return
        }
        guard FileManager.default.isExecutableFile(atPath: configuration.helperURL.path) else {
            presentAlert(
                title: "Replay can’t install this update",
                message: "The update helper is missing. Download the latest version of Replay manually and replace this copy."
            )
            return
        }

        let backupURL = configuration.updatesDirectory
            .appendingPathComponent("Previous-Replay.app", isDirectory: true)
        let process = Process()
        process.executableURL = configuration.helperURL
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            stagedUpdate.stagedAppPath,
            stagedUpdate.installedAppPath,
            Self.manifestURL(for: configuration).path,
            backupURL.path,
            configuration.logURL.path,
            "true"
        ]

        do {
            try process.run()
            phase = .installing
            log("Started update helper for Replay \(stagedUpdate.version)")
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
            log("Could not start update helper: \(error.localizedDescription)")
            presentAlert(
                title: "Replay can’t install this update",
                message: "The update helper could not start. Please try again."
            )
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func log(_ message: String) {
        let url = configuration.logURL
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            NSLog("Replay updater log error: %@", error.localizedDescription)
        }
    }

    private static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw UpdaterError.invalidServerResponse
        }
    }

    nonisolated private static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateStagedApp(_ appURL: URL, expectedVersion: UpdateVersion) async throws {
        let infoURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL),
              info["CFBundleIdentifier"] as? String == "com.mg.replay",
              let versionString = info["CFBundleShortVersionString"] as? String,
              UpdateVersion(versionString) == expectedVersion,
              FileManager.default.isExecutableFile(atPath: appURL
                .appendingPathComponent("Contents/MacOS/Replay").path) else {
            throw UpdaterError.invalidRelease("The downloaded app is not a valid Replay update.")
        }

        try await runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", appURL.path]
        )
    }

    private static func runProcess(executable: URL, arguments: [String]) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw UpdaterError.processFailed(message ?? executable.lastPathComponent)
            }
        }.value
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func manifestURL(for configuration: Configuration) -> URL {
        configuration.updatesDirectory.appendingPathComponent("staged-update.json")
    }

    private static func readStagedUpdate(at url: URL) -> StagedUpdate? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StagedUpdate.self, from: data)
    }

    private static func write(stagedUpdate: StagedUpdate, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(stagedUpdate)
        try data.write(to: url, options: .atomic)
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let error = error as? UpdaterError {
            return error.errorDescription ?? "The update could not be prepared."
        }
        if let error = error as? URLError {
            return "Check your internet connection, then try again. (\(error.localizedDescription))"
        }
        return error.localizedDescription
    }
}

private enum UpdaterError: LocalizedError {
    case invalidServerResponse
    case invalidRelease(String)
    case checksumMismatch
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerResponse:
            return "GitHub returned an unexpected response. Please try again later."
        case .invalidRelease(let message):
            return message
        case .checksumMismatch:
            return "The downloaded update did not match its published checksum."
        case .processFailed(let message):
            return message.isEmpty ? "The downloaded update could not be prepared." : message
        }
    }
}
