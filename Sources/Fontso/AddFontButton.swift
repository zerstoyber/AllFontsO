import FontsoCore
import SwiftUI

/// "Add font…": a popover with a search field over the whole library. Picking a font puts it into the preview
/// beside the fonts already there, so Align and Overlay can start from a single font.
struct AddFontButton: View {
    @Environment(LibraryStore.self) private var store
    var title = "Add font…"
    var help = "Search the library and add a font to the preview"
    /// Where the chosen font goes. Without it, into the preview.
    var onPick: ((FontFace) -> Void)? = nil
    /// Marks the fonts already in place.
    var isChosen: ((FontFace) -> Bool)? = nil
    @Environment(\.paperInk) private var paperInk
    @State private var open = false
    @State private var query = ""

    private let limit = 80

    var body: some View {
        styled(
            Button {
                open.toggle()
            } label: {
                Label(title, systemImage: "plus")
                    .font(.caption)
            }
        )
        .help(help)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Family or style…", text: $query)
                    .textFieldStyle(.roundedBorder)
                let matches = matches
                if matches.isEmpty {
                    Text(query.isEmpty ? "The library is empty." : "No font matches “\(query)”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(matches) { face in
                                Button {
                                    if let onPick {
                                        onPick(face)
                                    } else {
                                        store.addToPreview([face.identity])
                                    }
                                    open = false
                                } label: {
                                    HStack(spacing: 8) {
                                        FamilySample(face: face, text: "Aa", size: 16)
                                            .frame(width: 30, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(face.family)
                                                .lineLimit(1)
                                            Text(face.style)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                        if isChosen?(face) ?? store.previewFaces.contains(where: { $0.id == face.id }) {
                                            Image(systemName: "checkmark")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("\(face.family) \(face.style)")
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    if matches.count >= limit {
                        Text("Showing the first \(limit). Type more to narrow down.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(width: 320)
        }
    }

    /// On the preview's paper the button takes its ink; elsewhere it is a small system button.
    @ViewBuilder
    private func styled(_ button: some View) -> some View {
        if paperInk != nil {
            button.buttonStyle(.paper)
        } else {
            button.buttonStyle(.bordered).controlSize(.small)
        }
    }

    /// With no query, one row per family (its default cut). With a query, every matching cut.
    private var matches: [FontFace] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty {
            var seen: Set<String> = []
            var result: [FontFace] = []
            for face in sortedFonts where seen.insert(face.family.lowercased()).inserted {
                result.append(LibraryStore.defaultInstance(store.cuts(in: face.family)) ?? face)
                if result.count >= limit { break }
            }
            return result
        }
        let words = needle.split(separator: " ").map(String.init)
        return Array(sortedFonts.lazy.filter { face in
            let text = "\(face.family) \(face.style) \(face.postscriptName)".lowercased()
            return words.allSatisfy { text.contains($0) }
        }.prefix(limit))
    }

    private var sortedFonts: [FontFace] {
        store.fontsByName
    }
}
