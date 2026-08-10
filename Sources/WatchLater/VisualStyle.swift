import AppKit
import SwiftUI

enum WatchGlassStyle {
    case regular
    case clear
}

extension View {
    func watchGlass<S: Shape>(
        _ style: WatchGlassStyle = .regular,
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        modifier(WatchGlassModifier(style: style, tint: tint, interactive: interactive, shape: shape))
    }

    func watchGlassButton(prominent: Bool = false) -> some View {
        modifier(WatchGlassButtonModifier(prominent: prominent))
    }
}

private struct WatchGlassModifier<S: Shape>: ViewModifier {
    let style: WatchGlassStyle
    let tint: Color?
    let interactive: Bool
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = style == .clear ? .clear : .regular
            content.glassEffect(glass.tint(tint).interactive(interactive), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

private struct WatchGlassButtonModifier: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

struct WatchGlassContainer<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

struct WindowStyleConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false
        window.styleMask.insert(.fullSizeContentView)
        // The center-pane actions live inside the full-size title-bar region.
        // Treating all SwiftUI content as draggable background lets AppKit
        // consume their mouse-down events before Button and Menu receive them.
        // The standard title bar remains available for moving the window.
        window.isMovableByWindowBackground = false
        let minimumSize = NSSize(width: 980, height: 640)
        window.minSize = minimumSize

        // AppKit does not automatically enlarge a restored window that was
        // saved before a newer minimum size was introduced. Such a window can
        // squeeze NavigationSplitView below its column minimum and center its
        // overflowing content underneath the traffic lights. Repair that
        // legacy frame once it is attached, preserving the window's top edge.
        if window.frame.width < minimumSize.width || window.frame.height < minimumSize.height {
            var frame = window.frame
            let repairedHeight = max(frame.height, minimumSize.height)
            frame.origin.y -= repairedHeight - frame.height
            frame.size.width = max(frame.width, minimumSize.width)
            frame.size.height = repairedHeight
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

/// Reports the real NSWindow width. A GeometryReader attached to a
/// NavigationSplitView can inherit a column's proposed size during its own
/// visibility transition, which makes it an unreliable source for deciding
/// whether two side panes fit.
struct WindowWidthReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> WindowWidthTrackingView {
        let view = WindowWidthTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WindowWidthTrackingView, context: Context) {
        view.onChange = onChange
        view.reportWidth()
    }
}

final class WindowWidthTrackingView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private var resizeObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.reportWidth()
        }
        reportWidth()
    }

    func reportWidth() {
        guard let width = window?.frame.width else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(width)
        }
    }

    private func stopObserving() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        resizeObserver = nil
    }

    deinit {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
    }
}

/// SwiftUI can draw into a full-size title bar while AppKit's toolbar remains
/// above it in the window hierarchy. This host preserves SwiftUI's layout with
/// an invisible marker, then constrains the interactive content directly to
/// that marker above the toolbar so it follows pane and window layout changes.
private final class TitlebarHostingView<Content: View>: NSHostingView<Content> {
    // NSThemeFrame advertises the native title-bar safe area to descendants.
    // This detached overlay already lives inside that area, so inheriting it
    // would add 52 points to its fitting height and clip the real controls.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}

struct TitlebarInteractiveHost<Content: View>: NSViewRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    func makeNSView(context: Context) -> TitlebarInteractiveMarkerView {
        let marker = TitlebarInteractiveMarkerView()
        context.coordinator.attach(to: marker)
        return marker
    }

    func updateNSView(_ marker: TitlebarInteractiveMarkerView, context: Context) {
        context.coordinator.update(content: content)
    }

    static func dismantleNSView(
        _ marker: TitlebarInteractiveMarkerView,
        coordinator: Coordinator
    ) {
        coordinator.detach()
    }

    final class Coordinator {
        private let hostingView: TitlebarHostingView<AnyView>
        private weak var marker: TitlebarInteractiveMarkerView?
        private weak var observedWindow: NSWindow?
        private var windowResizeObserver: NSObjectProtocol?
        private var layoutObservers: [NSObjectProtocol] = []

        init(content: Content) {
            hostingView = TitlebarHostingView(rootView: Self.hosted(content))
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        func attach(to marker: TitlebarInteractiveMarkerView) {
            self.marker = marker
            marker.intrinsicSizeProvider = { [weak self] in
                self?.hostingView.fittingSize ?? .zero
            }
            marker.windowHandler = { [weak self] in
                self?.installHostingView()
            }
            marker.layoutHandler = { [weak self] in
                self?.scheduleOverlayFrameUpdate()
            }
            marker.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak self] in
                self?.installHostingView()
            }
        }

        func update(content: Content) {
            hostingView.rootView = Self.hosted(content)
            hostingView.invalidateIntrinsicContentSize()
            marker?.invalidateIntrinsicContentSize()
            scheduleOverlayFrameUpdate()
        }

