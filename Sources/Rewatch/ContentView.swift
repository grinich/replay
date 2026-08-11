import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: QueueStore
    @EnvironmentObject private var inbox: URLInbox
    @State private var urlText = ""
    @State private var isDropTarget = false
    @State private var itemToDelete: WatchItem?
    @State private var detailSelection: UUID?
    @State private var detailSelectionTask: Task<Void, Never>?
    @State private var knownItemIDs: Set<UUID> = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var queueRowFrames: [UUID: CGRect] = [:]
    @State private var windowWidth: CGFloat = 1320
    @State private var urlBarFrame: CGRect = .zero
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 272, ideal: 312, max: 360)
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .named("rewatch-window"))
                        .onEnded(handleWindowTap)
                )
        } detail: {
            detail
                .simultaneousGesture(
                    TapGesture().onEnded(dismissURLFieldFocus)
                )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 640)
        .coordinateSpace(name: "rewatch-window")
        .onPreferenceChange(URLBarFramePreferenceKey.self) { urlBarFrame = $0 }
        .background {
            ZStack {
                WindowStyleConfigurator(title: store.selectedItem?.title ?? "Rewatch")
                    .frame(width: 0, height: 0)

                WindowWidthReader { width in
                    guard abs(windowWidth - width) > 0.5 else { return }
                    windowWidth = width
                    if width < 1160,
                       columnVisibility != .detailOnly,
                       let selectedItem = store.selectedItem,
                       !selectedItem.availableChapters.isEmpty {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            columnVisibility = .detailOnly
                        }
                    }
                }
                .frame(width: 0, height: 0)
            }
        }
        .overlay(alignment: .top) {
            if let notice = store.intakeNotice {
                IntakeToast(notice: notice, dismiss: store.dismissIntakeNotice)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: store.intakeNotice?.id)
        .onAppear {
            if detailSelection == nil { detailSelection = store.selection }
            knownItemIDs = Set(store.items.map(\.id))
            consumePendingURLs()
            consumePendingClipboardValues()
        }
        .onDisappear { detailSelectionTask?.cancel() }
        .onChange(of: store.selection) { selectedID in
            updateDetailAfterSelectionPaints(selectedID)
        }
        .onChange(of: inbox.urls) { urls in
            urls.forEach(store.accept)
            inbox.clear()
        }
        .onChange(of: inbox.clipboardValues) { values in
            values.forEach { store.accept(rawValue: $0) }
            inbox.clearClipboard()
        }
        .alert("Couldn’t Add Links", isPresented: Binding(
            get: { store.lastIntakeError != nil },
            set: { if !$0 { store.lastIntakeError = nil } }
        )) {
            Button("OK", role: .cancel) { store.lastIntakeError = nil }
        } message: {
            Text(store.lastIntakeError ?? "Unknown error")
        }
        .confirmationDialog(
            "Remove this video?",
            isPresented: Binding(get: { itemToDelete != nil }, set: { if !$0 { itemToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove video and local file", role: .destructive) {
                if let itemToDelete { store.remove(itemToDelete.id) }
                itemToDelete = nil
            }
            Button("Cancel", role: .cancel) { itemToDelete = nil }
        }
    }

    private var sidebar: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
                .opacity(0.38)
                .ignoresSafeArea()

            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color.white.opacity(0.055), Color.clear, Color.accentColor.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                DropAndAddBar(
                    urlText: $urlText,
                    isDropTarget: $isDropTarget,
                    isURLFieldFocused: $isURLFieldFocused,
                    submit: submitURL,
                    receiveProviders: receiveProviders
                )
                .padding(.leading, 82)
                .padding(.trailing, 54)
                // NavigationSplitView supplies the native title-bar inset. Keep
                // the add field in the unshifted center of that header so it
                // shares a baseline with the traffic-light cluster.
                .frame(height: 46)

                Divider()

                queueList
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    @ViewBuilder
    private var queueList: some View {
        let queueItems = store.queueItems
        let archivedItems = store.archivedItems

        if queueItems.isEmpty && archivedItems.isEmpty {
            SidebarEmptyState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                        if !queueItems.isEmpty {
                            ForEach(queueItems) { item in
                                sidebarRow(item)
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: QueueRowFramePreferenceKey.self,
                                                value: [item.id: geometry.frame(in: .named("queue-list"))]
                                            )
                                        }
                                    }
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 4, coordinateSpace: .named("queue-list"))
                                            .onChanged { updateQueueDrag(item.id, at: $0.location) }
                                    )
                            }
                        }

                        if !archivedItems.isEmpty {
                            Section {
                                ForEach(archivedItems) { item in
                                    sidebarRow(item)
                                }
                            } header: {
                                SidebarSectionHeader(
                                    title: "Archive",
                                    count: archivedItems.count,
                                    systemImage: "checkmark.circle"
                                )
                                .padding(.top, queueItems.isEmpty ? 0 : 10)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .scrollIndicators(.hidden)
                .clipped()
                .coordinateSpace(name: "queue-list")
                .onPreferenceChange(QueueRowFramePreferenceKey.self) { queueRowFrames = $0 }
                .onChange(of: store.items.map(\.id)) { itemIDs in
                    let addedID = itemIDs.last { !knownItemIDs.contains($0) }
                    knownItemIDs = Set(itemIDs)
                    guard let addedID else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(addedID, anchor: .bottom)
                    }
                }
                .onAppear {
                    guard let selectedID = store.selection else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(selectedID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func sidebarRow(_ item: WatchItem) -> some View {
        QueueRow(
            item: item,
            isSelected: store.selection == item.id,
            select: { store.selection = item.id },
            rename: { store.rename(item.id, to: $0) }
        )
        .equatable()
        .id(item.id)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(item.isWatched ? "Move to Queue" : "Mark Watched") {
                store.toggleWatched(item.id)
            }
            if item.state == .failed {
                Button("Retry Download") { store.startDownload(for: item.id) }
            }
            Button("Open Original") { store.openOriginal(item.id) }
            Divider()
            Button("Remove", role: .destructive) { itemToDelete = item }
        }
    }

    private func updateQueueDrag(_ draggedID: UUID, at location: CGPoint) {
        guard let target = queueRowFrames
            .filter({ $0.key != draggedID && $0.value.contains(location) })
            .min(by: { abs($0.value.midY - location.y) < abs($1.value.midY - location.y) }) else { return }
        let insertAfter = location.y >= target.value.midY
        withAnimation(.easeInOut(duration: 0.15)) {
            store.reorderQueueItem(draggedID, relativeTo: target.key, insertAfter: insertAfter)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let detailSelection,
           let item = store.items.first(where: { $0.id == detailSelection }) {
            VideoDetail(
                item: item,
                sidebarCollapsed: columnVisibility == .detailOnly,
                windowWidth: windowWidth,
                collapseSidebar: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        columnVisibility = .detailOnly
                    }
                }
            )
                .id(item.id)
        } else {
            EmptyLibraryView(isDropTarget: $isDropTarget, receiveProviders: receiveProviders)
        }
    }

    private func updateDetailAfterSelectionPaints(_ selectedID: UUID?) {
        detailSelectionTask?.cancel()
        detailSelectionTask = Task {
            await Task.yield()
            guard !Task.isCancelled, store.selection == selectedID else { return }
            detailSelection = selectedID
        }
    }

    private func submitURL() {
        let value = urlText
        urlText = ""
        store.accept(rawValue: value)
    }

    private func consumePendingURLs() {
        guard !inbox.urls.isEmpty else { return }
        inbox.urls.forEach(store.accept)
        inbox.clear()
    }

    private func consumePendingClipboardValues() {
        guard !inbox.clipboardValues.isEmpty else { return }
        inbox.clipboardValues.forEach { store.accept(rawValue: $0) }
        inbox.clearClipboard()
    }

    private func receiveProviders(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSURL.self) {
                accepted = true
                provider.loadObject(ofClass: NSURL.self) { object, _ in
                    guard let url = object as? URL else { return }
                    DispatchQueue.main.async { store.accept(url) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String else { return }
                    DispatchQueue.main.async { store.accept(rawValue: text) }
                }
            }
        }
        return accepted
    }

    private func handleWindowTap(_ tap: SpatialTapGesture.Value) {
        guard !urlBarFrame.contains(tap.location) else { return }
        dismissURLFieldFocus()
    }

    private func dismissURLFieldFocus() {
        guard isURLFieldFocused else { return }
        isURLFieldFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

private struct QueueRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct URLBarFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct IntakeToast: View {
    let notice: QueueStore.IntakeNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.systemImage)
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                Text(notice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.leading, 13)
        .padding(.trailing, 9)
        .watchGlass(.regular, interactive: true, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18))
        }
        .frame(maxWidth: 430)
    }
}

