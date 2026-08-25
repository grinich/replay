import Foundation

private enum CheckError: Error {
    case failed(String)
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
}

private func version(of app: URL) -> String? {
    let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    return info?["CFBundleShortVersionString"] as? String
}

guard CommandLine.arguments.count == 2 else {
    fputs("Expected ReplayUpdater path\n", stderr)
    exit(1)
}

let fileManager = FileManager.default
let root = fileManager.temporaryDirectory
    .appendingPathComponent("Replay-helper-check-\(UUID().uuidString)", isDirectory: true)
defer { try? fileManager.removeItem(at: root) }

do {
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let installed = root.appendingPathComponent("Replay.app", isDirectory: true)
    let staged = root.appendingPathComponent("Staged-Replay.app", isDirectory: true)
    let backup = root.appendingPathComponent("Previous-Replay.app", isDirectory: true)
    let manifest = root.appendingPathComponent("staged-update.json")
    let log = root.appendingPathComponent("updater.log")
    try makeReplayApp(at: installed, version: "1.0.0")
    try makeReplayApp(at: staged, version: "2.0.0")
    try Data("{}".utf8).write(to: manifest)

    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
    helper.arguments = [
        "999999", staged.path, installed.path, manifest.path,
        backup.path, log.path, "false"
    ]
    try helper.run()
    helper.waitUntilExit()
    guard helper.terminationStatus == 0 else {
        throw CheckError.failed("ReplayUpdater exited with \(helper.terminationStatus)")
    }
    guard version(of: installed) == "2.0.0",
          version(of: backup) == "1.0.0",
          !fileManager.fileExists(atPath: manifest.path) else {
        throw CheckError.failed("ReplayUpdater did not replace the app correctly")
    }
    print("Updater helper checks passed")
} catch {
    fputs("Updater helper check failed: \(error)\n", stderr)
    exit(1)
}
