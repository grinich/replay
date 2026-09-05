import AppKit
import SwiftUI

@main
struct ReplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = QueueStore()
    @State private var isBrowserAuthenticationPresented = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(appDelegate.inbox)
                .sheet(isPresented: $isBrowserAuthenticationPresented) {
                    BrowserAuthenticationView(browser: store.authenticationBrowser)
                        .environmentObject(store)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.flushPendingSaves()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { }
            ReplayCommands(
                updater: appDelegate.updater,
                store: store,
                isBrowserAuthenticationPresented: $isBrowserAuthenticationPresented
            )
        }
    }
}

private struct ReplayCommands: Commands {
    @ObservedObject var updater: AppUpdater
    @ObservedObject var store: QueueStore
    @Binding var isBrowserAuthenticationPresented: Bool

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(updater.menuTitle) {
                updater.performMenuAction()
            }
            .disabled(!updater.menuItemIsEnabled)

            Divider()
            Button("YouTube Sign-In…") { isBrowserAuthenticationPresented = true }
            Button("Retry Failed Downloads") { store.retryFailedDownloads() }
                .disabled(!store.hasRetryableFailedDownloads)

            Divider()
            Button("Show Downloads Folder") { store.revealMediaFolder() }
            Button("Show Download Logs") { store.revealLogsFolder() }
        }
    }
}
