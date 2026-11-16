import AppKit
import FontsoCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Asks Preview to export the fonts of the open navigation source as PDF or PNG.
    static let fontsoListExport = Notification.Name("fontso.listExport")
}

/// How many families one export takes at most. Larger libraries get a note and the first ones only.
enum ListExport {
    static let familyLimit = 200
}

/// Format, orientation, and file type for a list export — the same choices Use offers.
struct ListExportSheet: View {
    var title: String
    var families: [String]
    var totalFamilies: Int
    var screenWidth: CGFloat
    var export: (PlaygroundExportOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = PlaygroundExportOptions()
    @State private var customWidth = "210"
    @State private var customHeight = "297"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export list")
                .font(AppChrome.type(13, weight: .medium))
                .foregroundStyle(AppChrome.ink)
                .padding(.bottom, 2)
            Text(sourceLine)
                .font(AppChrome.small)
                .foregroundStyle(AppChrome.half)
                .fixedSize(horizontal: false, vertical: true)
            row("Page") {
                ForEach(PlaygroundPaper.allCases) { paper in
                    choice(paper.title, on: options.paper == paper, help: "Page size: \(paper.title)") {
                        options.paper = paper
                    }
                }
            }
            switch options.paper {
            case .screen:
                note("One page as wide as Preview is now (\(Int(screenWidth)) pt) and as tall as the list.")
            case .a4, .a3:
                row("Orientation") {
                    choice("Portrait", on: !options.landscape, help: "Upright page") { options.landscape = false }
                    choice("Landscape", on: options.landscape, help: "Page on its side") { options.landscape = true }
                }
                note("12 mm margin. Longer lists run over several pages.")
            case .custom:
                row("Size") {
                    field("Width", text: $customWidth)
                    Text("×")
                        .foregroundStyle(AppChrome.half)
                    field("Height", text: $customHeight)
                    Text("mm")
                        .foregroundStyle(AppChrome.half)
                }
                note("12 mm margin. Longer lists run over several pages.")
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
                Text(ListPage.fileName(title: title, families: families, kind: options.kind))
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
                    .disabled(families.isEmpty)
                    .help("Choose where to save the export")
            }
        }
        .font(AppChrome.type(11))
        .padding(18)
        .frame(width: 420)
        .modifier(ChromeSheet())
    }

    private var sourceLine: String {
        if totalFamilies > families.count {
            return "\(title): the first \(families.count) of \(AppChrome.count(totalFamilies)) families."
        }
        return "\(title): \(AppChrome.count(families.count)) \(families.count == 1 ? "family" : "families")."
    }

    private var summary: String {
        var parts = [options.paper.title]
        switch options.paper {
        case .a4, .a3: parts.append(options.landscape ? "landscape" : "portrait")
        case .custom: parts.append("\(customWidth)×\(customHeight) mm")
        case .screen: break
        }
        parts.append(options.kind.title)
        return parts.joined(separator: " · ")
    }

    private var resolved: PlaygroundExportOptions {
        var value = options
        if options.paper == .custom {
            value.customWidth = Double(customWidth.replacingOccurrences(of: ",", with: ".")) ?? 210
            value.customHeight = Double(customHeight.replacingOccurrences(of: ",", with: ".")) ?? 297
        }
        return value
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .foregroundStyle(AppChrome.half)
                .frame(width: 72, alignment: .leading)
            HStack(spacing: 4) { content() }
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

/// Lays a font list out for export: family name, then a specimen line in that family’s lead cut.
enum ListPage {
    struct Entry {
        var family: String
        var face: FontFace
    }

    static func fileName(title: String, families: [String], kind: PlaygroundExportKind) -> String {
        var name = title.isEmpty ? "List" : title
        if !families.isEmpty {
            let shown = families.prefix(3).joined(separator: ", ")
            let more = families.count > 3 ? " +\(families.count - 3)" : ""
            name += " – " + shown + more
        }
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        name = String(name.unicodeScalars.filter { !forbidden.contains($0) }.map(Character.init))
        if name.count > 90 { name = String(name.prefix(90)).trimmingCharacters(in: .whitespaces) + "…" }
        return name + "." + kind.rawValue
    }

    @MainActor
    static func layout(
        entries: [Entry],
        sample: String,
        size: CGFloat,
        tracking: CGFloat,
        leading: CGFloat,
        format: PlaygroundPage.Format,
        paper: NSColor,
        ink: NSColor
    ) -> PlaygroundPage.Layout {
        let storage = NSTextStorage()
        let sampleText = sample.isEmpty ? "Handgloves" : sample
        let nameFont = AppChrome.nsFont(10, weight: .medium)
        let metaFont = AppChrome.nsFont(9)
        for entry in entries {
            let nameParagraph = SpecimenParagraph.style(lineHeight: 14)
            nameParagraph.paragraphSpacingBefore = 10
            nameParagraph.paragraphSpacing = 2
            storage.append(NSAttributedString(string: entry.family + "\n", attributes: [
                .font: nameFont,
                .foregroundColor: ink.withAlphaComponent(0.9),
                .paragraphStyle: nameParagraph
            ]))
            let meta = "\(entry.face.style) · \(entry.face.category.rawValue)\n"
            let metaParagraph = SpecimenParagraph.style(lineHeight: 12)
            metaParagraph.paragraphSpacing = 4
            storage.append(NSAttributedString(string: meta, attributes: [
                .font: metaFont,
                .foregroundColor: ink.withAlphaComponent(0.55),
                .paragraphStyle: metaParagraph
            ]))
            guard let font = SpecimenFont.make(
                path: entry.face.filePath,
                index: entry.face.faceIndex,
                size: size,
                variations: [:]
            ) else { continue }
            let specimenParagraph = SpecimenParagraph.style(lineHeight: size * leading)
            specimenParagraph.paragraphSpacing = 8
            storage.append(NSAttributedString(string: sampleText + "\n", attributes: [
                .font: font,
                .foregroundColor: ink,
                .kern: tracking * size,
                .paragraphStyle: specimenParagraph
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
        return PlaygroundPage.Layout(format: format, paper: paper, manager: manager, storage: storage, pages: pages, pageHeight: pageHeight)
    }
}


struct ListExportWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 720
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
