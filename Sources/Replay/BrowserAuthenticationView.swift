import SwiftUI

/// Holds a draft choice until the user explicitly applies it. Opening or
/// cancelling this sheet never enables access to a browser session.
struct BrowserAuthenticationView: View {
    @EnvironmentObject private var store: QueueStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBrowser: DownloadBrowser
    let retryItemID: UUID?

    init(browser: DownloadBrowser, retryItemID: UUID? = nil) {
        _selectedBrowser = State(initialValue: browser)
        self.retryItemID = retryItemID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("YouTube Sign-In")
                        .font(.title2.weight(.semibold))
                    Text(retryItemID == nil ? "Choose a browser" : "Sign in, then retry this video")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Choose a browser where you’re already signed into YouTube. Replay will use that session for future YouTube previews and downloads.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                Picker("Browser", selection: $selectedBrowser) {
                    ForEach(DownloadBrowser.allCases) { browser in
                        Text(browser == .none ? (retryItemID == nil ? "Off" : "Choose a browser…") : browser.displayName)
                            .tag(browser)
                    }
                }
                .pickerStyle(.menu)
                Text("Uses the browser’s default or most recently used profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                Label {
                    Text("Replay’s downloader reads cookies locally from this browser and sends your YouTube session to YouTube. No cookie file is exported.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(6)
            }

            if selectedBrowser != .none && selectedBrowser != .firefox {
                Text(selectedBrowser == .safari
                     ? "Safari may require Full Disk Access for Replay in System Settings."
                     : "macOS may ask you to allow access to the browser’s Keychain entry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(retryItemID != nil && selectedBrowser == .none)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onExitCommand { dismiss() }
    }

    private var confirmTitle: String {
        if selectedBrowser == .none { return retryItemID == nil ? "Save" : "Choose a Browser" }
        return retryItemID == nil
            ? "Use \(selectedBrowser.displayName)"
            : "Use \(selectedBrowser.displayName) & Retry"
    }

    private func confirm() {
        if let retryItemID {
            guard selectedBrowser != .none else { return }
            store.authenticateAndRetry(retryItemID, using: selectedBrowser)
        } else {
            store.authenticationBrowser = selectedBrowser
        }
        dismiss()
    }
}