private struct QueueRow: View, Equatable {
    let item: WatchItem
    let isSelected: Bool
    let select: () -> Void
    let rename: (String) -> Void
    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @FocusState private var isTitleFocused: Bool

    static func == (lhs: QueueRow, rhs: QueueRow) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 11) {
            QueueThumbnail(item: item, icon: icon, isSelected: isSelected)

            VStack(alignment: .leading, spacing: 5) {
                title

                HStack(spacing: 5) {
                    Text(displaySource)
                    Circle()
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: 2.5, height: 2.5)
                    Text(statusText)
                        .lineLimit(1)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)

                if item.state == .downloading {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(.accentColor)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.2))
                    }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }

    @ViewBuilder
    private var title: some View {
        if isEditingTitle {
            TextField("Video title", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.callout.weight(.semibold))
                .focused($isTitleFocused)
                .onSubmit { finishEditing(save: true) }
                .onExitCommand { finishEditing(save: false) }
                .onChange(of: isTitleFocused) { focused in
                    if !focused, isEditingTitle {
                        finishEditing(save: true)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                }
        } else {
            Text(item.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: beginEditing)
                .help("Double-click to rename")
        }
    }

    private func beginEditing() {
        select()
        draftTitle = item.title
        isEditingTitle = true
        DispatchQueue.main.async {
            isTitleFocused = true
        }
    }

    private func finishEditing(save: Bool) {
        guard isEditingTitle else { return }
        if save {
            let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                rename(trimmed)
            }
        }
        isEditingTitle = false
        isTitleFocused = false
    }

    private var icon: String {
        switch item.state {
        case .queued: return "clock.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .ready: return item.isWatched ? "checkmark.circle.fill" : "play.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var displaySource: String {
        item.sourceName.lowercased().capitalized
    }

    private var statusText: String {
        switch item.state {
        case .queued, .downloading:
            return item.progressLabel
        case .ready:
            return item.resumablePosition > 0
                ? "Resume \(formatTime(item.resumablePosition))"
                : "Saved offline"
        case .failed:
            return item.progressLabel
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct QueueThumbnail: View {
    let item: WatchItem
    let icon: String
    let isSelected: Bool

    var body: some View {
        ZStack {
            if let image = ThumbnailImageCache.image(for: item.thumbnailFileURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.32), Color.secondary.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
            }

            if item.state == .downloading || item.state == .queued {
                Color.black.opacity(0.22)
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    if item.isWatched {
                        Image(systemName: "checkmark")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Color.green.opacity(0.9), in: Circle())
                    }
                    Spacer()
                    if let duration = item.duration, item.state == .ready {
                        Text(formatDuration(duration))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.68), in: Capsule())
                    }
                }
                .padding(5)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1))
        }
        .overlay(alignment: .bottomLeading) {
            if let duration = item.duration, duration > 0, item.resumablePosition > 0 {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * min(item.resumablePosition / duration, 1), height: 3)
                }
                .frame(height: 3)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }
}

