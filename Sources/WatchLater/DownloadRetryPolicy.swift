import Foundation

enum DownloadRetryPolicy {
    static let maximumRetries = 3
    private static let retryDelays: [UInt64] = [2, 5, 10]

    static func delaySeconds(forRetry attempt: Int) -> UInt64 {
        guard attempt > 0 else { return retryDelays[0] }
        return retryDelays[min(attempt - 1, retryDelays.count - 1)]
    }

    static func isNetworkFailure(message: String, isOnline: Bool) -> Bool {
        if !isOnline { return true }
        let value = message.lowercased()
        let indicators = [
            "network", "connection", "timed out", "timeout", "dns",
            "unable to download webpage", "temporary failure",
            "remote end closed", "connection reset", "connection refused",
            "no route to host", "offline", "name resolution"
        ]
        return indicators.contains { value.contains($0) }
    }
}
