import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

private final class Callback<Value> {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Swift.Result<Value, Error>?

    func finish(_ value: Swift.Result<Value, Error>) {
        lock.lock()
        result = value
        lock.unlock()
        semaphore.signal()
    }

    func wait() throws -> Swift.Result<Value, Error> {
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw CheckFailure(description: "DownloadEngine did not invoke its completion")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let result else { throw CheckFailure(description: "Completion had no result") }
        return result
    }
}

private final class Events {
    private let lock = NSLock()
    private var metadata = false
    private var progress = false
    private var subtitle = false
    let playback = DispatchSemaphore(value: 0)

    func record(_ event: DownloadEngine.Event) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .metadata(let value): metadata = value.title == "Offline fixture"
        case .progress(let fraction, _): progress = fraction == 0.5
        case .subtitleFile: subtitle = true
        case .playbackSource: playback.signal()
        }
    }

    func checkDownloadEvents() throws {
        lock.lock()
        defer { lock.unlock() }
        try check(metadata && progress && subtitle, "Download events lost metadata, progress, or captions")
    }
}

@main
struct BrowserAuthEngineCheck {
    static func main() throws {
        guard let rootPath = ProcessInfo.processInfo.environment["REPLAY_AUTH_CHECK_ROOT"] else {
            throw CheckFailure(description: "Run through scripts/test_browser_auth_engine.sh")
        }
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
        let resources = Bundle.main.resourceURL?.resolvingSymlinksInPath().path ?? ""
        try check(resources.hasPrefix(root.path + "/"), "Refusing to use tools outside the temporary app")
        try check(Bundle.main.bundleIdentifier == "com.mg.replay.tests.browser-auth-engine", "Refusing to use Replay preferences")
        try check(DownloadEngine.logsFolderURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"), "Refusing to create logs outside the temporary home")
        let defaults = UserDefaults.standard
        // Volatile preferences exercise the actual engine selection without
        // reading or writing the user's Replay persistent preference domain.
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        try check(BrowserAuthentication.browser() == .none, "Browser authentication must default to disabled")
        defer { defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain) }

        let engine = DownloadEngine()
        let youtube = URL(string: "https://www.youtube.com/watch?v=offline0001")!
        let unrelated = URL(string: "https://x.com/fixture/status/1")!
        let failure = URL(string: "https://www.youtube.com/watch?v=fail-auth00")!
        // A playlist avoids the fast video-preview HTTP path while exercising
        // the real yt-dlp preview fallback. The fake response has no thumbnail URL.
        let youtubePreview = URL(string: "https://www.youtube.com/playlist?list=fixture")!
        let destination = root.appendingPathComponent("downloads")
        let callsFolder = root.appendingPathComponent("calls")

        func calls() throws -> [[String]] {
            try FileManager.default.contentsOfDirectory(at: callsFolder, includingPropertiesForKeys: nil)
                .map { try String(decoding: Data(contentsOf: $0), as: UTF8.self)
                    .split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init) }
        }

