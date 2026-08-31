import AppKit
import Foundation

struct AddVideoRequest: Identifiable, Equatable {
    enum Source: Equatable {
        case foregroundClipboard
        case pasteShortcut
    }

    let id = UUID()
    let url: URL
    let source: Source
}

@MainActor
final class URLInbox: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published private(set) var addVideoRequest: AddVideoRequest?
    private var offeredClipboardURLs: Set<String> = []

    func receive(_ incoming: [URL]) {
        urls.append(contentsOf: incoming)
    }

    func offerForegroundClipboard(_ value: String) {
        guard let url = URLIntake.foregroundVideoURL(from: value) else { return }
        let canonical = URLIntake.canonicalString(for: url)
        guard offeredClipboardURLs.insert(canonical).inserted else { return }
        addVideoRequest = AddVideoRequest(url: URL(string: canonical) ?? url, source: .foregroundClipboard)
    }

    func requestAddVideo(from value: String) {
        guard let url = URLIntake.webURL(from: value) else { return }
        addVideoRequest = AddVideoRequest(url: url, source: .pasteShortcut)
    }

    func clear() {
        urls.removeAll()
    }

    func clearAddVideoRequest() {
        addVideoRequest = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let inbox = URLInbox()
    let updater = AppUpdater()
    private var pasteMonitor: Any?
    private var localMediaKeyMonitor: Any?
    private var globalMediaKeyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = updater.installStagedUpdateFromPreviousLaunchIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard updater.phase != .installing else { return }
        SystemMediaController.shared.start()
        updater.startAutomaticChecks()
        localMediaKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleHardwareMediaKey(event) == true ? nil : event
        }
        // Local event monitors only see events delivered to Replay. The
        // keyboard's system play/pause key must keep controlling the active
        // Replay video when another app is frontmost, so cover that half of
        // AppKit's event stream with a matching global monitor.
        globalMediaKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            DispatchQueue.main.async {
                _ = self?.handleHardwareMediaKey(event)
            }
        }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let shortcutModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // SwiftUI text fields use AppKit's shared field editor. Let it
            // receive navigation, editing, and paste keys before considering
            // any app-wide playback or URL shortcuts.
            if Self.isEditingText(in: event.window) {
                return event
            }

            if shortcutModifiers.isEmpty {
                if event.keyCode == 49, PlaybackCommandCenter.shared.hasActivePlayer {
                    if !event.isARepeat {
                        PlaybackCommandCenter.shared.togglePlayback()
                    }
                    return nil
                }

                if event.charactersIgnoringModifiers?.lowercased() == "f",
                   PlaybackCommandCenter.shared.hasActivePlayer {
                    if !event.isARepeat {
                        PlaybackCommandCenter.shared.toggleFullscreen()
                    }
                    return nil
                }

                if event.keyCode == 53,
                   PlaybackCommandCenter.shared.exitFullscreen() {
                    return nil
                }

                if event.keyCode == 126,
                   PlaybackCommandCenter.shared.adjustPlaybackRate(by: 0.1) {
                    return nil
                }
                if event.keyCode == 125,
                   PlaybackCommandCenter.shared.adjustPlaybackRate(by: -0.1) {
                    return nil
                }

                let skipAmount: Double?
                switch event.keyCode {
                case 123: skipAmount = -10
                case 124: skipAmount = 10
                default: skipAmount = nil
                }
                if let skipAmount, PlaybackCommandCenter.shared.skip(by: skipAmount) {
                    return nil
                }
            }

            guard shortcutModifiers == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else {
                return event
            }

            let pasteboard = NSPasteboard.general
            let urlType = NSPasteboard.PasteboardType("public.url")
            guard let value = pasteboard.string(forType: .string)
                    ?? pasteboard.string(forType: urlType) else {
                NSSound.beep()
                return nil
            }

            self?.inbox.requestAddVideo(from: value)
            return nil
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let pasteboard = NSPasteboard.general
        let urlType = NSPasteboard.PasteboardType("public.url")
        guard let value = pasteboard.string(forType: .string)
                ?? pasteboard.string(forType: urlType) else { return }
        inbox.offerForegroundClipboard(value)
    }

    private static func isEditingText(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let textView = responder as? NSTextView {
            return textView.isEditable
        }
        if let textField = responder as? NSTextField {
            return textField.isEditable
        }
        if let control = responder as? NSControl {
            return control.currentEditor() != nil
        }
        return false
    }

    private func handleHardwareMediaKey(_ event: NSEvent) -> Bool {
        guard let action = HardwareMediaKeyEventPolicy.action(
            subtype: Int(event.subtype.rawValue),
            data1: event.data1
        ), PlaybackCommandCenter.shared.hasActivePlayer else { return false }
        return SystemMediaController.shared.handleHardwareMediaKey(action)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemMediaController.shared.stop()
        if let pasteMonitor {
            NSEvent.removeMonitor(pasteMonitor)
        }
        if let localMediaKeyMonitor {
            NSEvent.removeMonitor(localMediaKeyMonitor)
        }
        if let globalMediaKeyMonitor {
            NSEvent.removeMonitor(globalMediaKeyMonitor)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        inbox.receive(urls)
        application.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        inbox.receive(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
        sender.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}
