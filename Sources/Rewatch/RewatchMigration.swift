import Foundation

struct RewatchMigrationResult {
    let applicationSupport: URL
    let mediaFolder: URL
    let legacyMediaFolder: URL
    let didMoveMediaFolder: Bool

    func remappedMediaPath(_ path: String?) -> String? {
        guard didMoveMediaFolder, let path else { return path }
        let legacyPrefix = legacyMediaFolder.standardizedFileURL.path + "/"
        guard path.hasPrefix(legacyPrefix) else { return path }
        let relativePath = String(path.dropFirst(legacyPrefix.count))
        return mediaFolder.appendingPathComponent(relativePath).path
    }
}

enum RewatchMigration {
    static let applicationName = "Rewatch"
    static let legacyApplicationName = ["Watch", "Later"].joined(separator: " ")
    static let legacyBundleIdentifier = "com.mg." + "watch" + "later"
    static let preferenceKeys = [
        "playbackRate",
        "playbackVolume",
        "subtitlesEnabled",
        "chaptersPresented"
    ]

    static func migrateDirectories(
        fileManager: FileManager = .default,
        applicationSupportRoot: URL,
        moviesRoot: URL
    ) -> RewatchMigrationResult {
        let applicationSupport = applicationSupportRoot
            .appendingPathComponent(applicationName, isDirectory: true)
        let legacyApplicationSupport = applicationSupportRoot
            .appendingPathComponent(legacyApplicationName, isDirectory: true)
        let mediaFolder = moviesRoot
            .appendingPathComponent(applicationName, isDirectory: true)
        let legacyMediaFolder = moviesRoot
            .appendingPathComponent(legacyApplicationName, isDirectory: true)

        _ = moveDirectoryIfNeeded(
            from: legacyApplicationSupport,
            to: applicationSupport,
            fileManager: fileManager
        )
        let didMoveMediaFolder = moveDirectoryIfNeeded(
            from: legacyMediaFolder,
            to: mediaFolder,
            fileManager: fileManager
        )

        return RewatchMigrationResult(
            applicationSupport: applicationSupport,
            mediaFolder: mediaFolder,
            legacyMediaFolder: legacyMediaFolder,
            didMoveMediaFolder: didMoveMediaFolder
        )
    }

    static func migratePreferences(
        from legacyDefaults: UserDefaults? = UserDefaults(suiteName: legacyBundleIdentifier),
        to currentDefaults: UserDefaults = .standard
    ) {
        guard let legacyDefaults else { return }
        for key in preferenceKeys where currentDefaults.object(forKey: key) == nil {
            guard let value = legacyDefaults.object(forKey: key) else { continue }
            currentDefaults.set(value, forKey: key)
        }
    }

    private static func moveDirectoryIfNeeded(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path) else { return false }
        do {
            try fileManager.moveItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }
}
