import AppKit
import FontsoCore
import SwiftUI

struct NewsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var outsideAnchor: String?
    @State private var editingOutside: OutsideFont?

    var body: some View {
        ColumnScroll {
            VStack(alignment: .leading, spacing: 18) {
                Text(lane == .seen
                    ? "Names and posts you marked as seen. Remove one to hide it. No font file is downloaded."
                    : "New names from each foundry’s own site, and posts from its RSS feed when it has one. Mark one as seen, or remove it. No font file is downloaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.isReadingFoundries {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the foundries you follow")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if store.foundries.filter(\.watched).isEmpty {
                    emptyFollow
                } else {
                    let items = lane == .seen ? seen : fresh
                    if items.isEmpty && !store.isReadingFoundries {
                        Text(lane == .seen ? "Nothing has been marked as seen." : "No new name or post is waiting.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if items.count > 1 {
                        selectionBar(items)
                    }
                    ForEach(items) { notice in
                        newsRow(notice, in: items)
                    }
                    Button("Follow more") { store.showFoundries = true }
                        .buttonStyle(.borderless)
                        .help("Pick more foundries to follow")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await store.refreshWatchedFonts() }
        .sheet(item: $editingOutside) { item in
            OutsideFontForm(editing: item) { name, source, url in
                store.updateOutsideItem(item, name: name, source: source, url: url)
            }
        }
    }

    private var openNotices: [FoundryNotice] {
        let known = store.knownFamilyNames
        return store.notices.filter { !known.contains(folded($0.name)) }
    }

    private var lane: NewsLane {
        if case .news(let lane) = store.filter { return lane }
        return .fresh
    }

    private var fresh: [FoundryNotice] {
        openNotices
            .filter { !$0.seen }
            .sorted { lhs, rhs in
                let left = lhs.publishedAt ?? .distantPast
                let right = rhs.publishedAt ?? .distantPast
                if left != right { return left > right }
                return lhs.discoveredAt > rhs.discoveredAt
            }
    }

    private var seen: [FoundryNotice] {
        openNotices
            .filter(\.seen)
            .sorted { $0.discoveredAt > $1.discoveredAt }
    }

    private var emptyFollow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You are not following a foundry yet.")
                .font(.headline)
            Text("Star a foundry, or add your own. New names then sort into News, New, and Old.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.foundries.isEmpty {
                Button("Index foundries") { store.indexFoundries() }
                    .buttonStyle(.borderless)
                    .help("Fetch the list of foundries to follow")
            } else {
                ForEach(store.suggestedFoundries()) { foundry in
                    suggestionRow(foundry)
                }
                Button("All foundries") { store.showFoundries = true }
                    .buttonStyle(.borderless)
                    .help("See every foundry and choose which to follow")
            }
        }
    }

    private func suggestionRow(_ foundry: FoundryEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                store.setFoundryWatched(foundry, watched: true)
            } label: {
                Image(systemName: "star")
            }
            .buttonStyle(.borderless)
            .help("Follow \(foundry.name)")
            VStack(alignment: .leading, spacing: 2) {
                Text(foundry.name)
                Text(foundry.sources)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { NSWorkspace.shared.open(foundry.url) }
                .buttonStyle(.borderless)
                .help("Open the foundry’s website")
        }
        .padding(.vertical, 4)
    }

    private func isSelected(_ notice: FoundryNotice) -> Bool {
        store.outsideSelection.contains { $0.name == notice.name && $0.source == notice.foundryName }
    }

    private func selectedNotices(in items: [FoundryNotice]) -> [FoundryNotice] {
        items.filter(isSelected)
    }

    /// Acts on every selected notice at once. Shift and Command click build the selection, Select all takes the whole lane.
    private func selectionBar(_ items: [FoundryNotice]) -> some View {
        let chosen = selectedNotices(in: items)
        let allChosen = chosen.count == items.count
        return HStack(spacing: 10) {
            if chosen.isEmpty {
                Text("Shift-click or Command-click to pick several.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(chosen.count) of \(items.count) selected")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                if lane == .fresh {
                    Button("Mark seen") { markSeen(chosen) }
                        .buttonStyle(.borderless)
                        .help("Move the selected releases to Old")
                }
                Button("Remove", role: .destructive) { remove(chosen) }
                    .buttonStyle(.borderless)
                    .help("Remove the selected releases from News")
            }
            Spacer(minLength: 4)
            Button(allChosen ? "Deselect all" : "Select all") {
                if allChosen {
                    store.outsideSelection = []
                } else {
                    store.outsideSelection = items.map(outsideFont)
                    store.selection = []
                    outsideAnchor = items.first.map { outsideFont($0).id }
                }
            }
            .buttonStyle(.borderless)
            .help("Select or deselect every release in this view")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(chosen.isEmpty ? 0 : 0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func markSeen(_ notices: [FoundryNotice]) {
        for notice in notices where !notice.seen {
            store.markNoticeSeen(notice)
        }
        clearSelection(notices)
    }

    private func remove(_ notices: [FoundryNotice]) {
        for notice in notices {
            store.dismissNotice(notice)
        }
        clearSelection(notices)
    }

    private func clearSelection(_ notices: [FoundryNotice]) {
        let gone = Set(notices.map { outsideFont($0).id })
        store.outsideSelection.removeAll { gone.contains($0.id) }
    }

    private func newsRow(_ notice: FoundryNotice, in order: [FoundryNotice]) -> some View {
        let item = outsideFont(notice)
        let selected = isSelected(notice)
        let batch = selected ? selectedNotices(in: order) : [notice]
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.name)
                    .font(.body.weight(.medium))
                Text(notice.foundryName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(dateLine(notice))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .padding(.trailing, 120)
            .contentShape(Rectangle())
            .onTapGesture {
                select(item, in: order.map(outsideFont))
            }
            .help("Select for the preview, or drag it onto a list. The font file is not in the library.")
            HStack(spacing: 8) {
                if !notice.seen {
                    Button(batch.count > 1 ? "Seen (\(batch.count))" : "Seen") { markSeen(batch) }
                        .buttonStyle(.borderless)
                        .help(batch.count > 1 ? "Mark the \(batch.count) selected as seen" : "Mark as seen")
                }
                Button(batch.count > 1 ? "Remove (\(batch.count))" : "Remove") { remove(batch) }
                    .buttonStyle(.borderless)
                    .help(batch.count > 1 ? "Remove the \(batch.count) selected" : "Remove")
            }
            .padding(8)
        }
        .background(
            selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .draggable(FontDragItem(outsideName: item.name, outsideSource: item.source, outsideURL: item.url.absoluteString))
        .contextMenu {
            listMenuItems(item)
            Divider()
            Button("Edit…") { editingOutside = item }
            if lane == .fresh {
                Button(batch.count > 1 ? "Mark \(batch.count) as seen" : "Mark as seen") { markSeen(batch) }
            }
            Button(batch.count > 1 ? "Remove \(batch.count)" : "Remove", role: .destructive) { remove(batch) }
        }
    }

    @ViewBuilder
    private func listMenuItems(_ item: OutsideFont) -> some View {
        if store.groups.isEmpty {
            Button("New list…") { store.showNewGroup = true }
        } else {
            Menu("Add to list") {
                ForEach(store.menuGroups) { group in
                    Button(store.menuTitle(group)) {
                        store.addListLink(group.id, name: item.name, source: item.source, url: item.url)
                    }
                }
            }
        }
    }

    private func dateLine(_ notice: FoundryNotice) -> String {
        if let published = notice.publishedAt {
            return "Published \(published.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Found \(notice.discoveredAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func outsideFont(_ notice: FoundryNotice) -> OutsideFont {
        OutsideFont(
            name: notice.name,
            source: notice.foundryName,
            detail: dateLine(notice),
            url: notice.url
        )
    }

    private func select(_ item: OutsideFont, in order: [OutsideFont]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift),
           let anchor = outsideAnchor,
           let from = order.firstIndex(where: { $0.id == anchor }),
           let to = order.firstIndex(where: { $0.id == item.id }) {
            store.outsideSelection = Array(order[min(from, to)...max(from, to)])
            store.selection = []
        } else if flags.contains(.command) {
            if let index = store.outsideSelection.firstIndex(where: { $0.id == item.id }) {
                store.outsideSelection.remove(at: index)
            } else {
                store.outsideSelection.append(item)
            }
            outsideAnchor = item.id
        } else {
            store.outsideSelection = [item]
            store.selection = []
            outsideAnchor = item.id
        }
    }

    private func folded(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }
}
