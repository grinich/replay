import Foundation
import Network

@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.mg.replay.network-monitor")
    private var isStarted = false

    private(set) var isOnline = false
    var onBecameOnline: (() -> Void)?

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                self?.receive(online: online)
            }
        }
        monitor.start(queue: queue)
    }

    private func receive(online: Bool) {
        let wasOnline = isOnline
        isOnline = online
        if online && !wasOnline {
            onBecameOnline?()
        }
    }

    deinit {
        monitor.cancel()
    }
}
