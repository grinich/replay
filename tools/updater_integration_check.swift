import AppKit
import CryptoKit
import Foundation

private enum CheckError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw CheckError.failed("\(executable) failed: \(output)")
    }
}

private func serverFailure(_ message: String, server: Process, logURL: URL) -> CheckError {
    let status = server.isRunning ? "running" : "exited with status \(server.terminationStatus)"
    let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "No server output"
    return .failed("\(message) (server \(status))\n\(log)")
}

private func waitForServerPort(_ server: Process, in root: URL, logURL: URL) async throws -> Int {
    let portURL = root.appendingPathComponent("server-port.txt")
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        guard server.isRunning else {
            throw serverFailure("Fixture HTTP server stopped during startup", server: server, logURL: logURL)
        }
        if let value = try? String(contentsOf: portURL, encoding: .utf8),
           let port = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
           (1...65535).contains(port) {
            return port
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw serverFailure("Timed out waiting for fixture HTTP server to bind", server: server, logURL: logURL)
}

private func waitForServerResponse(
    _ server: Process, at url: URL, expectedData: Data, logURL: URL
) async throws {
    let deadline = Date().addingTimeInterval(15)
    var lastError = "No response received"
    while Date() < deadline {
        guard server.isRunning else {
            throw serverFailure("Fixture HTTP server stopped before readiness", server: server, logURL: logURL)
        }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 1
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200, data == expectedData { return }
            lastError = "Unexpected response from fixture HTTP server"
        } catch {
            lastError = error.localizedDescription
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw serverFailure("Fixture HTTP server was not ready: \(lastError)", server: server, logURL: logURL)
}

private func sha256(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func makeReplayApp(at url: URL, version: String) throws {
    let fileManager = FileManager.default
    let executableDirectory = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try fileManager.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
    try fileManager.copyItem(
        at: URL(fileURLWithPath: CommandLine.arguments[0]),
        to: executableDirectory.appendingPathComponent("Replay")
    )
    let info: [String: Any] = [
        "CFBundleExecutable": "Replay",
        "CFBundleIdentifier": "com.mg.replay",
        "CFBundleName": "Replay",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": "1"
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", url.path])
}

@main
private struct UpdaterIntegrationCheck {
    @MainActor
    static func main() async {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("Replay-updater-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        var server: Process?
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let appURL = root.appendingPathComponent("Replay.app", isDirectory: true)
            try makeReplayApp(at: appURL, version: "9.9.9")
            let archiveURL = root.appendingPathComponent("Replay-macOS.zip")
            try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", appURL.path, archiveURL.path])
            let checksum = try sha256(archiveURL)

            let serverLogURL = root.appendingPathComponent("http-server.log")
            fileManager.createFile(atPath: serverLogURL.path, contents: nil)
            let serverLog = try FileHandle(forWritingTo: serverLogURL)
            defer { try? serverLog.close() }
            let httpServer = Process()
            httpServer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            // Let the server retain the OS-assigned port from bind through
            // shutdown. Reserving and releasing a port before launching Python
            // races other processes, and a fixed sleep races slow CI startup.
            httpServer.arguments = ["-u", "-c", """
            import functools
            import http.server
            import pathlib
            import sys

            root = pathlib.Path(sys.argv[1])
            handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root))
            with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
                temporary = root / "server-port.tmp"
                temporary.write_text(str(server.server_port))
                temporary.replace(root / "server-port.txt")
                server.serve_forever()
            """, root.path]
            httpServer.standardOutput = serverLog
            httpServer.standardError = serverLog
            try httpServer.run()
            server = httpServer
            let port = try await waitForServerPort(httpServer, in: root, logURL: serverLogURL)
            let release: [String: Any] = [
                "tag_name": "v9.9.9",
                "assets": [[
                    "name": "Replay-macOS.zip",
                    "browser_download_url": "http://127.0.0.1:\(port)/Replay-macOS.zip",
                    "digest": "sha256:\(checksum)"
                ]]
            ]
            let releaseData = try JSONSerialization.data(withJSONObject: release, options: [.prettyPrinted])
            try releaseData.write(to: root.appendingPathComponent("release.json"))
            let releaseURL = URL(string: "http://127.0.0.1:\(port)/release.json")!
            try await waitForServerResponse(httpServer, at: releaseURL, expectedData: releaseData, logURL: serverLogURL)

            let updates = root.appendingPathComponent("Updates", isDirectory: true)
            let configuration = AppUpdater.Configuration(
                releaseAPIURL: releaseURL,
                updatesDirectory: updates,
                installedAppURL: root.appendingPathComponent("Installed/Replay.app"),
                helperURL: root.appendingPathComponent("ReplayUpdater"),
                logURL: root.appendingPathComponent("updater.log"),
                currentVersion: UpdateVersion("1.0.0")!
            )
            let updater = AppUpdater(configuration: configuration)
            // Exercise the silent automatic path so failures are reported
            // through `phase` instead of a modal alert in this headless test.
            updater.startAutomaticChecks()

            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if case .ready(let version) = updater.phase {
                    guard version == "9.9.9" else {
                        throw CheckError.failed("Unexpected staged version \(version)")
                    }
                    let manifest = updates.appendingPathComponent("staged-update.json")
                    guard fileManager.fileExists(atPath: manifest.path),
                          fileManager.fileExists(atPath: updates
                            .appendingPathComponent("Replay-9.9.9/Expanded/Replay.app").path) else {
                        throw CheckError.failed("Update was not staged")
                    }
                    let nextLaunchUpdater = AppUpdater(configuration: configuration)
                    guard nextLaunchUpdater.menuTitle == "Restart App to Update",
                          nextLaunchUpdater.menuItemIsEnabled else {
                        throw CheckError.failed("A staged update was not restored on the next launch")
                    }
                    server?.terminate()
                    server?.waitUntilExit()
                    print("Updater integration checks passed")
                    return
                }
                if case .failed(let message) = updater.phase {
                    throw CheckError.failed("Updater failed: \(message)")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw CheckError.failed("Timed out waiting for staged update")
        } catch {
            if server?.isRunning == true {
                server?.terminate()
                server?.waitUntilExit()
            }
            fputs("Updater integration check failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