        func detach() {
            marker?.windowHandler = nil
            marker?.intrinsicSizeProvider = nil
            marker?.layoutHandler = nil
            stopObservingWindow()
            hostingView.removeFromSuperview()
            marker = nil
        }

        private func installHostingView() {
            guard let marker,
                  let window = marker.window,
                  let windowFrameView = window.contentView?.superview else {
                stopObservingWindow()
                hostingView.removeFromSuperview()
                return
            }

            if hostingView.superview !== windowFrameView {
                hostingView.removeFromSuperview()
                windowFrameView.addSubview(hostingView, positioned: .above, relativeTo: nil)
                hostingView.translatesAutoresizingMaskIntoConstraints = true
                hostingView.invalidateIntrinsicContentSize()
                marker.invalidateIntrinsicContentSize()
            }
            observeWindowIfNeeded(window)
            observeLayoutChain(from: marker, through: windowFrameView)
            updateOverlayFrame()
            scheduleOverlayFrameUpdatesThroughAnimation()
        }

        private func observeWindowIfNeeded(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            stopObservingWindow()
            observedWindow = window
            windowResizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleOverlayFrameUpdate()
            }
        }

        private func stopObservingWindow() {
            if let windowResizeObserver {
                NotificationCenter.default.removeObserver(windowResizeObserver)
            }
            windowResizeObserver = nil
            observedWindow = nil
            stopObservingLayoutChain()
        }

        private func observeLayoutChain(from marker: NSView, through windowFrameView: NSView) {
            stopObservingLayoutChain()

            var view: NSView? = marker
            while let current = view {
                current.postsFrameChangedNotifications = true
                current.postsBoundsChangedNotifications = true

                for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                    layoutObservers.append(
                        NotificationCenter.default.addObserver(
                            forName: name,
                            object: current,
                            queue: .main
                        ) { [weak self] _ in
                            self?.scheduleOverlayFrameUpdate()
                        }
                    )
                }

                if current === windowFrameView { break }
                view = current.superview
            }
        }

        private func stopObservingLayoutChain() {
            for observer in layoutObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            layoutObservers.removeAll()
        }

        private func scheduleOverlayFrameUpdate() {
            DispatchQueue.main.async { [weak self] in
                self?.updateOverlayFrame()
            }
        }

        /// Split-view visibility transitions can move an entire ancestor chain
        /// without resizing the window or relaying out the marker itself. Keep
        /// the overlay attached throughout the short system animation, with a
        /// final pass after it settles to avoid retaining an intermediate frame.
        private func scheduleOverlayFrameUpdatesThroughAnimation() {
            for delay in [0.0, 0.05, 0.12, 0.22, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.updateOverlayFrame()
                }
            }
        }

        private func updateOverlayFrame() {
            guard let marker,
                  let window = marker.window,
                  let windowFrameView = window.contentView?.superview,
                  hostingView.superview === windowFrameView else { return }
            let markerAnchorFrame = marker.convert(marker.bounds, to: windowFrameView)
            let fittingSize = hostingView.fittingSize
            guard fittingSize.width > 0, fittingSize.height > 0 else { return }
            var markerFrame = NSRect(
                x: markerAnchorFrame.maxX - fittingSize.width,
                y: markerAnchorFrame.minY,
                width: fittingSize.width,
                height: fittingSize.height
            )
            // Every pane uses the same 56-point title row. Anchor the hosted
            // control to the visible NSWindow frame instead of compensating
            // for marker safe areas or NSThemeFrame bounds, both of which can
            // change across window states. Horizontal placement remains
            // entirely marker-driven.
            let titleRowHeight: CGFloat = 56
            let verticalInset = (titleRowHeight - markerFrame.height) / 2
            let controlBottomOnScreen = window.frame.maxY - verticalInset - markerFrame.height
            let controlBottomInWindow = window.convertPoint(
                fromScreen: NSPoint(x: window.frame.minX, y: controlBottomOnScreen)
            )
            markerFrame.origin.y = windowFrameView.convert(controlBottomInWindow, from: nil).y
            guard hostingView.frame != markerFrame else { return }
            hostingView.frame = markerFrame
        }

        private static func hosted(_ content: Content) -> AnyView {
            AnyView(
                // This host also supplies the marker's intrinsic size. Asking
                // for infinite space here creates a feedback loop with the
                // split view during live window resizing: the title-bar item
                // remembers the old pane width and prevents the detail pane
                // from shrinking. Title-bar controls are intrinsically sized,
                // so keep the bridge at that compact size and let the live
                // marker frame position it.
                content.fixedSize()
            )
        }
    }
}

final class TitlebarInteractiveMarkerView: NSView {
    var intrinsicSizeProvider: (() -> NSSize)?
    var windowHandler: (() -> Void)?
    var layoutHandler: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        intrinsicSizeProvider?() ?? .zero
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.windowHandler?()
        }
    }

    override func layout() {
        super.layout()
        layoutHandler?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
enum ThumbnailImageCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
