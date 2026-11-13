import AppKit
import FontsoCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Asks the open Playground to export its page; the object is "pdf" or "png".
    static let fontsoPlaygroundExport = Notification.Name("fontso.playgroundExport")
    /// The three dots of the pinned fonts in Shape › Mix: the mix on show becomes a block in the Playground.
    static let fontsoMixToPlayground = Notification.Name("fontso.mixToPlayground")
}

/// One text block in the Playground: its own font, size, tracking, leading, and padding.
struct PlaygroundBlock: Codable, Identifiable, Hashable {
    var id = UUID()
    var text = ""
    var fontIdentity = ""
    var size = 32.0
    /// Tracking in em, applied as size × tracking.
    var tracking = 0.0
    var leading = 1.2
    /// Space around the block, in points, each side on its own.
    var padTop = 24.0
    var padBottom = 24.0
    var padLeft = 24.0
    var padRight = 24.0
    /// A mix from the preview: the cut of each letter. Letters without an entry use `fontIdentity`.
    var letters: [MixLetter] = []

    var isMix: Bool { !letters.isEmpty }

    init(id: UUID = UUID(), text: String = "", fontIdentity: String = "", size: Double = 32, tracking: Double = 0, leading: Double = 1.2, padding: Double = 24) {
        self.id = id
        self.text = text
        self.fontIdentity = fontIdentity
        self.size = size
        self.tracking = tracking
        self.leading = leading
        padTop = padding
        padBottom = padding
        padLeft = padding
        padRight = padding
    }

    var insets: EdgeInsets {
        EdgeInsets(top: padTop, leading: padLeft, bottom: padBottom, trailing: padRight)
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, fontIdentity, size, tracking, leading, padding, padTop, padBottom, padLeft, padRight, letters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        fontIdentity = try container.decodeIfPresent(String.self, forKey: .fontIdentity) ?? ""
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? 32
        tracking = try container.decodeIfPresent(Double.self, forKey: .tracking) ?? 0
        leading = try container.decodeIfPresent(Double.self, forKey: .leading) ?? 1.2
        // Older files had one padding for all sides.
        let shared = try container.decodeIfPresent(Double.self, forKey: .padding) ?? 24
        padTop = try container.decodeIfPresent(Double.self, forKey: .padTop) ?? shared
        padBottom = try container.decodeIfPresent(Double.self, forKey: .padBottom) ?? shared
        padLeft = try container.decodeIfPresent(Double.self, forKey: .padLeft) ?? shared
        padRight = try container.decodeIfPresent(Double.self, forKey: .padRight) ?? shared
        letters = try container.decodeIfPresent([MixLetter].self, forKey: .letters) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(fontIdentity, forKey: .fontIdentity)
        try container.encode(size, forKey: .size)
        try container.encode(tracking, forKey: .tracking)
        try container.encode(leading, forKey: .leading)
        try container.encode(padTop, forKey: .padTop)
        try container.encode(padBottom, forKey: .padBottom)
        try container.encode(padLeft, forKey: .padLeft)
        try container.encode(padRight, forKey: .padRight)
        if !letters.isEmpty {
            try container.encode(letters, forKey: .letters)
        }
    }

    /// The cut of every letter by its UTF-16 offset, with `fontIdentity` for letters the mix leaves open.
    var letterFonts: [Int: String] {
        Dictionary(letters.map { ($0.at, $0.font) }, uniquingKeysWith: { _, last in last })
    }

    /// Keeps the mix in step with an edit: letters after it move along, typed letters take the cut of the letter before.
    /// Called before the edit lands, so `text` is still the old text.
    mutating func shiftLetters(replacing range: NSRange, with length: Int) {
        guard isMix else { return }
        let before = letterFonts
        var next = MixText.shift(before, replacing: range, with: length)
        let string = text as NSString
        if length > 0 {
            var neighbour: Int?
            if range.location > 0, range.location <= string.length {
                neighbour = string.rangeOfComposedCharacterSequence(at: range.location - 1).location
            } else if NSMaxRange(range) < string.length {
                neighbour = NSMaxRange(range)
            }
            if let neighbour, let inherited = before[neighbour], inherited != fontIdentity {
                for offset in range.location..<(range.location + length) {
                    next[offset] = inherited
                }
            }
        }
        setLetterFonts(next)
    }

    /// Gives letters their own cut, or hands them back to the block's font with nil.
    mutating func setFont(_ identity: String?, forLettersIn ranges: [NSRange]) {
        var next = letterFonts
        for range in ranges {
            next[range.location] = identity == fontIdentity ? nil : identity
        }
        setLetterFonts(next)
    }

    private mutating func setLetterFonts(_ fonts: [Int: String]) {
        letters = fonts.map { MixLetter(at: $0.key, font: $0.value) }.sorted { $0.at < $1.at }
    }
}

/// The Playground's blocks, kept in Application Support/Fontso/playground.json.
@MainActor
final class PlaygroundDocument: ObservableObject {
    /// One page for the whole app, so a font can be sent here from the preview or a list.
    static let shared = PlaygroundDocument()

    @Published var blocks: [PlaygroundBlock] {
        didSet { save() }
    }

    init() {
        blocks = PlaygroundDocument.load()
    }