private struct SidebarEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.square.stack")
                .font(.system(size: 28, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("Your library is quiet")
                .font(.subheadline.weight(.semibold))
            Text("Paste a link to save your next video.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 190)
        }
        .padding()
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let count: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
            Spacer()
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
    }
}

private struct VideoDetail: View {
    @EnvironmentObject private var store: QueueStore
    @AppStorage("subtitlesEnabled") private var subtitlesEnabled = false
    @AppStorage("chaptersPresented") private var chaptersPresented = true
    @State private var seekRequest: PlayerSeekRequest?
    @State private var playback = PlaybackSnapshot.empty
    @State private var subtitleTrack: VideoSubtitleTrack?
    @State private var isPlayerPrepared = false
    @State private var playerPreparationTask: Task<Void, Never>?
    @State private var subtitleLoadTask: Task<Void, Never>?
    @State private var volumeHUDValue = PlaybackVolumePreference.load()
    @State private var volumeHUDVisible = false
    @State private var volumeHUDDismissalTask: Task<Void, Never>?
    let item: WatchItem
    let sidebarCollapsed: Bool
    let windowWidth: CGFloat
    let collapseSidebar: () -> Void

    var body: some View {
        detailBody
            .navigationTitle("")
    }

    private var detailBody: some View {
        chapterLayout
            .onAppear {
                preparePlayerAfterSelection()
                loadSubtitles()
                collapseSidebarForNarrowChapterLayoutIfNeeded()
            }
            .onDisappear {
                playerPreparationTask?.cancel()
                subtitleLoadTask?.cancel()
                volumeHUDDismissalTask?.cancel()
            }
            .onChange(of: item.localFilePath) { _ in preparePlayerAfterSelection() }
            .onChange(of: item.subtitleFilePath) { _ in loadSubtitles() }
            .onChange(of: windowWidth) { _ in collapseSidebarForNarrowChapterLayoutIfNeeded() }
            .onChange(of: sidebarCollapsed) { isCollapsed in
                guard !isCollapsed, prefersOneSidePane, chaptersPresented else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    chaptersPresented = false
                }
            }
    }

    private var usesCompactToolbarActions: Bool {
        !item.availableChapters.isEmpty
    }

    @ViewBuilder
    private var chapterLayout: some View {
        if item.availableChapters.isEmpty {
            centerPane
        } else if #available(macOS 14.0, *) {
            centerPane
                .inspector(isPresented: $chaptersPresented) {
                    chapterSidebar
                        .inspectorColumnWidth(min: 232, ideal: 300, max: 400)
                }
        } else {
            HSplitView {
                centerPane
                    .frame(minWidth: 620)

                if chaptersPresented {
                    chapterSidebar
                        .frame(minWidth: 232, idealWidth: 300, maxWidth: 400)
                }
            }
        }
    }

    private var centerPane: some View {
        VStack(spacing: 0) {
            centerPaneHeader
            Divider()
            mainContent
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var centerPaneHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !item.author.isEmpty {
                    Text(item.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            TitlebarInteractiveHost {
                videoActionButtons
            }
            .fixedSize()

            if !item.availableChapters.isEmpty, !chaptersPresented {
                TitlebarInteractiveHost {
                    Button(action: toggleChapters) {
                        Image(systemName: "sidebar.trailing")
                    }
                    .watchGlassButton()
                    .help("Show chapters")
                }
                .fixedSize()
            }
        }
        .padding(.leading, sidebarCollapsed ? 154 : 14)
        .padding(.trailing, 14)
        .frame(height: 56)
    }

    private var videoActionButtons: some View {
        WatchGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    store.openOriginal(item.id)
                } label: {
                    if usesCompactToolbarActions {
                        Image(systemName: "safari")
                    } else {
                        Label("Open Original", systemImage: "safari")
                    }
                }
                .watchGlassButton()
                .help("Open the original video")

                Button {
                    store.toggleWatched(item.id)
                } label: {
                    if usesCompactToolbarActions {
                        Image(systemName: item.isWatched ? "arrow.uturn.backward" : "checkmark")
                    } else {
                        Label(
                            item.isWatched ? "Move to Queue" : "Mark Watched",
                            systemImage: item.isWatched ? "arrow.uturn.backward" : "checkmark"
                        )
                    }
                }
                .watchGlassButton()
                .help(item.isWatched ? "Move this video back to the queue" : "Mark this video as watched")
            }
        }
    }

    private var mainContent: some View {
        GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - 32)

            ZStack {
                DetailBackdrop(thumbnailURL: item.thumbnailFileURL)
                    .equatable()

                VStack(spacing: 13) {
                    playerSurface
                        .frame(width: contentWidth)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 12)

                    if item.localFileURL != nil, item.state == .ready, isPlayerPrepared {
                        PlaybackControls(
                            snapshot: playback,
                            knownDuration: item.duration,
                            chapters: item.availableChapters,
                            togglePlayback: { PlaybackCommandCenter.shared.togglePlayback() },
                            skip: { PlaybackCommandCenter.shared.skip(by: $0) },
                            seek: seekToTime,
                            toggleMute: { PlaybackCommandCenter.shared.toggleMute() },
                            setPlaybackRate: { PlaybackCommandCenter.shared.setPlaybackRate(to: $0) },
                            hasSubtitles: subtitleTrack != nil,
                            subtitlesEnabled: subtitlesEnabled,
                            toggleSubtitles: { subtitlesEnabled.toggle() }
                        )
                        .frame(width: contentWidth)
                        .padding(.bottom, 14)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
    }

    private var chapterSidebar: some View {
        ChapterSidebar(
            chapters: item.availableChapters,
            currentTime: playback.currentTime,
            isPresented: chaptersPresented,
            toggle: toggleChapters,
            select: seekToChapter
        )
        .ignoresSafeArea(.container, edges: .top)
    }

    private var playerSurface: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let fileURL = item.localFileURL, item.state == .ready {
                    if isPlayerPrepared {
                        GeometryReader { geometry in
                            LocalVideoPlayer(
                                url: fileURL,
                                title: item.title,
                                author: item.author,
                                resumeAt: item.resumablePosition,
                                seekRequest: seekRequest,
                                onProgress: { store.updatePlaybackPosition($0, for: item.id) },
                                onStateChange: { playback = $0 },
                                onVolumeChange: showVolumeHUD,
                                onEnded: { store.markWatched(item.id) }
                            )
                            .id(fileURL)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    } else {
                        playerLoadingState
                    }
                } else {
                    downloadState
                }
            }

            if subtitlesEnabled, let caption = subtitleTrack?.text(at: playback.currentTime) {
                Text(caption)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
                    .frame(maxWidth: 900)
                    .padding(.horizontal, 48)
                    .padding(.bottom, 26)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if volumeHUDVisible {
                PlayerVolumeHUD(
                    volume: volumeHUDValue,
                    isMuted: playback.isMuted || volumeHUDValue <= 0
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12))
        }
    }

    private func preparePlayerAfterSelection() {
        playerPreparationTask?.cancel()
        isPlayerPrepared = false
        guard item.state == .ready, item.localFileURL != nil else { return }
        playerPreparationTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            isPlayerPrepared = true
        }
    }

    private func loadSubtitles() {
        subtitleLoadTask?.cancel()
        subtitleTrack = nil
        guard let subtitleURL = item.subtitleFileURL else { return }
        subtitleLoadTask = Task {
            let track = await Task.detached(priority: .utility) {
                VideoSubtitleTrack(contentsOf: subtitleURL)
            }.value
            guard !Task.isCancelled else { return }
            subtitleTrack = track
        }
    }

    private func showVolumeHUD(_ volume: Double) {
        volumeHUDDismissalTask?.cancel()
        volumeHUDValue = PlaybackVolumePreference.normalized(volume)
        withAnimation(volumeHUDAnimation) {
            volumeHUDVisible = true
        }
        volumeHUDDismissalTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(volumeHUDAnimation) {
                volumeHUDVisible = false
            }
        }
    }

    private var volumeHUDAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil
            : .easeOut(duration: 0.15)
    }

    private var playerLoadingState: some View {
        ZStack {
            if let image = ThumbnailImageCache.image(for: item.thumbnailFileURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.42)
            }
            Color.black.opacity(0.36)
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }

    @ViewBuilder
    private var downloadState: some View {
        ZStack {
            if let image = ThumbnailImageCache.image(for: item.thumbnailFileURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 22)
                    .opacity(0.38)
            }
            LinearGradient(
                colors: [Color.black.opacity(0.28), Color.black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 15) {
                Image(systemName: stateIcon)
                    .font(.system(size: 38, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                Text(item.state == .failed ? "Download failed" : "Saving for offline")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                if item.state == .downloading {
                    ProgressView(value: item.progress)
                        .tint(.white)
                        .frame(width: 300)
                    Text(item.progressLabel)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.68))
                } else if item.state == .failed {
                    Text(item.errorMessage ?? "Unknown download error")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                        .textSelection(.enabled)
                    Button("Retry Download") { store.startDownload(for: item.id) }
                        .watchGlassButton(prominent: true)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
            .padding(40)
        }
    }

    private var stateIcon: String {
        item.state == .failed ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill"
    }

    private func seekToChapter(_ chapter: VideoChapter) {
        seekRequest = PlayerSeekRequest(time: chapter.startTime, shouldPlay: playback.isPlaying)
        store.updatePlaybackPosition(chapter.startTime, for: item.id)
    }

    private func seekToTime(_ time: Double) {
        seekRequest = PlayerSeekRequest(time: time, shouldPlay: playback.isPlaying)
        store.updatePlaybackPosition(time, for: item.id)
    }

    private func toggleChapters() {
        let willShow = !chaptersPresented
        if willShow, prefersOneSidePane, !sidebarCollapsed {
            collapseSidebar()
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            chaptersPresented = willShow
        }
    }

    private var prefersOneSidePane: Bool {
        windowWidth < 1160 && !item.availableChapters.isEmpty
    }

    private func collapseSidebarForNarrowChapterLayoutIfNeeded() {
        guard prefersOneSidePane, chaptersPresented, !sidebarCollapsed else { return }
        collapseSidebar()
    }
}

private struct DetailBackdrop: View, Equatable {
    let thumbnailURL: URL?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            if let image = ThumbnailImageCache.image(for: thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 90)
                    .saturation(1.15)
                    .opacity(0.12)
                    .scaleEffect(1.15)
            }

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.88)

            LinearGradient(
                colors: [Color.white.opacity(0.025), Color.clear, Color.black.opacity(0.025)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct PlayerVolumeHUD: View {
    let volume: Double
    let isMuted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 26)

            ProgressView(value: isMuted ? 0 : volume)
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(width: 112)

            Text("\(Int(((isMuted ? 0 : volume) * 100).rounded()))%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 38, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14))
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue(isMuted ? "Muted" : "\(Int((volume * 100).rounded())) percent")
    }

    private var symbolName: String {
        if isMuted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

private struct PlaybackControls: View {
    let snapshot: PlaybackSnapshot
    let knownDuration: Double?
    let chapters: [VideoChapter]
    let togglePlayback: () -> Void
    let skip: (Double) -> Void
    let seek: (Double) -> Void
    let toggleMute: () -> Void
    let setPlaybackRate: (Double) -> Void
    let hasSubtitles: Bool
    let subtitlesEnabled: Bool
    let toggleSubtitles: () -> Void
    @State private var scrubTime: Double?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(showRemainingTime: true, spacing: 10)
            controlRow(showRemainingTime: false, spacing: 6)
            compactControlLayout
            narrowControlLayout
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .watchGlass(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14))
        }
    }

    private func controlRow(showRemainingTime: Bool, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            transportControls
            timeline(showRemainingTime: showRemainingTime)
            utilityControls
        }
    }

    private var compactControlLayout: some View {
        VStack(spacing: 2) {
            timeline(showRemainingTime: false)

            HStack(spacing: 6) {
                transportControls
                Spacer(minLength: 4)
                utilityControls
            }
        }
    }

    private var narrowControlLayout: some View {
        VStack(spacing: 4) {
            timeline(showRemainingTime: false)
            transportControls
            utilityControls
        }
        .frame(maxWidth: .infinity)
    }

    private var transportControls: some View {
        WatchGlassContainer(spacing: 4) {
            HStack(spacing: 3) {
                PlayerControlButton(
                    systemImage: snapshot.isPlaying ? "pause.fill" : "play.fill",
                    help: snapshot.isPlaying ? "Pause (Space)" : "Play (Space)",
                    isPrimary: true,
                    action: togglePlayback
                )
                PlayerControlButton(systemImage: "gobackward.10", help: "Back 10 seconds (Left Arrow)") {
                    skip(-10)
                }
                PlayerControlButton(systemImage: "goforward.10", help: "Forward 10 seconds (Right Arrow)") {
                    skip(10)
                }
            }
        }
        .fixedSize()
    }

    private var utilityControls: some View {
        HStack(spacing: 6) {
            PlaybackSpeedMenu(
                playbackRate: snapshot.playbackRate,
                select: setPlaybackRate
            )

            PlayerControlButton(
                systemImage: subtitlesEnabled && hasSubtitles ? "captions.bubble.fill" : "captions.bubble",
                help: hasSubtitles
                    ? (subtitlesEnabled ? "Turn subtitles off" : "Turn subtitles on")
                    : "No English subtitles available",
                isEnabled: hasSubtitles,
                isSelected: subtitlesEnabled && hasSubtitles,
                action: toggleSubtitles
            )

            AirPlayRoutePicker()
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(snapshot.isExternalPlaybackActive
                            ? Color.accentColor.opacity(0.16)
                            : Color.primary.opacity(0.04))
                }
                .help(snapshot.isExternalPlaybackActive ? "AirPlay is connected" : "Choose an AirPlay device")

            PlayerControlButton(
                systemImage: snapshot.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                help: snapshot.isMuted ? "Unmute" : "Mute",
                action: toggleMute
            )
        }
        .fixedSize()
    }

    @ViewBuilder
    private func timeline(showRemainingTime: Bool) -> some View {
        HStack(spacing: 6) {
            Text(formatTime(displayTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 46, alignment: .trailing)

            ChapterScrubber(
                value: min(displayTime, effectiveDuration),
                duration: effectiveDuration,
                chapters: chapters,
                scrubChanged: { scrubTime = $0 },
                scrubEnded: { time in
                    seek(time)
                    scrubTime = nil
                }
            )
            .frame(minWidth: 80, maxWidth: .infinity)
            .frame(height: 44)
            .disabled(effectiveDuration <= 0)

            if showRemainingTime {
                Text("−\(formatTime(max(0, effectiveDuration - displayTime)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .leading)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var effectiveDuration: Double {
        max(snapshot.duration, knownDuration ?? 0)
    }

    private var displayTime: Double {
        scrubTime ?? snapshot.currentTime
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }
}

private struct PlaybackSpeedMenu: View {
    let playbackRate: Double
    let select: (Double) -> Void

    var body: some View {
        Menu {
            ForEach(PlaybackRatePolicy.supportedRates, id: \.self) { rate in
                Button {
                    select(rate)
                } label: {
                    if rate == normalizedRate {
                        Label(rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(rate))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                    .font(.caption)
                Text(rateLabel(normalizedRate))
                    .font(.caption.weight(.semibold).monospacedDigit())
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Capsule())
            .watchGlass(.clear, interactive: true, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.07))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose playback speed (Up/Down Arrow adjusts by 0.1×)")
        .accessibilityLabel("Playback speed")
        .accessibilityValue(rateLabel(normalizedRate))
    }

    private var normalizedRate: Double {
        PlaybackRatePolicy.normalized(playbackRate)
    }

    private func rateLabel(_ rate: Double) -> String {
        String(format: "%.1f×", rate)
    }
}

private struct ChapterTimelineSegment: Identifiable {
    let startTime: Double
    let endTime: Double
    let title: String

    var id: String { "\(startTime)-\(title)" }
}

private struct ChapterScrubber: View {
    let value: Double
    let duration: Double
    let chapters: [VideoChapter]
    let scrubChanged: (Double) -> Void
    let scrubEnded: (Double) -> Void
    @State private var hoverTime: Double?
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let previewTime = hoverTime.map { min(max(0, $0), duration) }
            let timelineSegments = segments
            let currentChapterTime: Double? = hasChapterTitles && !timelineSegments.isEmpty && duration > 0
                ? min(max(0, value), duration)
                : nil
            let displayedPillTime = previewTime ?? currentChapterTime

            ZStack(alignment: .topLeading) {
                if let displayedPillTime {
                    chapterPopover(time: displayedPillTime, width: width, segments: timelineSegments)
                }

                timelineTrack(width: width, segments: timelineSegments)
                    .frame(width: width, height: 8, alignment: .leading)
                    .offset(y: 31)

                Circle()
                    .fill(Color.accentColor)
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.95), lineWidth: 2)
                    }
                    .shadow(color: Color.accentColor.opacity(0.32), radius: 3)
                    .frame(width: 13, height: 13)
                    .position(x: thumbPosition(for: value, width: width), y: 35)

                if let previewTime, !isDragging {
                    Circle()
                        .fill(Color.primary.opacity(0.8))
                        .overlay {
                            Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                        }
                        .frame(width: 8, height: 8)
                        .position(x: xPosition(for: previewTime, width: width), y: 35)
                }
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { gesture in
                        guard duration > 0 else { return }
                        isDragging = true
                        let time = time(for: gesture.location.x, width: width)
                        hoverTime = time
                        scrubChanged(time)
                    }
                    .onEnded { gesture in
                        guard duration > 0 else { return }
                        let time = time(for: gesture.location.x, width: width)
                        scrubChanged(time)
                        scrubEnded(time)
                        isDragging = false
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard duration > 0 else { return }
                    hoverTime = time(for: location.x, width: width)
                case .ended:
                    if !isDragging { hoverTime = nil }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(formatTime(value)) of \(formatTime(duration))")
    }

    private func timelineTrack(width: CGFloat, segments: [ChapterTimelineSegment]) -> some View {
        ZStack(alignment: .leading) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                let geometry = segmentGeometry(
                    segment,
                    index: index,
                    width: width,
                    segmentCount: segments.count
                )

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(isActive(segment) ? 0.22 : 0.12))
                    .frame(width: geometry.width, height: 8)
                    .offset(x: geometry.x)

                if geometry.filledWidth > 0 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: geometry.filledWidth, height: 8)
                        .offset(x: geometry.x)
                }
            }
        }
    }

    private func chapterPopover(
        time: Double,
        width: CGFloat,
        segments: [ChapterTimelineSegment]
    ) -> some View {
        let title = segment(at: time, in: segments)?.title ?? "Video"
        let estimatedTitleWidth = CGFloat(title.count) * 6.6 + 28
        let popoverWidth = min(max(1, width), min(420, max(150, estimatedTitleWidth)))
        let halfWidth = popoverWidth / 2
        let anchor = xPosition(for: time, width: width)
        let popoverOrigin = min(max(0, anchor - halfWidth), max(0, width - popoverWidth))
        let pointerLimit = max(0, halfWidth - 14)
        let pointerOffset = min(
            max(anchor - popoverOrigin - halfWidth, -pointerLimit),
            pointerLimit
        )

        return VStack(spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .lineSpacing(1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                .foregroundStyle(.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .frame(width: popoverWidth, alignment: .leading)
                .watchGlass(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                }
                .shadow(color: .black.opacity(0.16), radius: 7, y: 2)

            Capsule()
                .fill(Color.accentColor.opacity(0.85))
                .frame(width: 2, height: 6)
                .offset(x: pointerOffset)
        }
        .frame(width: popoverWidth)
        .offset(x: popoverOrigin)
        .fixedSize(horizontal: false, vertical: true)
        .alignmentGuide(.top) { dimensions in
            dimensions[.bottom] - 27
        }
        .allowsHitTesting(false)
    }

    private var segments: [ChapterTimelineSegment] {
        guard duration > 0 else { return [] }
        let sorted = chapters
            .filter {
                $0.startTime.isFinite
                    && $0.startTime >= 0
                    && $0.startTime < duration
                    && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.startTime < $1.startTime }

        var unique: [VideoChapter] = []
        for chapter in sorted where unique.last.map({ abs($0.startTime - chapter.startTime) > 0.01 }) ?? true {
            unique.append(chapter)
        }
        guard !unique.isEmpty else {
            return [ChapterTimelineSegment(startTime: 0, endTime: duration, title: "Video")]
        }

        var result: [ChapterTimelineSegment] = []
        if let first = unique.first, first.startTime > 0.01 {
            result.append(ChapterTimelineSegment(startTime: 0, endTime: first.startTime, title: "Video"))
        }
        for index in unique.indices {
            let start = unique[index].startTime
            let end = index + 1 < unique.count ? unique[index + 1].startTime : duration
            guard end > start else { continue }
            result.append(ChapterTimelineSegment(startTime: start, endTime: end, title: unique[index].title))
        }
        return result
    }

    private var hasChapterTitles: Bool {
        chapters.contains {
            $0.startTime.isFinite
                && $0.startTime >= 0
                && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func segment(
        at time: Double,
        in segments: [ChapterTimelineSegment]
    ) -> ChapterTimelineSegment? {
        segments.last { time >= $0.startTime && time < $0.endTime } ?? segments.last
    }

    private func segmentGeometry(
        _ segment: ChapterTimelineSegment,
        index: Int,
        width: CGFloat,
        segmentCount: Int
    ) -> (x: CGFloat, width: CGFloat, filledWidth: CGFloat) {
        let gap: CGFloat = segmentCount > 1 ? 5 : 0
        let rawStart = xPosition(for: segment.startTime, width: width)
        let rawEnd = xPosition(for: segment.endTime, width: width)
        let leadingGap = index == 0 ? 0 : gap / 2
        let trailingGap = index == segmentCount - 1 ? 0 : gap / 2
        let x = rawStart + leadingGap
        let segmentWidth = max(1, rawEnd - rawStart - leadingGap - trailingGap)
        let filledEnd = xPosition(for: min(max(value, segment.startTime), segment.endTime), width: width)
        let filledWidth = min(segmentWidth, max(0, filledEnd - x))
        return (x, segmentWidth, filledWidth)
    }

    private func xPosition(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return width * CGFloat(min(max(0, time / duration), 1))
    }

    private func thumbPosition(for time: Double, width: CGFloat) -> CGFloat {
        min(max(6.5, xPosition(for: time, width: width)), max(6.5, width - 6.5))
    }

    private func isActive(_ segment: ChapterTimelineSegment) -> Bool {
        value >= segment.startTime && value < segment.endTime
    }

    private func time(for x: CGFloat, width: CGFloat) -> Double {
        guard duration > 0, width > 0 else { return 0 }
        return duration * Double(min(max(0, x / width), 1))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }
}

private struct PlayerControlButton: View {
    let systemImage: String
    let help: String
    var isPrimary = false
    var isEnabled = true
    var isSelected = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isPrimary ? Color.white : (isSelected ? Color.accentColor : Color.primary))
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(buttonBackground)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.34)
        .scaleEffect(isHovering && isEnabled ? 1.04 : 1)
        .animation(.easeOut(duration: 0.13), value: isHovering)
        .onHover { isHovering = $0 }
        .help(help)
    }

    private var buttonBackground: Color {
        if isPrimary { return .accentColor }
        if isSelected { return Color.accentColor.opacity(0.16) }
        return Color.primary.opacity(isHovering && isEnabled ? 0.1 : 0)
    }
}

