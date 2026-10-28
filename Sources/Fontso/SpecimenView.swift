import AppKit
import CoreText
import FontsoCore
import SwiftUI
import WebKit

struct FoundryPageView: View {
    var url: URL
    @State private var status = FoundryPageStatus()

    var body: some View {
        VStack(spacing: 0) {
            FoundryWebView(url: url, status: $status)
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
                    Button("Reload") { status.reloadToken += 1 }
                        .buttonStyle(.borderless)
                        .help("Load the page again")
                    Button("Open in browser") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderless)
                        .help("Open the page in your browser")
                }
                .font(.caption)
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
        load(url, in: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.status = $status
        if context.coordinator.reloadToken != status.reloadToken {
            context.coordinator.reloadToken = status.reloadToken
            load(url, in: view, coordinator: context.coordinator)
            return
        }
        guard context.coordinator.loaded != url else { return }
        load(url, in: view, coordinator: context.coordinator)
    }

    private func load(_ url: URL, in view: WKWebView, coordinator: Coordinator) {
        coordinator.loaded = url
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        view.load(request)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loaded: URL?
        var reloadToken = 0
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
            report(error)
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

struct SpecimenPicture: View {
    var item: OutsideFont?
    var url: URL?
    var height: CGFloat = 220
    @Environment(LibraryStore.self) private var store
    @State private var gaveUp = false

    private var imageURL: URL? { url ?? item?.imageURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: height, alignment: .leading)
                    case .failure:
                        EmptyView()
                    default:
                        ProgressView()
                            .controlSize(.small)
                            .frame(height: 28, alignment: .leading)
                    }
                }
                if item != nil {
                    Text("Specimen picture from Typecache. The font file is not downloaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let item, !gaveUp {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for a specimen picture…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .task(id: item.id) {
                    await store.attachSpecimen(to: item)
                    if store.outsideSelection.first(where: { $0.id == item.id })?.imageURL == nil {
                        gaveUp = true
                    }
                }
            } else if item != nil {
                Text("Typecache has no specimen picture for this name. The font file is not downloaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SpecimenView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("fontso.sampleText") private var specimenText = SpecimenText.standard
    @AppStorage("fontso.specimenSize") private var specimenSize = 48.0
    @AppStorage("fontso.specimen.unit") private var unitRaw = SpecimenUnit.point.rawValue
    @AppStorage("fontso.specimen.tracking") private var tracking = 0.0
    @AppStorage("fontso.specimen.leading") private var leading = 1.2
    @AppStorage("fontso.specimen.background") private var backgroundHex = "F6F3EE"
    @AppStorage("fontso.specimen.foreground") private var foregroundHex = "212121"
    @State private var variations: [UInt32: Double] = [:]
    @State private var editorHeights: [Int64: CGFloat] = [:]
    @State private var activeSourcePath = ""
    @State private var metadataOpen = false
    @State private var infoOpen = false
    @State private var listsOpen = false
    @State private var fileWholeFamily = true
    @State private var notesOpen = false
    @State private var licenseOpen = false
    @State private var licenseWholeFamily = false
    @State private var charactersOpen = false
    @State private var featuresOpen = false
    @State private var glyphScalars: [UnicodeScalar] = []
    @State private var glyphTotal = 0
    @State private var glyphsLoaded = false
    @State private var copiedCode = ""
    @State private var panel = PreviewPanel.adjust
    @AppStorage("fontso.inspectorOpen") private var inspectorOpen = true
    @AppStorage("fontso.previewCollapsed") private var previewCollapsed = false
    @AppStorage("fontso.playgroundOpen") private var playgroundOpen = false
    @AppStorage("fontso.mixOpen") private var mixOpen = false
    @State private var colorsOpen = false
    @Environment(\.barLeadingInset) private var barLeadingInset
    /// Feature switches moved away from the font's defaults, by feature id. Shared by every font in the preview,
    /// so "small caps on" carries over when comparing.
    @State private var featureOverrides: [String: Bool] = [:]
    @State private var characterQuery = ""
    @State private var alignOpen = false
    @State private var overlayOpen = false
    @State private var editingOutside: OutsideFont?
    @State private var inspectorHeight: CGFloat = 220
    @State private var overlayFocus: Int64?
    @State private var referenceID: Int64?
    @State private var alignShifts: [Int64: CGFloat] = [:]
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

    private let previewLimit = 24

    var body: some View {
        let faces = arranged(store.previewFaces)
        VStack(spacing: 0) {
            previewColumnBar(faces)
            if playgroundOpen {
                PlaygroundView()
                    .paperColors(ink: ink, paper: Color(nsColor: paper))
            } else if mixOpen {
                LetterMixView()
                    .paperColors(ink: ink, paper: Color(nsColor: paper))
            } else if faces.isEmpty && store.outsideSelection.isEmpty {
                ContentUnavailableView {
                    Label("Specimen", systemImage: "doc.richtext")
                } description: {
                    Text(mode == .preview
                        ? "Select a font for the preview, metadata, and activation."
                        : "\(mode.title) needs fonts. Select them in the library, drop them here, or add them.")
                } actions: {
                    AddFontButton(title: "Add font…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: FontDragItem.self) { items, _ in
                    store.addToPreview(items.flatMap(\.identities))
                }
            } else if faces.isEmpty && (alignOpen || overlayOpen) {
                // A news item is a web page, not a font file: nothing to set on a baseline or lay over another.
                ContentUnavailableView {
                    Label("\(mode.title) works with fonts from the library", systemImage: mode.symbol)
                } description: {
                    Text(store.outsideSelection.isEmpty
                        ? "Select fonts in the library, drop them here, or add them."
                        : "A news item is a web preview, so it cannot be aligned or overlaid. Select fonts in the library, drop them here, or add them.")
                } actions: {
                    HStack {
                        AddFontButton(title: "Add font…")
                        Button("Back to Preview") { select(.preview, faces: faces) }
                            .controlSize(.small)
                            .help("Back to the plain preview")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: FontDragItem.self) { items, _ in
                    store.addToPreview(items.flatMap(\.identities))
                }
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
        .onChange(of: store.previewFaces.map(\.id)) { _, ids in
            reconcilePreviewOrder(ids)
        }
        .sheet(item: $editingOutside) { item in
            OutsideFontForm(editing: item) { name, source, url in
                store.updateOutsideItem(item, name: name, source: source, url: url)
            }
        }
    }

    /// Which of the preview modes is showing.
    private enum PreviewMode: String, CaseIterable, Identifiable {
        case preview, align, overlay, mix, playground
        var id: String { rawValue }

        var title: String {
            switch self {
            case .preview: return "Preview"
            case .align: return "Align"
            case .overlay: return "Overlay"
            case .mix: return "Mix"
            case .playground: return "Playground"
            }
        }

        var symbol: String {
            switch self {
            case .preview: return "text.alignleft"
            case .align: return "rectangle.split.2x1"
            case .overlay: return "square.on.square"
            case .mix: return "dice"
            case .playground: return "square.text.square"
            }
        }

        var help: String {
            switch self {
            case .preview: return "Preview: each font on its own, with Adjust and Info"
            case .align: return "Align: fonts side by side on one baseline, to compare x-height and cap height"
            case .overlay: return "Overlay: fonts laid on top of each other"
            case .mix: return "Mix: every letter in its own cut, chosen by you, at random, or close in x-height and width"
            case .playground: return "Playground: mix fonts in text blocks, each with its own size, tracking, and leading"
            }
        }
    }

    private var mode: PreviewMode {
        if playgroundOpen { return .playground }
        if mixOpen { return .mix }
        if overlayOpen { return .overlay }
        if alignOpen { return .align }
        return .preview
    }

    private func select(_ mode: PreviewMode, faces: [FontFace]) {
        playgroundOpen = mode == .playground
        mixOpen = mode == .mix
        alignOpen = mode == .align
        overlayOpen = mode == .overlay
        if mode == .overlay, overlayFocus == nil {
            overlayFocus = faces.dropFirst().first?.id ?? faces.first?.id
        }
    }

    /// The mode switch on the left, always showing all four modes; view controls (colours, export, size, hide) on the right.
    private func previewColumnBar(_ faces: [FontFace]) -> some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                modeSwitch(faces, labels: true)
                modeSwitch(faces, labels: false)
            }
            if faces.count > 1, mode != .playground {
                Text("\(min(faces.count, previewLimit))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !store.pinnedIdentities.isEmpty, mode != .playground {
                Button {
                    store.unpinAll()
                } label: {
                    Label("\(store.pinnedIdentities.count)", systemImage: "pin.fill")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("\(store.pinnedIdentities.count) pinned in the preview. Click to unpin all.")
            }
            Spacer(minLength: 8)
            colorButton
            if playgroundOpen {
                Button {
                    NotificationCenter.default.post(name: .fontsoPlaygroundExport, object: nil)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .help("Export the playground as PDF or PNG: screen, A4, A3, or a custom page")
            }
            previewSizeButton
            if !store.previewExpanded {
                Button {
                    previewCollapsed = true
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help("Hide the preview")
            }
        }
        .padding(.horizontal, 14)
        .padding(.leading, barLeadingInset)
        .frame(height: ColumnBarMetrics.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
        }
    }

    private func specimen(_ faces: [FontFace]) -> some View {
        let face = faces[0]
        return ZStack(alignment: .bottom) {
            ColumnScroll(
                resetID: "\(store.filterTitle)-\(faces.map { String($0.id) }.joined(separator: ","))",
                bottomInset: inspectorHeight + 28
            ) {
                previewStack(faces)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: paper))
            HStack(spacing: 0) {
                Spacer(minLength: 10)
                Group {
                    if inspectorOpen {
                        previewInspector(faces)
                            .frame(maxWidth: .infinity)
                    } else {
                        Button {
                            inspectorOpen = true
                        } label: {
                            Label(
                                faces.count == 1 && panel == .info ? "Info" : "Adjust",
                                systemImage: "slider.horizontal.3"
                            )
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ink)
                        .background(Color(nsColor: paper), in: Capsule())
                        .overlay(Capsule().stroke(ink.opacity(0.18)))
                        .shadow(color: Color.black.opacity(0.16), radius: 10, y: 4)
                        .help(faces.count == 1 ? "Show Adjust and Info" : "Show Adjust")
                    }
                }
                .frame(maxWidth: 720)
                Spacer(minLength: 10)
            }
            .padding(.bottom, 12)
            .environment(\.colorScheme, paperIsDark ? .dark : .light)
            .reportOverlayHeight()
        }
        .onPreferenceChange(OverlayHeightKey.self) { inspectorHeight = $0 }
        .onChange(of: face.id) { _, _ in
            variations = [:]
            glyphScalars = []
            glyphTotal = 0
            glyphsLoaded = false
            copiedCode = ""
            if face.category == .unclassified, faces.count == 1 {
                listsOpen = true
                panel = .info
            }
        }
        .onChange(of: faces.count) { _, count in
            if count > 1, panel == .info {
                panel = .adjust
            }
        }
        .task(id: face.postscriptName) {
            let path = FontActivator.activeFileURL(postScriptName: face.postscriptName)?.path ?? ""
            activeSourcePath = path == face.filePath ? "" : path
        }
        .task(id: "\(face.id)|\(charactersOpen)|\(faces.count)") {
            guard charactersOpen, faces.count == 1 else { return }
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

    private func previewInspector(_ faces: [FontFace]) -> some View {
        let face = faces[0]
        let showAxes = faces.count == 1 && face.isVariable && !face.axes.isEmpty
        let oneFont = faces.count == 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if oneFont {
                    Picker("Panel", selection: $panel) {
                        Text("Adjust").tag(PreviewPanel.adjust)
                        Text("Info").tag(PreviewPanel.info)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .help("Adjust sets size and spacing; Info shows the font’s details")
                } else {
                    Text("Adjust")
                        .font(.caption.weight(.semibold))
                    Text("Info is for one font.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Button {
                    inspectorOpen = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Hide Adjust and Info")
            }
            FittedPanel {
                VStack(alignment: .leading, spacing: 8) {
                    if oneFont, panel == .info {
                        metadataSection(face)
                        infoSection(face)
                        listSection(face)
                        licenseSection(Array(faces.prefix(previewLimit)))
                        featureSection(face)
                        characterSection(face)
                        notesSection(Array(faces.prefix(previewLimit)))
                        finderSection(face)
                    } else {
                        adjustControls(face, showAxes: showAxes)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !(oneFont && panel == .info) {
                Divider()
                UsedCutsBand(faces: Array(faces.prefix(previewLimit)), onRemove: { store.removeFromPreview($0) }, embedded: true)
            }
        }
        .padding(8)
        .background(Color(nsColor: paper), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ink.opacity(0.18))
        )
        .shadow(color: Color.black.opacity(0.14), radius: 14, y: 6)
    }

    private func previewStack(_ faces: [FontFace]) -> some View {
        let shown = Array(faces.prefix(previewLimit))
        let comparing = overlayOpen || alignOpen
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if overlayOpen && shown.count > 1 {
                    overlayBoard(shown)
                        .padding(12)
                } else if alignOpen && shown.count > 1 {
                    alignBoard(shown)
                        .padding(12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, face in
                            if index > 0 {
                                Rectangle()
                                    .fill(ink.opacity(0.14))
                                    .frame(height: 1)
                            }
                            previewSlice(face, placeholder: index == 0, index: index, count: faces.count)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            if comparing {
                // Comparing wants company: a second font to set beside or over the first.
                HStack(spacing: 10) {
                    if shown.count < 2 {
                        Text("\(mode.title) needs a second font. Select another one in the library, drop it here, or add it.")
                            .font(.caption)
                            .foregroundStyle(ink.opacity(0.72))
                    }
                    AddFontButton(title: shown.count < 2 ? "Add font…" : "Add another font…")
                        .tint(ink)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            if faces.count > shown.count {
                Text("Showing \(shown.count) of \(faces.count) selected fonts.")
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.72))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            if !store.outsideSelection.isEmpty {
                outsideStack
                    .padding(16)
            }
        }
        .dropDestination(for: FontDragItem.self) { items, _ in
            store.addToPreview(items.flatMap(\.identities))
        }
    }

    private func outsideFocus(_ item: OutsideFont) -> some View {
        let page = previewPage(for: item)
        let ready = page.path.count > 1 || store.resolvedFontPages.contains(store.fontPageKey(item))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ink)
                        .lineLimit(2)
                    Text(item.source)
                        .font(.caption)
                        .foregroundStyle(ink.opacity(0.72))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                paperButton("Edit…", help: "Change the name, source, or link") { editingOutside = item }
                paperButton("Open", help: "Open the page in your browser") { NSWorkspace.shared.open(ready ? page : item.url) }
            }
            if ready {
                FoundryPageView(url: page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 520)
                    .layoutPriority(1)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ink.opacity(0.2)))
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Opening the font page…")
                        .font(.caption)
                        .foregroundStyle(ink.opacity(0.72))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(minHeight: 520)
                .task(id: store.fontPageKey(item)) {
                    await store.attachSpecimen(to: item)
                }
            }
            Text("The foundry's own page. The font file is not downloaded.")
                .font(.caption)
                .foregroundStyle(ink.opacity(0.72))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: paper))
    }

    private var outsideStack: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Outside the library")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ink.opacity(0.72))
            ForEach(store.outsideSelection) { item in
                outsidePreview(item, embedPage: store.outsideSelection.count == 1)
            }
            if store.outsideSelection.count > 1 {
                Text("Select one font to show its page here.")
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outsidePreview(_ item: OutsideFont, embedPage: Bool) -> some View {
        let match = store.face(forFamily: item.name)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(match == nil ? "Name only" : "In library")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ink.opacity(0.12), in: Capsule())
                Text(item.source)
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.72))
                Spacer()
                paperButton("Edit…", help: "Change the name, source, or link") { editingOutside = item }
                paperButton("Open", help: "Open the page in your browser") { NSWorkspace.shared.open(item.url) }
            }
            Text(item.name)
                .font(.system(size: match == nil ? 28 : 22, weight: .medium))
                .foregroundStyle(ink)
                .lineLimit(2)
            SpecimenPicture(item: item)
            if embedPage {
                let page = previewPage(for: item)
                let ready = page.path.count > 1 || store.resolvedFontPages.contains(store.fontPageKey(item))
                VStack(alignment: .leading, spacing: 6) {
                    Text(ready && page.path.count > 1 ? "Font page" : "Foundry page")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ink.opacity(0.72))
                    if ready {
                        FoundryPageView(url: page)
                            .frame(height: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ink.opacity(0.2)))
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Opening the font page…")
                                .font(.caption)
                                .foregroundStyle(ink.opacity(0.72))
                        }
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                        .task(id: store.fontPageKey(item)) {
                            await store.attachSpecimen(to: item)
                        }
                    }
                    Text("The foundry's own page for this font. The font file is not downloaded.")
                        .font(.caption)
                        .foregroundStyle(ink.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let match {
                FamilySample(face: match, text: specimenText, size: min(specimenSize, 48))
                Text("A font with this name is already in the library, so the sample uses that file.")
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.72))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func previewPage(for item: OutsideFont) -> URL {
        if !FoundryLookup.isDirectoryHost(item.url) {
            return item.url
        }
        return store.foundrySite(for: item) ?? item.url
    }

    /// Which project the shown cuts are licensed for. One field writes to every cut on screen, or to the whole family.
    private func licenseSection(_ faces: [FontFace]) -> some View {
        let targets = licenseTargets(faces)
        let projects = Set(faces.map { store.license(for: $0) })
        let shared = projects.count == 1 ? projects.first ?? "" : ""
        let mixed = projects.count > 1
        let familyCount = faces.map { store.familyFaceCount($0) }.reduce(0, +)
        return DisclosureGroup(isExpanded: $licenseOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TextField(
                        mixed ? "Different projects – type to set one for all" : "Project or client, e.g. Acme rebrand",
                        text: Binding(
                            get: { shared },
                            set: { store.setLicense($0, for: targets) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    if !store.licenseProjects.isEmpty {
                        Menu {
                            ForEach(store.licenseProjects, id: \.self) { project in
                                Button(project) { store.setLicense(project, for: targets) }
                            }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Use a project you already entered")
                    }
                    if !shared.isEmpty || mixed {
                        Button {
                            store.setLicense("", for: targets)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove the license note")
                    }
                }
                if mixed {
                    ForEach(faces) { face in
                        HStack(spacing: 6) {
                            Text("\(face.family) · \(face.style)")
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(store.license(for: face).isEmpty ? "–" : store.license(for: face))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .font(.caption)
                    }
                }
                if familyCount > faces.count {
                    Toggle("Apply to the whole family (\(familyCount) styles)", isOn: $licenseWholeFamily)
                        .font(.callout)
                        .help("Set the license for every style of the family at once")
                }
                Text("Licensed cuts appear under Licensed in the sidebar and with the Only licensed filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text("License")
                if !shared.isEmpty {
                    Text(shared)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if mixed {
                    Text("mixed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.headline)
    }

    /// The cuts a license entry applies to: the ones on screen, or every cut of their families.
    private func licenseTargets(_ faces: [FontFace]) -> [FontFace] {
        guard licenseWholeFamily else { return faces }
        let families = Set(faces.map(\.family))
        return families.flatMap { family in store.cuts(in: family).filter { $0.family == family } }
    }

    private func notesSection(_ faces: [FontFace]) -> some View {
        DisclosureGroup("Notes", isExpanded: $notesOpen) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(faces) { face in
                    noteField(face, showName: faces.count > 1)
                }
            }
            .padding(.top, 8)
        }
        .font(.headline)
    }

    private func noteField(_ face: FontFace, showName: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if showName {
                Text("\(face.family) · \(face.style)")
                    .font(.caption)
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
            ZStack {
                Circle()
                    .fill(Color(nsColor: paper))
                Circle()
                    .trim(from: 0, to: 0.5)
                    .fill(ink)
                    .rotationEffect(.degrees(45))
                Circle()
                    .stroke(Color.primary.opacity(0.35), lineWidth: 1)
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.borderless)
        .help("Paper and text colours")
        .popover(isPresented: $colorsOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Colors")
                    .font(.caption.weight(.semibold))
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

    private var previewSizeButton: some View {
        Button {
            store.previewExpanded.toggle()
        } label: {
            if store.previewExpanded {
                Label("Show library", systemImage: "arrow.down.right.and.arrow.up.left")
            } else {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
        }
        .buttonStyle(.borderless)
        .help(store.previewExpanded ? "Show the library beside the preview" : "Enlarge the preview")
    }

    private func modeSwitch(_ faces: [FontFace], labels: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(PreviewMode.allCases) { candidate in
                let active = mode == candidate
                Button {
                    select(candidate, faces: faces)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: active && candidate != .preview ? candidate.symbol + ".fill" : candidate.symbol)
                        if labels {
                            Text(candidate.title)
                        }
                    }
                    .font(.caption.weight(active ? .semibold : .regular))
                    .padding(.horizontal, labels ? 8 : 6)
                    .padding(.vertical, 4)
                    .background(active ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(candidate.help)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
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

    private func previewSlice(_ face: FontFace, placeholder: Bool, index: Int, count: Int) -> some View {
        let height = editorHeights[face.id] ?? 120
        // A variable slice stands for a whole file, so its menu switches between that file's named instances.
        let cuts = face.isVariable ? store.instances(of: face) : store.cuts(in: face.family)
        let familyShown = !face.isVariable && store.previewFaces.filter { $0.family == face.family }.count > 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(ink.opacity(0.55))
                    .help(count > 1 ? "Drag to change the order, or into the chat or a list" : "Drag this font into the chat or a list")
                Text(face.family)
                    .font(.caption2)
                    .foregroundStyle(ink.opacity(0.82))
                    .lineLimit(1)
                if familyShown {
                    // Several cuts of this family are already on screen, so each slice simply names its style.
                    Text(face.style)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ink.opacity(0.82))
                        .lineLimit(1)
                } else {
                    cutMenu(face, cuts: cuts)
                }
                if store.isLicensed(face) {
                    LicenseMark(project: store.license(for: face), tint: ink.opacity(0.7))
                }
                if face.isVariable {
                    Text("VAR")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.82))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(ink.opacity(0.1), in: Capsule())
                        .help("Variable font. Alone in the preview, its axes appear under Adjust.")
                }
                activationButton(face)
                Spacer(minLength: 0)
                playgroundButton(face)
                pinButton(face)
            }
            .font(.caption2)
            .foregroundStyle(ink.opacity(0.82))
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .contentShape(Rectangle())
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
                    textColor: nsColor(hex: foregroundHex, fallback: .black),
                    background: paper,
                    variations: facesUseAxes ? variations : [:],
                    features: featureSettings(face),
                    measuredHeight: heightBinding(face.id)
                )
                .frame(maxWidth: .infinity, minHeight: max(height, specimenSize * max(leading, 1.2) + 48), alignment: .topLeading)
                if placeholder && specimenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Type here")
                        .foregroundStyle(ink.opacity(0.4))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sends this font to the Playground as a new block, set in the current sample text.
    private func playgroundButton(_ face: FontFace) -> some View {
        Button {
            store.addToPlayground([face.identity])
        } label: {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.caption2.weight(.medium))
                .foregroundStyle(ink.opacity(0.6))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add this font to the Playground")
    }

    /// Keeps a font in the preview while the selection moves on, so other fonts can be browsed against it.
    private func pinButton(_ face: FontFace) -> some View {
        let pinned = store.isPinned(face)
        return Button {
            store.togglePin(face)
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.caption2.weight(.medium))
                .foregroundStyle(pinned ? ink : ink.opacity(0.6))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pinned ? "Pinned: stays in the preview whatever you select. Click to unpin." : "Pin this font so it stays in the preview while you look at others")
    }

    private func overlayBoard(_ faces: [FontFace]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                referenceMenu(faces)
                paperButton("X-height", help: "Shift the fonts so their x-heights meet the reference") { snapAlign(faces, metric: CTFontGetXHeight) }
                paperButton("Cap height", help: "Shift the fonts so their cap heights meet the reference") { snapAlign(faces, metric: CTFontGetCapHeight) }
                paperReset("Reset alignment") { alignShifts = [:] }
                Spacer(minLength: 0)
                playgroundMenu(faces)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(faces.enumerated()), id: \.element.id) { index, face in
                        overlayChip(face, index: index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
            }
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
                focusedID: overlayFocus,
                onShift: { id, shift in
                    alignShifts[id] = shift
                },
                onHeight: { alignCanvasHeight = $0 }
            )
            .frame(maxWidth: .infinity)
            .frame(height: alignCanvasHeight)
        }
    }

    private func alignBoard(_ faces: [FontFace]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                referenceMenu(faces)
                paperButton("X-height", help: "Shift the fonts so their x-heights meet the reference") { snapAlign(faces, metric: CTFontGetXHeight) }
                paperButton("Cap height", help: "Shift the fonts so their cap heights meet the reference") { snapAlign(faces, metric: CTFontGetCapHeight) }
                paperReset("Reset alignment") { alignShifts = [:] }
                Text("Drag a font up or down.")
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.82))
                Spacer(minLength: 0)
                playgroundMenu(faces)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
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

    /// One chip per font in Overlay: a colour dot that opens the palette, and the name, which focuses the font.
    private func overlayChip(_ face: FontFace, index: Int) -> some View {
        let focused = overlayFocus == face.id
        let color = overlayNSColor(face, index: index).withAlphaComponent(1)
        return HStack(spacing: 7) {
            Button {
                overlayColorFor = overlayColorFor == face.id ? nil : face.id
            } label: {
                Circle()
                    .fill(Color(nsColor: color))
                    .overlay(Circle().stroke(ink.opacity(0.5), lineWidth: 1))
                    .frame(width: 14, height: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Colour of this font")
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
                                    .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 1))
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .help(entry.name)
                        }
                    }
                    ColorPicker("Custom", selection: overlayColor(face, index: index), supportsOpacity: false)
                        .font(.caption)
                }
                .padding(12)
            }
            Button {
                overlayFocus = focused ? nil : face.id
            } label: {
                Text("\(face.family) \(face.style)")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Click to bring this font to the front and drag it up or down. Drag the chip into the chat or a list.")
            .draggable(FontDragItem(identities: [face.identity]))
        }
        .font(.caption.weight(focused ? .semibold : .regular))
        .foregroundStyle(ink)
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(ink.opacity(focused ? 0.16 : 0.08), in: Capsule())
        .overlay(Capsule().stroke(ink.opacity(focused ? 0.6 : 0.3), lineWidth: 1))
    }

    /// In Align and Overlay there is no slice header, so the fonts go to the Playground from here.
    private func playgroundMenu(_ faces: [FontFace]) -> some View {
        Menu {
            ForEach(faces) { face in
                Button("\(face.family) \(face.style)") { store.addToPlayground([face.identity]) }
            }
            if faces.count > 1 {
                Divider()
                Button("All \(faces.count) fonts") { store.addToPlayground(faces.map(\.identity)) }
            }
        } label: {
            Label("Playground", systemImage: "plus.rectangle.on.rectangle")
                .font(.caption.weight(.medium))
                .foregroundStyle(ink)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ink.opacity(0.45)))
        .help("Add one of these fonts, or all of them, to the Playground")
    }

    private func referenceFace(_ faces: [FontFace]) -> FontFace? {
        if let referenceID, let face = faces.first(where: { $0.id == referenceID }) {
            return face
        }
        return faces.first
    }

    private func referenceMenu(_ faces: [FontFace]) -> some View {
        let current = referenceFace(faces)
        return Menu {
            ForEach(faces) { face in
                Button {
                    referenceID = face.id
                } label: {
                    if face.id == current?.id {
                        Label("\(face.family) \(face.style)", systemImage: "checkmark")
                    } else {
                        Text("\(face.family) \(face.style)")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current.map { "From \($0.family)" } ?? "Reference")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ink.opacity(0.45)))
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 220)
        .help("The font the others line up to")
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

    private var facesUseAxes: Bool {
        store.previewFaces.count == 1
    }

    private var paper: NSColor {
        nsColor(hex: backgroundHex, fallback: .white)
    }

    private var paperIsDark: Bool {
        let color = paper.usingColorSpace(.sRGB) ?? paper
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        return luminance < 0.45
    }

    private var ink: Color {
        Color(nsColor: nsColor(hex: foregroundHex, fallback: .black))
    }

    private func heightBinding(_ id: Int64) -> Binding<CGFloat> {
        Binding(
            get: { editorHeights[id] ?? 180 },
            set: { editorHeights[id] = $0 }
        )
    }

    private func adjustControls(_ face: FontFace, showAxes: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            metricRow("Size", value: displaySize, range: sliderRange, step: sliderStep, fraction: unit == .rem ? 2 : 1, reset: { specimenSize = 48 }) {
                Picker("Unit", selection: $unitRaw) {
                    ForEach(SpecimenUnit.allCases, id: \.rawValue) { unit in
                        Text(unit.title).tag(unit.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(minWidth: 92, idealWidth: 112, maxWidth: 130)
                .help("Unit for size and line height: points, CSS pixels, or rem")
            }
            metricRow("Spacing", value: $tracking, range: -0.08...0.4, step: 0.01, fraction: 2, reset: { tracking = 0 })
            metricRow("Line height", value: displayLeading, range: leadingRange, step: sliderStep, fraction: unit == .rem ? 2 : 1, reset: { leading = 1.2 })
            if showAxes {
                HStack {
                    Text("Variable")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    resetButton("Reset variable axes") { variations = [:] }
                }
                ForEach(face.axes) { axis in
                    if axis.max > axis.min {
                        metricRow(
                            axis.name,
                            value: Binding(
                                get: { variations[axis.tag] ?? axis.defaultValue },
                                set: { variations[axis.tag] = $0 }
                            ),
                            range: axis.min...axis.max,
                            step: 1,
                            fraction: 1,
                            reset: { variations[axis.tag] = nil }
                        )
                    }
                }
            }
        }
    }

    private func metricRow<Extra: View>(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        fraction: Int,
        reset: @escaping () -> Void,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        AdjustRow(title: title, value: value, range: range, step: step, fraction: fraction, reset: reset, extra: extra)
    }

    /// Rounds a slider value to its step and keeps it inside the range.
    static func snap(_ value: Double, step: Double, range: ClosedRange<Double>) -> Double {
        guard step > 0 else { return value }
        let rounded = (value / step).rounded() * step
        return min(range.upperBound, max(range.lowerBound, rounded))
    }

    private func metricRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        fraction: Int,
        reset: @escaping () -> Void
    ) -> some View {
        metricRow(title, value: value, range: range, step: step, fraction: fraction, reset: reset) {
            EmptyView()
        }
    }

    private var colorSwatches: some View {
        HStack(spacing: 6) {
            ForEach(SpecimenSwatch.presets) { swatch in
                Button(swatch.name) {
                    backgroundHex = swatch.background
                    foregroundHex = swatch.foreground
                }
                .buttonStyle(.paper)
                .help("Paper and ink: \(swatch.name)")
            }
        }
    }

    private var colorReset: some View {
        resetButton("Reset colors") {
            backgroundHex = "F6F3EE"
            foregroundHex = "212121"
        }
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
            DisclosureGroup(isExpanded: $featuresOpen) {
                featureSwitches(face, features: features)
            } label: {
                HStack(spacing: 6) {
                    Text("OpenType features")
                    Text("\(features.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if !featureOverrides.isEmpty {
                        Text("· \(featureOverrides.count) changed")
                            .font(.caption)
                            .foregroundStyle(ink.opacity(0.8))
                    }
                }
            }
            .font(.headline)
        }
    }

    private func featureSwitches(_ face: FontFace, features: [FontFeature]) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Switches apply to the preview text. Features the font turns on by itself start on.")
                        .font(.caption2)
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
                                .font(.caption2)
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
                                    .font(.caption)
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
            .padding(.top, 8)
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
        DisclosureGroup("Characters", isExpanded: $charactersOpen) {
            if !glyphsLoaded {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 8)
            } else if glyphScalars.isEmpty {
                Text("This font has no visible characters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Character, U+00E9, 00e9, or “e acute”", text: $characterQuery)
                            .textFieldStyle(.plain)
                        if !characterQuery.isEmpty {
                            Button {
                                characterQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear the search")
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    let shown = filteredScalars
                    Text(characterCaption(shown.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let font = SpecimenFont.make(path: face.filePath, index: face.faceIndex, size: 18, variations: variations)
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
                                                .font(.caption2)
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
                .padding(.top, 8)
            }
        }
        .font(.headline)
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
        DisclosureGroup("Metadata", isExpanded: $metadataOpen) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 8) {
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
            .padding(.top, 8)
            if !face.copyright.isEmpty {
                Text(face.copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
        .font(.headline)
    }

    private func infoSection(_ face: FontFace) -> some View {
        DisclosureGroup("Info", isExpanded: $infoOpen) {
            VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(face.activation.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        face.activation.isAvailableToApps ? Color.green.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: Capsule()
                    )
                Spacer()
                if face.canActivate || face.canDeactivate {
                    Button {
                        store.toggle(face)
                    } label: {
                        Label(
                            face.canDeactivate ? "Deactivate" : "Activate",
                            systemImage: face.canDeactivate ? "minus.circle" : "checkmark.circle"
                        )
                    }
                    .buttonStyle(.paperProminent)
                    .help("Activate makes the font available to other apps; Deactivate removes it again")
                }
            }
            if store.selection.count > 1 {
                Text("\(store.selection.count) fonts selected. The toolbar acts on the whole selection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(helpText(face))
                .font(.callout)
                .foregroundStyle(ink.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        }
        .font(.headline)
    }

    private func listSection(_ face: FontFace) -> some View {
        let lists = store.lists(containing: face)
        let familyCount = store.familyFaceCount(face)
        return DisclosureGroup("Lists", isExpanded: $listsOpen) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Standard list")
                        .font(.subheadline.weight(.semibold))
                    Text("A font can belong to more than one standard list.")
                        .font(.caption)
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
                                            .font(.caption.weight(.bold))
                                    }
                                    Text(category.rawValue)
                                }
                                .font(.callout.weight(selected ? .semibold : .regular))
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
                            .font(.callout)
                            .help("File every style of the family at once")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your lists")
                        .font(.subheadline.weight(.semibold))
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
            .padding(.top, 8)
        }
        .font(.headline)
    }

    private func finderSection(_ face: FontFace) -> some View {
        Button {
            store.reveal(face)
        } label: {
            Label("Show in Finder", systemImage: "folder")
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
            set: { backgroundHex = hexString($0) }
        )
    }

    private var foregroundColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: nsColor(hex: foregroundHex, fallback: .black)) },
            set: { foregroundHex = hexString($0) }
        )
    }

    private func cutMenu(_ face: FontFace, cuts: [FontFace]) -> some View {
        // One Text only: the macOS menu button keeps just the first text of a composed label, which dropped the style name.
        let label = Text("\(face.isVariable ? "Instance" : "Cut"): \(face.style)")
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ink.opacity(0.45)))

        return Group {
            if cuts.count > 1 {
                Menu {
                    ForEach(cuts) { cut in
                        Button {
                            // Work from what is on screen: a family preview can show faces that are not selected themselves.
                            var ids = Set(store.previewFaces.map(\.id))
                            ids.remove(face.id)
                            ids.insert(cut.id)
                            store.selection = ids
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
        return Button {
            store.toggle(face)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(active ? Color.green : Color.clear)
                    .overlay(Circle().stroke(ink.opacity(0.7), lineWidth: 1))
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(active ? Color.green.opacity(0.22) : ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ink.opacity(0.45)))
        }
        .buttonStyle(.plain)
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

    private func paperReset(_ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ink)
                .padding(5)
                .background(ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ink.opacity(0.45)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func resetButton(_ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func meta(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(ink.opacity(0.72))
            Text(value.isEmpty ? "—" : value)
                .font(.body)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
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
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
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
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
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
}

private struct SpecimenSwatch: Identifiable {
    var name: String
    var background: String
    var foreground: String
    var id: String { name }

    static let presets = [
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
            for (index, face) in faces.enumerated() {
                let color = colors.isEmpty ? textColor : colors[index % colors.count]
                drawFace(face, context: context, x: 16, width: bounds.width - 24, baseline: baseline, color: color)
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
            let nameAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: face.id == reference?.id ? .semibold : .regular),
                .foregroundColor: textColor.withAlphaComponent(face.id == reference?.id ? 1 : 0.82)
            ]
            name.draw(at: CGPoint(x: column + 10, y: bounds.height - 18), withAttributes: nameAttributes)
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
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: guideColor
        ])
    }
}

private enum PreviewPanel {
    case adjust
    case info
}

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FittedPanel<Content: View>: View {
    var maxHeight: CGFloat = 300
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .scrollDisabled(height <= maxHeight)
        .frame(height: min(max(height, 1), maxHeight))
        .onPreferenceChange(PanelHeightKey.self) { height = $0 }
    }
}
