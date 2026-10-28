import FontsoCore
import SwiftUI

/// "Used cuts": the fonts a preview mode is showing, folded into Adjust by default. Each card shows the cut,
/// whether it is pinned, and can be dragged into a list or the chat; the menu files one or all of them in a list.
struct UsedCutsBand<Trailing: View>: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("fontso.usedCuts.open") private var open = false
    @Environment(\.paperInk) private var paperInk
    var faces: [FontFace]
    var title = "Used cuts"
    var note: String?
    /// Takes a cut out of what the mode shows. Without it, cards have no remove button.
    var onRemove: ((FontFace) -> Void)?
    /// Inside another panel (Adjust): no band background or rule of its own.
    var embedded = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    open.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 10)
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text("\(faces.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ink.opacity(0.6))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ink)
                .help(open ? "Fold the used cuts" : "Show the used cuts")
                let pinned = faces.filter { store.isPinned($0) }.count
                if pinned > 0 {
                    Label("\(pinned)", systemImage: "pin.fill")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ink)
                        .help("\(pinned) of these \(pinned == 1 ? "is" : "are") pinned and stay while you browse")
                }
                Spacer(minLength: 0)
                trailing()
                if !faces.isEmpty {
                    listMenu(faces, title: faces.count == 1 ? "Add to list" : "Add all to list")
                        .help("File every used cut in a list")
                }
            }
            if open, !faces.isEmpty {
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(ink.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // One or two rows stay as they are; more scroll inside the band so the preview keeps its room.
                ViewThatFits(in: .vertical) {
                    grid
                    ScrollView { grid }
                }
                .frame(maxHeight: 118)
            }
        }
        .padding(.horizontal, embedded ? 0 : 14)
        .padding(.vertical, embedded ? 0 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(embedded ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            if !embedded {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 1)
            }
        }
        .controlSize(.small)
    }

    /// The preview's ink on paper, the system's primary colour elsewhere.
    private var ink: Color { paperInk ?? Color.primary }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(faces) { face in
                card(face)
            }
        }
    }

    private func card(_ face: FontFace) -> some View {
        let pinned = store.isPinned(face)
        return HStack(spacing: 6) {
            FamilySample(face: face, text: "Aa", size: 22)
                .frame(width: 44, height: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(face.family).lineLimit(1)
                Text(face.style)
                    .font(.caption2)
                    .foregroundStyle(ink.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                store.togglePin(face)
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? ink : ink.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help(pinned ? "Pinned: stays in the preview while you browse. Click to unpin." : "Pin: keep this cut in the preview while you browse")
            if let onRemove {
                Button {
                    onRemove(face)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ink.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help("Take this cut out")
            }
        }
        .font(.caption)
        .foregroundStyle(ink)
        .padding(6)
        .background(
            ink.opacity(pinned ? 0.12 : 0.05),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(pinned ? ink.opacity(0.6) : Color.clear)
        )
        .contentShape(Rectangle())
        .draggable(FontDragItem(identities: [face.identity]))
        .help("\(face.family) \(face.style). Drag onto a list in the sidebar to file it.")
        .contextMenu {
            listMenu([face], title: "Add to list")
            Button(pinned ? "Unpin" : "Pin") { store.togglePin(face) }
            Button("Show in library") {
                store.selection = [face.id]
                store.outsideSelection = []
            }
            if let onRemove {
                Divider()
                Button("Take out") { onRemove(face) }
            }
        }
    }

    private func listMenu(_ faces: [FontFace], title: String) -> some View {
        let identities = faces.map(\.identity)
        return Menu {
            if store.groups.isEmpty {
                Button("New list…") { store.showNewGroup = true }
            }
            ForEach(store.menuGroups) { group in
                Button(store.menuTitle(group)) { store.addToGroup(group.id, identities: identities) }
            }
        } label: {
            Label(title, systemImage: "text.badge.plus")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

extension UsedCutsBand where Trailing == EmptyView {
    init(faces: [FontFace], title: String = "Used cuts", note: String? = nil, onRemove: ((FontFace) -> Void)? = nil, embedded: Bool = false) {
        self.init(faces: faces, title: title, note: note, onRemove: onRemove, embedded: embedded) { EmptyView() }
    }
}