private struct ChapterSidebar: View {
    let chapters: [VideoChapter]
    let currentTime: Double
    let isPresented: Bool
    let toggle: () -> Void
    let select: (VideoChapter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label("Chapters", systemImage: "list.bullet.rectangle")
                    .font(.headline.weight(.semibold))
                Text("\(chapters.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                Spacer(minLength: 8)
                if isPresented {
                    TitlebarInteractiveHost {
                        Button(action: toggle) {
                            Image(systemName: "sidebar.trailing")
                        }
                        .watchGlassButton()
                        .help("Hide chapters")
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 56)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(chapters) { chapter in
                        Button {
                            select(chapter)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(formatTime(chapter.startTime))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(isCurrent(chapter) ? Color.accentColor : Color.secondary)
                                    .frame(width: 48, alignment: .trailing)
                                Text(chapter.title)
                                    .font(.callout.weight(isCurrent(chapter) ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .background {
                                if isCurrent(chapter) {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.13))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
        .background(.ultraThinMaterial)
    }

    private func isCurrent(_ chapter: VideoChapter) -> Bool {
        guard currentTime >= chapter.startTime else { return false }
        if let endTime = chapter.endTime { return currentTime < endTime }
        guard let index = chapters.firstIndex(of: chapter), index + 1 < chapters.count else { return true }
        return currentTime < chapters[index + 1].startTime
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }
}

private struct DropAndAddBar: View {
    @Binding var urlText: String
    @Binding var isDropTarget: Bool
    var isURLFieldFocused: FocusState<Bool>.Binding
    let submit: () -> Void
    let receiveProviders: ([NSItemProvider]) -> Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDropTarget ? Color.accentColor : Color.secondary)
            TextField("Paste a URL or text", text: $urlText)
                .textFieldStyle(.plain)
                .frame(minWidth: 0, maxWidth: .infinity)
                .focused(isURLFieldFocused)
                .onSubmit(submit)
                .onExitCommand(perform: removeFocus)
            Button(action: submit) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
            }
            .watchGlassButton(prominent: true)
            .controlSize(.small)
            .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
        .watchGlass(
            .clear,
            tint: isDropTarget ? Color.accentColor.opacity(0.12) : nil,
            interactive: true,
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(isDropTarget ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.07))
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: URLBarFramePreferenceKey.self,
                    value: geometry.frame(in: .named("rewatch-window"))
                )
            }
        }
        .onDrop(of: [UTType.url, UTType.fileURL, UTType.plainText], isTargeted: $isDropTarget, perform: receiveProviders)
    }

    private func removeFocus() {
        isURLFieldFocused.wrappedValue = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

private struct EmptyLibraryView: View {
    @Binding var isDropTarget: Bool
    let receiveProviders: ([NSItemProvider]) -> Bool

    var body: some View {
        ZStack {
            DetailBackdrop(thumbnailURL: nil)

            VStack(spacing: 14) {
                Image(systemName: isDropTarget ? "arrow.down" : "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isDropTarget ? Color.white : Color.accentColor)
                    .frame(width: 70, height: 70)
                    .watchGlass(
                        .regular,
                        tint: isDropTarget ? Color.accentColor : Color.accentColor.opacity(0.08),
                        in: Circle()
                    )
                Text(isDropTarget ? "Drop to save for later" : "Ready when you are")
                    .font(.title2.weight(.semibold))
                Text("Copy a video link and press ⌘V. Rewatch downloads a clean offline copy and remembers your place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .padding(36)
            .watchGlass(.clear, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .onDrop(of: [UTType.url, UTType.fileURL, UTType.plainText], isTargeted: $isDropTarget, perform: receiveProviders)
    }
}