        func clearCalls() throws {
            for url in try FileManager.default.contentsOfDirectory(at: callsFolder, includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: url)
            }
        }

        func verifyArguments(_ invocations: [[String]], browser: DownloadBrowser, expectedCount: Int) throws {
            try check(invocations.count == expectedCount, "Expected \(expectedCount) invocations, got \(invocations.count)")
            for arguments in invocations {
                try check(arguments.contains("--ignore-config"), "A helper can load an uncontrolled yt-dlp configuration")
                try check(!arguments.contains("--cookies"), "Replay must not export a cookies file")
                let cookieOptions = arguments.indices.filter { arguments[$0] == "--cookies-from-browser" }
                if browser == .none {
                    try check(cookieOptions.isEmpty, "An unauthenticated operation tried to read browser cookies")
                } else {
                    try check(cookieOptions.count == 1, "Authenticated operation omitted or duplicated the browser option")
                    let index = cookieOptions[0]
                    try check(index + 1 < arguments.count && arguments[index + 1] == browser.rawValue, "Wrong browser passed to yt-dlp")
                    try check(!arguments.contains("youtube:player_client=android"), "Browser authentication reached the incompatible Android resolver")
                }
            }
        }

        func metadata(_ source: URL) throws {
            let callback = Callback<DownloadEngine.Metadata>()
            engine.fetchMetadata(sourceURL: source, completion: callback.finish)
            let value = try callback.wait().get()
            try check(value.title == "Offline fixture" && value.duration == 12, "Metadata callback did not parse the fixture")
        }

        func helpers(_ source: URL, previewSource: URL) throws {
            try metadata(source)
            let thumbnail = Callback<URL?>()
            engine.fetchThumbnail(itemID: UUID(), sourceURL: source, destination: destination, completion: thumbnail.finish)
            let thumbnailURL = try thumbnail.wait().get()
            try check(thumbnailURL?.pathExtension == "jpg", "Thumbnail callback lost the downloaded sidecar")
            let subtitle = Callback<URL?>()
            engine.fetchSubtitle(itemID: UUID(), sourceURL: source, destination: destination, completion: subtitle.finish)
            let subtitleURL = try subtitle.wait().get()
            try check(subtitleURL?.pathExtension == "srt", "Subtitle callback lost the downloaded sidecar")
            let preview = Callback<DownloadEngine.Preview>()
            engine.fetchPreview(sourceURL: previewSource, completion: preview.finish)
            let value = try preview.wait().get()
            try check(value.title == "Offline fixture" && value.thumbnailData == nil, "Preview fallback did not parse the offline fixture")
        }

        func download(_ source: URL, authenticated: Bool) throws {
            let callback = Callback<DownloadEngine.Result>()
            let events = Events()
            engine.start(itemID: UUID(), sourceURL: source, destination: destination, onEvent: events.record, completion: callback.finish)
            let value = try callback.wait().get()
            try check(FileManager.default.fileExists(atPath: value.fileURL.path), "Success callback lost the movie")
            try check(value.thumbnailFileURL != nil && value.subtitleFileURL != nil, "Success callback lost sidecars")
            try events.checkDownloadEvents()
            if authenticated {
                try check(events.playback.wait(timeout: .now() + 0.25) == .timedOut, "Authenticated download started the Android resolver")
            } else {
                try check(events.playback.wait(timeout: .now() + 5) == .success, "Ordinary download lost progressive playback")
            }
        }

        try helpers(youtube, previewSource: youtubePreview)
        try download(youtube, authenticated: false)
        try verifyArguments(calls(), browser: .none, expectedCount: 6)
        try clearCalls()

        defaults.setVolatileDomain([BrowserAuthentication.preferenceKey: "chrome"], forName: UserDefaults.argumentDomain)
        try helpers(youtube, previewSource: youtubePreview)
        try download(youtube, authenticated: true)
        try verifyArguments(calls(), browser: .chrome, expectedCount: 5)
        try clearCalls()

        try helpers(unrelated, previewSource: unrelated)
        try download(unrelated, authenticated: false)
        try verifyArguments(calls(), browser: .none, expectedCount: 6)
        try clearCalls()

        let failed = Callback<DownloadEngine.Result>()
        engine.start(itemID: UUID(), sourceURL: failure, destination: destination, onEvent: { _ in }, completion: failed.finish)
        switch try failed.wait() {
        case .success: throw CheckFailure(description: "Failed downloader incorrectly reported success")
        case .failure(let error):
            try check(DownloadFailureKind.classify(error.localizedDescription) == .authenticationRequired, "Download failure lost its actionable authentication error")
        }
        try verifyArguments(calls(), browser: .chrome, expectedCount: 1)
        try clearCalls()

        let failedMetadata = Callback<DownloadEngine.Metadata>()
        engine.fetchMetadata(sourceURL: failure, completion: failedMetadata.finish)
        if case .success = try failedMetadata.wait() { throw CheckFailure(description: "Failed metadata incorrectly reported success") }
        let failedThumbnail = Callback<URL?>()
        engine.fetchThumbnail(itemID: UUID(), sourceURL: failure, destination: destination, completion: failedThumbnail.finish)
        if case .success = try failedThumbnail.wait() { throw CheckFailure(description: "Failed thumbnail incorrectly reported success") }
        let failedSubtitle = Callback<URL?>()
        engine.fetchSubtitle(itemID: UUID(), sourceURL: failure, destination: destination, completion: failedSubtitle.finish)
        if case .success = try failedSubtitle.wait() { throw CheckFailure(description: "Failed subtitles incorrectly reported success") }
        try verifyArguments(calls(), browser: .chrome, expectedCount: 3)
        print("browser_auth_engine_check=passed (offline fixtures; default, selected browser, service boundary, callbacks, resolver)")
    }
}
