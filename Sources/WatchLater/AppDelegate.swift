import AppKit
import Foundation

@MainActor
final class URLInbox: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published private(set) var clipboardValues: [String] = []

    func receive(_ incoming: [URL]) {
        urls.append(contentsOf: incoming)
    }

    func receiveClipboard(_ value: String) {
        clipboardValues.append(value)
    }

    func clear() {
        urls.removeAll()
    }

    func clearClipboard() {
        clipboardValues.removeAll()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let inbox = URLInbox()
    private var pasteMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SystemMediaController.shared.start()
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

            self?.inbox.receiveClipboard(value)
            return nil
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        SystemMediaController.shared.stop()
        if let pasteMonitor {
            NSEvent.removeMonitor(pasteMonitor)
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
