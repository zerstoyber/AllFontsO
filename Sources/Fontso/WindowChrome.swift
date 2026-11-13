import AppKit
import SwiftUI

/// What the window looks like right now, for views that make room for the traffic lights.
@MainActor
final class WindowChrome: ObservableObject {
    @Published var fullScreen = false

    /// Horizontal room the close, minimise, and zoom buttons take at the left edge of the window.
    static let trafficLightWidth: CGFloat = 70

    /// Room to leave at the left of the leftmost column bar.
    var leadingInset: CGFloat { fullScreen ? 0 : WindowChrome.trafficLightWidth }
}

private struct BarLeadingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Extra space before the first control in a column bar, where the window buttons sit.
    var barLeadingInset: CGFloat {
        get { self[BarLeadingInsetKey.self] }
        set { self[BarLeadingInsetKey.self] = newValue }
    }
}

/// Folds the window's title bar into the app: the title bar turns transparent, the content runs up to the top edge,
/// and the three window buttons move down into the first column bar, centred on its height.
struct TitleBarIntegration: NSViewRepresentable {
    @ObservedObject var chrome: WindowChrome

    func makeNSView(context: Context) -> NSView {
        let view = HookView()
        view.onWindow = { window in context.coordinator.attach(window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(chrome: chrome) }

    private final class HookView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    @MainActor
    final class Coordinator {
        private let chrome: WindowChrome
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(chrome: WindowChrome) {
            self.chrome = chrome
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = AppChrome.windowNS
            window.isOpaque = true
            chrome.fullScreen = window.styleMask.contains(.fullScreen)
            let center = NotificationCenter.default
            let relayout: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeMainNotification,
            ]
            for name in relayout {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutButtons() }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.chrome.fullScreen = true }
            })
            observers.append(center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.chrome.fullScreen = false }
            })
            layoutButtons()
            DispatchQueue.main.async { [weak self] in self?.layoutButtons() }
        }

        /// Moves the title bar container down to the height of the column bar and centres the buttons in it.
        private func layoutButtons() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview,
                  let container = titlebar.superview,
                  let frameView = container.superview else { return }
            let barHeight = AppChrome.titleBarHeight
            var frame = container.frame
            frame.size.height = barHeight
            frame.origin.y = frameView.bounds.height - barHeight
            if container.frame != frame { container.frame = frame }
            if titlebar.frame.height != barHeight {
                var inner = titlebar.frame
                inner.origin.y = 0
                inner.size.height = barHeight
                titlebar.frame = inner
            }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            let spacing: CGFloat = 20
            for (index, button) in buttons.enumerated() {
                let size = button.frame.size
                let origin = CGPoint(x: 12 + CGFloat(index) * spacing, y: (barHeight - size.height) / 2)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}

/// An empty area in a column bar that drags the window, the way the title bar used to.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
