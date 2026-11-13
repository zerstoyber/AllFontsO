import AppKit
import CoreText
import FontsoCore
import SwiftUI
import WebKit

struct FoundryPageView: View {
    var url: URL
    /// The page's state for a view around it, which then knows the page reached by clicking and can go back.
    var shared: Binding<FoundryPageStatus>? = nil
    @State private var own = FoundryPageStatus()

    var body: some View {
        let binding = shared ?? $own
        let status = binding.wrappedValue
        VStack(spacing: 0) {
            FoundryWebView(url: url, status: binding)
            if status.failure != nil || status.loading {
                HStack(spacing: 8) {
                    if status.loading {
                        ProgressView().controlSize(.small)
                        Text("Loading \(url.host ?? "the page")…")
                    } else if let failure = status.failure {
                        Text(failure)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button("Reload") { binding.wrappedValue.reloadToken += 1 }
                        .buttonStyle(.paper)
                        .help("Load the page again")
                    Button("Open in browser") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.paper)
                        .help("Open the page in your browser")
                }
                .font(.uiCaption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }
}

struct FoundryPageStatus: Equatable {
    var loading = false
    var failure: String?
    var reloadToken = 0
    /// The page shown now: the one opened, or one reached by clicking around in it.
    var current: URL?
    var canGoBack = false
    var backToken = 0

    /// The page reached by clicking around, when it is another one than `page`. Http and https, www, and a slash
    /// at the end make no other page.
    func reached(from page: URL) -> URL? {
        guard let current, current.scheme?.hasPrefix("http") == true else { return nil }
        func key(_ url: URL) -> String {
            var host = url.host?.lowercased() ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            var path = url.path
            while path.hasSuffix("/") { path.removeLast() }
            return host + path + "?" + (url.query ?? "")
        }
        return key(current) == key(page) ? nil : current
    }
}

private struct FoundryWebView: NSViewRepresentable {
    var url: URL
    @Binding var status: FoundryPageStatus

    func makeCoordinator() -> Coordinator {
        Coordinator(status: $status)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "Version/17.4 Safari/605.1.15"
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        let coordinator = context.coordinator
        coordinator.watching = [
            view.observe(\.url) { [weak coordinator] view, _ in coordinator?.moved(view) },
            view.observe(\.canGoBack) { [weak coordinator] view, _ in coordinator?.moved(view) }
        ]
        load(url, in: view, coordinator: coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.status = $status
        if context.coordinator.reloadToken != status.reloadToken {
            context.coordinator.reloadToken = status.reloadToken
            load(url, in: view, coordinator: context.coordinator)
            return
        }
        if context.coordinator.backToken != status.backToken {
            context.coordinator.backToken = status.backToken
            view.goBack()
            return
        }
        guard context.coordinator.loaded != url else { return }
        // The page reached by clicking was made the link: it is on show already.
        if let shown = view.url, FoundryPageStatus(current: shown).reached(from: url) == nil {
            context.coordinator.loaded = url
            return
        }
        load(url, in: view, coordinator: context.coordinator)
    }

    private func load(_ url: URL, in view: WKWebView, coordinator: Coordinator) {
        coordinator.loaded = url
        // Over https first: macOS refuses plain http outside a web page, and nearly every foundry answers there.
        let secure = FoundryLookup.secure(url)
        coordinator.fallback = secure == url ? nil : url
        var request = URLRequest(url: secure, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        view.load(request)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loaded: URL?
        var reloadToken = 0
        var backToken = 0
        /// The address as the foundry gave it, over http, for the few sites that have no https.
        var fallback: URL?
        var watching: [NSKeyValueObservation] = []
        var status: Binding<FoundryPageStatus>

        init(status: Binding<FoundryPageStatus>) {
            self.status = status
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            update { $0.loading = true; $0.failure = nil }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            update { $0.loading = false }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if let plain = fallback, (error as NSError).code != NSURLErrorCancelled {
                fallback = nil
                webView.load(URLRequest(url: plain, timeoutInterval: 30))
                return
            }
            report(error)
        }

        /// The page changed, by a link or by the site itself, or there is now a page to go back to.
        func moved(_ webView: WKWebView) {
            let url = webView.url
            let back = webView.canGoBack
            update { $0.current = url; $0.canGoBack = back }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            update { $0.loading = false; $0.failure = "The page stopped. Reload to try again." }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        private func report(_ error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            let text = error.localizedDescription
            update { $0.loading = false; $0.failure = text }
        }

        private func update(_ change: @escaping (inout FoundryPageStatus) -> Void) {
            DispatchQueue.main.async {
                var next = self.status.wrappedValue
                change(&next)
                if next != self.status.wrappedValue {
                    self.status.wrappedValue = next
                }
            }
        }
    }
}

struct SpecimenView: View {
    /// The workspace on the right, or the Info panel under the navigation. Info reuses the sections and their
    /// state handling here, set on the chrome instead of the paper.
    enum Role {
        case workspace
        case info
    }

    var role = Role.workspace
    /// The most room Info may take, so the navigation above keeps its share.
    var infoLimit: CGFloat = 600
    @Environment(LibraryStore.self) private var store
    @AppStorage("fontso.sampleText") private var specimenText = SpecimenText.standard
    @AppStorage("fontso.specimenSize") private var specimenSize = 48.0
    @AppStorage("fontso.specimen.unit") private var unitRaw = SpecimenUnit.point.rawValue
    @AppStorage("fontso.specimen.tracking") private var tracking = 0.0
    @AppStorage("fontso.specimen.leading") private var leading = 1.2
    @ObservedObject private var theme = PaperSettings.shared
    @State private var editorHeights: [Int64: CGFloat] = [:]
    @State private var activeSourcePath = ""
    @AppStorage("fontso.info.metadata") private var metadataOpen = true
    @AppStorage("fontso.info.activation") private var infoOpen = true
    @AppStorage("fontso.info.lists") private var listsOpen = false
    @State private var fileWholeFamily = true
    @AppStorage("fontso.info.notes") private var notesOpen = false
    @AppStorage("fontso.info.license") private var licenseOpen = false
    @State private var licenseWholeFamily = false
    @State private var licenseDraft = ""
    @AppStorage("fontso.info.characters") private var charactersOpen = false
    @AppStorage("fontso.info.features") private var featuresOpen = false
    @State private var glyphScalars: [UnicodeScalar] = []
    @State private var glyphTotal = 0
    @State private var glyphsLoaded = false
    @State private var copiedCode = ""
    @AppStorage("fontso.inspectorOpen") private var inspectorOpen = true
    @AppStorage("fontso.infoHeight") private var infoHeight = 340.0
    @State private var infoDragStart: Double?
    @State private var colorsOpen = false
    /// Families whose cuts are folded open (or, when a single family fills the preview, folded shut).
    @State private var toggledFamilies: Set<String> = []
    @State private var characterQuery = ""
    @State private var typedQuery = ""
    @State private var editingOutside: OutsideFont?
    @State private var addingLink = false
    @State private var inspectorHeight: CGFloat = 220
    @State private var referenceID: Int64?
    @State private var alignShifts: [Int64: CGFloat] = [:]
    @State private var alignSnap: AlignSnap?
    @State private var alignCanvasHeight: CGFloat = 240
    @State private var overlayColorHex: [Int64: String] = [:]
    @State private var previewOrder: [Int64] = []

    /// Pure RGB colours, so overlapping outlines read as plain mixes. Slightly translucent so both fonts stay visible where they cross.
    private let overlayPalette: [(name: String, color: NSColor)] = [
        ("Blue", NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.8)),
        ("Green", NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.8)),
        ("Yellow", NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 0.8)),
        ("Red", NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.8)),
        ("Magenta", NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 0.8)),
        ("Cyan", NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 0.8)),
        ("Black", NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.8)),
        ("White", NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
    ]
    @State private var overlayColorFor: Int64?
    /// The pinned fonts large across the dock. Preview and Playground share the choice.
    @AppStorage("fontso.pinned.large.dock") private var dockPinnedLarge = false

    private let previewLimit = 24

    /// Feature switches moved away from the font's defaults. Kept in the store, so the switches in Info reach the preview.
    private var featureOverrides: [String: Bool] {
        get { store.featureOverrides }
        nonmutating set { store.featureOverrides = newValue }
    }

    var body: some View {
        if role == .info {
            infoPanel
        } else {
            workspaceBody
        }
    }

