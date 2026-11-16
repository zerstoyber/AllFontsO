import FontsoCore
import SwiftUI

@main
enum FontsoEntry {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--mcp") {
            MCPStdioBridge.run()
        }
        FontsoApp.main()
    }
}

struct FontsoApp: App {
    @State private var store = LibraryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .chromeDefaults()
                .frame(minWidth: 1100, minHeight: 680)
        }
        // The title bar folds into the first column bar; see TitleBarIntegration.
        .windowStyle(.hiddenTitleBar)
        .commands {
            FontsoCommands(store: store)
        }
        .defaultSize(width: 1280, height: 800)
        // Its own window, so the library stays in view while families are checked.
        Window("Review", id: "review") {
            ReviewView()
                .environment(store)
                .chromeDefaults()
        }
        .defaultSize(width: 760, height: 640)
        .defaultPosition(.center)
        // Preview, Compare, Shape, or Use in a window of its own, beside the main one. One window per mode.
        WindowGroup("Mode", id: "workspace", for: WorkspaceWindow.self) { $window in
            DetachedWorkspace(window: window ?? WorkspaceWindow(tab: .preview, source: LibraryFilter.all.key))
                .environment(store)
                .chromeDefaults()
                .frame(minWidth: 520, minHeight: 420)
        }
        .defaultSize(width: 960, height: 720)
        .commandsRemoved()
        // Info beside the main window. While it is open, the panel under the navigation steps aside.
        Window("Info", id: "info") {
            InfoWindow()
                .environment(store)
                .chromeDefaults()
                .frame(minWidth: 280, minHeight: 320)
        }
        .defaultSize(width: 340, height: 640)
        .commandsRemoved()
    }
}

/// Info for the selected font, in a window of its own. It shows the same sections as the panel under the navigation.
struct InfoWindow: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        SpecimenView(role: .info, infoFillsWindow: true)
            .padding(AppChrome.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppChrome.window)
            .navigationTitle("AllFontsO · Info")
            .onAppear { store.infoWindowOpen = true }
            .onDisappear { store.infoWindowOpen = false }
            .background(WindowCloseWatch { store.infoWindowOpen = false })
    }
}

/// One mode of the workspace as its own window: the same pane as in the main window, held to that mode. It
/// works on the same library, pinned fonts, sample text, and settings. A Preview window keeps the list or view
/// it was opened with. While the window is open, its mode has no tab in the main window; Preview always has.
struct DetachedWorkspace: View {
    var window: WorkspaceWindow
    @Environment(LibraryStore.self) private var store
    /// This window's sample sizes: those of the main window until its chain is opened.
    @State private var sizes: SampleSizes

    init(window: WorkspaceWindow) {
        self.window = window
        _sizes = State(initialValue: SampleSizes(window: window))
    }

    private var title: String {
        guard window.tab == .preview, let source = window.filter else { return window.tab.title }
        return "\(store.title(of: source)) · Preview"
    }

    var body: some View {
        SpecimenView(fixedTab: window.tab, fixedSource: window.tab == .preview ? (window.filter ?? .all) : nil)
            .environment(\.barLeadingInset, 0)
            .environment(\.sampleSizes, sizes)
            .modifier(WorkspacePaper())
            .padding(.horizontal, AppChrome.inset)
            .padding(.bottom, AppChrome.inset)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppChrome.window)
            .navigationTitle("AllFontsO · \(title)")
            .onAppear { store.windowOpened(window) }
            .onDisappear { store.windowClosed(window) }
            .background(WindowCloseWatch { store.windowClosed(window) })
            .background(DeleteKeyCatcher {
                guard window.tab == .preview, case .group(let id) = window.filter else { return false }
                return store.handleDeleteKey(inList: id)
            })
    }
}

/// Tells when the window a view sits in closes, so its mode goes back into the tabs of the main window.
private struct WindowCloseWatch: NSViewRepresentable {
    var onClose: () -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.onClose = onClose
    }

    final class Probe: NSView {
        var onClose: (() -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose?() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
