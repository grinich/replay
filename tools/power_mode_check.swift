import Foundation

@main
@MainActor
struct PowerModeCheck {
    static func main() {
        let monitor = PowerModeMonitor()
        precondition(monitor.isLowPowerModeEnabled == ProcessInfo.processInfo.isLowPowerModeEnabled)
        monitor.start()
        print("power_mode_check=passed")
    }
}
