import FontsoCore
import SwiftUI

/// "Add font…": a popover with a search field over the whole library. Picking a font puts it into the preview
/// beside the fonts already there, so Align and Overlay can start from a single font.
struct AddFontButton: View {
    /// Something else the popover can do, under the fonts: back to the block font, clear the font.
    struct Action {
        var title: String
        var perform: () -> Void
    }

    @Environment(LibraryStore.self) private var store
    var title = "Add font…"
    var help = "Search the library and add a font to the preview"
    /// Where the chosen font goes. Without it, into the preview.
    var onPick: ((FontFace) -> Void)? = nil
    /// Marks the fonts already in place.
    var isChosen: ((FontFace) -> Bool)? = nil
    /// The small chip of the dock, without the plus.
    var compact = false
    /// Only a plus, as in the row of pinned fonts.
    var iconOnly = false
    /// The name of the font as the button, for the tools of a Playground block.
    var tool = false
    var symbol: String? = nil
    /// The font in place. Its family's other cuts come first in the popover.
    var current: FontFace? = nil
    /// Lists the pinned fonts first.
    var showsPinned = false
    var actions: [Action] = []
    /// Told when the popover opens and closes.
    var onOpen: ((Bool) -> Void)? = nil
    @Environment(\.paperInk) private var paperInk
    @State private var open = false
    @State private var query = ""

    private let limit = 80

    var body: some View {
        trigger
        .onChange(of: open) { _, value in onOpen?(value) }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Family or style…", text: $query)
                    .textFieldStyle(.roundedBorder)
                let matches = matches
                let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
                let pinned = showsPinned && !searching ? store.pinnedFaces : []
                let cuts = !searching ? (current.map { store.cuts(in: $0.family) } ?? []) : []
                if matches.isEmpty && pinned.isEmpty && cuts.isEmpty {
                    Text(query.isEmpty ? "The library is empty." : "No font matches “\(query)”.")
                        .font(.uiCaption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !pinned.isEmpty {
                                sectionTitle("Pinned")
                                ForEach(pinned) { face in
                                    row(face)
                                }
                            }
                            if cuts.count > 1, let current {
                                sectionTitle("Cuts of \(current.family)")
                                ForEach(cuts) { face in
                                    row(face)
                                }
                            }
                            if !pinned.isEmpty || cuts.count > 1 {
                                sectionTitle("Library")
                            }
                            ForEach(matches) { face in
                                row(face)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    if matches.count >= limit {
                        Text("Showing the first \(limit). Type more to narrow down.")
                            .font(.uiCaption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !actions.isEmpty {
                    Divider()
                    HStack(spacing: 6) {
                        ForEach(actions.indices, id: \.self) { index in
                            Button(actions[index].title) {
                                actions[index].perform()
                                open = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(12)
            .frame(width: 320)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.uiCaption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(_ face: FontFace) -> some View {
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
                        .font(.uiCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isChosen?(face) ?? store.isPinned(face) {
                    Image(systemName: "checkmark")
                        .font(.uiCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(RowHover())
        .help("\(face.family) \(face.style)")
    }

    /// On the preview's paper the button takes its ink; elsewhere it is a small system button.
    @ViewBuilder
    private var trigger: some View {
        if iconOnly {
            IconChip(symbol: "plus", help: help) { open.toggle() }
        } else if tool {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 4) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.uiCaption.weight(.medium))
                    }
                    Text(title)
                        .font(.uiCaption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .opacity(0.6)
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 4)
                .frame(height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .help(help)
        } else {
            styled(
                Button {
                    open.toggle()
                } label: {
                    if compact {
                        Text(title)
                    } else {
                        Label(title, systemImage: "plus")
                            .font(.uiCaption)
                    }
                }
            )
            .help(help)
        }
    }

    @ViewBuilder
    private func styled(_ button: some View) -> some View {
        if compact {
            button.buttonStyle(.chip())
        } else if paperInk != nil {
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
