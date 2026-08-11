import Foundation

@main
struct RewatchMigrationCheck {
    static func main() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationSupportRoot = root.appendingPathComponent("Application Support", isDirectory: true)
        let moviesRoot = root.appendingPathComponent("Movies", isDirectory: true)
        let legacySupport = applicationSupportRoot
            .appendingPathComponent(RewatchMigration.legacyApplicationName, isDirectory: true)
        let legacyMedia = moviesRoot
            .appendingPathComponent(RewatchMigration.legacyApplicationName, isDirectory: true)
        try fileManager.createDirectory(at: legacySupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacyMedia, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: legacySupport.appendingPathComponent("queue.json"))
        let legacyVideo = legacyMedia.appendingPathComponent("video.mp4")
        try Data("video".utf8).write(to: legacyVideo)

        let result = RewatchMigration.migrateDirectories(
            fileManager: fileManager,
            applicationSupportRoot: applicationSupportRoot,
            moviesRoot: moviesRoot
        )
        precondition(fileManager.fileExists(atPath: result.applicationSupport.appendingPathComponent("queue.json").path))
        precondition(fileManager.fileExists(atPath: result.mediaFolder.appendingPathComponent("video.mp4").path))
        precondition(!fileManager.fileExists(atPath: legacySupport.path))
        precondition(!fileManager.fileExists(atPath: legacyMedia.path))
        precondition(
            result.remappedMediaPath(legacyVideo.path) ==
            result.mediaFolder.appendingPathComponent("video.mp4").path
        )

        let legacySuiteName = "RewatchMigration.Legacy.\(UUID().uuidString)"
        let currentSuiteName = "RewatchMigration.Current.\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
        let currentDefaults = UserDefaults(suiteName: currentSuiteName)!
        defer {
            legacyDefaults.removePersistentDomain(forName: legacySuiteName)
            currentDefaults.removePersistentDomain(forName: currentSuiteName)
        }
        legacyDefaults.set(1.7, forKey: "playbackRate")
        legacyDefaults.set(true, forKey: "subtitlesEnabled")
        currentDefaults.set(0.4, forKey: "playbackVolume")
        legacyDefaults.set(0.9, forKey: "playbackVolume")

        RewatchMigration.migratePreferences(from: legacyDefaults, to: currentDefaults)
        precondition(currentDefaults.double(forKey: "playbackRate") == 1.7)
        precondition(currentDefaults.bool(forKey: "subtitlesEnabled"))
        precondition(currentDefaults.double(forKey: "playbackVolume") == 0.4)

        print("rewatch_migration_check=passed")
    }
}
