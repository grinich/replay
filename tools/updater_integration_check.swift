import AppKit
import CryptoKit
import Darwin
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

private func availablePort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CheckError.failed("Could not create test socket") }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw CheckError.failed("Could not bind test socket") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard nameResult == 0 else { throw CheckError.failed("Could not inspect test socket") }
    return Int(UInt16(bigEndian: address.sin_port))
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
            let port = try availablePort()
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

            let httpServer = Process()
            httpServer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            httpServer.arguments = [
                "-m", "http.server", "--bind", "127.0.0.1",
                String(port), "--directory", root.path
            ]
            httpServer.standardOutput = FileHandle.nullDevice
            httpServer.standardError = FileHandle.nullDevice
            try httpServer.run()
            server = httpServer
            try await Task.sleep(nanoseconds: 400_000_000)

            let updates = root.appendingPathComponent("Updates", isDirectory: true)
            let configuration = AppUpdater.Configuration(
                releaseAPIURL: URL(string: "http://127.0.0.1:\(port)/release.json")!,
                updatesDirectory: updates,
                installedAppURL: root.appendingPathComponent("Installed/Replay.app"),
                helperURL: root.appendingPathComponent("ReplayUpdater"),
                logURL: root.appendingPathComponent("updater.log"),
                currentVersion: UpdateVersion("1.0.0")!
            )
            let updater = AppUpdater(configuration: configuration)
            updater.performMenuAction()

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
            server?.terminate()
            fputs("Updater integration check failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