    /// Appends one block per font, set in the Playground's last size and padding. Returns how many were added.
    @discardableResult
    func add(identities: [String], text: String) -> Int {
        var added = 0
        for identity in identities where !identity.isEmpty {
            var block = PlaygroundBlock(text: text)
            block.fontIdentity = identity
            if let last = blocks.last {
                block.size = last.size
                block.leading = last.leading
                block.padTop = last.padTop
                block.padBottom = last.padBottom
                block.padLeft = last.padLeft
                block.padRight = last.padRight
            }
            blocks.append(block)
            added += 1
        }
        return added
    }

    /// Appends a mix from the preview as one block, keeping the cut of every letter.
    func addMix(text: String, letters: [MixLetter], size: Double, tracking: Double, leading: Double) {
        var block = PlaygroundBlock(text: text, size: size, tracking: tracking, leading: leading)
        block.fontIdentity = letters.first?.font ?? ""
        block.letters = letters
        if let last = blocks.last {
            block.padTop = last.padTop
            block.padBottom = last.padBottom
            block.padLeft = last.padLeft
            block.padRight = last.padRight
        }
        blocks.append(block)
    }

    /// Runs a change to the page and records it for Undo. Typing is undone by the text view on the same stack.
    func change(_ undoManager: UndoManager?, _ name: String, _ body: () -> Void) {
        let before = blocks
        body()
        registerUndo(from: before, undoManager, name)
    }

    private func registerUndo(from before: [PlaygroundBlock], _ undoManager: UndoManager?, _ name: String) {
        guard let undoManager, before != blocks else { return }
        undoManager.registerUndo(withTarget: self) { document in
            let now = document.blocks
            document.blocks = before
            document.registerUndo(from: now, undoManager, name)
        }
        undoManager.setActionName(name)
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fontso", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("playground.json")
    }

    private static func load() -> [PlaygroundBlock] {
        guard let data = try? Data(contentsOf: fileURL),
              let blocks = try? JSONDecoder().decode([PlaygroundBlock].self, from: data), !blocks.isEmpty else {
            return [
                PlaygroundBlock(text: "Headline in one typeface", size: 56, leading: 1.05),
                PlaygroundBlock(text: "Body copy in another. Mix the two, change sizes and spacing, and see how they sit together on the page.", size: 18, leading: 1.45),
            ]
        }
        return blocks
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(blocks) else { return }
        try? data.write(to: PlaygroundDocument.fileURL, options: .atomic)
    }
}

/// A quiet page of text blocks for trying fonts together. The controls for a block appear when the pointer rests on it.
struct PlaygroundView: View {
    @Environment(LibraryStore.self) private var store
    @ObservedObject private var document = PlaygroundDocument.shared
    @ObservedObject private var theme = PaperSettings.shared
    @AppStorage("fontso.playground.dockOpen") private var dockOpen = true
    /// The pinned fonts large across the dock. Preview and Playground share the choice.
    @AppStorage("fontso.pinned.large.dock") private var dockPinnedLarge = false
    /// The block the dock adjusts: the one last clicked into.
    @State private var activeBlock: UUID?
    @State private var heights: [UUID: CGFloat] = [:]
    @State private var settingsFor: UUID?
    @State private var pageWidth: CGFloat = 600
    @State private var exportOpen = false
    @State private var dockHeight: CGFloat = 60
    /// The letters selected in each block, for giving them a cut of their own.
    @State private var selections: [UUID: NSRange] = [:]
    @Environment(\.undoManager) private var undoManager
    @AppStorage("fontso.specimen.unit") private var unitRaw = SpecimenUnit.point.rawValue

    private var unit: SpecimenUnit { SpecimenUnit(rawValue: unitRaw) ?? .point }

    var body: some View {
        ZStack(alignment: .bottom) {
            page
            // Floats over the page like the dock in the other modes.
            Group {
                if dockOpen {
                    dock
                } else {
                    DockPill(title: "Adjust · Padding · Cuts", help: "Show Adjust, Padding, and the cuts on the page") {
                        dockOpen = true
                    }
                }
            }
            .padding(.horizontal, AppChrome.dockInset)
            .padding(.bottom, 12)
            .reportOverlayHeight()
        }
        .onPreferenceChange(OverlayHeightKey.self) { dockHeight = $0 }
        // A font dropped beside the blocks becomes a new block; dropped on a block it sets that block's font.
        .dropDestination(for: FontDragItem.self) { items, _ in
            let valid = items.flatMap(\.identities).filter { store.hasFace(identity: $0) }
            guard !valid.isEmpty else { return false }
            store.addToPlayground(valid)
            return true
        }
        // A new font for the block the cursor is in shows in Info straight away.
        .onChange(of: activeFont) { old, new in
            guard let old, let new, old.block == new.block, old.font != new.font,
                  let block = document.blocks.first(where: { $0.id == new.block }) else { return }
            showInfo(block)
        }
    }

    private struct ActiveFont: Equatable {
        var block: UUID
        var font: String
    }

    /// The block clicked into and the font it is set in.
    private var activeFont: ActiveFont? {
        guard let activeBlock, let block = document.blocks.first(where: { $0.id == activeBlock }) else { return nil }
        return ActiveFont(block: block.id, font: block.fontIdentity)
    }

