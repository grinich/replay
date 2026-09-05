import Foundation

enum DownloadBrowser: String, CaseIterable, Identifiable {
    case none
    case chrome
    case safari
    case firefox
    case edge
    case brave

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        }
    }
}

enum BrowserAuthentication {
    static let preferenceKey = "youtubeAuthenticationBrowser"

    static func browser(in defaults: UserDefaults = .standard) -> DownloadBrowser {
        guard let value = defaults.string(forKey: preferenceKey),
              let browser = DownloadBrowser(rawValue: value) else { return .none }
        return browser
    }

    static func supports(_ sourceURL: URL) -> Bool {
        guard let scheme = sourceURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = sourceURL.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
    }

    static func arguments(for sourceURL: URL, browser: DownloadBrowser) -> [String] {
        guard browser != .none, supports(sourceURL) else { return [] }
        // yt-dlp reads the browser session directly. Replay does not export or
        // persist a cookie file, and a saved preference never authenticates
        // unrelated services.
        return ["--cookies-from-browser", browser.rawValue]
    }
}

enum DownloadFailureKind: Equatable {
    case authenticationRequired
    case browserAccess
    case noVideo
    case other

    static func classify(_ message: String) -> Self {
        let lines = message.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: .newlines)

        // Match failures involving the browser session itself before any
        // subsequent sign-in error. A cookies help URL or option suggestion
        // alone must not turn an unrelated error into a browser-access error.
        if lines.contains(where: { line in
            let sessionFailurePatterns = [
                #"(?:failed|unable) to (?:extract|read|decrypt|copy|load|open|find).*cookies?"#,
                #"could not (?:extract|read|decrypt|copy|load|open|find).*cookies?"#,
                #"(?:error|permission denied|operation not permitted).*(?:cookies? database|cookies? file|cookies\.sqlite|cookies\.binarycookies)"#,
                #"(?:permission denied|operation not permitted).*[/\\]cookies(?:['\"]|$)"#,
                #"(?:cookies? database|cookies? file|cookies\.sqlite|cookies\.binarycookies).*(?:permission denied|operation not permitted|locked|not found|does not exist)"#,
                #"(?:failed|unable|could not|cannot|can't).*(?:keychain|browser profile|chrome profile|firefox profile|safari profile|edge profile|brave profile)"#,
                #"(?:keychain|browser profile).*(?:denied|not found|unavailable|locked)"#,
                #"could not find.*(?:chrome|firefox|safari|edge|brave).*profile"#
            ]
            return sessionFailurePatterns.contains {
                line.range(of: $0, options: .regularExpression) != nil
            }
        }) {
            return .browserAccess
        }
        if lines.contains(where: { $0.contains("extracting cookies from") }),
           lines.contains(where: {
               $0.contains("unable to open database file") || $0.contains("database is locked")
           }) {
            return .browserAccess
        }

        if lines.contains(where: { line in
            line.contains("sign in to confirm")
                || line.contains("sign in to view this video")
                || line.contains("sign in if you've been granted access")
                || (line.contains("[youtube]") && (
                    line.contains("login required")
                        || line.contains("authentication required")
                        || line.contains("this video requires authentication")
                ))
        }) {
            return .authenticationRequired
        }

        if lines.contains(where: { line in
            line.range(
                of: #"no videos? (?:could be |was |were )?(?:found )?in this (?:tweet|post)|(?:tweet|post) (?:does not|doesn't) contain (?:a |any )?video"#,
                options: .regularExpression
            ) != nil
        }) {
            return .noVideo
        }
        return .other
    }

    var title: String {
        switch self {
        case .authenticationRequired: return "YouTube sign-in needed"
        case .browserAccess: return "Browser access required"
        case .noVideo: return "No video found"
        case .other: return "Download failed"
        }
    }

    var message: String {
        switch self {
        case .authenticationRequired:
            return "Sign in to YouTube in your browser, then use Choose Browser & Retry to connect that browser."
        case .browserAccess:
            return "Replay couldn't read the selected browser's session. Open that browser, sign in to YouTube, and allow any macOS access request before retrying."
        case .noVideo:
            return "This post has no downloadable video. Add a link to a post or page that includes a video."
        case .other:
            return "The download could not finish. Open its log for details, then retry."
        }
    }

    var progressLabel: String {
        switch self {
        case .authenticationRequired: return "YouTube sign-in needed"
        case .browserAccess: return "Browser access required"
        case .noVideo: return "No video found"
        case .other: return "Download failed"
        }
    }
}
