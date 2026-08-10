import Foundation

@MainActor
final class PowerModeMonitor {
    private var observer: NSObjectProtocol?

    private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    var onChange: ((Bool) -> Void)?

    func start() {
        guard observer == nil else { return }
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task { @MainActor [weak self] in
                self?.receive(enabled: enabled)
            }
        }
    }

    private func receive(enabled: Bool) {
        guard isLowPowerModeEnabled != enabled else { return }
        isLowPowerModeEnabled = enabled
        onChange?(enabled)
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
