import Darwin
import Foundation

private enum HelperError: LocalizedError {
    case invalidArguments
    case invalidApp(String)
    case parentNotWritable
    case parentStillRunning

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "The Replay update helper received invalid arguments."
        case .invalidApp(let path):
            return "Not a valid Replay app: \(path)"
        case .parentNotWritable:
            return "The Replay application folder is not writable."
        case .parentStillRunning:
            return "Replay did not quit before the update timed out."
        }
    }
}

private struct HelperArguments {
    let parentPID: pid_t
    let stagedApp: URL
    let installedApp: URL
    let manifest: URL
    let backupApp: URL
    let log: URL
    let shouldRelaunch: Bool

    init?(_ values: [String]) {
        guard values.count == 8, let pid = Int32(values[1]) else { return nil }
        parentPID = pid
        stagedApp = URL(fileURLWithPath: values[2])
        installedApp = URL(fileURLWithPath: values[3])
        manifest = URL(fileURLWithPath: values[4])
        backupApp = URL(fileURLWithPath: values[5])
        log = URL(fileURLWithPath: values[6])
        shouldRelaunch = values[7].lowercased() == "true"
    }
}

private final class HelperLog {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func write(_ message: String) {
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
            fputs("Replay updater log error: \(error.localizedDescription)\n", stderr)
        }
    }
}

private func validateReplayApp(at url: URL) throws {
    let infoURL = url.appendingPathComponent("Contents/Info.plist")
    guard let info = NSDictionary(contentsOf: infoURL),
          info["CFBundleIdentifier"] as? String == "com.mg.replay",
          FileManager.default.isExecutableFile(atPath: url
            .appendingPathComponent("Contents/MacOS/Replay").path) else {
        throw HelperError.invalidApp(url.path)
    }
}

private func waitForExit(of pid: pid_t) -> Bool {
    let deadline = Date().addingTimeInterval(30)
    while kill(pid, 0) == 0, Date() < deadline {
        usleep(100_000)
    }
    return kill(pid, 0) != 0
}

private func launch(_ appURL: URL, log: HelperLog) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-n", appURL.path]
    do {
        try process.run()
        log.write("Relaunched \(appURL.path)")
    } catch {
        log.write("Could not relaunch Replay: \(error.localizedDescription)")
    }
}

private func run(_ arguments: HelperArguments) throws {
    let fileManager = FileManager.default
    let log = HelperLog(url: arguments.log)
    log.write("Waiting for Replay process \(arguments.parentPID) to exit")
    guard waitForExit(of: arguments.parentPID) else {
        throw HelperError.parentStillRunning
    }

    try validateReplayApp(at: arguments.stagedApp)
    try validateReplayApp(at: arguments.installedApp)
    guard fileManager.isWritableFile(atPath: arguments.installedApp.deletingLastPathComponent().path) else {
        throw HelperError.parentNotWritable
    }

    if fileManager.fileExists(atPath: arguments.backupApp.path) {
        try fileManager.removeItem(at: arguments.backupApp)
    }

    log.write("Replacing \(arguments.installedApp.path) with staged update")
    try fileManager.moveItem(at: arguments.installedApp, to: arguments.backupApp)
    do {
        try fileManager.moveItem(at: arguments.stagedApp, to: arguments.installedApp)
        try validateReplayApp(at: arguments.installedApp)
        try? fileManager.removeItem(at: arguments.manifest)
        log.write("Replay update installed successfully")
    } catch {
        log.write("Install failed; restoring previous Replay: \(error.localizedDescription)")
        if fileManager.fileExists(atPath: arguments.installedApp.path) {
            try? fileManager.removeItem(at: arguments.installedApp)
        }
        try? fileManager.moveItem(at: arguments.backupApp, to: arguments.installedApp)
        try? fileManager.removeItem(at: arguments.manifest)
        throw error
    }

    if arguments.shouldRelaunch {
        launch(arguments.installedApp, log: log)
    }
}

guard let arguments = HelperArguments(CommandLine.arguments) else {
    fputs("\(HelperError.invalidArguments.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}

do {
    try run(arguments)
} catch {
    let log = HelperLog(url: arguments.log)
    log.write("Replay update failed: \(error.localizedDescription)")
    if arguments.shouldRelaunch,
       FileManager.default.fileExists(atPath: arguments.installedApp.path) {
        launch(arguments.installedApp, log: log)
    }
    exit(EXIT_FAILURE)
}
