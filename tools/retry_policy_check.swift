import Foundation

@main
struct RetryPolicyCheck {
    static func main() {
        precondition(DownloadRetryPolicy.maximumRetries == 3)
        precondition(DownloadRetryPolicy.delaySeconds(forRetry: 1) == 2)
        precondition(DownloadRetryPolicy.delaySeconds(forRetry: 2) == 5)
        precondition(DownloadRetryPolicy.delaySeconds(forRetry: 3) == 10)
        precondition(DownloadRetryPolicy.isNetworkFailure(message: "connection reset", isOnline: true))
        precondition(DownloadRetryPolicy.isNetworkFailure(message: "anything", isOnline: false))
        precondition(!DownloadRetryPolicy.isNetworkFailure(message: "unsupported URL", isOnline: true))
        print("retry_policy_check=passed")
    }
}
