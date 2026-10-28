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

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                HStack(spacing: 5) {
                    Image(systemName: title.hasPrefix("Liste ") ? "list.bullet" : "textformat")
                        .font(.caption2.weight(.semibold))
                    Text(title.hasPrefix("Liste ") ? String(title.dropFirst("Liste ".count)) : title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.16), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1))
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
    @State private var choices: [ResearchChoice] = []
    @State private var selectionAnchor: Int64?
    @State private var attachedImage: NSImage?
    @State private var imageDrop = false
    @State private var composerHeight: CGFloat = 220
    @State private var fontDrop = false
    @State private var copiedChat = false
    @State private var lastFontDrop = Date.distantPast
    @State private var fontChips: [ChatFontChip] = []

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if store.researchMessages.isEmpty {
                                starters
                            }
                            if store.researchMessages.contains(where: { !$0.suggestions.isEmpty }) {
                                Text("Click a card to preview it. Command-click adds another font, Shift-click selects a range.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
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
        .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: $imageDrop) { providers in
            loadDroppedImage(providers)
        }
        .dropDestination(for: FontDragItem.self) { items, _ in
            acceptFontDrop(items)
            return true
        } isTargeted: { fontDrop = $0 }
        .onAppear { consumeResearchReference() }
        .onChange(of: store.researchReference) { _, _ in
            consumeResearchReference()
        }
        .overlay {
            if imageDrop || fontDrop {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if fontDrop {
                Text("Drop to add to the chat")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showModels, onDismiss: { modelLabel = ResearchSettings.label }) {
            ResearchModelSheet()
        }
        .task {
            choices = await ResearchConnection.discover()
        }
    }

    private var comparingPicture: Bool {
        store.isResearching && store.researchMessages.last?.imagePath.isEmpty == false
    }

    private var researchCard: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 10)
            Group {
                if composerOpen {
                    composer
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.primary.opacity(0.08))
                        )
                        .shadow(color: Color.black.opacity(0.16), radius: 16, y: 6)
                } else {
                    Button {
                        composerOpen = true
                    } label: {
                        Label("Research", systemImage: "bubble.left")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
                    .shadow(color: Color.black.opacity(0.16), radius: 10, y: 4)
                    .help("Show Research")
                }
            }
            .frame(maxWidth: 720)
            Spacer(minLength: 10)
        }
        .padding(.bottom, 12)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Research")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Button {
                    copyChat()
                } label: {
                    Image(systemName: copiedChat ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy this chat")
                .disabled(store.researchMessages.isEmpty)
                modelMenu
                Button {
                    composerOpen = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Hide Research")
            }
            if !fontChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
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
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button {
                        self.attachedImage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove the picture")
                    Spacer(minLength: 0)
                }
            }
            ZStack(alignment: .topLeading) {
                PromptEditor(
                    text: $draft,
                    onSubmit: send,
                    onFonts: insertReferences,
                    onFontHover: { fontDrop = $0 }
                )
                if draft.isEmpty && fontChips.isEmpty {
                    Text(attachedImage == nil ? "Ask for a typeface, or drop a font here" : "Optional note about the picture")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64, idealHeight: 96, maxHeight: 140)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(fontDrop ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: fontDrop ? 2 : 1)
            )
            .dropDestination(for: FontDragItem.self, action: { items, _ in
                acceptFontDrop(items)
                return true
            }, isTargeted: { fontDrop = $0 })
            composerActions
        }
        .padding(12)
    }

    private var composerActions: some View {
        HStack(spacing: 8) {
            Button {
                pickImage()
            } label: {
                Label("Image", systemImage: "photo")
            }
            .disabled(store.isResearching)
            .help("Find library fonts that look like a picture")
            Spacer(minLength: 8)
            Button(action: send) {
                Label("Send", systemImage: "arrow.up.circle.fill")
            }
            .disabled(store.isResearching || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fontChips.isEmpty && attachedImage == nil))
            .help("Send")
        }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(choices) { choice in
                Button(choice.title) { applyModel(choice) }
            }
            if !choices.isEmpty {
                Divider()
            }
            Button("Other model…") { showModels = true }
            Button(store.mcpEnabled ? "Your own AI (MCP on)…" : "Use with your own AI…") { showModels = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(modelLabel)
                    .lineLimit(1)
                if store.mcpEnabled {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .help("Other apps may control AllFontsO over MCP")
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 200)
        .help("Choose the model")
    }

    private func applyModel(_ choice: ResearchChoice) {
        if choice.kind == "apple" {
            ResearchSettings.useApple()
        } else {
            ResearchSettings.useCompatible(baseURL: choice.baseURL, model: choice.model, label: choice.title)
        }
        modelLabel = ResearchSettings.label
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chat about the project, or add a picture to find similar letterforms. AllFontsO only names fonts from your library.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(prompts, id: \.self) { prompt in
                Button(prompt) {
                    draft = prompt
                    send()
                }
                .buttonStyle(.bordered)
                .help("Ask this question")
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
        piece.font = .body.italic()
        return piece
    }

    @ViewBuilder
    private func messageView(_ message: ResearchMessage) -> some View {
        let isUser = message.role == "user"
        VStack(alignment: .leading, spacing: 8) {
            Text(isUser ? "You" : "Research")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let pieces = chatPieces(message.text)
            if !pieces.chips.isEmpty {
                FlowChips(titles: pieces.chips)
            }
            if !message.imagePath.isEmpty, let image = NSImage(contentsOfFile: message.imagePath) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 160, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if !pieces.rest.isEmpty {
                Text(styledResearch(pieces.rest, names: isUser ? [] : message.suggestions.map(\.family)))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.suggestions.isEmpty {
                if message.suggestions.allSatisfy({ $0.role == "preview" }) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(message.suggestions) { suggestion in
                            SuggestionCard(suggestion: suggestion, sampleSize: 28, onSelect: select)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(message.suggestions) { suggestion in
                            SuggestionCard(suggestion: suggestion, sampleSize: 22, onSelect: select)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(isUser ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
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

    private func dragIdentities(_ family: String) -> [String] {
        guard let face = store.face(forFamily: family) else { return [] }
        return [face.identity]
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
        insertReferences(items.flatMap(\.identities))
    }

    private func insertReferences(_ identities: [String]) {
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
        HStack(spacing: 5) {
            Image(systemName: title.hasPrefix("Liste ") ? "list.bullet" : "textformat")
                .font(.caption2.weight(.semibold))
            Text(title.hasPrefix("Liste ") ? String(title.dropFirst("Liste ".count)) : title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1))
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
        var onSubmit: () -> Void
        var onFonts: ([String]) -> Void
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
            textView.font = .systemFont(ofSize: 16)
            textView.drawsBackground = false
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainerInset = NSSize(width: 8, height: 10)
            textView.textContainer?.widthTracksTextView = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.unregisterDraggedTypes()
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
            if textView.string != text {
                textView.string = text
            }
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            var text: Binding<String>
            var onSubmit: () -> Void
            var onFonts: ([String]) -> Void
            var onFontHover: (Bool) -> Void

            init(
                text: Binding<String>,
                onSubmit: @escaping () -> Void,
                onFonts: @escaping ([String]) -> Void,
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

    private final class SubmitTextView: NSTextView {
        var onSubmit: (() -> Void)?
        var onFonts: (([String]) -> Void)?
        var onFontHover: ((Bool) -> Void)?

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

private struct SuggestionCard: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("fontso.sampleText") private var listSample = SpecimenText.standard
    var suggestion: ResearchSuggestion
    var sampleSize: CGFloat
    var onSelect: (FontFace) -> Void
    @State private var expanded = false

    private var face: FontFace? {
        suggestion.reason.isEmpty
            ? store.face(forFamily: suggestion.family)
            : store.face(forFamily: suggestion.family, matching: suggestion.reason)
    }

    private var cuts: [FontFace] {
        store.cuts(in: suggestion.family)
    }

    private var detail: String {
        var parts: [String] = []
        if let category = face?.category, category != .unclassified {
            parts.append(category.rawValue)
        }
        if !suggestion.reason.isEmpty {
            parts.append(suggestion.reason)
        } else if cuts.count == 1 {
            parts.append(cuts[0].style)
        } else {
            parts.append(cuts.count == 1 ? "1 style" : "\(cuts.count) styles")
        }
        return parts.joined(separator: " · ")
    }

    private var formats: String {
        let names = Array(Set(cuts.map { $0.format.uppercased() })).sorted()
        if names.count <= 1 { return names.first ?? face?.format.uppercased() ?? "" }
        if names.count <= 3 { return names.joined(separator: " · ") }
        return "Mixed"
    }

    var body: some View {
        let selected = face.map { store.selection.contains($0.id) } ?? false
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill((face?.activation.isAvailableToApps ?? false) ? Color.green : Color.clear)
                    .overlay(Circle().stroke((face?.activation.isAvailableToApps ?? false) ? Color.green : Color.secondary.opacity(0.55), lineWidth: 1))
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(suggestion.family)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let face, !listSample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        FamilySample(face: face, text: listSample, size: min(sampleSize, 16))
                    }
                }
                Spacer(minLength: 8)
                if face?.isVariable == true {
                    Text("VAR")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                Text(formats)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if cuts.count > 1 {
                Button {
                    expanded.toggle()
                } label: {
                    Label(expanded ? "Hide styles" : "Show styles", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show or hide every style of this family")
                if expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(cuts) { cut in
                            HStack {
                                Button(cut.style) { onSelect(cut) }
                                    .buttonStyle(.plain)
                                    .lineLimit(1)
                                    .help("Use this style")
                                Spacer(minLength: 8)
                                Text(cut.format.uppercased())
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 18)
                            .contextMenu { addMenu(identities: [cut.identity]) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if let face { onSelect(face) }
        }
        .draggable(FontDragItem(identities: face.map { [$0.identity] } ?? []))
        .help("Click to preview. Command-click adds another font, Shift-click selects a range.")
        .contextMenu {
            if let face {
                addMenu(identities: [face.identity])
            }
        }
    }

    @ViewBuilder
    private func addMenu(identities: [String]) -> some View {
        Menu("Add this cut") {
            if store.groups.isEmpty {
                Button("New list…") { store.showNewGroup = true }
            }
            ForEach(store.menuGroups) { group in
                Button(store.menuTitle(group)) {
                    store.addToGroup(group.id, identities: identities)
                }
            }
        }
    }
}

/// Takes the place of the chat while another program drives AllFontsO over MCP.
struct ResearchHandledByMCPView: View {
    @Environment(LibraryStore.self) private var store
    @State private var showModels = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Chat – handled by your own AI")
                .font(.title3.weight(.semibold))
            Text("MCP is on, so your own AI program drives AllFontsO. Ask it to search, show, activate, or list fonts; the results appear here in the library. Chats inside AllFontsO rest until you switch MCP off.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            if let port = store.mcpPort {
                Text(MCPSettings.endpoint(port: port))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            } else if let error = store.mcpError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button("Configuration…") { showModels = true }
                    .help("Choose the AI that answers Research")
                Button("Switch MCP off") { store.setMCPEnabled(false) }
                    .help("Stop letting other apps control AllFontsO")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showModels) {
            ResearchModelSheet()
        }
    }
}

struct ResearchModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var store
    @State private var choices: [ResearchChoice] = []
    @State private var discovered = false
    @State private var claudeModel = ResearchSettings.kind == "anthropic" && !ResearchSettings.model.isEmpty
        ? ResearchSettings.model
        : "claude-haiku-4-5"
    @State private var claudeKey = ""
    @State private var claudeWorkspace = ResearchSettings.workspaceID
    @State private var hasStoredKey = false
    @State private var customURL = "http://127.0.0.1:11434/v1"
    @State private var customModel = ""
    @State private var customKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sheetContent
            }
            .padding(20)
        }
        .frame(width: 480, height: 640)
        .task {
            hasStoredKey = !ResearchKeychain.load().isEmpty
            choices = await ResearchConnection.discover()
            discovered = true
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
            Text("Model")
                .font(.title2.weight(.semibold))
            Text("Free, on this Mac")
                .font(.headline)
            Text("These run without an account, key, or any connection. Apple Intelligence is built into macOS 26. Ollama and LM Studio are free apps that run open models locally; AllFontsO finds them when they are running.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !discovered {
                ProgressView()
            } else if choices.isEmpty {
                Text("Nothing found right now. Start Ollama or LM Studio, or turn on Apple Intelligence in System Settings.")
                    .font(.callout)
            } else {
                HStack(spacing: 8) {
                    ForEach(choices) { choice in
                        Button(choice.title) {
                            apply(choice)
                        }
                        .buttonStyle(.bordered)
                        .help("Answer with this model")
                    }
                }
            }
            HStack {
                Button("Get Ollama") { open("https://ollama.com/download") }
                    .help("Open the Ollama download page")
                Button("Get LM Studio") { open("https://lmstudio.ai") }
                    .help("Open the LM Studio website")
            }
            Divider()
            Text("Your own AI")
                .font(.headline)
            Text("Lets a program of your choice drive AllFontsO over MCP: search the library, show fonts, activate them, and fill lists. Switched off until you turn it on. AllFontsO only answers on this Mac and writes nothing into other apps; paste the configuration into your AI program yourself.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Allow other apps to control AllFontsO (MCP)", isOn: Binding(
                get: { store.mcpEnabled },
                set: { store.setMCPEnabled($0) }
            ))
            .toggleStyle(.switch)
            .help("Lets your own AI agent search and organise the library through MCP. Off by default.")
            if store.mcpEnabled {
                if let error = store.mcpError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let port = store.mcpPort {
                    mcpBlock(
                        title: "Address for programs that connect over HTTP",
                        text: MCPSettings.endpoint(port: port)
                    )
                }
                mcpBlock(
                    title: "Configuration for Claude Desktop, Cursor, and other stdio clients",
                    text: MCPSettings.stdioConfiguration()
                )
                Text("Keep AllFontsO open while your AI uses it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("Claude API")
                .font(.headline)
            Text("A Claude chat subscription does not work here. Buy API credits, create a key, and paste it below. The key starts with sk-ant- and is shown only once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Buy credits") { open("https://platform.claude.com/settings/billing") }
                    .help("Open Claude billing in the browser")
                Button("Create API key") { open("https://platform.claude.com/settings/keys") }
                    .help("Open Claude API keys in the browser")
                Button("Workspaces") { open("https://platform.claude.com/settings/workspaces") }
                    .help("Open Claude workspaces in the browser")
            }
            Picker("Model", selection: $claudeModel) {
                Text("Haiku").tag("claude-haiku-4-5")
                Text("Sonnet").tag("claude-sonnet-4-5")
            }
            .pickerStyle(.segmented)
            .help("The Claude model that answers")
            SecureField("API key", text: $claudeKey, prompt: Text("sk-ant-…"))
                .textFieldStyle(.roundedBorder)
            TextField("Workspace ID", text: $claudeWorkspace, prompt: Text("wrkspc_…"))
                .textFieldStyle(.roundedBorder)
            Text("Needed when the key is not limited to one workspace. Copy the ID from Workspaces.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Use Claude") {
                let typed = claudeKey.cleanedFontName
                if !typed.isEmpty { ResearchKeychain.save(typed) }
                let model = claudeModel.cleanedFontName.isEmpty ? "claude-haiku-4-5" : claudeModel.cleanedFontName
                ResearchSettings.useAnthropic(model: model, workspaceID: claudeWorkspace.cleanedFontName)
                dismiss()
            }
            .disabled(claudeKey.cleanedFontName.isEmpty && !hasStoredKey)
            .help("Answer Research with Claude and this key")
            Divider()
            Text("Other OpenAI-compatible server")
                .font(.headline)
            TextField("Address", text: $customURL)
                .textFieldStyle(.roundedBorder)
            TextField("Model name", text: $customModel)
                .textFieldStyle(.roundedBorder)
            SecureField("API key, if the server asks for one", text: $customKey)
                .textFieldStyle(.roundedBorder)
            Button("Use this server") {
                if !customKey.isEmpty { ResearchKeychain.save(customKey) }
                ResearchSettings.useCompatible(
                    baseURL: customURL.cleanedFontName,
                    model: customModel.cleanedFontName,
                    label: customModel.cleanedFontName.isEmpty ? customURL : customModel.cleanedFontName
                )
                dismiss()
            }
            .disabled(customURL.cleanedFontName.isEmpty || customModel.cleanedFontName.isEmpty)
            .help("Answer Research with this server")
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .help("Close the settings")
            }
    }

    private func mcpBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
            HStack(alignment: .top, spacing: 8) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .help("Copy this to the clipboard")
            }
        }
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    private func apply(_ choice: ResearchChoice) {
        if choice.kind == "apple" {
            ResearchSettings.useApple()
        } else {
            ResearchSettings.useCompatible(baseURL: choice.baseURL, model: choice.model, label: choice.title)
        }
        dismiss()
    }
}
