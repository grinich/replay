import Foundation

@main
struct BrowserAuthenticationCheck {
    static func main() {
        let suiteName = "com.mg.replay.browser-auth-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        precondition(BrowserAuthentication.browser(in: defaults) == .none)
        for invalid in ["", "unknown", "Chrome", "chrome:/tmp/profile", "chrome --verbose"] {
            defaults.set(invalid, forKey: BrowserAuthentication.preferenceKey)
            precondition(BrowserAuthentication.browser(in: defaults) == .none)
        }

        let supportedURLs = [
            "https://youtube.com/watch?v=pwQ0l4hFCVI",
            "https://www.youtube.com/watch?v=pwQ0l4hFCVI",
            "http://m.youtube.com/watch?v=pwQ0l4hFCVI",
            "https://music.youtube.com/watch?v=pwQ0l4hFCVI",
            "HTTPS://WWW.YOUTUBE.COM/watch?v=pwQ0l4hFCVI",
            "https://youtu.be/pwQ0l4hFCVI"
        ].map { URL(string: $0)! }
        let unsupportedURLs = [
            "https://youtube.com.evil.example/watch?v=pwQ0l4hFCVI",
            "https://notyoutube.com/watch?v=pwQ0l4hFCVI",
            "https://youtu.be.evil.example/pwQ0l4hFCVI",
            "https://youtube.com@evil.example/watch?v=pwQ0l4hFCVI",
            "https://example.com/?next=https://youtube.com/watch?v=pwQ0l4hFCVI",
            "https://x.com/example/status/123",
            "https://vimeo.com/123",
            "ftp://youtube.com/watch?v=pwQ0l4hFCVI",
            "file:///youtube.com/watch",
            "youtube.com/watch?v=pwQ0l4hFCVI"
        ].map { URL(string: $0)! }

        for browser in DownloadBrowser.allCases {
            defaults.set(browser.rawValue, forKey: BrowserAuthentication.preferenceKey)
            precondition(BrowserAuthentication.browser(in: defaults) == browser)
            precondition(browser.id == browser.rawValue)
            precondition(!browser.displayName.isEmpty)
            for url in supportedURLs {
                precondition(BrowserAuthentication.supports(url))
                let expected = browser == .none ? [] : ["--cookies-from-browser", browser.rawValue]
                precondition(BrowserAuthentication.arguments(for: url, browser: browser) == expected)
            }
            for url in unsupportedURLs {
                precondition(!BrowserAuthentication.supports(url))
                precondition(BrowserAuthentication.arguments(for: url, browser: browser).isEmpty)
            }
        }

        let botError = """
        WARNING: [youtube] No title found in player responses; falling back to title from initial data.
        ERROR: [youtube] pwQ0l4hFCVI: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication. See https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp
        """
        precondition(DownloadFailureKind.classify(botError) == .authenticationRequired)
        precondition(DownloadFailureKind.classify("ERROR: [youtube] Sign in to confirm your age") == .authenticationRequired)

        let browserErrors = [
            "ERROR: could not find chrome cookies database in /example/Chrome",
            "ERROR: Failed to extract cookies from Safari",
            "WARNING: failed to decrypt cookie (AES-CBC) because UTF-8 decoding failed",
            "ERROR: Could not copy Chrome cookie database. See https://github.com/yt-dlp/yt-dlp/issues/7271",
            "ERROR: Unable to read cookies from Firefox",
            "ERROR: Could not find Firefox profile directory",
            "ERROR: unable to obtain password from keychain",
            "ERROR: Keychain access denied",
            "ERROR: [Errno 1] Operation not permitted: '/example/Cookies.binarycookies'",
            "ERROR: [Errno 13] Permission denied: '/example/Default/Cookies'",
            "Extracting cookies from chrome\nERROR: unable to open database file"
        ]
        for error in browserErrors {
            precondition(DownloadFailureKind.classify(error) == .browserAccess, error)
        }
        precondition(DownloadFailureKind.classify(browserErrors[0] + "\n" + botError) == .browserAccess)

        for error in [
            "ERROR: [twitter] 2094926146588885419: No video could be found in this tweet",
            "ERROR: No video found in this post",
            "ERROR: This tweet does not contain a video"
        ] {
            precondition(DownloadFailureKind.classify(error) == .noVideo, error)
        }

        for error in [
            "ERROR: HTTP Error 503: Service Unavailable",
            "ERROR: Video unavailable. Use --cookies-from-browser or --cookies for authentication. See https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp",
            "ERROR: unable to download webpage. See https://github.com/yt-dlp/yt-dlp/wiki/Extractors#exporting-youtube-cookies",
            "ERROR: Requested format is not available",
            "ERROR: [twitter] Login required",
            "ERROR: No video formats found",
            "ERROR: unable to open database file",
            "Extracting cookies from chrome\nExtracted 123 cookies from chrome",
            ""
        ] {
            precondition(DownloadFailureKind.classify(error) == .other, error)
        }

        print("browser_auth_check=passed")
    }
}