    @ViewBuilder
    private var workspaceBody: some View {
        let source = store.previewFaces
        let working = store.workingFaces
        let faces = store.workspaceTab == .preview ? source : working
        VStack(spacing: 0) {
            previewColumnBar(faces)
            if store.workspaceTab == .shape {
                ShapeView()
            } else if store.workspaceTab == .playground {
                PlaygroundView()
                    .paperColors(ink: ink, paper: Color(nsColor: paper))
            } else if store.workspaceTab == .compare {
                compareWorkspace(working)
                    .paperColors(ink: ink, paper: Color(nsColor: paper))
            } else if faces.isEmpty, store.isViewingList,
                      !store.previewListLinks.isEmpty || (store.outsideSelection.isEmpty && !store.narrowsView) {
                // A list without library fonts: only links to fonts outside the library, or nothing yet.
                ColumnScroll {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.previewListLinks.isEmpty {
                            Text("This list is empty. Drag fonts from the navigation or the preview onto the list to fill it.")
                                .font(AppChrome.type())
                                .foregroundStyle(tone.half)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 2)
                                .padding(.bottom, 8)
                        } else if store.narrowsView {
                            narrowedNotice
                        }
                        listLinkStack(store.previewListLinks)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 9)
                    .padding(.vertical, 12)
                }
                .paperColors(ink: ink, paper: Color(nsColor: paper))
            } else if faces.isEmpty, store.outsideSelection.isEmpty, store.narrowsView {
                narrowedEmpty
            } else if faces.isEmpty && store.outsideSelection.isEmpty {
                ContentUnavailableView {
                    Text(store.isViewingList ? "This list is empty" : "No fonts here")
                } description: {
                    Text(store.isViewingList
                        ? "Drag fonts from the navigation or the preview onto the list to fill it."
                        : "Click a list or a library view in the navigation to stack its fonts here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if faces.isEmpty && store.outsideSelection.count == 1, let item = store.outsideSelection.first {
                outsideFocus(item)
                    .paperColors(ink: ink, paper: Color(nsColor: paper))
            } else if faces.isEmpty {
                ColumnScroll {
                    outsideStack
                        .padding(16)
                }
                .paperColors(ink: ink, paper: Color(nsColor: paper))
            } else {
                specimen(faces)
                    .paperColors(ink: ink, paper: Color(nsColor: paper))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: store.pinnedIdentities) { _, _ in
            reconcilePreviewOrder(store.workingFaces.map(\.id))
        }
        .onAppear {
            typedQuery = store.query
        }
        .sheet(item: $editingOutside) { item in
            OutsideFontForm(editing: item) { name, source, url in
                store.updateOutsideItem(item, name: name, source: source, url: url)
            }
        }
    }

    /// The same, as one line above the fonts from the news, which no filter hides.
    private var narrowedNotice: some View {
        let names = store.activeFilterNames
        return HStack(spacing: 8) {
            Text(names.isEmpty
                ? "No library font of this list matches the search."
                : "The filter (\(names.joined(separator: ", "))) hides the library fonts of this list.")
                .font(AppChrome.small)
                .foregroundStyle(tone.half)
                .lineLimit(1)
            if !names.isEmpty {
                Button {
                    store.clearFilters()
                } label: {
                    Label("Reset filter", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.chip())
                .help("Switch every filter off")
            }
            Spacer(minLength: 0)
        }
    }

    /// The view has fonts, but the search or a filter holds all of them back. The way out is one click.
    private var narrowedEmpty: some View {
        let names = store.activeFilterNames
        let searching = !store.query.isEmpty
        return ContentUnavailableView {
            Text(names.isEmpty ? "No font matches the search" : "The filter hides every font here")
        } description: {
            VStack(spacing: 4) {
                if !names.isEmpty {
                    Text("Filter on: \(names.joined(separator: ", ")).")
                }
                if searching {
                    Text("Search: “\(store.query)”.")
                }
            }
        } actions: {
            HStack(spacing: 8) {
                if !names.isEmpty {
                    Button {
                        store.clearFilters()
                    } label: {
                        Label("Reset filter", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.chip())
                    .help("Switch every filter off and show all fonts of \(store.filterTitle)")
                }
                if searching {
                    Button {
                        typedQuery = ""
                        store.query = ""
                    } label: {
                        Label("Clear search", systemImage: "xmark")
                    }
                    .buttonStyle(.chip())
                    .help("Empty the search field")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var overlayOpen: Bool { store.workspaceTab == .compare && store.compareMode == .overlay }
    private var alignOpen: Bool { store.workspaceTab == .compare && store.compareMode == .align }

    /// Workspace tabs, then search, sort, and filter.
    private func previewColumnBar(_ faces: [FontFace]) -> some View {
        VStack(spacing: 0) {
            workspaceTabs(faces)
            // Search, sort, and filter belong to Preview, where they arrange the list on show.
            if store.workspaceTab == .preview {
                HStack(spacing: 8) {
                    searchField
                    sortMenu
                    filterMenu
                    if store.activeFilterCount > 0 {
                        IconChip(
                            symbol: "arrow.counterclockwise",
                            help: "Reset the filter (\(store.activeFilterNames.joined(separator: ", ")))"
                        ) {
                            store.clearFilters()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Rectangle()
                    .fill(tone.hairline)
                    .frame(height: 0.5)
            }
        }
    }

    // MARK: Compare

    /// Compare: the pinned fonts in a row at the top, as in Shape, then Align or Overlay with their settings, then
    /// the board. The pinned card that is clicked is the font the others line up to.
    private func compareWorkspace(_ faces: [FontFace]) -> some View {
        let shown = Array(faces.prefix(previewLimit))
        return VStack(spacing: 0) {
            PinnedBar(
                reference: referenceFace(shown),
                referenceTitle: "Lines up to",
                pickHelp: "Search the library and pin a font to compare",
                emptyNote: "Pin two or more fonts in Preview, or drag them here from the navigation. Align sets them side by side on one baseline, Overlay lays them over each other. The pinned font you click is the one the others line up to.",
                onChoose: { face in
                    referenceID = face.id
                    // A chosen snap follows the new reference.
                    if let alignSnap { snapAlign(shown, to: alignSnap) }
                },
                onPick: { face in store.addToPreview([face.identity]) },
                // In Overlay every pinned font carries its colour, so the board needs no second row of names.
                swatch: store.compareMode == .overlay && shown.count > 1
                    ? { face in
                        guard let index = shown.firstIndex(where: { $0.id == face.id }) else { return AnyView(EmptyView()) }
                        return AnyView(overlaySwatch(face, index: index))
                    }
                    : nil
            )
            Rectangle()
                .fill(tone.hairline)
                .frame(height: 0.5)
            SubNavigation(
                items: CompareMode.allCases.map { .init(title: $0.title, value: $0, help: $0.help) },
                selection: Bindable(store).compareMode
            )
            compareBar(shown)
                .settingsBar()
            if shown.count < 2 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(shown.isEmpty ? "Nothing pinned yet" : "One more font")
                        .font(AppChrome.type(12, weight: .medium))
                        .foregroundStyle(tone.ink)
                    Text(shown.isEmpty
                        ? "Compare works with the pinned fonts. Pin two in Preview, use Pin font above, or drag fonts here from the navigation."
                        : "Compare needs two pinned fonts. Pin another in Preview, use Pin font above, or drag one here from the navigation.")
                        .font(AppChrome.small)
                        .foregroundStyle(tone.half)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .dropDestination(for: FontDragItem.self) { items, _ in
                    store.addToPreview(items.flatMap(\.identities))
                }
            } else {
                specimen(faces)
            }
        }
    }

    /// The settings of Align and Overlay: the two snaps and the way back. A snap stays lit until a font is moved
    /// by hand. The fonts go to the Playground from the three dots beside the pinned fonts.
    private func compareBar(_ faces: [FontFace]) -> some View {
        HStack(spacing: 8) {
            ForEach(AlignSnap.allCases) { snap in
                Button(snap.title) {
                    if alignSnap == snap {
                        alignSnap = nil
                        alignShifts = [:]
                    } else {
                        snapAlign(faces, to: snap)
                    }
                }
                .buttonStyle(.chip(on: alignSnap == snap))
                .disabled(faces.count < 2)
                .help(alignSnap == snap
                    ? "The \(snap.title.lowercased())s meet the reference. Click to let go."
                    : "Shift the fonts so their \(snap.title.lowercased())s meet the reference")
            }
            IconChip(symbol: "arrow.counterclockwise", help: "Reset the alignment: every font back on the baseline") {
                alignSnap = nil
                alignShifts = [:]
            }
            .disabled(alignShifts.isEmpty)
            if faces.count > 1 {
                Text(store.compareMode == .align ? "Drag a font up or down." : "Click a pinned font, then drag it up or down. The dot on a pinned font sets its colour.")
                    .font(AppChrome.small)
                    .foregroundStyle(tone.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// What the fonts are shifted to meet.
    private enum AlignSnap: String, CaseIterable, Identifiable {
        case xHeight, capHeight
        var id: String { rawValue }

        var title: String {
            switch self {
            case .xHeight: return "X-height"
            case .capHeight: return "Cap height"
            }
        }
    }

    private func snapAlign(_ faces: [FontFace], to snap: AlignSnap) {
        switch snap {
        case .xHeight: snapAlign(faces, metric: CTFontGetXHeight)
        case .capHeight: snapAlign(faces, metric: CTFontGetCapHeight)
        }
        alignSnap = snap
    }

    /// The four tabs of the sketch: labels at the left of equal cells, hairlines between them, and a line under
    /// every tab except the open one, so the open tab runs into the content below.
    private func workspaceTabs(_ faces: [FontFace]) -> some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceTab.allCases) { tab in
                WorkspaceTabCell(title: tab.title, active: store.workspaceTab == tab, onFonts: { identities in
                    dropOnTab(tab, identities: identities)
                }) {
                    store.workspaceTab = tab
                }
                .help("\(tab.help). Drop a font here to use it in \(tab.title).")
            }
            HStack(spacing: 8) {
                if store.workspaceTab == .playground {
                    Button("Export") {
                        NotificationCenter.default.post(name: .fontsoPlaygroundExport, object: nil)
                    }
                    .buttonStyle(.chip())
                    .help("Export the playground as PDF or PNG: screen, A4, A3, or a custom page")
                }
                colorButton
            }
            .padding(.horizontal, 12)
            // A fixed field for the buttons, so the four tabs keep the same width in every mode.
            .frame(width: 148, height: 27, alignment: .trailing)
            .overlay(alignment: .bottom) {
                Rectangle().fill(tone.hairline).frame(height: 0.5)
            }
        }
    }

    /// A font dragged from the navigation onto a tab: pinned for Preview, Compare, and Shape, set as a new block in
    /// Playground. The tab opens, so the font is seen where it landed.
    private func dropOnTab(_ tab: WorkspaceTab, identities: [String]) -> Bool {
        let valid = identities.filter { store.hasFace(identity: $0) }
        guard !valid.isEmpty else { return false }
        if tab == .playground {
            store.addToPlayground(valid)
        } else {
            store.addToPreview(valid)
        }
        if tab != .preview {
            store.workspaceTab = tab
        }
        return true
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            TextField("Family, style, foundry", text: $typedQuery)
                .textFieldStyle(.plain)
                .font(AppChrome.type())
                .foregroundStyle(tone.ink)
                .onSubmit { store.query = typedQuery }
                .task(id: typedQuery) {
                    guard typedQuery != store.query else { return }
                    if typedQuery.isEmpty {
                        store.query = ""
                        return
                    }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if !Task.isCancelled, typedQuery != store.query {
                        store.query = typedQuery
                    }
                }
                .onChange(of: store.query) { _, query in
                    if query != typedQuery { typedQuery = query }
                }
            if !typedQuery.isEmpty {
                Button("Clear") {
                    typedQuery = ""
                    store.query = ""
                }
                .buttonStyle(.chip())
                .help("Clear the search")
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .background(tone.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help("Search the current list or library view")
    }


    private var sortMenu: some View {
        Menu {
            if store.isViewingList {
                Section("Order") {
                    sortChoice(.custom)
                    ForEach(LibrarySort.orderSection) { sortChoice($0) }
                }
            } else {
                Section("Order") {
                    ForEach(LibrarySort.orderSection) { sortChoice($0) }
                }
            }
            Section("Letterform") {
                ForEach(LibrarySort.letterformSection) { sortChoice($0) }
            }
            Section("File") {
                ForEach(LibrarySort.fileSection) { sortChoice($0) }
            }
            Section("Direction") {
                ForEach([true, false], id: \.self) { ascending in
                    Button {
                        store.sortAscending = ascending
                    } label: {
                        if store.sortAscending == ascending {
                            Label(store.sort.directionTitle(ascending: ascending), systemImage: "checkmark")
                        } else {
                            Text(store.sort.directionTitle(ascending: ascending))
                        }
                    }
                }
            }
        } label: {
            Text("Sort")
        }
        .chromeMenuChip()
        .help(store.sort.hint)
    }

    private func sortChoice(_ item: LibrarySort) -> some View {
        Button {
            store.sort = item
        } label: {
            if store.sort == item {
                Label(item.title, systemImage: "checkmark")
            } else {
                Text(item.title)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Toggle("Hide trials", isOn: Binding(get: { !store.showTrials }, set: { store.showTrials = !$0 }))
            Toggle("Only active", isOn: Bindable(store).onlyActive)
            Toggle("Only variable", isOn: Bindable(store).onlyVariable)
            Toggle("Only licensed", isOn: Bindable(store).onlyLicensed)
            Divider()
            Picker("Format", selection: Bindable(store).formatFilter) {
                ForEach(FormatFilter.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.inline)
            if store.activeFilterCount > 0 {
                Divider()
                Button("Clear filters") { store.clearFilters() }
            }
        } label: {
            Text(store.activeFilterCount > 0 ? "Filter · \(store.activeFilterCount)" : "Filter")
        }
        .chromeMenuChip()
        .help("Hide trials, keep only active, variable, licensed, or a format")
    }

    private func specimen(_ faces: [FontFace]) -> some View {
        ZStack(alignment: .bottom) {
            Group {
                if store.workspaceTab == .preview {
                    ScrollViewReader { scroll in
                        ScrollView {
                            previewStack(faces)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            Color.clear.frame(height: inspectorHeight + 28)
                        }
                        .onChange(of: store.focusPreviewID) { _, id in
                            guard let id else { return }
                            store.focusPreviewID = nil
                            let groups = clusters(faces)
                            guard let cluster = groups.first(where: { group in group.faces.contains { $0.id == id } }) else { return }
                            // A folded family shows one cut; open it when another of its cuts is asked for.
                            if cluster.faces.count > 1, !isOpen(cluster, alone: opensFamilies(groups)), leadFace(cluster.faces).id != id {
                                toggledFamilies.formSymmetricDifference([cluster.id])
                            }
                            scroll.scrollTo(cluster.id, anchor: .top)
                            DispatchQueue.main.async {
                                scroll.scrollTo(id, anchor: .top)
                            }
                        }
                        // A font from the news clicked in the navigation: its card stands under the library fonts.
                        .onChange(of: store.outsideSelection.first?.nameKey, initial: true) { _, id in
                            guard let id, store.previewListLinks.contains(where: { $0.nameKey == id }) else { return }
                            // First to the block of news fonts, which the lazy stack knows; then to the card itself.
                            DispatchQueue.main.async {
                                scroll.scrollTo("list-links", anchor: .top)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    scroll.scrollTo("link-\(id)", anchor: .top)
                                }
                            }
                        }
                    }
                } else {
                    ColumnScroll(
                        resetID: "\(store.filterTitle)-\(faces.map { String($0.id) }.joined(separator: ","))",
                        bottomInset: inspectorHeight + 28
                    ) {
                        previewStack(faces)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            Group {
                if inspectorOpen {
                    previewInspector(faces)
                } else {
                    DockPill(
                        title: store.workspaceTab == .preview ? "Text · Adjust · Pinned" : "Text · Adjust",
                        help: store.workspaceTab == .preview ? "Show sample text, size, and pinned fonts" : "Show sample text and size"
                    ) {
                        inspectorOpen = true
                    }
                }
            }
            .padding(.horizontal, AppChrome.dockInset)
            .padding(.bottom, 12)
            .reportOverlayHeight()
        }
        .onPreferenceChange(OverlayHeightKey.self) { inspectorHeight = $0 }
    }

    /// The dock of the sketch: Text, Adjust, and Pinned side by side on a blurred strip, with hairlines between.
    /// Each of the three folds to its title.
    private func previewInspector(_ faces: [FontFace]) -> some View {
        let face = faces[0]
        let sampleFace = store.selection.first.flatMap { store.face(id: $0) } ?? face
        return ChromeDock(
            hideHelp: store.workspaceTab == .preview ? "Hide Text, Adjust, and Pinned" : "Hide Text and Adjust",
            onHide: { inspectorOpen = false },
            // Large, the pinned fonts lie across the dock; small, they are one of its sections.
            above: store.workspaceTab == .preview && dockPinnedLarge ? AnyView(DockPinnedBoard(large: $dockPinnedLarge)) : nil
        ) {
            DockSection("Text", key: "text") {
                SampleChips(text: $specimenText, face: sampleFace)
            } content: {
                TextField("Type here", text: $specimenText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AppChrome.type())
                    .foregroundStyle(tone.ink)
                    .lineLimit(1...3)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .help("The sample text of every font in the preview")
            }
            DockSection("Adjust", key: "adjust") {
                ChromeSegments(
                    items: SpecimenUnit.allCases.map { .init(title: $0.title, value: $0.rawValue, help: "Size and line height in \($0.title)") },
                    selection: $unitRaw,
                    compact: true
                )
            } content: {
                adjustControls
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Compare shows the pinned fonts in the row at the top.
            if store.workspaceTab == .preview, !dockPinnedLarge {
                DockSection("Pinned", key: "pinned", detail: "\(store.pinnedFaces.count)", onFonts: { store.addToPreview($0) }) {
                    PinnedSizeChip(large: $dockPinnedLarge)
                    PinnedMenu()
                } content: {
                    PinnedStrip()
                }
            }
        }
    }

    // MARK: Info under the navigation

    /// Everything about the selected cut: metadata, activation, lists, license, OpenType features, characters, notes.
    private var infoPanel: some View {
        let face = store.selection.first.flatMap { store.face(id: $0) }
        let open = store.infoPanelOpen
        return VStack(spacing: 0) {
            infoHandle(active: open && face != nil)
            VStack(spacing: 0) {
                Button {
                    store.infoPanelOpen.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text("Info")
                            .foregroundStyle(tone.ink)
                        Text(face.map { "\($0.family) \($0.style)" } ?? "No font selected")
                            .foregroundStyle(tone.half)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if face != nil {
                            ChromeChevron(open: open, color: tone.half)
                        }
                    }
                    .font(AppChrome.type())
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(face == nil)
                .help(face == nil
                    ? "Select a font: click its name, its sample, or Info. Its metadata, lists, license, OpenType features, characters, and notes show here."
                    : open ? "Fold Info away" : "Show Info for the selected font")
                if open, let face {
                    // The title stays; what scrolls under it is set off by a line.
                    Rectangle()
                        .fill(tone.hairline)
                        .frame(height: 0.5)
                    ScrollView {
                        infoContent(face)
                    }
                    .frame(height: min(infoHeight, infoLimit))
                }
            }
            .chromePanel()
            // Without a font there is nothing to show: the panel steps back.
            .opacity(face == nil ? 0.45 : 1)
        }
        .paperColors(ink: AppChrome.ink, paper: AppChrome.panel)
        .onChange(of: face?.id) { _, _ in
            glyphScalars = []
            glyphTotal = 0
            glyphsLoaded = false
            copiedCode = ""
            characterQuery = ""
            if face?.category == .unclassified {
                listsOpen = true
            }
        }
        .task(id: face?.postscriptName) {
            guard let face else {
                activeSourcePath = ""
                return
            }
            let path = FontActivator.activeFileURL(postScriptName: face.postscriptName)?.path ?? ""
            activeSourcePath = path == face.filePath ? "" : path
        }
        .task(id: "\(face?.id ?? 0)|\(charactersOpen)|\(open)") {
            guard charactersOpen, open, let face else { return }
            let path = face.filePath
            let index = face.faceIndex
            // Every character, so the search covers the whole font; the grid shows the first few hundred.
            let loaded = await Task.detached(priority: .userInitiated) {
                SpecimenCharacters.glyphs(filePath: path, faceIndex: index, limit: 0x10000)
            }.value
            glyphScalars = Array(loaded?.shown.unicodeScalars ?? "".unicodeScalars)
            glyphTotal = loaded?.total ?? 0
            glyphsLoaded = true
        }
    }

    private func infoContent(_ face: FontFace) -> some View {
        // Set like the navigation: titles and rows at its sizes, the parts close together, no lines between them.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(face.family)
                    .font(AppChrome.type(12, weight: .medium))
                    .foregroundStyle(tone.ink)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text("\(face.style), \(face.format.uppercased())\(face.isVariable ? ", Variable" : "")")
                    .font(AppChrome.type())
                    .foregroundStyle(tone.half)
            }
            HStack(spacing: 5) {
                pinButton(face)
                activationButton(face)
                playgroundButton(face)
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .padding(.bottom, 6)
            metadataSection(face)
            infoSection(face)
            listSection(face)
            licenseSection([face])
            if !FontFeatures.list(filePath: face.filePath, faceIndex: face.faceIndex).isEmpty {
                featureSection(face)
            }
            characterSection(face)
            notesSection([face])
            finderSection(face)
                .padding(.top, 8)
        }
        .foregroundStyle(tone.ink)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The open space between the navigation and Info. With Info open it is a handle: drag it to give Info more or
    /// less room.
    private func infoHandle(active: Bool) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: AppChrome.gap)
            .contentShape(Rectangle())
            .onHover { inside in
                guard active else { return }
                if inside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { drag in
                        guard active else { return }
                        let start = infoDragStart ?? min(infoHeight, Double(infoLimit))
                        infoDragStart = start
                        infoHeight = min(Double(infoLimit), max(120, start - drag.translation.height))
                    }
                    .onEnded { _ in infoDragStart = nil }
            )
            .help(active ? "Drag to give Info more or less room" : "")
    }

    /// Neighbouring cuts of one family, as the cards of the stacked preview.
    private func clusters(_ faces: [FontFace]) -> [FamilyCluster] {
        var result: [FamilyCluster] = []
        for face in faces {
            if let last = result.indices.last, result[last].family.caseInsensitiveCompare(face.family) == .orderedSame {
                result[last].faces.append(face)
            } else {
                result.append(FamilyCluster(family: face.family, faces: [face]))
            }
        }
        return result
    }

    /// A library view with several families starts each one folded to a single sample. A family alone in the
    /// preview starts open, and so do your own lists, where every cut was picked by hand.
    private func opensFamilies(_ groups: [FamilyCluster]) -> Bool {
        groups.count == 1 || store.isViewingList
    }

    private func isOpen(_ cluster: FamilyCluster, alone: Bool) -> Bool {
        toggledFamilies.contains(cluster.id) != alone
    }

    /// The cut that stands for a folded family: upright, closest to regular.
    private func leadFace(_ faces: [FontFace]) -> FontFace {
        faces.min { lhs, rhs in
            if lhs.isItalic != rhs.isItalic { return !lhs.isItalic }
            return abs(lhs.weightClass - 400) < abs(rhs.weightClass - 400)
        } ?? faces[0]
    }

    private func clusterCard(_ cluster: FamilyCluster, alone: Bool, first: Bool, count: Int) -> some View {
        let open = isOpen(cluster, alone: alone)
        let shown = cluster.faces.count > 1 && !open ? [leadFace(cluster.faces)] : cluster.faces
        return sliceCard {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, face in
                if index > 0 {
                    Rectangle()
                        .fill(tone.stroke)
                        .frame(height: 0.5)
                }
                previewSlice(face, placeholder: first && index == 0, count: count, cluster: cluster, open: open, leads: index == 0)
                    .id(face.id)
            }
        }
    }

    private func sliceCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppChrome.cardRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(shape)
        .overlay(shape.stroke(tone.stroke, lineWidth: 0.5))
    }

    private func previewStack(_ faces: [FontFace]) -> some View {
        let shown = store.workspaceTab == .preview ? faces : Array(faces.prefix(previewLimit))
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if overlayOpen && shown.count > 1 {
                    overlayBoard(shown)
                        .padding(12)
                } else if alignOpen && shown.count > 1 {
                    alignBoard(shown)
                        .padding(12)
                } else if store.workspaceTab == .preview {
                    let groups = clusters(shown)
                    let headings = store.previewHeadings
                    let links = store.previewListLinks
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, cluster in
                            // The name of the sort group: a category, a foundry, a format.
                            if let heading = cluster.faces.first.flatMap({ headings[$0.id] }) {
                                stackHeading(heading)
                                    .padding(.top, index == 0 ? 0 : 8)
                            }
                            clusterCard(cluster, alone: opensFamilies(groups), first: index == 0, count: faces.count)
                                .id(cluster.id)
                        }
                        if !links.isEmpty || store.isViewingList {
                            listLinkStack(links)
                                .padding(.top, 8)
                                .id("list-links")
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 9)
                    // The room above the first card belongs to the list, so cards scroll away right under the line.
                    .padding(.top, 12)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, face in
                            sliceCard {
                                previewSlice(face, placeholder: index == 0, count: faces.count)
                            }
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 9)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            if store.workspaceTab != .preview, faces.count > shown.count {
                Text("Showing \(shown.count) of \(faces.count) pinned fonts.")
                    .font(.uiCaption)
                    .foregroundStyle(ink.opacity(0.72))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            if !looseOutside.isEmpty {
                outsideStack
                    .padding(16)
            }
        }
        .dropDestination(for: FontDragItem.self) { items, _ in
            store.addToPreview(items.flatMap(\.identities))
        }
    }

    private func stackHeading(_ title: String) -> some View {
        Text(title)
            .font(AppChrome.type(11, weight: .medium))
            .foregroundStyle(tone.half)
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Outside fonts on show that are not saved in the open list; those have their own cards under the list's fonts.
    private var looseOutside: [OutsideFont] {
        let saved = Set(store.previewListLinks.map(\.nameKey))
        return store.outsideSelection.filter { !saved.contains($0.nameKey) }
    }

    /// The fonts of this list that are not in the library, under those that are: saved from the news, or added
    /// by hand with the plus as a name and a link.
    private func listLinkStack(_ links: [OutsideFont]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                stackHeading(links.isEmpty ? "Not in library" : "Not in library · \(links.count)")
                if case .group(let list) = store.filter {
                    IconChip(symbol: "plus", help: "Add a font that is not in the library: its name and the link to its page") {
                        addingLink = true
                    }
                    .popover(isPresented: $addingLink, arrowEdge: .bottom) {
                        OutsideFontForm { name, source, url in
                            store.addListLink(list, name: name, source: source, url: url)
                        }
                    }
                }
            }
            if links.isEmpty {
                Text("Fonts you do not have yet: add a name and a link with the plus, or drag a name from News onto the list in the navigation.")
                    .font(AppChrome.small)
                    .foregroundStyle(tone.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
            ForEach(links) { item in
                listLinkCard(item)
                    .id("link-\(item.nameKey)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listLinkCard(_ item: OutsideFont) -> some View {
        // Looking up the foundry page gives the shown item its real address, so the two are matched by name.
        let open = store.outsideSelection.first { $0.nameKey == item.nameKey }
        return sliceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(AppChrome.type(12, weight: .medium))
                        .foregroundStyle(tone.ink)
                        .lineLimit(1)
                    Text(item.source)
                        .font(AppChrome.type(11))
                        .foregroundStyle(tone.half)
                        .lineLimit(1)
                    Text("Link")
                        .font(AppChrome.type(9, weight: .medium))
                        .foregroundStyle(tone.half)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(tone.stroke, lineWidth: 0.5))
                    Spacer(minLength: 8)
                    Button(open == nil ? "Show page" : "Hide page") {
                        store.outsideSelection = open == nil ? [item] : []
                    }
                    .buttonStyle(.chip(on: open != nil))
                    .help("Show the foundry's page for \(item.name) here")
                    Button("Open") { NSWorkspace.shared.open(item.url) }
                        .buttonStyle(.chip())
                        .help("Open the page in your browser")
                    Button("Edit…") { editingOutside = item }
                        .buttonStyle(.chip())
                        .help("Change the name, source, or link")
                    if case .group(let list) = store.filter {
                        IconChip(symbol: "xmark", help: "Remove \(item.name) from this list") {
                            store.removeListLink(list, item: item)
                        }
                    }
                }
                if let open {
                    outsidePreview(open, embedPage: true, header: false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }


    private func outsideFocus(_ item: OutsideFont) -> some View {
        let page = previewPage(for: item)
        let ready = page.path.count > 1 || store.resolvedFontPages.contains(store.fontPageKey(item))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.uiTitle3.weight(.semibold))
                        .foregroundStyle(ink)
                        .lineLimit(2)
                    Text(item.source)
                        .font(.uiCaption)
                        .foregroundStyle(ink.opacity(0.72))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                paperButton("Edit…", help: "Change the name, source, or link") { editingOutside = item }
                paperButton("Open", help: "Open the page in your browser") { NSWorkspace.shared.open(ready ? page : item.url) }
            }
            if ready {
                LinkedPage(item: item, page: page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 520)
                    .layoutPriority(1)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Opening the font page…")
                        .font(.uiCaption)
                        .foregroundStyle(ink.opacity(0.72))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(minHeight: 520)
                .task(id: store.fontPageKey(item)) {
                    await store.attachSpecimen(to: item)
                }
            }
            Text("The foundry's own page. The font file is not downloaded.")
                .font(.uiCaption)
                .foregroundStyle(ink.opacity(0.72))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: paper))
    }

    private var outsideStack: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Outside the library")
                .font(.uiCaption.weight(.semibold))
                .foregroundStyle(ink.opacity(0.72))
            ForEach(looseOutside) { item in
                outsidePreview(item, embedPage: looseOutside.count == 1)
            }
            if looseOutside.count > 1 {
                Text("Select one font to show its page here.")
                    .font(.uiCaption)
                    .foregroundStyle(ink.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outsidePreview(_ item: OutsideFont, embedPage: Bool, header: Bool = true) -> some View {
        let match = store.face(forFamily: item.name)
        return VStack(alignment: .leading, spacing: 8) {
            if header {
            HStack(spacing: 8) {
                Text(match == nil ? "Name only" : "In library")
                    .font(.uiCaption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ink.opacity(0.12), in: Capsule())
                Text(item.source)
                    .font(.uiCaption)
                    .foregroundStyle(ink.opacity(0.72))
                Spacer()
                paperButton("Edit…", help: "Change the name, source, or link") { editingOutside = item }
                paperButton("Open", help: "Open the page in your browser") { NSWorkspace.shared.open(item.url) }
            }
            Text(item.name)
                .font(.system(size: match == nil ? 28 : 22, weight: .medium))
                .foregroundStyle(ink)
                .lineLimit(2)
            }
            if embedPage {
                let page = previewPage(for: item)
                let ready = page.path.count > 1 || store.resolvedFontPages.contains(store.fontPageKey(item))
                VStack(alignment: .leading, spacing: 6) {
                    Text(ready && page.path.count > 1 ? "Font page" : "Foundry page")
                        .font(.uiCaption.weight(.semibold))
                        .foregroundStyle(ink.opacity(0.72))
                    if ready {
                        LinkedPage(item: item, page: page, height: 420)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Opening the font page…")
                                .font(.uiCaption)
                                .foregroundStyle(ink.opacity(0.72))
                        }
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                        .task(id: store.fontPageKey(item)) {
                            await store.attachSpecimen(to: item)
                        }
                    }
                    Text("The foundry's own page for this font. The font file is not downloaded.")
                        .font(.uiCaption)
                        .foregroundStyle(ink.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let match {
                FamilySample(face: match, text: specimenText, size: min(specimenSize, 48))
                Text("A font with this name is already in the library, so the sample uses that file.")
                    .font(.uiCaption)
                    .foregroundStyle(ink.opacity(0.72))
            }
        }
        .padding(header ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ink.opacity(header ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func previewPage(for item: OutsideFont) -> URL {
        if !FoundryLookup.isDirectoryHost(item.url) {
            return item.url
        }
        return store.foundrySite(for: item) ?? item.url
    }

    /// The projects the shown cuts are licensed for: one row each with its end date, and a field for another.
    /// What is entered goes to every cut on screen, or to the whole family.
    private func licenseSection(_ faces: [FontFace]) -> some View {
        let targets = licenseTargets(faces)
        let entries = licenseEntries(faces)
        let recent = store.licenseProjects.filter { project in !entries.contains { $0.project == project } }
        let familyCount = faces.map { store.familyFaceCount($0) }.reduce(0, +)
        let note = store.licenseNote(for: faces)
        return InfoGroup(isExpanded: $licenseOpen) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    licenseRow(entry, targets: targets)
                }
                HStack(spacing: 5) {
                    TextField(entries.isEmpty ? "Project or client" : "Another project", text: $licenseDraft)
                        .textFieldStyle(.plain)
                        .foregroundStyle(tone.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(tone.control, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .onSubmit { addLicenseDraft(targets) }
                        .help("The project or client this font is licensed for. A font used in several projects takes one entry for each.")
                    if !recent.isEmpty {
                        Menu {
                            ForEach(recent, id: \.self) { project in
                                Button(project) { store.addLicense(project, for: targets) }
                            }
                        } label: {
                            Text("Recent")
                        }
                        .chromeMenuChip(compact: true)
                        .help("Add a project you already entered for another font")
                    }
                    Button("Add") { addLicenseDraft(targets) }
                        .buttonStyle(.chip())
                        .disabled(licenseDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(entries.isEmpty ? "Note this project as the font's license" : "Add this project beside the others")
                }
                if familyCount > faces.count {
                    Toggle("Apply to the whole family (\(familyCount) styles)", isOn: $licenseWholeFamily)
                        .toggleStyle(.checkbox)
                        .help("Add, remove, and date a license for every style of the family at once")
                }
                Text(entries.isEmpty
                    ? "Licensed fonts carry a tag beside their name and stand under Licensed in the navigation."
                    : "A license with an end date shows it beside the font’s name; once the day has passed, the tag turns red.")
                    .font(.uiCaption)
                    .foregroundStyle(tone.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        } label: {
            HStack(spacing: 6) {
                Text("License")
                if let first = entries.first {
                    Text(entries.count > 1 ? "\(first.project) +\(entries.count - 1)" : first.project)
                        .font(.uiCaption)
                        .foregroundStyle(tone.half)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                if let note, note.expired {
                    Label(note.short, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.uiCaption)
                        .foregroundStyle(LicenseTag.alarm)
                        .lineLimit(1)
                        .help(note.help)
                } else if let note, !note.short.isEmpty {
                    Text(note.short)
                        .font(.uiCaption)
                        .foregroundStyle(tone.half)
                        .lineLimit(1)
                        .help(note.help)
                }
            }
        }
    }

    /// One project across the cuts on show, with the end date they share.
    private struct LicenseEntry: Identifiable {
        var project: String
        /// The end date, when every cut with this license has the same.
        var until: Date?
        /// The cuts carry different end dates for this project.
        var differs: Bool
        /// Of the cuts on show, how many carry it.
        var carriers: Int
        var id: String { project }

        var expired: Bool { FontLicense(project: project, until: until).expired }
    }

    private func licenseEntries(_ faces: [FontFace]) -> [LicenseEntry] {
        var order: [String] = []
        var ends: [String: Set<Date?>] = [:]
        var carriers: [String: Int] = [:]
        for face in faces {
            for license in store.licenses(for: face) {
                if ends[license.project] == nil { order.append(license.project) }
                ends[license.project, default: []].insert(license.until)
                carriers[license.project, default: 0] += 1
            }
        }
        return order.map { project in
            let dates = ends[project] ?? []
            return LicenseEntry(
                project: project,
                until: dates.count == 1 ? (dates.first ?? nil) : nil,
                differs: dates.count > 1,
                carriers: carriers[project] ?? 0
            )
        }
    }

    private func addLicenseDraft(_ targets: [FontFace]) {
        let project = licenseDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else { return }
        store.addLicense(project, for: targets)
        licenseDraft = ""
    }

    /// One license: the project, and under it the day it runs until. A day that has passed stands in red.
    private func licenseRow(_ entry: LicenseEntry, targets: [FontFace]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if entry.expired {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.uiCaption)
                        .foregroundStyle(LicenseTag.alarm)
                }
                Text(entry.project)
                    .font(AppChrome.type(12, weight: .medium))
                    .foregroundStyle(tone.ink)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                IconChip(symbol: "xmark", quiet: true, help: "Remove the license for \(entry.project)") {
                    store.removeLicense(entry.project, for: targets)
                }
            }
            HStack(spacing: 5) {
                if let until = entry.until {
                    Text(entry.expired ? "Expired" : "Valid until")
                        .font(entry.expired ? .uiCaption.weight(.semibold) : .uiCaption)
                        .foregroundStyle(entry.expired ? LicenseTag.alarm : tone.half)
                    DatePicker(
                        "Valid until",
                        selection: Binding(
                            get: { until },
                            set: { store.setLicenseEnd($0, project: entry.project, for: targets) }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("The last day the license for \(entry.project) is valid")
                    Spacer(minLength: 4)
                    IconChip(symbol: "arrow.counterclockwise", quiet: true, help: "Take the end date away: this license has no end") {
                        store.setLicenseEnd(nil, project: entry.project, for: targets)
                    }
                } else {
                    Text(entry.differs ? "Different end dates" : "No end date")
                        .font(.uiCaption)
                        .foregroundStyle(tone.half)
                    Spacer(minLength: 4)
                    Button("Set date") {
                        let start = Calendar.current.startOfDay(for: Date())
                        store.setLicenseEnd(Calendar.current.date(byAdding: .year, value: 1, to: start) ?? start, project: entry.project, for: targets)
                    }
                    .buttonStyle(.chip())
                    .help("Enter the day this license ends. It starts a year from today; change it to the real date.")
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(tone.card, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(entry.expired ? LicenseTag.alarm.opacity(0.7) : tone.hairline, lineWidth: 0.5)
        )
    }

    private func licenseTargets(_ faces: [FontFace]) -> [FontFace] {
        guard licenseWholeFamily else { return faces }
        let families = Set(faces.map(\.family))
        return families.flatMap { family in store.cuts(in: family).filter { $0.family == family } }
    }

    private func notesSection(_ faces: [FontFace]) -> some View {
        InfoGroup("Notes", isExpanded: $notesOpen) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(faces) { face in
                    noteField(face, showName: faces.count > 1)
                }
            }
            .padding(.top, 2)
        }
    }

    private func noteField(_ face: FontFace, showName: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if showName {
                Text("\(face.family) · \(face.style)")
                    .font(.uiCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            NoteEditor(face: face)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
        }
    }

    /// Paper and text colour for every preview mode and the Playground, from the column bar.
    private var colorButton: some View {
        Button {
            colorsOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Color(nsColor: paper))
                    Circle()
                        .trim(from: 0, to: 0.5)
                        .fill(ink)
                        .rotationEffect(.degrees(45))
                    Circle()
                        .stroke(Color.primary.opacity(0.35), lineWidth: 0.5)
                }
                .frame(width: 9, height: 9)
                Text("Colors")
            }
        }
        .buttonStyle(.chip(on: colorsOpen))
        .help("Paper and text colours")
        .popover(isPresented: $colorsOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Colors")
                    .font(.uiCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
                colorSwatches
                HStack(spacing: 10) {
                    ColorPicker("Background", selection: backgroundColor, supportsOpacity: false)
                    ColorPicker("Text", selection: foregroundColor, supportsOpacity: false)
                    Spacer(minLength: 0)
                    colorReset
                }
            }
            .controlSize(.small)
            .padding(12)
            .frame(width: 300)
        }
    }

    private func arranged(_ faces: [FontFace]) -> [FontFace] {
        let rank = Dictionary(uniqueKeysWithValues: previewOrder.enumerated().map { ($1, $0) })
        return faces.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? (10_000 + lhs.offset)
            let right = rank[rhs.element.id] ?? (10_000 + rhs.offset)
            return left < right
        }.map(\.element)
    }

    private func reconcilePreviewOrder(_ ids: [Int64]) {
        var next = previewOrder.filter { ids.contains($0) }
        for id in ids where !next.contains(id) {
            next.append(id)
        }
        if next != previewOrder {
            previewOrder = next
        }
    }

    private func reorderPreview(moving identities: [String], before face: FontFace) {
        let ids = Set(store.previewFaces.map(\.id))
        let movingIDs = identities.compactMap { identity in
            store.face(identity: identity).map(\.id).flatMap { ids.contains($0) ? $0 : nil }
        }
        guard !movingIDs.isEmpty, !movingIDs.contains(face.id) else { return }
        var order = previewOrder.isEmpty ? store.previewFaces.map(\.id) : previewOrder
        order.removeAll { movingIDs.contains($0) }
        let index = order.firstIndex(of: face.id) ?? order.endIndex
        order.insert(contentsOf: movingIDs, at: index)
        previewOrder = order
    }

    /// One cut in the stacked preview: a header with its name and buttons, then the editable sample.
    /// A selected cut sits on grey, and its Info shows under the navigation.
    private func previewSlice(
        _ face: FontFace,
        placeholder: Bool,
        count: Int,
        cluster: FamilyCluster? = nil,
        open: Bool = true,
        leads: Bool = true
    ) -> some View {
        let height = editorHeights[face.id] ?? 120
        let family = cluster?.faces ?? [face]
        let folded = family.count > 1 && !open
        let selected = store.selection.contains(face.id)
        let ground = selected ? selectedPaper : paper
        // A variable slice stands for a whole file, so its menu switches between that file's named instances.
        let instances = face.isVariable && !folded ? store.instances(of: face) : []
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let cluster, family.count > 1 {
                    if leads {
                        Button {
                            toggledFamilies.formSymmetricDifference([cluster.id])
                        } label: {
                            ChromeChevron(open: open, color: ink)
                        }
                        .buttonStyle(.plain)
                        .help(open ? "Fold \(face.family) to one sample" : "Show all \(family.count) styles of \(face.family)")
                    } else {
                        Color.clear.frame(width: 10, height: 12)
                    }
                }
                Text(face.family)
                    .font(AppChrome.type(AppChrome.smallSize + 1, weight: .medium))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .help(count > 1 ? "Drag to change the order, or into the chat or a list" : "Drag this font into the chat or a list")
                if instances.count > 1 {
                    cutMenu(face, cuts: instances)
                } else {
                    Text(folded ? foldedLabel(face, styles: family.count) : "\(face.style), \(face.format.uppercased())")
                        .font(AppChrome.small)
                        .foregroundStyle(ink.opacity(0.5))
                        .lineLimit(1)
                }
                if face.isVariable, !face.axes.isEmpty {
                    VariableAxesButton(face: face)
                } else if face.isVariable {
                    Text("VAR")
                        .font(AppChrome.type(9, weight: .medium))
                        .foregroundStyle(ink.opacity(0.7))
                        .help("Variable font")
                }
                if let note = store.licenseNote(for: folded ? family : [face]) {
                    LicenseTag(note: note) {
                        // The tag leads to the license itself.
                        store.selectInPreview(face, scroll: false)
                        licenseOpen = true
                    }
                }
                Spacer(minLength: 8)
                Button("Info") {
                    store.selectInPreview(face, scroll: false)
                }
                .buttonStyle(.chip(on: selected))
                .help(selected ? "Selected: its Info shows under the navigation" : "Select this cut and show its Info under the navigation")
                if folded {
                    activateAllButton(family)
                    pinAllButton(family)
                } else {
                    activationButton(face)
                    playgroundButton(face)
                    pinButton(face)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .onTapGesture { store.selectInPreview(face, scroll: false) }
            .draggable(FontDragItem(identities: [face.identity]))
            .dropDestination(for: FontDragItem.self) { items, _ in
                let identities = items.flatMap(\.identities)
                let shown = Set(store.previewFaces.map(\.identity))
                guard identities.contains(where: { shown.contains($0) }) else {
                    return store.addToPreview(identities)
                }
                reorderPreview(moving: identities, before: face)
                return true
            } isTargeted: { _ in }
            ZStack(alignment: .topLeading) {
                SpecimenEditor(
                    text: $specimenText,
                    face: face,
                    pointSize: specimenSize,
                    tracking: tracking * specimenSize,
                    leading: leading,
                    textColor: inkNS,
                    background: ground,
                    variations: store.axisValues[face.id] ?? [:],
                    features: featureSettings(face),
                    measuredHeight: heightBinding(face.id),
                    onFocus: { store.selectInPreview(face, scroll: false) }
                )
                .frame(maxWidth: .infinity, minHeight: max(height, specimenSize * max(leading, 1.2) + 48), alignment: .topLeading)
                if placeholder && specimenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Type here")
                        .foregroundStyle(ink.opacity(0.4))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: ground))
    }

    private func foldedLabel(_ face: FontFace, styles: Int) -> String {
        let category = face.category == .unclassified ? "" : "\(face.category.rawValue), "
        return "\(category)\(styles) Styles"
    }

    /// Sends this font to the Playground as a new block, set in the current sample text.
    private func playgroundButton(_ face: FontFace) -> some View {
        IconChip(symbol: "plus.rectangle.on.rectangle", help: "To Playground: add this font as a new text block") {
            store.addToPlayground([face.identity])
        }
    }

    /// Pins a font for Compare, Shape, and Playground.
    private func pinButton(_ face: FontFace) -> some View {
        let pinned = store.isPinned(face)
        return IconChip(
            symbol: pinned ? "pin.fill" : "pin",
            on: pinned,
            help: pinned ? "Pinned for Compare, Shape, and Playground. Click to unpin." : "Pin this font for Compare, Shape, and Playground"
        ) {
            store.togglePin(face)
        }
    }

    private func pinAllButton(_ faces: [FontFace]) -> some View {
        let pinned = faces.allSatisfy { store.isPinned($0) }
        return IconChip(
            symbol: pinned ? "pin.fill" : "pin",
            on: pinned,
            help: pinned ? "Every style of this family is pinned. Click to unpin them." : "Pin all \(faces.count) styles for Compare, Shape, and Playground"
        ) {
            if pinned {
                let identities = Set(faces.map(\.identity))
                store.pinnedIdentities.removeAll { identities.contains($0) }
            } else {
                for face in faces where !store.isPinned(face) {
                    store.togglePin(face)
                }
            }
        }
    }

    private func activateAllButton(_ faces: [FontFace]) -> some View {
        let active = faces.allSatisfy { $0.activation.isAvailableToApps }
        return Button(active ? "All active" : "Activate all") {
            if active {
                store.deactivate(paths: Array(Set(faces.filter(\.canDeactivate).map(\.filePath))))
            } else {
                store.activate(paths: Array(Set(faces.filter(\.canActivate).map(\.filePath))))
            }
        }
        .buttonStyle(.chip(on: active))
        .disabled(!faces.contains { active ? $0.canDeactivate : $0.canActivate })
        .help(active ? "Every style is available to other apps. Click to deactivate them." : "Activate all \(faces.count) styles so other apps can use them")
    }


    /// The pinned fonts over each other, each in its colour. The one clicked among the pinned fonts lies on top
    /// and is the one a drag moves.
    private func overlayBoard(_ faces: [FontFace]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlignCanvas(
                faces: faces,
                text: specimenText,
                pointSize: specimenSize,
                tracking: tracking * specimenSize,
                leading: leading,
                shifts: alignShifts,
                textColor: nsColor(hex: foregroundHex, fallback: .black),
                guide: nsColor(hex: foregroundHex, fallback: .black).withAlphaComponent(0.55),
                referenceID: referenceFace(faces)?.id,
                stacked: true,
                colors: overlayNSColors(faces),
                focusedID: referenceFace(faces)?.id,
                onShift: { id, shift in
                    alignShifts[id] = shift
                    alignSnap = nil
                },
                onHeight: { alignCanvasHeight = $0 }
            )
            .frame(maxWidth: .infinity)
            .frame(height: alignCanvasHeight)
        }
    }

    private func alignBoard(_ faces: [FontFace]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlignCanvas(
                faces: faces,
                text: specimenText,
                pointSize: specimenSize,
                tracking: tracking * specimenSize,
                leading: leading,
                shifts: alignShifts,
                textColor: nsColor(hex: foregroundHex, fallback: .black),
                guide: nsColor(hex: foregroundHex, fallback: .black).withAlphaComponent(0.55),
                referenceID: referenceFace(faces)?.id,
                onShift: { id, shift in
                    alignShifts[id] = shift
                    alignSnap = nil
                },
                onHeight: { alignCanvasHeight = $0 }
            )
            .frame(maxWidth: .infinity)
            .frame(height: alignCanvasHeight)
        }
    }

    private func overlayNSColor(_ face: FontFace, index: Int) -> NSColor {
        let fallback = overlayPalette[index % overlayPalette.count].color
        guard let hex = overlayColorHex[face.id] else { return fallback }
        return nsColor(hex: hex, fallback: fallback).withAlphaComponent(0.8)
    }

    private func overlayColor(_ face: FontFace, index: Int) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: overlayNSColor(face, index: index).withAlphaComponent(1)) },
            set: { overlayColorHex[face.id] = hexString($0) }
        )
    }

    private func overlayNSColors(_ faces: [FontFace]) -> [NSColor] {
        faces.enumerated().map { index, face in overlayNSColor(face, index: index) }
    }

    /// The colour of a font in Overlay, as a dot on its pinned card. A click opens the palette.
    private func overlaySwatch(_ face: FontFace, index: Int) -> some View {
        let color = overlayNSColor(face, index: index).withAlphaComponent(1)
        return Button {
            overlayColorFor = overlayColorFor == face.id ? nil : face.id
        } label: {
            Circle()
                .fill(Color(nsColor: color))
                .overlay(Circle().stroke(tone.half, lineWidth: 0.5))
                .frame(width: 12, height: 12)
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("The colour of \(face.family) \(face.style) in Overlay. Click to change it.")
        .popover(isPresented: Binding(get: { overlayColorFor == face.id }, set: { if !$0 { overlayColorFor = nil } }), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(overlayPalette, id: \.name) { entry in
                        Button {
                            overlayColorHex[face.id] = hexString(Color(nsColor: entry.color.withAlphaComponent(1)))
                            overlayColorFor = nil
                        } label: {
                            Circle()
                                .fill(Color(nsColor: entry.color.withAlphaComponent(1)))
                                .overlay(Circle().stroke(AppChrome.ink.opacity(0.35), lineWidth: 1))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help(entry.name)
                    }
                }
                ColorPicker("Custom", selection: overlayColor(face, index: index), supportsOpacity: false)
                    .font(AppChrome.small)
                    .foregroundStyle(AppChrome.ink)
            }
            .padding(12)
            .modifier(ChromeSheet())
        }
    }

    private func referenceFace(_ faces: [FontFace]) -> FontFace? {
        if let referenceID, let face = faces.first(where: { $0.id == referenceID }) {
            return face
        }
        return faces.first
    }

    private func snapAlign(_ faces: [FontFace], metric: (CTFont) -> CGFloat) {
        guard let basis = referenceFace(faces), let reference = verticalMetric(basis, metric) else { return }
        let base = alignShifts[basis.id] ?? 0
        var next = alignShifts
        for face in faces {
            guard let value = verticalMetric(face, metric) else { continue }
            next[face.id] = base + (reference - value)
        }
        alignShifts = next
    }

    private func verticalMetric(_ face: FontFace, _ read: (CTFont) -> CGFloat) -> CGFloat? {
        guard let font = SpecimenFont.make(
            path: face.filePath,
            index: face.faceIndex,
            size: specimenSize,
            variations: [:]
        ) else { return nil }
        return read(font)
    }

    /// The preview's paper. Info sits on the chrome panel instead.
    private var paper: NSColor {
        role == .info ? AppChrome.panelNS : theme.paper
    }

    private var paperIsDark: Bool {
        role == .info ? theme.themeDark : theme.isDark
    }

    private var inkNS: NSColor {
        role == .info ? AppChrome.inkNS : theme.ink
    }

    private var ink: Color {
        Color(nsColor: inkNS)
    }

    /// The greys of the surface this view sits on: the paper in the workspace, the dark panel for Info.
    private var tone: Surface { Surface(ink: ink) }

    private var backgroundHex: String { theme.paperHex }
    private var foregroundHex: String { theme.inkHex }

    /// The grey a selected cut sits on: the paper, a step towards the ink.
    private var selectedPaper: NSColor {
        let base = paper.usingColorSpace(.sRGB) ?? paper
        let top = inkNS.usingColorSpace(.sRGB) ?? inkNS
        return base.blended(withFraction: 0.15, of: top) ?? base
    }

    private func heightBinding(_ id: Int64) -> Binding<CGFloat> {
        Binding(
            get: { editorHeights[id] ?? 180 },
            set: { editorHeights[id] = $0 }
        )
    }

    private var adjustControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            DockSliderRow(title: "Size", value: displaySize, range: sliderRange, step: sliderStep, fraction: unit == .rem ? 2 : 1, reset: { specimenSize = 48 })
            DockSliderRow(title: "Spacing", value: $tracking, range: -0.08...0.4, step: 0.01, fraction: 2, reset: { tracking = 0 })
            DockSliderRow(title: "Height", value: displayLeading, range: leadingRange, step: sliderStep, fraction: unit == .rem ? 2 : 1, reset: { leading = 1.2 })
        }
    }

    /// Rounds a slider value to its step and keeps it inside the range.
    static func snap(_ value: Double, step: Double, range: ClosedRange<Double>) -> Double {
        guard step > 0 else { return value }
        let rounded = (value / step).rounded() * step
        return min(range.upperBound, max(range.lowerBound, rounded))
    }

    private var colorSwatches: some View {
        HStack(spacing: 6) {
            ForEach(SpecimenSwatch.presets) { swatch in
                Button(swatch.name) {
                    theme.choose(paper: swatch.background, ink: swatch.foreground)
                }
                .buttonStyle(.paper)
                .help("Paper and ink: \(swatch.name)")
            }
        }
    }

    private var colorReset: some View {
        Button("Theme colours") {
            theme.followSystem()
        }
        .buttonStyle(.chip(on: !theme.custom))
        .help("Back to the paper and ink of the theme chosen in the header")
    }

    // MARK: OpenType features

    private func featureSettings(_ face: FontFace) -> [[CFString: Any]] {
        guard !featureOverrides.isEmpty else { return [] }
        return FontFeatures.settings(FontFeatures.list(filePath: face.filePath, faceIndex: face.faceIndex), overrides: featureOverrides)
    }

    private func featureOn(_ feature: FontFeature) -> Bool {
        featureOverrides[feature.id] ?? feature.isDefault
    }

    private func setFeature(_ feature: FontFeature, on: Bool, among features: [FontFeature]) {
        if on, feature.isExclusive {
            // One member of an exclusive group at a time: the siblings go back to off.
            for sibling in features where sibling.group == feature.group && sibling.id != feature.id {
                featureOverrides[sibling.id] = sibling.isDefault ? false : nil
            }
        }
        featureOverrides[feature.id] = on == feature.isDefault ? nil : on
    }

    /// Switches for the font's OpenType (or AAT) features, grouped the way the font lists them.
    @ViewBuilder
    private func featureSection(_ face: FontFace) -> some View {
        let features = FontFeatures.list(filePath: face.filePath, faceIndex: face.faceIndex)
        if !features.isEmpty {
            InfoGroup(isExpanded: $featuresOpen) {
                featureSwitches(face, features: features)
            } label: {
                HStack(spacing: 6) {
                    Text("OpenType features")
                    Text("\(features.count)")
                        .font(.uiCaption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if !featureOverrides.isEmpty {
                        Text("· \(featureOverrides.count) changed")
                            .font(.uiCaption)
                            .foregroundStyle(ink.opacity(0.8))
                    }
                }
            }
        }
    }

    private func featureSwitches(_ face: FontFace, features: [FontFeature]) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Switches apply to the preview text. Features the font turns on by itself start on.")
                        .font(.uiCaption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if !featureOverrides.isEmpty {
                        resetButton("Back to the font's defaults") { featureOverrides = [:] }
                    }
                }
                let groups = featureGroups(features)
                ForEach(groups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        if groups.count > 1 {
                            Text(group.name)
                                .font(.uiCaption2)
                                .foregroundStyle(.tertiary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(group.features) { feature in
                                Toggle(isOn: Binding(
                                    get: { featureOn(feature) },
                                    set: { setFeature(feature, on: $0, among: features) }
                                )) {
                                    HStack(spacing: 4) {
                                        Text(feature.title)
                                            .lineLimit(1)
                                        if let tag = feature.tag {
                                            Text(tag)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .font(.uiCaption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .toggleStyle(.button)
                                .controlSize(.small)
                                .help(feature.tag.map { "\(feature.title) (\($0))" } ?? feature.title)
                            }
                        }
                    }
                }
            }
            .padding(.top, 2)
    }

    private struct FeatureGroup {
        var name: String
        var features: [FontFeature]
    }

    private func featureGroups(_ features: [FontFeature]) -> [FeatureGroup] {
        var order: [String] = []
        var grouped: [String: [FontFeature]] = [:]
        for feature in features {
            if grouped[feature.group] == nil { order.append(feature.group) }
            grouped[feature.group, default: []].append(feature)
        }
        return order.map { FeatureGroup(name: $0, features: grouped[$0] ?? []) }
    }

    // MARK: Characters

    private func characterSection(_ face: FontFace) -> some View {
        InfoGroup("Characters", isExpanded: $charactersOpen) {
            if !glyphsLoaded {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
            } else if glyphScalars.isEmpty {
                Text("This font has no visible characters.")
                    .font(.uiCaption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        TextField("Character, U+00E9, 00e9, or “e acute”", text: $characterQuery)
                            .textFieldStyle(.plain)
                        if !characterQuery.isEmpty {
                            Button("Clear") {
                                characterQuery = ""
                            }
                            .buttonStyle(.chip())
                            .help("Clear the search")
                        }
                    }
                    .font(.uiCallout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    let shown = filteredScalars
                    Text(characterCaption(shown.count))
                        .font(.uiCaption)
                        .foregroundStyle(.secondary)
                    let font = SpecimenFont.make(path: face.filePath, index: face.faceIndex, size: 18, variations: store.axisValues[face.id] ?? [:])
                    let searching = !characterQuery.trimmingCharacters(in: .whitespaces).isEmpty
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: searching ? 220 : 108), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(shown, id: \.value) { scalar in
                            let code = htmlCode(scalar)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                                copiedCode = code
                            } label: {
                                HStack(spacing: 6) {
                                    Text(String(scalar))
                                        .font(font.map(Font.init) ?? .body)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(code)
                                            .font(.caption2.monospaced())
                                            .lineLimit(1)
                                            .foregroundStyle(.secondary)
                                        if searching {
                                            Text(unicodeLabel(scalar))
                                                .font(.uiCaption2)
                                                .lineLimit(1)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    copiedCode == code ? ink.opacity(0.16) : ink.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                            }
                            .buttonStyle(.plain)
                            .help("\(unicodeLabel(scalar)) · click to copy \(code)")
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// The characters matching the search: the character itself, its code point in any spelling, or words of its Unicode name.
    private var filteredScalars: [UnicodeScalar] {
        let raw = characterQuery.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return Array(glyphScalars.prefix(SpecimenView.characterGridLimit)) }
        let lowered = raw.lowercased()
        var hex = lowered
        for prefix in ["u+", "&#x", "0x", "\\u", "u"] where hex.hasPrefix(prefix) {
            hex = String(hex.dropFirst(prefix.count))
            break
        }
        hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        let codePoint = hex.count >= 2 && hex.count <= 6 ? UInt32(hex, radix: 16) : nil
        let decimal = lowered.hasPrefix("&#") ? UInt32(lowered.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: ";"))) : nil
        let words = lowered.split(separator: " ").map(String.init)
        let direct = Set(raw.unicodeScalars.map(\.value))
        return Array(glyphScalars.lazy.filter { scalar in
            if direct.contains(scalar.value) && raw.unicodeScalars.count <= 3 { return true }
            if let codePoint, scalar.value == codePoint { return true }
            if let decimal, scalar.value == decimal { return true }
            guard words.count >= 1, let name = scalar.properties.name?.lowercased() else { return false }
            return words.allSatisfy { name.contains($0) }
        }.prefix(SpecimenView.characterGridLimit))
    }

    private func unicodeLabel(_ scalar: UnicodeScalar) -> String {
        let code = String(format: "U+%04X", scalar.value)
        guard let name = scalar.properties.name else { return code }
        return "\(code) \(name.capitalized)"
    }

    private func characterCaption(_ shownCount: Int) -> String {
        if !characterQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return shownCount == 0 ? "No character matches." : "\(shownCount) matching. Click a row to copy the HTML code."
        }
        let count = glyphTotal > shownCount
            ? "Showing \(shownCount) of \(glyphTotal); search finds all of them."
            : "\(glyphTotal) characters."
        return "\(count) Click a row to copy the HTML code."
    }

    private static let characterGridLimit = 480

    private func htmlCode(_ scalar: UnicodeScalar) -> String {
        if let named = Self.htmlNames[scalar.value] {
            return named
        }
        return String(format: "&#x%04X;", scalar.value)
    }

    private static let htmlNames: [UInt32: String] = [
        34: "&quot;",
        38: "&amp;",
        39: "&apos;",
        60: "&lt;",
        62: "&gt;",
        160: "&nbsp;",
        169: "&copy;",
        174: "&reg;",
        176: "&deg;",
        215: "&times;",
        247: "&divide;",
        8211: "&ndash;",
        8212: "&mdash;",
        8216: "&lsquo;",
        8217: "&rsquo;",
        8220: "&ldquo;",
        8221: "&rdquo;",
        8226: "&bull;",
        8230: "&hellip;",
        8364: "&euro;",
        8482: "&trade;"
    ]

    private func metadataSection(_ face: FontFace) -> some View {
        InfoGroup("Metadata", isExpanded: $metadataOpen) {
            VStack(alignment: .leading, spacing: 0) {
                meta("Family", face.family)
                meta("Style", face.style)
                meta("Full name", face.fullName)
                meta("PostScript", face.postscriptName)
                meta("Version", face.version)
                meta("Foundry", display(face.manufacturer))
                meta("Designer", display(face.designer))
                meta("Category", store.standardListLabel(face))
                meta("Weight", "\(FontClassification.weightLabel(face.weightClass)) (\(face.weightClass))")
                meta("Width", FontClassification.widthLabel(face.widthClass))
                meta("X-height", face.perMilleLabel(face.xHeight))
                meta("Cap height", face.perMilleLabel(face.capHeight))
                meta("Letter width", face.perMilleLabel(face.averageWidth))
                meta("Contrast", FontClassification.contrastLabel(face.contrast))
                meta("Scripts", face.scriptLabel)
                meta("Glyphs", "\(face.glyphCount)")
                meta("Format", face.isVariable ? "\(face.format.uppercased()) · Variable" : face.format.uppercased())
                meta("File size", fileSize(face.fileSize))
                meta("Modified", face.modifiedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en_US"))))
            }
            .padding(.top, 2)
            if !face.copyright.isEmpty {
                Text(face.copyright)
                    .font(.uiCaption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
    }

    private func infoSection(_ face: FontFace) -> some View {
        InfoGroup("Activation", isExpanded: $infoOpen) {
            VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(face.activation.label)
                    .font(.uiCaption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(face.activation.isAvailableToApps ? Color(nsColor: paper) : ink)
                    .background(
                        face.activation.isAvailableToApps ? ink : ink.opacity(0.14),
                        in: Capsule()
                    )
                    .help(face.activation.isAvailableToApps ? "Other apps can use this cut" : "Other apps cannot see this cut yet")
                Spacer()
                if face.canActivate || face.canDeactivate {
                    Button(face.canDeactivate ? "Deactivate" : "Activate") {
                        store.toggle(face)
                    }
                    .buttonStyle(.paper)
                    .help("Activate makes the font available to other apps; Deactivate removes it again")
                }
            }
            if store.selection.count > 1 {
                Text("\(store.selection.count) fonts selected. The toolbar acts on the whole selection.")
                    .font(.uiCallout)
                    .foregroundStyle(.secondary)
            }
            Text(helpText(face))
                .font(.uiCallout)
                .foregroundStyle(ink.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private func listSection(_ face: FontFace) -> some View {
        let lists = store.lists(containing: face)
        let familyCount = store.familyFaceCount(face)
        return InfoGroup("Lists", isExpanded: $listsOpen) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Standard list")
                        .font(.uiSubheadline.weight(.semibold))
                    Text("A font can belong to more than one standard list.")
                        .font(.uiCaption)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(FontCategory.allCases, id: \.self) { category in
                            let selected = store.isInStandardList(category, face)
                            Button {
                                store.toggleStandardList(category, for: face, familyWide: fileWholeFamily && familyCount > 1)
                            } label: {
                                HStack(spacing: 5) {
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.uiCaption.weight(.bold))
                                    }
                                    Text(category.rawValue)
                                }
                                .font(.uiCallout.weight(selected ? .semibold : .regular))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .foregroundStyle(selected ? Color(nsColor: paper) : ink)
                                .background(selected ? ink : Color.clear, in: Capsule())
                                .overlay(Capsule().stroke(selected ? Color.clear : ink.opacity(0.45), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help("Put this font in \(category.rawValue), or take it out")
                        }
                    }
                    if familyCount > 1 {
                        Toggle("Apply to all \(familyCount) styles", isOn: $fileWholeFamily)
                            .font(.uiCallout)
                            .help("File every style of the family at once")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your lists")
                        .font(.uiSubheadline.weight(.semibold))
                    if lists.isEmpty {
                        Text("This font is not in a list.")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(lists) { list in
                                Button(list.name) {
                                    store.filter = .group(list.id)
                                }
                                .buttonStyle(.paper)
                                .help("Show the list \(list.name)")
                            }
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func finderSection(_ face: FontFace) -> some View {
        Button("Show in Finder") {
            store.reveal(face)
        }
        .buttonStyle(.paper)
        .help("Show the file in the Finder: \(face.filePath)")
    }

    private var unit: SpecimenUnit {
        SpecimenUnit(rawValue: unitRaw) ?? .point
    }

    private var displaySize: Binding<Double> {
        Binding(
            get: { unit.display(from: specimenSize) },
            set: { specimenSize = unit.points(from: $0) }
        )
    }

    private var sliderRange: ClosedRange<Double> {
        unit.display(from: 8)...unit.display(from: 240)
    }

    private var sliderStep: Double {
        switch unit {
        case .point, .pixel: return 1
        case .rem: return 0.05
        }
    }

    private var lineHeightPoints: Double {
        specimenSize * leading
    }

    private var displayLeading: Binding<Double> {
        Binding(
            get: { unit.display(from: lineHeightPoints) },
            set: { newValue in
                let points = unit.points(from: newValue)
                leading = specimenSize > 0 ? min(2.4, max(0.5, points / specimenSize)) : 1.2
            }
        )
    }

    private var leadingRange: ClosedRange<Double> {
        let lower = unit.display(from: specimenSize * 0.5)
        let upper = unit.display(from: specimenSize * 2.4)
        return lower...max(lower, upper)
    }

    private var backgroundColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: nsColor(hex: backgroundHex, fallback: .white)) },
            set: { theme.choose(paper: hexString($0)) }
        )
    }

    private var foregroundColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: nsColor(hex: foregroundHex, fallback: .black)) },
            set: { theme.choose(ink: hexString($0)) }
        )
    }

    private func cutMenu(_ face: FontFace, cuts: [FontFace]) -> some View {
        // One Text only: the macOS menu button keeps just the first text of a composed label, which dropped the style name.
        let label = Text("\(face.isVariable ? "Instance" : "Cut"): \(face.style)")
            .font(AppChrome.small)
            .lineLimit(1)
            .foregroundStyle(ink)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(ink.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(ink.opacity(0.22), lineWidth: 0.5))

        return Group {
            if cuts.count > 1 {
                Menu {
                    ForEach(cuts) { cut in
                        Button {
                            store.selectInPreview(cut)
                        } label: {
                            if cut.id == face.id {
                                Label(cut.style, systemImage: "checkmark")
                            } else {
                                Text(cut.style)
                            }
                        }
                    }
                } label: {
                    label
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: 240)
                .help(face.isVariable ? "Choose another named instance of this file" : "Choose another cut of \(face.family)")
            } else {
                label
                    .help(face.isVariable ? "This file has one named instance" : "This family has one cut in the library")
            }
        }
    }

    private func activationButton(_ face: FontFace) -> some View {
        let active = face.activation.isAvailableToApps
        let title = active ? (face.canDeactivate ? "Active" : face.activation.label) : "Activate"
        return Button(title) {
            store.toggle(face)
        }
        .buttonStyle(.chip(on: active))
        .disabled(!face.canActivate && !face.canDeactivate)
        .help(active
            ? (face.canDeactivate ? "This cut is active. Click to deactivate it." : "This cut is already available to other apps.")
            : "Activate this file so other apps can use it.")
    }


    private func paperButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.paper)
            .help(help)
    }

    private func resetButton(_ help: String, action: @escaping () -> Void) -> some View {
        IconChip(symbol: "arrow.counterclockwise", help: help, action: action)
    }

    /// One line of Metadata: the label in grey, the value beside it.
    private func meta(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(AppChrome.type())
                .foregroundStyle(ink.opacity(0.5))
                .frame(width: 82, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(AppChrome.type())
                .foregroundStyle(ink)
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1.5)
    }

    private func helpText(_ face: FontFace) -> String {
        if SystemFontLocations.isProtected(face.filePath) {
            return "This is a system font. macOS always makes it available to apps."
        }
        if face.activation == .installed {
            return "This file lives in a macOS Fonts folder, so it is installed. Deactivate hides it without deleting the file."
        }
        if face.activation == .available {
            let source = activeSourcePath.isEmpty ? "" : " Loaded from: \(activeSourcePath)"
            return "Active means InDesign and other apps can already use this style. The loaded file often comes from another font manager and is not necessarily this one.\(source)"
        }
        return "Activate registers this file with the macOS font manager. InDesign, Illustrator, Photoshop, and other apps can then use it. The file stays where it is. Deactivate removes the registration. An app that is already open may need a restart before it sees new fonts."
    }

    private func fileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
            .replacingOccurrences(of: ",", with: ".")
    }

    private func display(_ value: String) -> String {
        value.isEmpty ? "—" : value
    }

    private func nsColor(hex: String, fallback: NSColor) -> NSColor {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let number = Int(cleaned, radix: 16) else { return fallback }
        return NSColor(
            srgbRed: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }

    private func hexString(_ color: Color) -> String {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}

private struct NoteEditor: NSViewRepresentable {
    @Environment(LibraryStore.self) private var store
    var face: FontFace

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, face: face)
    }

    func makeNSView(context: Context) -> NoteTextView {
        let textView = NoteTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.font = AppChrome.nsFont(12)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.delegate = context.coordinator
        textView.string = store.notes[face.identity] ?? ""
        return textView
    }

    func updateNSView(_ textView: NoteTextView, context: Context) {
        context.coordinator.store = store
        context.coordinator.face = face
        let stored = store.notes[face.identity] ?? ""
        guard textView.string != stored, textView.window?.firstResponder !== textView else { return }
        textView.string = stored
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var store: LibraryStore
        var face: FontFace

        init(store: LibraryStore, face: FontFace) {
            self.store = store
            self.face = face
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            store.setNote(view.string, for: face)
        }
    }
}

private final class NoteTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layout = layoutManager, let container = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 58)
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let height = min(max(used.height + textContainerInset.height * 2 + 8, 58), 140)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? AppChrome.nsFont(12),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        ("Note" as NSString).draw(
            at: CGPoint(x: textContainerInset.width + 2, y: textContainerInset.height),
            withAttributes: attributes
        )
    }

    override func scrollWheel(with event: NSEvent) {
        ScrollWheelForwarding.pass(event, from: self)
    }
}

private final class SpecimenTextView: NSTextView {
    /// TextKit 1, so glyphs may sit above a tight line box instead of being clipped there.
    /// TextKit 2 (the default on recent macOS) crops the first line to `maximumLineHeight`.
    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.usesFontLeading = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        clipsToBounds = false
        unregisterDraggedTypes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unused")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clipsToBounds = false
        layer?.masksToBounds = false
        superview?.clipsToBounds = false
    }

    /// Drops pass through to the preview, so a font dragged onto the sample text joins the preview.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }

    override func scrollWheel(with event: NSEvent) {
        ScrollWheelForwarding.pass(event, from: self)
    }

    var onFocus: (() -> Void)?

    /// A click into the sample selects its cut. Reported after the click, so the view update does not interrupt it.
    override func mouseDown(with event: NSEvent) {
        if let onFocus {
            DispatchQueue.main.async(execute: onFocus)
        }
        super.mouseDown(with: event)
    }
}

private struct SpecimenSwatch: Identifiable {
    var name: String
    var background: String
    var foreground: String
    var id: String { name }

    static let presets = [
        SpecimenSwatch(name: "Studio", background: "1F1F1F", foreground: "F5F5F5"),
        SpecimenSwatch(name: "Paper", background: "F6F3EE", foreground: "212121"),
        SpecimenSwatch(name: "White", background: "FFFFFF", foreground: "1A1A1A"),
        SpecimenSwatch(name: "Black", background: "141414", foreground: "F5F5F2")
    ]
}

enum SpecimenInk {
    static func overflow(font: NSFont, text: String) -> (top: CGFloat, bottom: CGFloat) {
        let fallback = max(8, font.pointSize * 0.25)
        let flat = String(text.prefix(160)).replacingOccurrences(of: "\n", with: " ")
        let sample = flat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Hg" : flat
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: sample, attributes: [.font: font]))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let bounds = CTLineGetImageBounds(line, nil)
        var inkTop = max(ascent, font.ascender)
        var inkBottom = max(descent, abs(font.descender))
        if bounds.width.isFinite, bounds.height.isFinite, bounds.height > 0, bounds.height < font.pointSize * 6 {
            // Image bounds sit on the baseline with +Y up. A flipped or empty rect is ignored above.
            inkTop = max(inkTop, bounds.maxY)
            inkBottom = max(inkBottom, -bounds.minY)
        }
        let top = max(0, inkTop - font.ascender)
        let bottom = max(0, inkBottom - abs(font.descender))
        return (max(top, 4), max(bottom, 4, fallback * 0.15))
    }
}

/// A paragraph with a fixed line height, so leading can go below the font's own line height as well as above it.
enum SpecimenParagraph {
    static func style(lineHeight: CGFloat) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        let height = max(1, lineHeight)
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        paragraph.lineSpacing = 0
        return paragraph
    }
}

/// A part of Info that folds to its title. Set like a section of the navigation: the title in its size and
/// weight, the small arrow at the right as on Info itself, the rows right under it.
struct InfoGroup<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label
    @Environment(\.surface) private var surface

    init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        _isExpanded = isExpanded
        self.content = content()
        self.label = label()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    label
                        .font(AppChrome.type(12, weight: .medium))
                        .foregroundStyle(surface.ink)
                    Spacer(minLength: 4)
                    ChromeChevron(open: isExpanded, color: surface.half)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Fold this part away" : "Show this part")
            if isExpanded {
                content
                    .font(AppChrome.type())
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension InfoGroup where Label == Text {
    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.init(isExpanded: isExpanded, content: content) { Text(title) }
    }
}

extension OutsideFont {
    /// Source and name. The address can change once the foundry's own page is found; these two stay.
    var nameKey: String { source + "\n" + name }
}

/// Fonts for previews, made from the file itself (and its variation settings). Used by the Playground export too.
enum SpecimenFont {
    static func make(path: String, index: Int, size: CGFloat, variations: [UInt32: Double], features: [[CFString: Any]] = []) -> NSFont? {
        let featureKey = features.map { setting in
            setting.keys.map { String($0) }.sorted().map { "\($0)=\(setting[$0 as CFString].map { "\($0)" } ?? "")" }.joined(separator: ";")
        }.joined(separator: "|")
        let key = "\(path)\n\(index)\n" + variations.keys.sorted().map { "\($0):\(variations[$0] ?? 0)" }.joined(separator: ",") + "\n" + featureKey
        let descriptor: CTFontDescriptor
        if let cached = descriptors[key] {
            descriptor = cached
        } else {
            let url = WebfontUnpacker.openableURL(path) as CFURL
            guard let found = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor],
                  found.indices.contains(index) else { return nil }
            var next = found[index]
            for (tag, value) in variations {
                var raw = Int32(bitPattern: tag)
                guard let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &raw) else { continue }
                next = CTFontDescriptorCreateCopyWithVariation(next, number, value)
            }
            if !features.isEmpty {
                next = CTFontDescriptorCreateCopyWithAttributes(next, [kCTFontFeatureSettingsAttribute: features] as CFDictionary)
            }
            // Dragging an axis asks for a new descriptor at every step; the store starts over before it grows large.
            if descriptors.count > 600 { descriptors.removeAll(keepingCapacity: true) }
            descriptors[key] = next
            descriptor = next
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }

    private static var descriptors: [String: CTFontDescriptor] = [:]
}

/// An editable text view drawn with one font file. Also used by the Playground, so it stays internal.
struct SpecimenEditor: NSViewRepresentable {
    @Binding var text: String
    var face: FontFace
    var pointSize: Double
    var tracking: Double
    var leading: Double
    var textColor: NSColor
    var background: NSColor
    var variations: [UInt32: Double]
    /// Core Text feature settings (OpenType tags or AAT selectors) switched away from the font's defaults.
    var features: [[CFString: Any]] = []
    @Binding var measuredHeight: CGFloat
    /// Called when a click puts the cursor into the text, so the cut can be selected.
    var onFocus: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, measuredHeight: $measuredHeight)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = SpecimenTextView()
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 14, height: 16)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = context.coordinator
        textView.string = text
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.measuredHeight = $measuredHeight
        (textView as? SpecimenTextView)?.onFocus = onFocus
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
        }
        guard let font = SpecimenFont.make(
            path: face.filePath,
            index: face.faceIndex,
            size: pointSize,
            variations: variations,
            features: features
        ) else { return }
        let overflow = SpecimenInk.overflow(font: font, text: textView.string)
        let natural = font.ascender + abs(font.descender) + max(font.leading, 0)
        let desired = CGFloat(pointSize * leading)
        // Room above the first line: tight leading still paints into this inset instead of clipping.
        let lineClash = max(0, natural - desired)
        let pad = 16 + max(overflow.top, overflow.bottom) + lineClash
        textView.clipsToBounds = false
        textView.layer?.masksToBounds = false
        if abs(textView.textContainerInset.height - pad) > 0.5 {
            textView.textContainerInset = NSSize(width: 14, height: pad)
        }
        textView.layoutManager?.usesFontLeading = false
        let paragraph = SpecimenParagraph.style(lineHeight: desired)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .kern: tracking,
            .paragraphStyle: paragraph
        ]
        textView.backgroundColor = background
        textView.insertionPointColor = textColor
        textView.typingAttributes = attributes
        if let storage = textView.textStorage, storage.length > 0 {
            let selected = textView.selectedRanges
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            textView.selectedRanges = selected
        }
        context.coordinator.report(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var measuredHeight: Binding<CGFloat>

        init(text: Binding<String>, measuredHeight: Binding<CGFloat>) {
            self.text = text
            self.measuredHeight = measuredHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if text.wrappedValue != view.string {
                text.wrappedValue = view.string
            }
            report(view)
        }

        func report(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let height = max(used.height + view.textContainerInset.height * 2 + 8, 80)
            guard abs(measuredHeight.wrappedValue - height) > 1 else { return }
            DispatchQueue.main.async {
                self.measuredHeight.wrappedValue = height
            }
        }
    }
}

private struct AlignCanvas: NSViewRepresentable {
    var faces: [FontFace]
    var text: String
    var pointSize: CGFloat
    var tracking: CGFloat
    var leading: CGFloat
    var shifts: [Int64: CGFloat]
    var textColor: NSColor
    var guide: NSColor
    var referenceID: Int64?
    var stacked = false
    var colors: [NSColor] = []
    var focusedID: Int64?
    var onShift: (Int64, CGFloat) -> Void
    var onHeight: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> AlignColumnView {
        let view = AlignColumnView()
        view.onShift = onShift
        view.onHeight = onHeight
        return view
    }

    func updateNSView(_ view: AlignColumnView, context: Context) {
        view.faces = faces
        view.sample = text
        view.pointSize = pointSize
        view.tracking = tracking
        view.leading = leading
        if view.dragID == nil {
            view.shifts = shifts
        }
        view.textColor = textColor
        view.guideColor = guide
        view.referenceID = referenceID
        view.stacked = stacked
        view.colors = colors
        view.focusedID = focusedID
        view.onShift = onShift
        view.onHeight = onHeight
        view.needsDisplay = true
        view.reportHeight()
    }
}

private final class AlignColumnView: NSView {
    var faces: [FontFace] = []
    var sample = ""
    var pointSize: CGFloat = 48
    var tracking: CGFloat = 0
    var leading: CGFloat = 1.2
    var shifts: [Int64: CGFloat] = [:]
    var textColor: NSColor = .black
    var guideColor: NSColor = .gray
    var referenceID: Int64?
    var stacked = false
    var colors: [NSColor] = []
    var focusedID: Int64?
    var onShift: ((Int64, CGFloat) -> Void)?
    var onHeight: ((CGFloat) -> Void)?

    fileprivate var dragID: Int64?
    private var dragStartY: CGFloat = 0
    private var dragStartShift: CGFloat = 0
    private var reportedHeight: CGFloat = 0
    private var measureKey = ""
    private var lineCache: [LineKey: [CTLine]] = [:]

    private struct LineKey: Hashable {
        var id: Int64
        var width: Int
        var size: Int
        var tracking: Int
        var sample: Int
        var color: Int
    }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        reportHeight()
    }

    func reportHeight() {
        let width = bounds.width
        guard width > 40 else { return }
        let key = "\(Int(width))|\(faces.count)|\(sample.hashValue)|\(Int(pointSize))|\(stacked)|\(Int(leading * 100))"
        if key == measureKey { return }
        let needed = preferredHeight(for: width)
        measureKey = key
        guard abs(needed - reportedHeight) > 2 else { return }
        reportedHeight = needed
        let callback = onHeight
        DispatchQueue.main.async {
            callback?(needed)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let width = bounds.width / CGFloat(max(faces.count, 1))
        let baseline = firstBaseline
        let reference = faces.first { $0.id == referenceID } ?? faces.first
        let referenceShift = reference.flatMap { shifts[$0.id] } ?? 0
        let referenceFont = reference.flatMap {
            SpecimenFont.make(path: $0.filePath, index: $0.faceIndex, size: pointSize, variations: [:])
        }

        if let referenceFont {
            let xHeight = CTFontGetXHeight(referenceFont)
            let capHeight = CTFontGetCapHeight(referenceFont)
            stroke(context, y: baseline + referenceShift + xHeight, label: "x")
            stroke(context, y: baseline + referenceShift + capHeight, label: "H")
        }
        stroke(context, y: baseline + referenceShift, label: "")

        if stacked {
            // The font that was clicked lies on top; each keeps the colour of its place among the pinned fonts.
            let order = faces.indices.sorted { lhs, rhs in
                let left = faces[lhs].id == focusedID
                let right = faces[rhs].id == focusedID
                return left == right ? lhs < rhs : !left
            }
            for index in order {
                let color = colors.isEmpty ? textColor : colors[index % colors.count]
                drawFace(faces[index], context: context, x: 16, width: bounds.width - 24, baseline: baseline, color: color)
            }
            return
        }

        for (index, face) in faces.enumerated() {
            let column = bounds.width * CGFloat(index) / CGFloat(max(faces.count, 1))
            if index > 0 {
                context.setStrokeColor(guideColor.cgColor)
                context.setLineWidth(1)
                context.move(to: CGPoint(x: column, y: 8))
                context.addLine(to: CGPoint(x: column, y: bounds.height - 8))
                context.strokePath()
            }
            let name = "\(face.family) · \(face.style)" as NSString
            // A name longer than its column is cut short, so it stays out of the next one.
            let nameStyle = NSMutableParagraphStyle()
            nameStyle.lineBreakMode = .byTruncatingTail
            let nameAttributes: [NSAttributedString.Key: Any] = [
                .font: AppChrome.nsFont(10, weight: face.id == reference?.id ? .medium : .regular),
                .foregroundColor: textColor.withAlphaComponent(face.id == reference?.id ? 1 : 0.82),
                .paragraphStyle: nameStyle
            ]
            let nameHeight = ceil(name.size(withAttributes: nameAttributes).height)
            name.draw(
                in: CGRect(x: column + 10, y: bounds.height - 18, width: max(width - 18, 1), height: nameHeight),
                withAttributes: nameAttributes
            )
            drawFace(face, context: context, x: column + 10, width: max(width - 12, 1), baseline: baseline, color: textColor)
        }
    }

    private func drawFace(
        _ face: FontFace,
        context: CGContext,
        x: CGFloat,
        width: CGFloat,
        baseline: CGFloat,
        color: NSColor
    ) {
        let shift = shifts[face.id] ?? 0
        let step = max(pointSize * leading, pointSize)
        let lines = wrappedLines(face, width: width, color: color)
        let topReserve: CGFloat = stacked ? 4 : 22
        context.saveGState()
        context.clip(to: CGRect(x: x, y: 0, width: max(width, 1), height: max(bounds.height - topReserve, 1)))
        for (lineIndex, line) in lines.enumerated() {
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: baseline + shift - CGFloat(lineIndex) * step)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    private var firstBaseline: CGFloat {
        bounds.height - pointSize * 1.15 - (stacked ? 12 : 26)
    }

    private func preferredHeight(for width: CGFloat) -> CGFloat {
        let columnWidth = stacked
            ? max(width - 24, 40)
            : max(width / CGFloat(max(faces.count, 1)) - 12, 40)
        var maxLines = 1
        for (index, face) in faces.enumerated() {
            let color = stacked && !colors.isEmpty ? colors[index % colors.count] : textColor
            maxLines = max(maxLines, wrappedLines(face, width: columnWidth, color: color).count)
        }
        let step = max(pointSize * leading, pointSize)
        let top = pointSize * 1.15 + (stacked ? 12 : 26)
        return max(top + step * CGFloat(maxLines) + pointSize * 0.45, 200)
    }

    private func wrappedLines(_ face: FontFace, width: CGFloat, color: NSColor) -> [CTLine] {
        let key = LineKey(
            id: face.id,
            width: Int(width.rounded()),
            size: Int(pointSize.rounded()),
            tracking: Int(tracking.rounded()),
            sample: sample.hashValue,
            color: color.hashValue
        )
        if let cached = lineCache[key] { return cached }
        guard let font = SpecimenFont.make(path: face.filePath, index: face.faceIndex, size: pointSize, variations: [:]) else {
            return []
        }
        let paragraphs = sample.isEmpty ? [" "] : sample.components(separatedBy: .newlines)
        var result: [CTLine] = []
        let safeWidth = max(width, 8)
        for paragraph in paragraphs {
            let attributed = NSAttributedString(string: paragraph.isEmpty ? " " : paragraph, attributes: [
                .font: font,
                .foregroundColor: color,
                .kern: tracking
            ])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let length = CFAttributedStringGetLength(attributed)
            var start = 0
            while start < length && result.count < 60 {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(safeWidth))
                if count <= 0 { count = 1 }
                count = min(count, length - start)
                result.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
                start += count
            }
        }
        if lineCache.count > 240 { lineCache.removeAll(keepingCapacity: true) }
        lineCache[key] = result
        return result
    }

    override func scrollWheel(with event: NSEvent) {
        ScrollWheelForwarding.pass(event, from: self)
    }

    override func mouseDown(with event: NSEvent) {
        if stacked {
            guard let id = focusedID ?? faces.last?.id else { return }
            dragID = id
            let point = convert(event.locationInWindow, from: nil)
            dragStartY = point.y
            dragStartShift = shifts[id] ?? 0
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let id = faceID(at: point) else { return }
        dragID = id
        dragStartY = point.y
        dragStartShift = shifts[id] ?? 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragID else { return }
        let point = convert(event.locationInWindow, from: nil)
        let next = dragStartShift + (point.y - dragStartY)
        shifts[dragID] = next
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let dragID {
            onShift?(dragID, shifts[dragID] ?? dragStartShift)
        }
        dragID = nil
    }

    private func faceID(at point: CGPoint) -> Int64? {
        guard !faces.isEmpty else { return nil }
        let width = bounds.width / CGFloat(faces.count)
        let index = Int(point.x / max(width, 1))
        guard faces.indices.contains(index) else { return nil }
        return faces[index].id
    }

    private func stroke(_ context: CGContext, y: CGFloat, label: String) {
        context.setStrokeColor(guideColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 8, y: y))
        context.addLine(to: CGPoint(x: bounds.width - 8, y: y))
        context.strokePath()
        guard !label.isEmpty else { return }
        let text = label as NSString
        text.draw(at: CGPoint(x: 8, y: y + 2), withAttributes: [
            .font: AppChrome.nsFont(9),
            .foregroundColor: guideColor
        ])
    }
}

/// One workspace tab. The open tab has no line under it and full-strength text; the others sit a shade darker.
/// Fonts can be dropped on it.
private struct WorkspaceTabCell: View {
    var title: String
    var active: Bool
    var onFonts: ([String]) -> Bool
    var action: () -> Void
    @State private var hovering = false
    @State private var targeted = false
    @Environment(\.surface) private var surface
    @Environment(\.colorScheme) private var colorScheme

    /// How much darker than the paper a closed tab sits.
    private var shade: Double { colorScheme == .dark ? 0.22 : 0.07 }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppChrome.type(12, weight: active ? .medium : .regular))
                .foregroundStyle(active || hovering || targeted ? surface.ink : surface.half)
                .lineLimit(1)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 27)
                .background {
                    Rectangle().fill(targeted ? surface.selection : active ? Color.clear : Color.black.opacity(shade * (hovering ? 0.45 : 1)))
                }
                .overlay(alignment: .bottom) {
                    if !active {
                        Rectangle().fill(surface.hairline).frame(height: 0.5)
                    }
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(surface.hairline).frame(width: 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .dropDestination(for: FontDragItem.self) { items, _ in
            onFonts(items.flatMap(\.identities))
        } isTargeted: { targeted = $0 }
    }
}

/// A run of preview cuts that share a family, shown as one card.
private struct FamilyCluster: Identifiable {
    var family: String
    var faces: [FontFace]
    /// Named after its first cut, so the same family twice in a sorted list stays two cards.
    var id: String { "family:\(faces.first?.identity ?? family)" }
}
