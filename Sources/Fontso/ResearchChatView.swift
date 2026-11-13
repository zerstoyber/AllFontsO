import AppKit
import FontsoCore
import SwiftUI
import UniformTypeIdentifiers

private struct ChatFontChip: Identifiable, Equatable {
    let id = UUID()
    var title: String
}

private struct FlowChips: View {
    var titles: [String]
    @Environment(\.surface) private var surface

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                Text(title.hasPrefix("Liste ") ? "List: " + String(title.dropFirst("Liste ".count)) : title)
                    .font(AppChrome.small)
                    .foregroundStyle(surface.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(surface.control, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(surface.stroke, lineWidth: 0.5))
            }
        }
    }
}

struct ResearchChatView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("fontso.researchPanelOpen") private var composerOpen = true
    @State private var draft = ""
    @State private var showModels = false
    @State private var modelLabel = ResearchSettings.label
    @State private var selectionAnchor: Int64?
    @State private var attachedImage: NSImage?
    @State private var imageDrop = false
    @State private var composerHeight: CGFloat = 220
    @State private var fontDrop = false
    @State private var copiedChat = false
    @State private var lastFontDrop = Date.distantPast
    @State private var fontChips: [ChatFontChip] = []
    /// The suggested families that are unfolded into their cuts, by message and family.
    @State private var openCards: Set<String> = []
    @Environment(\.surface) private var surface

    var body: some View {
        VStack(spacing: 0) {
            // The chat's own name stands in the navigation; here the pane only says what it is.
            PaneTitle(title: "Chat", detail: modelLabel) {
                Button(copiedChat ? "Copied" : "Copy") { copyChat() }
                    .buttonStyle(.chip(on: copiedChat))
                    .disabled(store.researchMessages.isEmpty)
                    .help("Copy this chat")
                modelMenu
            }
            conversation
        }
        .sheet(isPresented: $showModels, onDismiss: { modelLabel = ResearchSettings.label }) {
            ResearchModelSheet()
        }
        .task {
            // The chat answers with Apple Intelligence; a model chosen in an earlier version steps back to it.
            if ResearchSettings.kind != "apple" {
                ResearchSettings.useApple()
                modelLabel = ResearchSettings.label
            }
        }
    }

    private var conversation: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if store.researchMessages.isEmpty {
                                starters
                            }
                            if store.researchMessages.contains(where: { !$0.suggestions.isEmpty }) {
                                Text("Click a card to select it and see its Info. Command-click adds another font, Shift-click selects a range.")
                                    .font(AppChrome.small)
                                    .foregroundStyle(surface.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(store.researchMessages) { message in
                                messageView(message)
                                    .id(message.id)
                            }
                            if store.isResearching {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(comparingPicture ? "Comparing letterforms…" : "Thinking…")
                                        .foregroundStyle(surface.half)
                                }
                                .font(AppChrome.type())
                                .id("working")
                            }
                        }
                        .padding(16)
                        .padding(.bottom, composerHeight + 28)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: proxy.size.height, alignment: .topLeading)
                    }
                    .onChange(of: store.researchMessages.count) { _, _ in
                        scroll(scroller)
                    }
                    .onChange(of: store.isResearching) { _, _ in
                        scroll(scroller)
                    }
                }
                .frame(width: max(proxy.size.width, 1), height: max(proxy.size.height, 1), alignment: .topLeading)
            }
            researchCard
                .reportOverlayHeight()
        }
        .onPreferenceChange(OverlayHeightKey.self) { composerHeight = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One drop for the whole chat: a font, a family, or a list from the navigation, or a picture.
        .onDrop(of: [UTType.json, UTType.image, UTType.fileURL], isTargeted: $imageDrop) { providers in
            let fonts = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.json.identifier) }
            guard !fonts.isEmpty else { return loadDroppedImage(providers) }
            FontDragItem.load(fonts) { items in
                acceptFontDrop(items)
            }
            return true
        }
        .onAppear { consumeResearchReference() }
        .onChange(of: store.researchReference) { _, _ in
            consumeResearchReference()
        }
        .overlay {
            if imageDrop || fontDrop {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(surface.ink, lineWidth: 1)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if fontDrop || imageDrop {
                Text("Drop to add to the chat")
                    .font(AppChrome.type(12, weight: .medium))
                    .foregroundStyle(surface.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DockBackground())
                    .allowsHitTesting(false)
            }
        }
    }

    private var comparingPicture: Bool {
        store.isResearching && store.researchMessages.last?.imagePath.isEmpty == false
    }

    /// The composer floats over the chat like the dock over the preview, and folds into a chip.
    private var researchCard: some View {
        Group {
            if composerOpen {
                // As wide as a message of your own and at the right, where your messages appear.
                composer
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(DockBackground())
                    .clipShape(RoundedRectangle(cornerRadius: AppChrome.dockRadius, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                DockPill(title: "Message", help: "Show the message field") {
                    composerOpen = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !fontChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(fontChips) { chip in
                            fontChip(chip.title) {
                                fontChips.removeAll { $0.id == chip.id }
                            }
                        }
                    }
                }
            }
            if let attachedImage {
                HStack(spacing: 8) {
                    Image(nsImage: attachedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 180, maxHeight: 72)
                        .clipShape(RoundedRectangle(cornerRadius: AppChrome.cardRadius, style: .continuous))
                    Button("Remove picture") {
                        self.attachedImage = nil
                    }
                    .buttonStyle(.chip())
                    .help("Remove the picture")
                    Spacer(minLength: 0)
                }
            }
            ZStack(alignment: .topLeading) {
                PromptEditor(
                    text: $draft,
                    ink: AppChrome.inkNS,
                    onSubmit: send,
                    onFonts: acceptFontDrop,
                    onFontHover: { fontDrop = $0 }
                )
                if draft.isEmpty && fontChips.isEmpty {
                    Text(attachedImage == nil ? "Ask for a typeface, or drop a font or a list here" : "Optional note about the picture")
                        .font(AppChrome.type())
                        .foregroundStyle(surface.muted)
                        .padding(.vertical, 2)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 40, idealHeight: 56, maxHeight: 120)
            composerActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var composerActions: some View {
        HStack(spacing: 5) {
            Button("Image") {
                pickImage()
            }
            .buttonStyle(.chip(on: attachedImage != nil))
            .disabled(store.isResearching)
            .help("Find library fonts that look like a picture")
            Spacer(minLength: 8)
            Button("Hide") { composerOpen = false }
                .buttonStyle(.chip())
                .help("Fold the message field away")
            Button("Send", action: send)
                .buttonStyle(.chip(on: canSend))
                .disabled(!canSend)
                .help("Send. Return sends too; Shift-Return starts a new line.")
        }
    }

    private var canSend: Bool {
        !store.isResearching && !(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fontChips.isEmpty && attachedImage == nil)
    }

    private var modelMenu: some View {
        Button("Model") { showModels = true }
            .buttonStyle(.chip())
            .help("Now answering: \(modelLabel). Choose between Apple Intelligence and your own AI.")
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chat about the project, or add a picture to find similar letterforms. AllFontsO only names fonts from your library.")
                .font(AppChrome.type())
                .foregroundStyle(surface.half)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                ForEach(prompts, id: \.self) { prompt in
                    Button(prompt) {
                        draft = prompt
                        send()
                    }
                    .buttonStyle(.chip())
                    .help("Ask this question")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var prompts: [String] {
        [
            "A serif for a wine label",
            "Pair a headline with body text",
            "Something technical and monospaced"
        ]
    }

    /// Turns **PT Sans** into italic, and italicizes library names even when the stars are already gone.
    private func styledResearch(_ text: String, names: [String]) -> AttributedString {
        let ordered = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
            .sorted { $0.count > $1.count }
        var result = AttributedString()
        var italic = false
        var buffer = ""
        var index = text.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(italic ? emphasized(buffer) : emphasizingNames(in: buffer, names: ordered))
            buffer.removeAll(keepingCapacity: true)
        }

        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == "*", next < text.endIndex, text[next] == "*" {
                flush()
                italic.toggle()
                index = text.index(next, offsetBy: 1)
                continue
            }
            buffer.append(text[index])
            index = next
        }
        flush()
        return result
    }

    private func emphasizingNames(in text: String, names: [String]) -> AttributedString {
        guard !names.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var rest = text[...]
        while !rest.isEmpty {
            var found: Range<Substring.Index>?
            for name in names {
                guard let range = rest.range(of: name) else { continue }
                if found == nil || range.lowerBound < found!.lowerBound {
                    found = range
                }
            }
            guard let found else {
                result.append(AttributedString(String(rest)))
                break
            }
            if found.lowerBound > rest.startIndex {
                result.append(AttributedString(String(rest[..<found.lowerBound])))
            }
            result.append(emphasized(String(rest[found])))
            rest = rest[found.upperBound...]
        }
        return result
    }

    private func emphasized(_ text: String) -> AttributedString {
        var piece = AttributedString(text)
        piece.font = AppChrome.type().italic()
        return piece
    }

    /// Your own messages sit on a grey field at the right; the answers run plain across the column.
    @ViewBuilder
    private func messageView(_ message: ResearchMessage) -> some View {
        let isUser = message.role == "user"
        let pieces = chatPieces(message.text)
        let content = VStack(alignment: .leading, spacing: 6) {
            Text(isUser ? "You" : "AllFontsO")
                .font(AppChrome.small)
                .foregroundStyle(surface.half)
            if !pieces.chips.isEmpty {
                FlowChips(titles: pieces.chips)
            }
            if !message.imagePath.isEmpty, let image = NSImage(contentsOfFile: message.imagePath) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 160, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: AppChrome.cardRadius, style: .continuous))
            }
            if !pieces.rest.isEmpty {
                Text(styledResearch(pieces.rest, names: isUser ? [] : message.suggestions.map(\.family)))
                    .font(AppChrome.type())
                    .foregroundStyle(surface.ink)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
            }
            if !message.suggestions.isEmpty {
                // One card per family, as in the preview: side by side for the fonts you asked about, stacked otherwise.
                if message.suggestions.allSatisfy({ $0.role == "preview" }) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(message.suggestions) { suggestion in
                            fontCard(suggestion, in: message)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(message.suggestions) { suggestion in
                            fontCard(suggestion, in: message)
                        }
                    }
                }
            }
        }
        if isUser {
            HStack(spacing: 0) {
                Spacer(minLength: 80)
                content
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(surface.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fontCard(_ suggestion: ResearchSuggestion, in message: ResearchMessage) -> some View {
        let key = "\(message.id)|\(suggestion.id)"
        return ChatFontCard(
            suggestion: suggestion,
            open: openCards.contains(key),
            onToggle: { openCards.formSymmetricDifference([key]) },
            onSelect: select
        )
    }

    private var suggestionFaces: [FontFace] {
        var seen = Set<Int64>()
        var faces: [FontFace] = []
        for message in store.researchMessages {
            for suggestion in message.suggestions {
                let face = suggestion.reason.isEmpty
                    ? store.face(forFamily: suggestion.family)
                    : store.face(forFamily: suggestion.family, matching: suggestion.reason)
                guard let face, seen.insert(face.id).inserted else { continue }
                faces.append(face)
            }
        }
        return faces
    }

    private func select(_ face: FontFace) {
        let flags = NSEvent.modifierFlags
        let order = suggestionFaces
        if flags.contains(.shift),
           let anchor = selectionAnchor,
           let from = order.firstIndex(where: { $0.id == anchor }),
           let to = order.firstIndex(where: { $0.id == face.id }) {
            let ids = Set(order[min(from, to)...max(from, to)].map(\.id))
            store.selection = flags.contains(.command) ? store.selection.union(ids) : ids
        } else if flags.contains(.command) {
            if store.selection.contains(face.id) {
                store.selection.remove(face.id)
            } else {
                store.selection.insert(face.id)
            }
            selectionAnchor = face.id
        } else {
            store.selection = [face.id]
            selectionAnchor = face.id
        }
    }

    private func copyChat() {
        var blocks = ["Model: \(modelLabel)"]
        for message in store.researchMessages {
            let who = message.role == "user" ? "You" : "Research"
            let pieces = chatPieces(message.text)
            let spoken = pieces.chips.isEmpty ? message.text : (pieces.chips + [pieces.rest]).filter { !$0.isEmpty }.joined(separator: "\n")
            var block = "\(who)\n\(spoken)"
            if !message.imagePath.isEmpty {
                block += "\n[picture]"
            }
            if !message.suggestions.isEmpty {
                let cards = message.suggestions.map { suggestion -> String in
                    let formats = Array(Set(
                        store.fonts
                            .filter { $0.family.caseInsensitiveCompare(suggestion.family) == .orderedSame }
                            .map { $0.format.uppercased() }
                    )).sorted()
                    let format = formats.isEmpty ? "not in library" : formats.joined(separator: ", ")
                    let detail = suggestion.reason.isEmpty ? "" : " — \(suggestion.reason)"
                    return "- \(suggestion.family) (\(format))\(detail)"
                }
                block += "\nCards:\n" + cards.joined(separator: "\n")
            }
            blocks.append(block)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(blocks.joined(separator: "\n\n"), forType: .string)
        copiedChat = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copiedChat = false
        }
    }

    private func consumeResearchReference() {
        let phrase = store.researchReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        store.researchReference = ""
        addChips(phrase)
        composerOpen = true
    }

    private func acceptFontDrop(_ items: [FontDragItem]) {
        let lists = items.map(\.listName).filter { !$0.isEmpty }
        if !lists.isEmpty {
            let now = Date()
            guard now.timeIntervalSince(lastFontDrop) > 0.3 else { return }
            lastFontDrop = now
            for name in lists {
                addChips("Liste \(name)")
            }
            composerOpen = true
            store.statusText = "\(lists.joined(separator: ", ")) added to the chat."
            fontDrop = false
            return
        }
        // A name from the news has no file; it goes in by its name.
        let outside = items.map(\.outsideName).filter { !$0.isEmpty }
        if !outside.isEmpty {
            addChips(outside.joined(separator: ", "))
            composerOpen = true
            fontDrop = false
        }
        insertReferences(items.flatMap(\.identities))
    }

    private func insertReferences(_ identities: [String]) {
        guard !identities.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFontDrop) > 0.3 else { return }
        lastFontDrop = now
        let phrase = store.researchPhrase(for: identities)
        guard !phrase.isEmpty else { return }
        addChips(phrase)
        composerOpen = true
        store.statusText = "\(phrase) added to the chat."
        fontDrop = false
    }

    private func addChips(_ phrase: String) {
        let titles = phrase.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for title in titles where !fontChips.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            fontChips.append(ChatFontChip(title: title))
        }
    }

    private func send() {
        let names = fontChips.map { "«\($0.title)»" }.joined(separator: " ")
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = [names, typed].filter { !$0.isEmpty }.joined(separator: "\n")
        let image = attachedImage
        guard !text.isEmpty || image != nil else { return }
        draft = ""
        fontChips = []
        attachedImage = nil
        let path = image.flatMap { store.storeResearchImage($0) } ?? ""
        store.sendResearch(text, imagePath: path)
    }

    private func fontChip(_ title: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title.hasPrefix("Liste ") ? "List: " + String(title.dropFirst("Liste ".count)) : title)
                .font(AppChrome.small)
                .foregroundStyle(surface.ink)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(surface.half)
                    .frame(width: 10, height: 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 2.5)
        .background(surface.control, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(surface.stroke, lineWidth: 0.5))
        .help(title)
    }

    private func chatPieces(_ text: String) -> (chips: [String], rest: String) {
        var chips: [String] = []
        var rest = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "«", let close = text[text.index(after: index)...].firstIndex(of: "»") {
                let name = text[text.index(after: index)..<close].trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { chips.append(name) }
                index = text.index(after: close)
                continue
            }
            rest.append(text[index])
            index = text.index(after: index)
        }
        return (chips, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add"
        panel.message = "Choose a picture. AllFontsO looks for library fonts with similar letterforms."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        attachedImage = image
    }

    private func loadDroppedImage(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async { attachedImage = image }
            }
            return true
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url = item as? URL ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            guard let url, let image = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async { attachedImage = image }
        }
        return true
    }

    private struct PromptEditor: NSViewRepresentable {
        @Binding var text: String
        var ink: NSColor
        var onSubmit: () -> Void
        var onFonts: ([FontDragItem]) -> Void
        var onFontHover: (Bool) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(text: $text, onSubmit: onSubmit, onFonts: onFonts, onFontHover: onFontHover)
        }

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            let textView = SubmitTextView()
            textView.isRichText = false
            textView.importsGraphics = false
            textView.font = AppChrome.nsFont(13)
            textView.textColor = ink
            textView.insertionPointColor = ink
            textView.drawsBackground = false
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainerInset = NSSize(width: 0, height: 2)
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.widthTracksTextView = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.delegate = context.coordinator
            textView.onSubmit = onSubmit
            textView.onFonts = onFonts
            textView.onFontHover = onFontHover
            textView.string = text
            scroll.documentView = textView
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            context.coordinator.onSubmit = onSubmit
            guard let textView = scroll.documentView as? SubmitTextView else { return }
            textView.onSubmit = onSubmit
            textView.onFonts = onFonts
            textView.onFontHover = onFontHover
            if textView.textColor != ink {
                textView.textColor = ink
                textView.insertionPointColor = ink
            }
            if textView.string != text {
                textView.string = text
            }
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            var text: Binding<String>
            var onSubmit: () -> Void
            var onFonts: ([FontDragItem]) -> Void
            var onFontHover: (Bool) -> Void

            init(
                text: Binding<String>,
                onSubmit: @escaping () -> Void,
                onFonts: @escaping ([FontDragItem]) -> Void,
                onFontHover: @escaping (Bool) -> Void
            ) {
                self.text = text
                self.onSubmit = onSubmit
                self.onFonts = onFonts
                self.onFontHover = onFontHover
            }

            func textDidChange(_ notification: Notification) {
                guard let view = notification.object as? NSTextView else { return }
                text.wrappedValue = view.string
            }
        }
    }

    /// The message field. It takes fonts and lists dragged from the navigation itself, as chips above the text;
    /// a text view left to its own drag types would swallow them.
    private final class SubmitTextView: NSTextView {
        var onSubmit: (() -> Void)?
        var onFonts: (([FontDragItem]) -> Void)?
        var onFontHover: ((Bool) -> Void)?
        private static let fontType = NSPasteboard.PasteboardType("public.json")

        override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [SubmitTextView.fontType] }

        override func updateDragTypeRegistration() {
            unregisterDraggedTypes()
            registerForDraggedTypes([SubmitTextView.fontType])
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateDragTypeRegistration()
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            onFontHover?(true)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onFontHover?(false)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onFontHover?(false)
            let decoder = JSONDecoder()
            let items = (sender.draggingPasteboard.pasteboardItems ?? []).compactMap { entry in
                entry.data(forType: SubmitTextView.fontType).flatMap { try? decoder.decode(FontDragItem.self, from: $0) }
            }
            guard !items.isEmpty else { return false }
            onFonts?(items)
            return true
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {}

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            if isReturn && !event.modifierFlags.contains(.shift) {
                onSubmit?()
                return
            }
            super.keyDown(with: event)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        if store.isResearching {
            proxy.scrollTo("working", anchor: .bottom)
        } else if let last = store.researchMessages.last?.id {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}

/// One suggested family in the chat, built like a card of the preview: a header with the name and the buttons,
/// then the sample text. A family with several cuts unfolds into one slice per cut.
private struct ChatFontCard: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.surface) private var surface
    @AppStorage("fontso.sampleText") private var sample = SpecimenText.standard
    @AppStorage("fontso.specimenSize") private var specimenSize = 48.0
    @AppStorage("fontso.specimen.tracking") private var tracking = 0.0
    var suggestion: ResearchSuggestion
    var open: Bool
    var onToggle: () -> Void
    var onSelect: (FontFace) -> Void

    /// The cut the answer means: the one its note names, else the family's regular.
    private var lead: FontFace? {
        suggestion.reason.isEmpty
            ? store.face(forFamily: suggestion.family)
            : store.face(forFamily: suggestion.family, matching: suggestion.reason)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppChrome.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if let lead {
                let cuts = store.cuts(in: lead.family)
                let family = cuts.contains(where: { $0.id == lead.id }) ? cuts : [lead]
                let folded = family.count > 1 && !open
                ForEach(Array((folded ? [lead] : family).enumerated()), id: \.element.id) { index, cut in
                    if index > 0 {
                        Rectangle().fill(surface.stroke).frame(height: 0.5)
                    }
                    slice(cut, family: family, folded: folded, leads: index == 0)
                }
            } else {
                missing
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(shape)
        .overlay(shape.stroke(surface.stroke, lineWidth: 0.5))
    }

    /// A name the answer gave that the library does not hold.
    private var missing: some View {
        HStack(spacing: 6) {
            Text(suggestion.family)
                .font(AppChrome.type(AppChrome.smallSize + 1, weight: .medium))
                .foregroundStyle(surface.ink)
                .lineLimit(1)
            Text("Not in your library")
                .font(AppChrome.small)
                .foregroundStyle(surface.half)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func slice(_ face: FontFace, family: [FontFace], folded: Bool, leads: Bool) -> some View {
        let selected = store.selection.contains(face.id)
        let note = suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if family.count > 1 {
                    if leads {
                        Button(action: onToggle) {
                            ChromeChevron(open: open, color: surface.ink)
                        }
                        .buttonStyle(.plain)
                        .help(open ? "Fold \(face.family) to one sample" : "Show all \(family.count) styles of \(face.family)")
                    } else {
                        Color.clear.frame(width: 10, height: 12)
                    }
                }
                Text(face.family)
                    .font(AppChrome.type(AppChrome.smallSize + 1, weight: .medium))
                    .foregroundStyle(surface.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(folded ? foldedLabel(face, styles: family.count) : "\(face.style), \(face.format.uppercased())")
                    .font(AppChrome.small)
                    .foregroundStyle(surface.half)
                    .lineLimit(1)
                if leads, !note.isEmpty, note.caseInsensitiveCompare(face.style) != .orderedSame {
                    Text(note)
                        .font(AppChrome.small)
                        .foregroundStyle(surface.muted)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                if face.isVariable {
                    Text("VAR")
                        .font(AppChrome.type(9, weight: .medium))
                        .foregroundStyle(surface.ink.opacity(0.7))
                        .help("Variable font")
                }
                Spacer(minLength: 8)
                Button("Info") {
                    onSelect(face)
                    store.infoPanelOpen = true
                }
                .buttonStyle(.chip(on: selected))
                .help(selected ? "Selected: its Info shows under the navigation" : "Select this cut and show its Info under the navigation")
                if folded {
                    activateAllButton(family)
                    pinAllButton(family)
                } else {
                    activationButton(face)
                    IconChip(symbol: "plus.rectangle.on.rectangle", help: "To Playground: add this font as a new text block") {
                        store.addToPlayground([face.identity])
                    }
                    IconChip(
                        symbol: store.isPinned(face) ? "pin.fill" : "pin",
                        on: store.isPinned(face),
                        help: store.isPinned(face) ? "Pinned for Compare, Shape, and Playground. Click to unpin." : "Pin this font for Compare, Shape, and Playground"
                    ) {
                        store.togglePin(face)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 2)
            sampleText(face)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Rectangle().fill(selected ? surface.selection : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(face) }
        .draggable(FontDragItem(identities: folded ? family.map(\.identity) : [face.identity]))
        .help("Click to select it and see its Info. Command-click adds another font, Shift-click selects a range. Drag it onto a list, Pinned, or a mode of the preview.")
        .contextMenu {
            Menu(folded ? "Add this family to list" : "Add this cut to list") {
                if store.groups.isEmpty {
                    Button("New list…") { store.showNewGroup = true }
                }
                ForEach(store.menuGroups) { group in
                    Button(store.menuTitle(group)) {
                        store.addToGroup(group.id, identities: folded ? family.map(\.identity) : [face.identity])
                    }
                }
            }
        }
    }

    /// The sample text of the preview, in this cut. It follows the text and spacing set there, at a size that
    /// lets several cards share the chat.
    @ViewBuilder
    private func sampleText(_ face: FontFace) -> some View {
        let size = min(max(specimenSize, 14), 32)
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty,
           let font = SpecimenFont.make(path: face.filePath, index: face.faceIndex, size: size, variations: store.axisValues[face.id] ?? [:]) {
            Text(text)
                .font(Font(font as CTFont))
                .tracking(tracking * size)
                .foregroundStyle(surface.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 12)
        } else {
            Color.clear.frame(height: 6)
        }
    }

    private func foldedLabel(_ face: FontFace, styles: Int) -> String {
        let category = face.category == .unclassified ? "" : "\(face.category.rawValue), "
        return "\(category)\(styles) Styles"
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
}

/// Takes the place of the chat while another program drives AllFontsO over MCP.
struct ResearchHandledByMCPView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.surface) private var surface
    @State private var showModels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your own AI answers")
                .font(AppChrome.type(12, weight: .medium))
                .foregroundStyle(surface.ink)
            Text("Your own AI program drives AllFontsO over MCP. Ask it to search, show, activate, or list fonts; the results appear here in the library. The chats inside AllFontsO rest until you go back to Apple Intelligence.")
                .font(AppChrome.type())
                .foregroundStyle(surface.half)
                .fixedSize(horizontal: false, vertical: true)
            if let error = store.mcpError {
                Text(error)
                    .font(AppChrome.type())
                    .foregroundStyle(surface.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let port = store.mcpPort {
                Text(MCPSettings.endpoint(port: port))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(surface.half)
                    .textSelection(.enabled)
            }
            HStack(spacing: 5) {
                Button("Model") { showModels = true }
                    .help("See how to connect your AI program, or choose Apple Intelligence")
                Button("Back to Apple Intelligence") { store.setMCPEnabled(false) }
                    .help("Stop letting other programs drive AllFontsO and chat inside AllFontsO again")
            }
            .buttonStyle(.chip())
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: 480, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showModels) {
            ResearchModelSheet()
        }
    }
}

/// Who answers: Apple Intelligence inside AllFontsO, or a program of your own that drives AllFontsO over MCP.
/// The one chosen is a filled button; the sheet keeps the colours of the theme.
struct ResearchModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var store
    @State private var copied = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model")
                .font(AppChrome.type(13, weight: .medium))
                .foregroundStyle(AppChrome.ink)
                .padding(.bottom, 2)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("Answers")
                    .foregroundStyle(AppChrome.half)
                    .frame(width: 78, alignment: .leading)
                choice("Apple Intelligence", on: !store.mcpEnabled, help: "Chat inside AllFontsO, answered on this Mac") {
                    ResearchSettings.useApple()
                    store.setMCPEnabled(false)
                }
                choice("Your own AI", on: store.mcpEnabled, help: "Let a program of your own, such as Claude Desktop, drive AllFontsO over MCP") {
                    store.setMCPEnabled(true)
                }
                Spacer(minLength: 0)
            }
            if store.mcpEnabled {
                ownAI
            } else {
                appleIntelligence
            }
            Rectangle()
                .fill(AppChrome.hairline)
                .frame(height: 0.5)
                .padding(.top, 2)
            HStack(spacing: 6) {
                Text(store.mcpEnabled ? "Your own AI, over MCP" : "Apple Intelligence, on this Mac")
                    .font(AppChrome.small)
                    .foregroundStyle(AppChrome.half)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Done") { dismiss() }
                    .buttonStyle(.paperProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Close")
            }
        }
        .font(AppChrome.type(11))
        .padding(18)
        .frame(width: 470)
        .modifier(ChromeSheet())
    }

    @ViewBuilder
    private var appleIntelligence: some View {
        note("The chat inside AllFontsO is answered by Apple Intelligence, on this Mac. It needs no account and no key, and nothing leaves the Mac.")
        if let reason = ResearchAssistant.unavailableReason() {
            Text(reason)
                .foregroundStyle(AppChrome.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 83)
        }
    }

    @ViewBuilder
    private var ownAI: some View {
        note("A program of your own drives AllFontsO over MCP: it searches the library, shows fonts, activates them, and fills lists. AllFontsO answers only on this Mac and writes nothing into other programs. Meanwhile the chats inside AllFontsO rest.")
        if let error = store.mcpError {
            Text(error)
                .foregroundStyle(AppChrome.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 83)
        } else {
            block(
                "Claude Desktop",
                detail: "Also with the free plan. In Claude Desktop open Settings › Developer › Edit Config, paste this into the file, and start Claude again. A file that already lists servers takes the allfontso entry beside them.",
                text: MCPSettings.stdioConfiguration()
            )
            if let port = store.mcpPort {
                block(
                    "By address",
                    detail: "For programs on this Mac that connect to an MCP address.",
                    text: MCPSettings.endpoint(port: port)
                )
            }
            note("Keep AllFontsO open while your AI uses it.")
        }
    }

    private func choice(_ title: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(PaperButtonStyle(prominent: on))
            .help(help)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(AppChrome.small)
            .foregroundStyle(AppChrome.half)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 83)
    }

    /// A piece of configuration to copy: what it is for at the left, the text itself on a grey field.
    private func block(_ title: String, detail: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title)
                .foregroundStyle(AppChrome.half)
                .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(detail)
                    .font(AppChrome.small)
                    .foregroundStyle(AppChrome.half)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AppChrome.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
                    .background(AppChrome.control, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(AppChrome.ink.opacity(0.22), lineWidth: 0.5))
                Button(copied == text ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = text
                }
                .buttonStyle(.paper)
                .help("Copy this to the clipboard")
            }
        }
    }
}