    /// The index of the block the dock adjusts: the one clicked. A page with a single block needs no click.
    private var activeIndex: Int? {
        if let activeBlock, let index = document.blocks.firstIndex(where: { $0.id == activeBlock }) { return index }
        return document.blocks.count == 1 ? 0 : nil
    }

    /// Info under the navigation follows the Playground: the cut of the block the cursor is in, or of the letter
    /// right at the cursor when the block mixes cuts.
    private func showInfo(_ block: PlaygroundBlock, at location: Int? = nil) {
        var identity = block.fontIdentity
        if let location, block.isMix {
            let length = (block.text as NSString).length
            let offset = min(max(location, 0), max(length - 1, 0))
            identity = block.letterFonts[offset] ?? block.fontIdentity
        }
        guard let face = face(for: identity), store.selection != [face.id] else { return }
        store.selection = [face.id]
        store.outsideSelection = []
    }

    /// A binding that finds its block by id, so it stays valid while blocks are moved or removed.
    private func blockBinding(_ block: PlaygroundBlock) -> Binding<PlaygroundBlock> {
        let id = block.id
        return Binding(
            get: { document.blocks.first { $0.id == id } ?? block },
            set: { value in
                if let index = document.blocks.firstIndex(where: { $0.id == id }) {
                    document.blocks[index] = value
                }
            }
        )
    }

