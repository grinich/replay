import AppKit
import SwiftUI

@main
struct ReplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = QueueStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(appDelegate.inbox)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.flushPendingSaves()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { }
            ReplayCommands(updater: appDelegate.updater, store: store)
        }
    }
}

private struct ReplayCommands: Commands {
    @ObservedObject var updater: AppUpdater
    let store: QueueStore

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(updater.menuTitle) {
                updater.performMenuAction()
            }
            .disabled(!updater.menuItemIsEnabled)

            Divider()
            Button("Show Downloads Folder") { store.revealMediaFolder() }
            Button("Show Download Logs") { store.revealLogsFolder() }
        }
    }
}
