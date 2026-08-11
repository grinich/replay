import Foundation

struct ReplayMigrationResult {
    let applicationSupport: URL
    let mediaFolder: URL
    let movedFromMediaFolder: URL?

    var didMoveMediaFolder: Bool {
        movedFromMediaFolder != nil
    }

    func remappedMediaPath(_ path: String?) -> String? {
        guard let movedFromMediaFolder, let path else { return path }
        let legacyPrefix = movedFromMediaFolder.standardizedFileURL.path + "/"
        guard path.hasPrefix(legacyPrefix) else { return path }
        let relativePath = String(path.dropFirst(legacyPrefix.count))
        return mediaFolder.appendingPathComponent(relativePath).path
    }
}

enum ReplayMigration {
    static let applicationName = "Replay"
    static let legacyApplicationNames = [
        ["Re", "watch"].joined(),
        ["Watch", "Later"].joined(separator: " ")
    ]
    static let legacyBundleIdentifiers = [
        "com.mg." + ["re", "watch"].joined(),
        "com.mg." + "watch" + "later"
    ]
    static let preferenceKeys = [
        "playbackRate",
        "playbackVolume",
        "subtitlesEnabled",
        "chaptersPresented",
        "queueOrderVersion"
    ]

    static func migrateDirectories(
        fileManager: FileManager = .default,
        applicationSupportRoot: URL,
        moviesRoot: URL
    ) -> ReplayMigrationResult {
        let applicationSupport = applicationSupportRoot
            .appendingPathComponent(applicationName, isDirectory: true)
        let mediaFolder = moviesRoot
            .appendingPathComponent(applicationName, isDirectory: true)
        let legacyApplicationSupportFolders = legacyApplicationNames.map {
            applicationSupportRoot.appendingPathComponent($0, isDirectory: true)
        }
        let legacyMediaFolders = legacyApplicationNames.map {
            moviesRoot.appendingPathComponent($0, isDirectory: true)
        }

        _ = moveFirstDirectoryIfNeeded(
            from: legacyApplicationSupportFolders,
            to: applicationSupport,
            fileManager: fileManager
        )
        let movedFromMediaFolder = moveFirstDirectoryIfNeeded(
            from: legacyMediaFolders,
            to: mediaFolder,
            fileManager: fileManager
        )

        return ReplayMigrationResult(
            applicationSupport: applicationSupport,
            mediaFolder: mediaFolder,
            movedFromMediaFolder: movedFromMediaFolder
        )
    }

    static func migratePreferences(
        from legacyDefaults: [UserDefaults?] = legacyBundleIdentifiers.map { UserDefaults(suiteName: $0) },
        to currentDefaults: UserDefaults = .standard
    ) {
        for defaults in legacyDefaults.compactMap({ $0 }) {
            for key in preferenceKeys where currentDefaults.object(forKey: key) == nil {
                guard let value = defaults.object(forKey: key) else { continue }
                currentDefaults.set(value, forKey: key)
            }
        }
    }

    private static func moveFirstDirectoryIfNeeded(
        from sources: [URL],
        to destination: URL,
        fileManager: FileManager
    ) -> URL? {
        guard !fileManager.fileExists(atPath: destination.path) else { return nil }
        for source in sources where fileManager.fileExists(atPath: source.path) {
            do {
                try fileManager.moveItem(at: source, to: destination)
                return source
            } catch {
                continue
            }
        }
        return nil
    }
}