    /// Adjust and Padding for the block last clicked into, then the cuts on the page and the pinned fonts.
    private var dock: some View {
        let used = usedFaces
        let pinnedNote = "Pin fonts in Preview, then drag them from here onto a block or a letter."
        return ChromeDock(
            hideHelp: "Hide Adjust, Padding, and the cuts",
            onHide: { dockOpen = false },
            above: dockPinnedLarge ? AnyView(DockPinnedBoard(large: $dockPinnedLarge, emptyNote: pinnedNote)) : nil
        ) {
            if let index = activeIndex {
                let block = blockBinding(document.blocks[index])
                DockSection("Adjust", key: "playground.adjust", detail: blockTitle(block.wrappedValue, face: face(for: block.wrappedValue.fontIdentity))) {
                    UnitSegments()
                } content: {
                    adjustRows(block)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DockSection("Padding", key: "playground.padding", startsOpen: false) {
                    paddingRows(block)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                DockSection("Adjust", key: "playground.adjust") {
                    Text("Click a block to adjust its size, tracking, leading, and padding.")
                        .font(AppChrome.small)
                        .foregroundStyle(ink.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            DockSection("Used cuts", key: "playground.used", detail: "\(used.count)", minWidth: 200) {
                CutStrip(
                    faces: used,
                    emptyNote: "Every cut on the page shows here, whole blocks and single letters."
                )
            }
            if !dockPinnedLarge {
                DockSection("Pinned", key: "playground.pinned", detail: "\(store.pinnedFaces.count)", minWidth: 200, startsOpen: false, onFonts: { store.addToPreview($0) }) {
                    PinnedSizeChip(large: $dockPinnedLarge)
                    PinnedMenu()
                } content: {
                    PinnedStrip(emptyNote: pinnedNote)
                }
            }
        }
    }

    private var page: some View {
        ColumnScroll(bottomInset: dockHeight + 28) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach($document.blocks) { $block in
                    blockView($block)
                }
                addButton
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { pageWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, value in pageWidth = value }
                }
            )
            // A click beside the blocks lets go of the chosen one.
            .contentShape(Rectangle())
            .onTapGesture { activeBlock = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fontsoPlaygroundExport)) { _ in
            exportOpen = true
        }
        .sheet(isPresented: $exportOpen) {
            PlaygroundExportSheet(families: usedFamilies, screenWidth: max(320, pageWidth)) { options in
                exportOpen = false
                // Let the sheet close before the save panel comes up.
                DispatchQueue.main.async { export(options) }
            }
        }
    }

    // MARK: Blocks

    private func blockView(_ block: Binding<PlaygroundBlock>) -> some View {
        let value = block.wrappedValue
        let face = face(for: value.fontIdentity)
        // A block is chosen by a click, not by the pointer passing over it: only then do its tools show and the
        // strip at the bottom adjusts it.
        let showsTools = activeBlock == value.id || settingsFor == value.id
        let isActive = document.blocks.count > 1 && activeBlock == value.id
        return Group {
            if let face {
                // Every block can give single letters a cut of their own; without any, it is set in one font.
                MixEditor(
                    text: block.text,
                    fonts: mixFonts(value),
                    fallback: SpecimenFont.make(path: face.filePath, index: face.faceIndex, size: value.size, variations: [:]) ?? .systemFont(ofSize: value.size),
                    marked: [],
                    pointSize: value.size,
                    tracking: value.tracking * value.size,
                    leading: value.leading,
                    textColor: inkColor,
                    background: paper,
                    measuredHeight: heightBinding(value.id),
                    onEdit: { range, length in
                        block.wrappedValue.shiftLetters(replacing: range, with: length)
                    },
                    onSelect: { range in
                        selections[value.id] = range
                        // In the chosen block, Info shows the cut under the cursor.
                        if activeBlock == value.id {
                            showInfo(block.wrappedValue, at: range.location)
                        }
                    },
                    // A click into a block makes it the one with the tools, the one the strip at the bottom adjusts.
                    onClick: {
                        activeBlock = value.id
                        showInfo(block.wrappedValue)
                    },
                    onDropFont: { identities, offset in
                        guard let identity = identities.first(where: store.hasFace(identity:)) else { return }
                        let selected = selectedLetters(block.wrappedValue)
                        let selection = selections[block.wrappedValue.id] ?? NSRange(location: 0, length: 0)
                        if let offset, !selected.isEmpty, NSLocationInRange(offset, selection) {
                            document.change(undoManager, "Set Letters") {
                                block.wrappedValue.setFont(identity, forLettersIn: selected)
                            }
                        } else if let offset, block.wrappedValue.isMix {
                            let letter = (block.wrappedValue.text as NSString).rangeOfComposedCharacterSequence(at: offset)
                            document.change(undoManager, "Set Letter") {
                                block.wrappedValue.setFont(identity, forLettersIn: [letter])
                            }
                        } else {
                            document.change(undoManager, "Set Font") {
                                block.wrappedValue.fontIdentity = identity
                                block.wrappedValue.letters = []
                            }
                        }
                    }
                )
                .frame(maxWidth: .infinity, minHeight: max(heights[value.id] ?? 100, value.size * max(value.leading, 1.2) + 48), alignment: .topLeading)
            } else {
                Text(value.fontIdentity.isEmpty ? "Drop a font here, or click and pick one." : "This font left the library. Pick another one.")
                    .font(.uiCallout)
                    .foregroundStyle(ink.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(ink.opacity(0.3))
                    )
            }
        }
        .padding(value.insets)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // The padding around the text and a block without a font take the click too.
        .contentShape(Rectangle())
        .onTapGesture {
            activeBlock = value.id
            showInfo(value)
        }
        .overlay(alignment: .topTrailing) {
            if showsTools {
                tools(block, face: face)
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .overlay {
            if showsTools {
                Rectangle()
                    .strokeBorder(ink.opacity(0.1), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            // A short bar marks the block the strip at the bottom adjusts.
            if isActive {
                Rectangle()
                    .fill(ink.opacity(0.45))
                    .frame(width: 2)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showsTools)
        .dropDestination(for: FontDragItem.self) { items, _ in
            guard let identity = items.flatMap(\.identities).first,
                  store.hasFace(identity: identity) else { return false }
            document.change(undoManager, "Set Font") {
                block.wrappedValue.fontIdentity = identity
                block.wrappedValue.letters = []
            }
            return true
        }
    }

    /// The floating toolbar of the clicked block: font, settings, order, duplicate, remove.
    private func tools(_ block: Binding<PlaygroundBlock>, face: FontFace?) -> some View {
        let value = block.wrappedValue
        let index = document.blocks.firstIndex { $0.id == value.id } ?? 0
        let letters = selectedLetters(value)
        return HStack(spacing: 2) {
            fontMenu(block, face: face)
            if !letters.isEmpty {
                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 2)
                lettersMenu(block, letters: letters, face: face)
            }
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)
            toolButton("slider.horizontal.3", help: dockOpen ? "Hide the strip below with size, tracking, leading, and padding" : "Adjust this block in the strip below: size, tracking, leading, and padding", active: dockOpen) {
                dockOpen.toggle()
            }
            toolButton("arrow.up", help: "Move up", disabled: index == 0) {
                document.change(undoManager, "Move Block") { document.blocks.swapAt(index, index - 1) }
            }
            toolButton("arrow.down", help: "Move down", disabled: index >= document.blocks.count - 1) {
                document.change(undoManager, "Move Block") { document.blocks.swapAt(index, index + 1) }
            }
            toolButton("plus.square.on.square", help: "Duplicate this block") {
                var copy = value
                copy.id = UUID()
                document.change(undoManager, "Duplicate Block") { document.blocks.insert(copy, at: index + 1) }
            }
            toolButton("xmark", help: "Remove this block", disabled: document.blocks.count == 1) {
                document.change(undoManager, "Remove Block") { _ = document.blocks.remove(at: index) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ink.opacity(0.22), lineWidth: 0.5))
    }

    /// The font of a block, picked the way fonts are picked everywhere else: a search over the library, with the
    /// pinned fonts and the other cuts of the family first.
    private func fontMenu(_ block: Binding<PlaygroundBlock>, face: FontFace?) -> some View {
        let id = block.wrappedValue.id
        var actions: [AddFontButton.Action] = []
        if let face {
            actions.append(.init(title: "Show Info") {
                store.selection = [face.id]
                store.outsideSelection = []
                store.infoPanelOpen = true
            })
            actions.append(.init(title: "Clear font") {
                document.change(undoManager, "Clear Font") {
                    block.wrappedValue.fontIdentity = ""
                    block.wrappedValue.letters = []
                }
            })
        }
        return AddFontButton(
            title: blockTitle(block.wrappedValue, face: face),
            help: "Pick a font for this block: a pinned cut, another cut of the family, or any font of the library. You can also drop a font onto the block. In a mix, drop a font on a letter to change just that letter.",
            onPick: { picked in
                document.change(undoManager, "Set Font") {
                    block.wrappedValue.fontIdentity = picked.identity
                    block.wrappedValue.letters = []
                }
            },
            isChosen: { $0.identity == block.wrappedValue.fontIdentity },
            tool: true,
            current: face,
            showsPinned: true,
            actions: actions,
            onOpen: { open in keepTools(id, open: open) }
        )
    }

    /// The tools of a block stay while one of their popovers is open, even with the pointer over the popover.
    private func keepTools(_ id: UUID, open: Bool) {
        if open {
            settingsFor = id
        } else if settingsFor == id {
            settingsFor = nil
        }
    }

    private func blockTitle(_ block: PlaygroundBlock, face: FontFace?) -> String {
        if block.isMix {
            let cuts = Set(block.letters.map(\.font)).union([block.fontIdentity]).count
            return "Mix · \(cuts) \(cuts == 1 ? "cut" : "cuts")"
        }
        return face.map { "\($0.family) \($0.style)" } ?? "Choose font"
    }

    /// A cut for the letters selected in a block: from the library selection, the block's family, or anywhere.
    private func lettersMenu(_ block: Binding<PlaygroundBlock>, letters: [NSRange], face: FontFace?) -> some View {
        let current = Set(letters.map { block.wrappedValue.letterFonts[$0.location] ?? block.wrappedValue.fontIdentity })
        let title = letters.count == 1 ? "1 letter" : "\(letters.count) letters"
        let pick: (String?, String) -> Void = { identity, name in
            document.change(undoManager, name) {
                block.wrappedValue.setFont(identity, forLettersIn: letters)
            }
        }
        var actions: [AddFontButton.Action] = []
        if face != nil {
            actions.append(.init(title: "Back to the block font") { pick(nil, "Reset Letters") })
        }
        let id = block.wrappedValue.id
        return AddFontButton(
            title: title,
            help: "Give the selected letters a cut of their own: a pinned cut, another cut of the family, or any font of the library. You can also drop a font onto the selection.",
            onPick: { picked in pick(picked.identity, "Set Letters") },
            isChosen: { current == [$0.identity] },
            tool: true,
            symbol: "character.cursor.ibeam",
            current: face,
            showsPinned: true,
            actions: actions,
            onOpen: { open in keepTools(id, open: open) }
        )
    }

    private func selectedLetters(_ block: PlaygroundBlock) -> [NSRange] {
        guard let selection = selections[block.id], selection.length > 0 else { return [] }
        let string = block.text as NSString
        guard NSMaxRange(selection) <= string.length else { return [] }
        return MixText.letters(in: block.text).filter { range in
            NSIntersectionRange(range, selection).length > 0 && !string.substring(with: range).allSatisfy(\.isWhitespace)
        }
    }

    private func mixFonts(_ block: PlaygroundBlock) -> [Int: NSFont] {
        var made: [String: NSFont] = [:]
        var result: [Int: NSFont] = [:]
        for letter in block.letters {
            if made[letter.font] == nil, let face = face(for: letter.font),
               let font = SpecimenFont.make(path: face.filePath, index: face.faceIndex, size: block.size, variations: [:]) {
                made[letter.font] = font
            }
            if let font = made[letter.font] { result[letter.at] = font }
        }
        return result
    }

    /// Size, tracking, and leading of a block, in the unit chosen for the preview: pt, CSS px, or rem.
    private func adjustRows(_ block: Binding<PlaygroundBlock>) -> some View {
        let displaySize = Binding<Double>(
            get: { unit.display(from: block.wrappedValue.size) },
            set: { block.wrappedValue.size = unit.points(from: $0) }
        )
        return VStack(alignment: .leading, spacing: 3) {
            DockSliderRow(title: "Size", value: displaySize, range: unit.display(from: 6)...unit.display(from: 240), step: unit == .rem ? 0.05 : 1, fraction: unit == .rem ? 2 : 0, reset: { block.wrappedValue.size = 32 })
            DockSliderRow(title: "Tracking", value: block.tracking, range: -0.1...0.5, step: 0.005, fraction: 3, reset: { block.wrappedValue.tracking = 0 })
            DockSliderRow(title: "Leading", value: block.leading, range: 0.5...2.6, step: 0.05, fraction: 2, reset: { block.wrappedValue.leading = 1.2 })
        }
    }

    /// Padding follows the same unit, so a layout can be read straight into CSS.
    private func paddingRows(_ block: Binding<PlaygroundBlock>) -> some View {
        let range = unit.display(from: 0)...unit.display(from: 200)
        let step: Double = unit == .rem ? 0.125 : 2
        let fraction = unit == .rem ? 3 : 0
        return VStack(alignment: .leading, spacing: 3) {
            DockSliderRow(title: "Top", value: inUnit(block.padTop), range: range, step: step, fraction: fraction, reset: { block.wrappedValue.padTop = 24 })
            DockSliderRow(title: "Bottom", value: inUnit(block.padBottom), range: range, step: step, fraction: fraction, reset: { block.wrappedValue.padBottom = 24 })
            DockSliderRow(title: "Left", value: inUnit(block.padLeft), range: range, step: step, fraction: fraction, reset: { block.wrappedValue.padLeft = 24 })
            DockSliderRow(title: "Right", value: inUnit(block.padRight), range: range, step: step, fraction: fraction, reset: { block.wrappedValue.padRight = 24 })
        }
    }

    /// A point value shown and edited in the chosen unit; the block keeps storing points.
    private func inUnit(_ points: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { unit.display(from: points.wrappedValue) },
            set: { points.wrappedValue = unit.points(from: $0) }
        )
    }

    private func toolButton(_ symbol: String, help: String, active: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.uiCaption.weight(.medium))
                .foregroundStyle(active ? AppChrome.highlight : Color.primary.opacity(disabled ? 0.3 : 0.75))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private var addButton: some View {
        Button {
            var block = PlaygroundBlock()
            block.fontIdentity = store.previewFace?.identity ?? ""
            block.size = document.blocks.last?.size ?? 32
            if let last = document.blocks.last {
                block.padTop = last.padTop
                block.padBottom = last.padBottom
                block.padLeft = last.padLeft
                block.padRight = last.padRight
            }
            document.change(undoManager, "Add Block") { document.blocks.append(block) }
            settingsFor = nil
            activeBlock = block.id
        } label: {
            Label("Add block", systemImage: "plus")
                .font(.uiCaption)
                .foregroundStyle(ink.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help("Add a text block with the font selected in the library")
    }

    // MARK: Export

    /// Every cut on the page in block order: the block font, then the cuts of its letters.
    private var usedFaces: [FontFace] {
        var seen: Set<String> = []
        var result: [FontFace] = []
        for block in document.blocks {
            for identity in [block.fontIdentity] + block.letters.map(\.font) where seen.insert(identity).inserted {
                if let face = face(for: identity) { result.append(face) }
            }
        }
        return result
    }

    /// The families on the page, in block order, for the file name.
    private var usedFamilies: [String] {
        var seen: Set<String> = []
        var families: [String] = []
        for block in document.blocks {
            let identities = block.isMix ? Array(Set(block.letters.map(\.font))).sorted() : [block.fontIdentity]
            for identity in identities {
                guard let face = face(for: identity), seen.insert(face.family.lowercased()).inserted else { continue }
                families.append(face.family)
            }
        }
        return families
    }

    private func export(_ options: PlaygroundExportOptions) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.kind == .pdf ? .pdf : .png]
        panel.nameFieldStringValue = PlaygroundPage.fileName(families: usedFamilies, kind: options.kind)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let faces = store.facesKeyedByIdentity
        let layout = PlaygroundPage.layout(
            blocks: document.blocks,
            faces: faces,
            format: options.resolved(screenWidth: max(320, pageWidth)),
            paper: paper,
            ink: inkColor
        )
        do {
            let written = try PlaygroundPage.write(layout, to: url, kind: options.kind)
            if written.count > 1 {
                store.alertMessage = "Exported \(written.count) pages as separate PNG files next to \(url.lastPathComponent)."
            }
        } catch {
            store.alertMessage = error.localizedDescription
        }
    }

    // MARK: Helpers

    private func face(for identity: String) -> FontFace? {
        guard !identity.isEmpty else { return nil }
        return store.face(identity: identity)
    }

    private func heightBinding(_ id: UUID) -> Binding<CGFloat> {
        Binding(
            get: { heights[id] ?? 100 },
            set: { heights[id] = $0 }
        )
    }

    private var paper: NSColor { theme.paper }
    private var inkColor: NSColor { theme.ink }
    private var ink: Color { Color(nsColor: inkColor) }
}

// MARK: - Export

enum PlaygroundExportKind: String, CaseIterable, Identifiable {
    case pdf, png
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

enum PlaygroundPaper: String, CaseIterable, Identifiable {
    case screen, a4, a3, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Screen"
        case .a4: return "A4"
        case .a3: return "A3"
        case .custom: return "Custom"
        }
    }

    /// Portrait size in points (72 per inch); nil for the screen page, which is as tall as its text.
    var portraitSize: CGSize? {
        switch self {
        case .screen: return nil
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .a3: return CGSize(width: 841.89, height: 1190.55)
        case .custom: return nil
        }
    }
}

/// What the user picked in the export sheet.
struct PlaygroundExportOptions {
    var kind = PlaygroundExportKind.pdf
    var paper = PlaygroundPaper.a4
    var landscape = false
    /// Custom size in millimetres.
    var customWidth = 210.0
    var customHeight = 297.0

    static let pointsPerMillimetre = 72.0 / 25.4

    /// The page to lay out: width, height (nil = one page as tall as the text), and margin.
    func resolved(screenWidth: CGFloat) -> PlaygroundPage.Format {
        switch paper {
        case .screen:
            return PlaygroundPage.Format(width: screenWidth, height: nil, margin: 14)
        case .custom:
            let width = max(60, customWidth) * PlaygroundExportOptions.pointsPerMillimetre
            let height = max(60, customHeight) * PlaygroundExportOptions.pointsPerMillimetre
            return PlaygroundPage.Format(width: width, height: height, margin: 12 * PlaygroundExportOptions.pointsPerMillimetre)
        case .a4, .a3:
            let size = paper.portraitSize ?? CGSize(width: 595.28, height: 841.89)
            let width = landscape ? size.height : size.width
            let height = landscape ? size.width : size.height
            return PlaygroundPage.Format(width: width, height: height, margin: 12 * PlaygroundExportOptions.pointsPerMillimetre)
        }
    }
}

/// Format, orientation, and file type for the Playground export, with the file name the fonts give it.
/// What is chosen is a filled button, so it reads at a glance; the sheet keeps the colours of the theme.
struct PlaygroundExportSheet: View {
    var families: [String]
    var screenWidth: CGFloat
    var export: (PlaygroundExportOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = PlaygroundExportOptions()
    @State private var customWidth = "210"
    @State private var customHeight = "297"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export the playground")
                .font(AppChrome.type(13, weight: .medium))
                .foregroundStyle(AppChrome.ink)
                .padding(.bottom, 2)
            row("Page") {
                ForEach(PlaygroundPaper.allCases) { paper in
                    choice(paper.title, on: options.paper == paper, help: "Page size: \(paper.title)") {
                        options.paper = paper
                    }
                }
            }
            switch options.paper {
            case .screen:
                note("One page as wide as the Playground is now (\(Int(screenWidth)) pt) and as tall as the text.")
            case .a4, .a3:
                row("Orientation") {
                    choice("Portrait", on: !options.landscape, help: "Upright page") { options.landscape = false }
                    choice("Landscape", on: options.landscape, help: "Page on its side") { options.landscape = true }
                }
                note("12 mm margin. Longer text runs over several pages.")
            case .custom:
                row("Size") {
                    field("Width", text: $customWidth)
                    Text("×")
                        .foregroundStyle(AppChrome.half)
                    field("Height", text: $customHeight)
                    Text("mm")
                        .foregroundStyle(AppChrome.half)
                }
                note("12 mm margin. Longer text runs over several pages.")
            }
            row("File") {
                ForEach(PlaygroundExportKind.allCases) { kind in
                    choice(
                        kind.title,
                        on: options.kind == kind,
                        help: kind == .pdf ? "PDF keeps the text sharp at any size" : "PNG is an image, 2× for Retina"
                    ) {
                        options.kind = kind
                    }
                }
            }
            if options.kind == .png, options.paper != .screen {
                note("PNG is 2× for Retina; every page becomes its own file.")
            }
            row("Name") {
                Text(PlaygroundPage.fileName(families: families, kind: options.kind))
                    .foregroundStyle(AppChrome.ink)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle()
                .fill(AppChrome.hairline)
                .frame(height: 0.5)
                .padding(.top, 2)
            HStack(spacing: 6) {
                Text(summary)
                    .font(AppChrome.small)
                    .foregroundStyle(AppChrome.half)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.paper)
                    .keyboardShortcut(.cancelAction)
                    .help("Close without exporting")
                Button("Export…") { export(resolved) }
                    .buttonStyle(.paperProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Choose where to save the export")
            }
        }
        .font(AppChrome.type(11))
        .padding(18)
        .frame(width: 420)
        .modifier(ChromeSheet())
    }

    /// What will be written, in one line beside the buttons.
    private var summary: String {
        var parts = [options.paper.title]
        switch options.paper {
        case .a4, .a3: parts.append(options.landscape ? "landscape" : "portrait")
        case .custom: parts.append("\(Self.shown(resolved.customWidth)) × \(Self.shown(resolved.customHeight)) mm")
        case .screen: parts.append("\(Int(screenWidth)) pt wide")
        }
        parts.append(options.kind.title)
        return parts.joined(separator: ", ")
    }

    /// The options with the custom size read from what was typed, a comma or a point as the decimal mark.
    private var resolved: PlaygroundExportOptions {
        var result = options
        result.customWidth = Self.number(customWidth) ?? options.customWidth
        result.customHeight = Self.number(customHeight) ?? options.customHeight
        return result
    }

    private static func number(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." }
        guard let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    private static func shown(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title)
                .foregroundStyle(AppChrome.half)
                .frame(width: 78, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func choice(_ title: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(PaperButtonStyle(prominent: on))
            .help(help)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .font(AppChrome.type(11).monospacedDigit())
            .foregroundStyle(AppChrome.ink)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(width: 58)
            .background(AppChrome.control, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(AppChrome.ink.opacity(0.22), lineWidth: 0.5))
            .help("\(title) in millimetres")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(AppChrome.small)
            .foregroundStyle(AppChrome.half)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 83)
    }
}

/// Lays the Playground out for export with the same fonts, sizes, spacing, and colours as on screen, breaking
/// between lines where a page ends.
enum PlaygroundPage {
    struct Format {
        var width: CGFloat
        /// Nil makes one page as tall as the text.
        var height: CGFloat?
        var margin: CGFloat
    }

    struct Layout {
        var format: Format
        var paper: NSColor
        var manager: NSLayoutManager
        var storage: NSTextStorage
        /// Glyph range and top offset of each page.
        var pages: [(glyphs: NSRange, top: CGFloat)]
        var pageHeight: CGFloat
    }

    /// "Playground – Family, Family.pdf", with characters a file name must not hold taken out.
    static func fileName(families: [String], kind: PlaygroundExportKind) -> String {
        var name = "Playground"
        if !families.isEmpty {
            let shown = families.prefix(4).joined(separator: ", ")
            let more = families.count > 4 ? " +\(families.count - 4)" : ""
            name += " – " + shown + more
        }
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        name = String(name.unicodeScalars.filter { !forbidden.contains($0) }.map(Character.init))
        if name.count > 90 { name = String(name.prefix(90)).trimmingCharacters(in: .whitespaces) + "…" }
        return name + "." + kind.rawValue
    }

    @MainActor
    static func layout(blocks: [PlaygroundBlock], faces: [String: FontFace], format: Format, paper: NSColor, ink: NSColor) -> Layout {
        let storage = NSTextStorage()
        for block in blocks {
            guard let face = faces[block.fontIdentity],
                  let font = SpecimenFont.make(path: face.filePath, index: face.faceIndex, size: block.size, variations: [:]) else { continue }
            let paragraph = SpecimenParagraph.style(lineHeight: block.size * block.leading)
            paragraph.firstLineHeadIndent = CGFloat(block.padLeft)
            paragraph.headIndent = CGFloat(block.padLeft)
            paragraph.tailIndent = -CGFloat(block.padRight)
            paragraph.paragraphSpacingBefore = CGFloat(block.padTop)
            paragraph.paragraphSpacing = CGFloat(block.padBottom)
            let text = block.text.isEmpty ? " " : block.text
            let start = storage.length
            storage.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font,
                .foregroundColor: ink,
                .kern: block.tracking * block.size,
                .paragraphStyle: paragraph
            ]))
            let string = text as NSString
            for letter in block.letters where letter.at < string.length {
                guard let cut = faces[letter.font],
                      let letterFont = SpecimenFont.make(path: cut.filePath, index: cut.faceIndex, size: block.size, variations: [:]) else { continue }
                let range = string.rangeOfComposedCharacterSequence(at: letter.at)
                storage.addAttribute(.font, value: letterFont, range: NSRange(location: start + range.location, length: range.length))
            }
        }
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: format.width - 2 * format.margin, height: 10_000_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        var fragments: [(rect: CGRect, glyphs: NSRange)] = []
        let all = NSRange(location: 0, length: manager.numberOfGlyphs)
        manager.enumerateLineFragments(forGlyphRange: all) { rect, _, _, glyphs, _ in
            fragments.append((rect, glyphs))
        }
        let used = manager.usedRect(for: container)
        let pageHeight = format.height ?? ceil(used.height + 2 * format.margin)
        let room = max(40, pageHeight - 2 * format.margin)

        var pages: [(glyphs: NSRange, top: CGFloat)] = []
        var start: NSRange?
        var top: CGFloat = 0
        for fragment in fragments {
            if let current = start, fragment.rect.maxY - top > room {
                pages.append((current, top))
                start = nil
                top = fragment.rect.minY
            }
            if let current = start {
                start = NSUnionRange(current, fragment.glyphs)
            } else {
                start = fragment.glyphs
            }
        }
        if let current = start { pages.append((current, top)) }
        if pages.isEmpty { pages.append((NSRange(location: 0, length: 0), 0)) }
        return Layout(format: format, paper: paper, manager: manager, storage: storage, pages: pages, pageHeight: pageHeight)
    }

    /// Writes the PDF, or one PNG per page. Returns the files written.
    @MainActor
    @discardableResult
    static func write(_ layout: Layout, to url: URL, kind: PlaygroundExportKind) throws -> [URL] {
        switch kind {
        case .pdf:
            try pdf(layout).write(to: url, options: .atomic)
            return [url]
        case .png:
            var written: [URL] = []
            let base = url.deletingPathExtension()
            for index in layout.pages.indices {
                guard let data = png(layout, page: index) else { continue }
                let target = index == 0 ? url : base.appendingPathExtension("\(index + 1).png")
                try data.write(to: target, options: .atomic)
                written.append(target)
            }
            return written
        }
    }

    @MainActor
    static func pdf(_ layout: Layout) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: layout.format.width, height: layout.pageHeight)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for index in layout.pages.indices {
            context.beginPDFPage(nil)
            // Flip so TextKit's top-left origin lands the right way up.
            context.translateBy(x: 0, y: layout.pageHeight)
            context.scaleBy(x: 1, y: -1)
            draw(layout, page: index, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A 2× PNG of one page, so it stays sharp on Retina screens.
    @MainActor
    static func png(_ layout: Layout, page index: Int) -> Data? {
        let scale: CGFloat = 2
        let width = layout.format.width
        let height = layout.pageHeight
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale),
            pixelsHigh: Int(height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let context = graphics.cgContext
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        draw(layout, page: index, in: context)
        return rep.representation(using: .png, properties: [:])
    }

    /// Draws one page into a flipped (top-left origin) context.
    @MainActor
    private static func draw(_ layout: Layout, page index: Int, in context: CGContext) {
        let page = layout.pages[index]
        let format = layout.format
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.setFillColor(layout.paper.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: format.width, height: layout.pageHeight))
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: format.margin, width: format.width, height: layout.pageHeight - 2 * format.margin))
        let origin = CGPoint(x: format.margin, y: format.margin - page.top)
        if page.glyphs.length > 0 {
            layout.manager.drawBackground(forGlyphRange: page.glyphs, at: origin)
            layout.manager.drawGlyphs(forGlyphRange: page.glyphs, at: origin)
        }
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }
}

