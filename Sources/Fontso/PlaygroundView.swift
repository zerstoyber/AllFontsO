import AppKit
import FontsoCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Asks the open Playground to export its page; the object is "pdf" or "png".
    static let fontsoPlaygroundExport = Notification.Name("fontso.playgroundExport")
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
        case id, text, fontIdentity, size, tracking, leading, padding, padTop, padBottom, padLeft, padRight
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
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var document = PlaygroundDocument.shared
    @AppStorage("fontso.specimen.background") private var backgroundHex = "F6F3EE"
    @AppStorage("fontso.specimen.foreground") private var foregroundHex = "212121"
    @State private var heights: [UUID: CGFloat] = [:]
    @State private var hovered: UUID?
    @State private var settingsFor: UUID?
    @State private var pageWidth: CGFloat = 600
    @State private var exportOpen = false
    @AppStorage("fontso.specimen.unit") private var unitRaw = SpecimenUnit.point.rawValue

    private var unit: SpecimenUnit { SpecimenUnit(rawValue: unitRaw) ?? .point }

    var body: some View {
        ColumnScroll {
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
        }
        .background(Color(nsColor: paper))
        .environment(\.colorScheme, paperIsDark ? .dark : .light)
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
        let showsTools = hovered == value.id || settingsFor == value.id
        return Group {
            if let face {
                SpecimenEditor(
                    text: block.text,
                    face: face,
                    pointSize: value.size,
                    tracking: value.tracking * value.size,
                    leading: value.leading,
                    textColor: inkColor,
                    background: paper,
                    variations: [:],
                    measuredHeight: heightBinding(value.id)
                )
                .frame(maxWidth: .infinity, minHeight: max(heights[value.id] ?? 100, value.size * max(value.leading, 1.2) + 48), alignment: .topLeading)
            } else {
                Text(value.fontIdentity.isEmpty ? "Drop a font here, or pick one from the menu." : "This font left the library. Pick another one.")
                    .font(.callout)
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
        .animation(.easeOut(duration: 0.12), value: showsTools)
        .onHover { inside in
            if inside {
                hovered = value.id
            } else if hovered == value.id {
                hovered = nil
            }
        }
        .dropDestination(for: FontDragItem.self) { items, _ in
            guard let identity = items.flatMap(\.identities).first,
                  store.fonts.contains(where: { $0.identity == identity }) else { return false }
            block.wrappedValue.fontIdentity = identity
            return true
        }
    }

    /// The floating toolbar on a hovered block: font, settings, order, duplicate, remove.
    private func tools(_ block: Binding<PlaygroundBlock>, face: FontFace?) -> some View {
        let value = block.wrappedValue
        let index = document.blocks.firstIndex { $0.id == value.id } ?? 0
        return HStack(spacing: 2) {
            fontMenu(block, face: face)
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)
            toolButton("slider.horizontal.3", help: "Size, tracking, leading, and padding", active: settingsFor == value.id) {
                settingsFor = settingsFor == value.id ? nil : value.id
            }
            .popover(isPresented: settingsBinding(value.id), arrowEdge: .bottom) {
                settings(block)
                    .padding(14)
                    .frame(width: 320)
            }
            toolButton("arrow.up", help: "Move up", disabled: index == 0) {
                document.blocks.swapAt(index, index - 1)
            }
            toolButton("arrow.down", help: "Move down", disabled: index >= document.blocks.count - 1) {
                document.blocks.swapAt(index, index + 1)
            }
            toolButton("plus.square.on.square", help: "Duplicate this block") {
                var copy = value
                copy.id = UUID()
                document.blocks.insert(copy, at: index + 1)
            }
            toolButton("xmark", help: "Remove this block", disabled: document.blocks.count == 1) {
                document.blocks.remove(at: index)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .environment(\.colorScheme, paperIsDark ? .dark : .light)
    }

    private func settingsBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { settingsFor == id },
            set: { open in
                if open {
                    settingsFor = id
                } else if settingsFor == id {
                    settingsFor = nil
                }
            }
        )
    }

    private func fontMenu(_ block: Binding<PlaygroundBlock>, face: FontFace?) -> some View {
        let selected = store.previewFaces.prefix(24)
        return Menu {
            if selected.isEmpty {
                Text("Select fonts in the library to list them here")
            } else {
                Section("Selected in the library") {
                    ForEach(Array(selected)) { candidate in
                        Button {
                            block.wrappedValue.fontIdentity = candidate.identity
                        } label: {
                            if candidate.identity == block.wrappedValue.fontIdentity {
                                Label("\(candidate.family) \(candidate.style)", systemImage: "checkmark")
                            } else {
                                Text("\(candidate.family) \(candidate.style)")
                            }
                        }
                    }
                }
            }
            if let face {
                Section("Cuts of \(face.family)") {
                    ForEach(store.cuts(in: face.family)) { cut in
                        Button {
                            block.wrappedValue.fontIdentity = cut.identity
                        } label: {
                            if cut.id == face.id {
                                Label(cut.style, systemImage: "checkmark")
                            } else {
                                Text(cut.style)
                            }
                        }
                    }
                }
                Divider()
                Button("Show in library") {
                    store.selection = [face.id]
                    store.outsideSelection = []
                }
                Button("Clear font") { block.wrappedValue.fontIdentity = "" }
            }
        } label: {
            Text(face.map { "\($0.family) \($0.style)" } ?? "Choose font")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: 240)
        .help("Pick a font for this block: one of the fonts selected in the library, or another cut of the same family. You can also drop a font onto the block.")
    }

    private func settings(_ block: Binding<PlaygroundBlock>) -> some View {
        // Size in the unit chosen for the preview: pt, CSS px, or rem.
        let displaySize = Binding<Double>(
            get: { unit.display(from: block.wrappedValue.size) },
            set: { block.wrappedValue.size = unit.points(from: $0) }
        )
        let sizeStep: Double = unit == .rem ? 0.05 : 1
        let sizeFormat = unit == .rem ? "%.2f rem" : "%.0f \(unit.title)"
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Unit")
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Picker("Unit", selection: $unitRaw) {
                    ForEach(SpecimenUnit.allCases, id: \.rawValue) { candidate in
                        Text(candidate.title).tag(candidate.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 150)
                Spacer(minLength: 0)
            }
            metric("Size", value: displaySize, range: unit.display(from: 6)...unit.display(from: 240), step: sizeStep, format: sizeFormat, reset: unit.display(from: 32))
            metric("Tracking", value: block.tracking, range: -0.1...0.5, step: 0.005, format: "%.3f em", reset: 0)
            metric("Leading", value: block.leading, range: 0.5...2.6, step: 0.05, format: "%.2f", reset: 1.2)
            Divider()
                .padding(.vertical, 2)
            // Padding follows the same unit, so a layout can be read straight into CSS.
            let padRange = unit.display(from: 0)...unit.display(from: 200)
            let padStep: Double = unit == .rem ? 0.125 : 2
            let padFormat = unit == .rem ? "%.3f rem" : "%.0f \(unit.title)"
            let padReset = unit.display(from: 24)
            metric("Top", value: inUnit(block.padTop), range: padRange, step: padStep, format: padFormat, reset: padReset)
            metric("Bottom", value: inUnit(block.padBottom), range: padRange, step: padStep, format: padFormat, reset: padReset)
            metric("Left", value: inUnit(block.padLeft), range: padRange, step: padStep, format: padFormat, reset: padReset)
            metric("Right", value: inUnit(block.padRight), range: padRange, step: padStep, format: padFormat, reset: padReset)
        }
        .font(.caption)
    }

    /// A point value shown and edited in the chosen unit; the block keeps storing points.
    private func inUnit(_ points: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { unit.display(from: points.wrappedValue) },
            set: { points.wrappedValue = unit.points(from: $0) }
        )
    }

    private func metric(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String, reset: Double) -> some View {
        let snapped = Binding<Double>(
            get: { value.wrappedValue },
            set: { value.wrappedValue = SpecimenView.snap($0, step: step, range: range) }
        )
        return HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Slider(value: snapped, in: range)
                .controlSize(.small)
            Text(String(format: format, value.wrappedValue))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Button {
                value.wrappedValue = reset
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Back to \(String(format: format, reset))")
        }
    }

    private func toolButton(_ symbol: String, help: String, active: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(disabled ? 0.3 : 0.75))
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
            document.blocks.append(block)
            settingsFor = nil
        } label: {
            Label("Add block", systemImage: "plus")
                .font(.caption)
                .foregroundStyle(ink.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help("Add a text block with the font selected in the library")
    }

    // MARK: Export

    /// The families on the page, in block order, for the file name.
    private var usedFamilies: [String] {
        var seen: Set<String> = []
        return document.blocks.compactMap { block in
            guard let face = face(for: block.fontIdentity), seen.insert(face.family.lowercased()).inserted else { return nil }
            return face.family
        }
    }

    private func export(_ options: PlaygroundExportOptions) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.kind == .pdf ? .pdf : .png]
        panel.nameFieldStringValue = PlaygroundPage.fileName(families: usedFamilies, kind: options.kind)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let faces = Dictionary(store.fonts.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
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
        return store.fonts.first { $0.identity == identity }
    }

    private func heightBinding(_ id: UUID) -> Binding<CGFloat> {
        Binding(
            get: { heights[id] ?? 100 },
            set: { heights[id] = $0 }
        )
    }

    private var paper: NSColor { NSColor.fontsoHex(backgroundHex, fallback: .white) }
    private var inkColor: NSColor { NSColor.fontsoHex(foregroundHex, fallback: .black) }
    private var ink: Color { Color(nsColor: inkColor) }

    private var paperIsDark: Bool {
        guard let rgb = paper.usingColorSpace(.sRGB) else { return false }
        return (0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent) < 0.5
    }
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
struct PlaygroundExportSheet: View {
    var families: [String]
    var screenWidth: CGFloat
    var export: (PlaygroundExportOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = PlaygroundExportOptions()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export the playground")
                .font(.headline)
            Picker("Page", selection: $options.paper) {
                ForEach(PlaygroundPaper.allCases) { paper in
                    Text(paper.title).tag(paper)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch options.paper {
            case .screen:
                Text("One page as wide as the preview column (\(Int(screenWidth)) pt) and as tall as the text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .a4, .a3:
                Picker("Orientation", selection: $options.landscape) {
                    Text("Portrait").tag(false)
                    Text("Landscape").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
                Text("12 mm margin. Longer text runs over several pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .custom:
                HStack(spacing: 8) {
                    TextField("Width", value: $options.customWidth, format: .number)
                        .frame(width: 64)
                    Text("×")
                    TextField("Height", value: $options.customHeight, format: .number)
                        .frame(width: 64)
                    Text("mm")
                        .foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
                Text("12 mm margin. Longer text runs over several pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("File", selection: $options.kind) {
                ForEach(PlaygroundExportKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            if options.kind == .png, options.paper != .screen {
                Text("PNG is 2× for Retina; every page becomes its own file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("File name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(PlaygroundPage.fileName(families: families, kind: options.kind))
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export(options) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
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
            storage.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font,
                .foregroundColor: ink,
                .kern: block.tracking * block.size,
                .paragraphStyle: paragraph
            ]))
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

extension NSColor {
    /// A colour from six hex digits, or the fallback when the text is not a colour.
    static func fontsoHex(_ hex: String, fallback: NSColor) -> NSColor {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let number = Int(cleaned, radix: 16) else { return fallback }
        return NSColor(
            srgbRed: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }
}
