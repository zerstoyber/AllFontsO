import AppKit
import FontsoCore
import SwiftUI

struct NewsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var outsideAnchor: String?
    @State private var editingOutside: OutsideFont?
    /// The width of the list of names; the line between the two columns drags it.
    @AppStorage("fontso.news.listWidth") private var listWidth = 290.0
    @State private var listDragStart: Double?
    @Environment(\.surface) private var surface

    var body: some View {
        let items = lane == .seen ? seen : fresh
        VStack(spacing: 0) {
            PaneTitle(title: "News", detail: lane == .seen ? "Old" : "New") {
                let reading = store.isCheckingNews || store.isReadingFoundries
                if reading {
                    ProgressView().controlSize(.mini)
                    Text("Reading the foundries you follow")
                        .font(AppChrome.small)
                        .foregroundStyle(surface.half)
                } else if let checked = store.newsCheckedAt {
                    Text(checkedLine(checked))
                        .font(AppChrome.small)
                        .foregroundStyle(surface.half)
                        .help("Every followed foundry is read again after six hours, at launch and while AllFontsO is open.")
                }
                if !store.foundries.filter(\.watched).isEmpty {
                    Button("Check now") { store.checkNews(force: true) }
                        .buttonStyle(.chip())
                        .disabled(reading)
                        .help("Read every followed foundry now and list the names that are new")
                }
                Button("Foundries") { store.showFoundries = true }
                    .buttonStyle(.chip())
                    .help("Pick the foundries to follow")
            }
            if store.foundries.filter(\.watched).isEmpty {
                ColumnScroll {
                    emptyFollow
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // The list of names on the left, the foundry's own page for the chosen one on the right.
                GeometryReader { proxy in
                    let width = clampedList(listWidth, in: proxy.size.width)
                    HStack(spacing: 0) {
                        listColumn(items)
                            .frame(width: width)
                        columnHandle(width: width, total: proxy.size.width)
                        pageColumn(items)
                    }
                }
            }
        }
        .task { store.checkNews() }
        .task(id: "\(lane)|\(items.first?.name ?? "")") {
            // The newest name opens by itself, so the page is there without a click.
            if store.outsideSelection.isEmpty, let first = items.first {
                store.outsideSelection = [outsideFont(first)]
                outsideAnchor = outsideFont(first).id
            }
        }
        .sheet(item: $editingOutside) { item in
            OutsideFontForm(editing: item) { name, source, url in
                store.updateOutsideItem(item, name: name, source: source, url: url)
            }
        }
    }

    /// Both columns keep room: the names at least 200 wide, the page at least 320.
    private func clampedList(_ width: Double, in total: CGFloat) -> CGFloat {
        let most = max(200, min(560, total - 320))
        return min(most, max(200, CGFloat(width)))
    }

    /// The line between the names and the page. A few points to either side of it take the pointer, so it drags easily.
    private func columnHandle(width: CGFloat, total: CGFloat) -> some View {
        Rectangle()
            .fill(surface.hairline)
            .frame(width: 0.5)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = listDragStart ?? Double(width)
                        listDragStart = start
                        listWidth = Double(clampedList(start + drag.translation.width, in: total))
                    }
                    .onEnded { _ in listDragStart = nil }
            )
            .padding(.horizontal, -4)
            .zIndex(1)
            .help("Drag to make the list of names wider or narrower")
    }

    private func listColumn(_ items: [FoundryNotice]) -> some View {
        VStack(spacing: 0) {
            if items.count > 1 {
                selectionBar(items)
                Rectangle()
                    .fill(surface.hairline)
                    .frame(height: 0.5)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if items.isEmpty && !store.isReadingFoundries && !store.isCheckingNews {
                        Text(lane == .seen ? "Nothing has been marked as seen." : "No new name or post is waiting.")
                            .font(AppChrome.type())
                            .foregroundStyle(surface.muted)
                            .padding(12)
                    }
                    ForEach(items) { notice in
                        newsRow(notice, in: items)
                        Rectangle()
                            .fill(surface.hairline)
                            .frame(height: 0.5)
                            .padding(.horizontal, 8)
                    }
                    Text(lane == .seen
                        ? "Names and posts you marked as seen. No font file is downloaded."
                        : "New names from each foundry’s own site, and posts from its RSS feed when it has one. No font file is downloaded.")
                        .font(AppChrome.small)
                        .foregroundStyle(surface.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func pageColumn(_ items: [FoundryNotice]) -> some View {
        let chosen = store.outsideSelection
        if chosen.count == 1, let item = chosen.first {
            // By name, not by address: making the page reached the link keeps the page on show.
            OutsidePage(item: item, onEdit: { editingOutside = item })
                .id(store.fontPageKey(item))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(chosen.isEmpty ? "Click a name on the left to open the foundry’s page for it here." : "\(chosen.count) names selected. Click one to open its page.")
                    .font(AppChrome.type())
                    .foregroundStyle(surface.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    /// The newest first: by the day a post was published, or the day a name was found on the foundry's site.
    private var fresh: [FoundryNotice] {
        openNotices
            .filter { !$0.seen }
            .sorted { lhs, rhs in
                let left = lhs.publishedAt ?? lhs.discoveredAt
                let right = rhs.publishedAt ?? rhs.discoveredAt
                if left != right { return left > right }
                if lhs.discoveredAt != rhs.discoveredAt { return lhs.discoveredAt > rhs.discoveredAt }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func checkedLine(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Checked today, \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Checked yesterday, \(time)" }
        return "Checked \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private var seen: [FoundryNotice] {
        openNotices
            .filter(\.seen)
            .sorted { $0.discoveredAt > $1.discoveredAt }
    }

    private var emptyFollow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You are not following a foundry yet.")
                .font(AppChrome.type(12, weight: .medium))
                .foregroundStyle(surface.ink)
            Text("Follow a foundry, or add your own. New names then sort into News, New, and Old.")
                .font(AppChrome.type())
                .foregroundStyle(surface.half)
                .fixedSize(horizontal: false, vertical: true)
            if store.foundries.isEmpty {
                Button("Index foundries") { store.indexFoundries() }
                    .buttonStyle(.chip())
                    .help("Fetch the list of foundries to follow")
            } else {
                ForEach(store.suggestedFoundries()) { foundry in
                    suggestionRow(foundry)
                }
                Button("All foundries") { store.showFoundries = true }
                    .buttonStyle(.chip())
                    .help("See every foundry and choose which to follow")
            }
        }
    }

    private func suggestionRow(_ foundry: FoundryEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(foundry.name)
                    .font(AppChrome.type())
                    .foregroundStyle(surface.ink)
                Text(foundry.sources)
                    .font(AppChrome.small)
                    .foregroundStyle(surface.half)
            }
            Spacer()
            Button("Follow") { store.setFoundryWatched(foundry, watched: true) }
                .buttonStyle(.chip())
                .help("Follow \(foundry.name)")
            Button("Open") { NSWorkspace.shared.open(foundry.url) }
                .buttonStyle(.chip())
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
        return HStack(spacing: 5) {
            Text(chosen.count > 1 ? "\(chosen.count) of \(items.count)" : "\(items.count) names")
                .font(AppChrome.small.monospacedDigit())
                .foregroundStyle(surface.half)
                .lineLimit(1)
            Spacer(minLength: 4)
            if chosen.count > 1 {
                if lane == .fresh {
                    Button("Seen") { markSeen(chosen) }
                        .help("Move the \(chosen.count) selected to Old")
                }
                Button("Remove") { remove(chosen) }
                    .help("Remove the \(chosen.count) selected from News")
            }
            Button(allChosen ? "Deselect all" : "Select all") {
                if allChosen {
                    store.outsideSelection = []
                } else {
                    store.outsideSelection = items.map(outsideFont)
                    store.selection = []
                    outsideAnchor = items.first.map { outsideFont($0).id }
                }
            }
            .help("Select or deselect every name in this view. Shift-click or Command-click picks several.")
        }
        .buttonStyle(.chip())
        .padding(.horizontal, 12)
        .frame(height: 30)
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
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.name)
                    .font(AppChrome.type(12, weight: selected ? .medium : .regular))
                    .foregroundStyle(surface.ink)
                    .lineLimit(2)
                Text("\(notice.foundryName), \(dateLine(notice))")
                    .font(AppChrome.small)
                    .foregroundStyle(surface.half)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                if !notice.seen {
                    Button("Seen") { markSeen(batch) }
                        .help(batch.count > 1 ? "Mark the \(batch.count) selected as seen" : "Mark as seen: it moves to Old")
                }
                Button("Remove") { remove(batch) }
                    .help(batch.count > 1 ? "Remove the \(batch.count) selected" : "Remove it from News")
            }
            .buttonStyle(.chip())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            selected ? surface.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: AppChrome.cardRadius, style: .continuous)
        )
        .modifier(RowHover())
        .contentShape(Rectangle())
        .onTapGesture {
            select(item, in: order.map(outsideFont))
        }
        .help("Click to open the foundry’s page for it, or drag it onto a list. The font file is not in the library.")
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
            return "published \(published.formatted(date: .abbreviated, time: .omitted))"
        }
        return "found \(notice.discoveredAt.formatted(date: .abbreviated, time: .omitted))"
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

/// The foundry's own page for a name that is not in the library, with its title and the buttons above it: back,
/// keep the page reached as the link, add to a list, edit, open in the browser.
struct OutsidePage: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.surface) private var surface
    var item: OutsideFont
    var onEdit: () -> Void
    @State private var status = FoundryPageStatus()

    var body: some View {
        let page = page
        let ready = page.path.count > 1 || store.resolvedFontPages.contains(store.fontPageKey(item))
        let reached = ready ? status.reached(from: page) : nil
        let shape = RoundedRectangle(cornerRadius: AppChrome.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if status.canGoBack {
                    IconChip(symbol: "chevron.left", help: "Back to the page before") {
                        status.backToken += 1
                    }
                }
                Text(item.name)
                    .font(AppChrome.type(AppChrome.smallSize + 1, weight: .medium))
                    .foregroundStyle(surface.ink)
                    .lineLimit(1)
                Text(item.source)
                    .font(AppChrome.small)
                    .foregroundStyle(surface.half)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let reached {
                    Button("Use this page") {
                        store.updateOutsideItem(item, name: item.name, source: item.source, url: reached)
                    }
                    .help("Keep the page on show as the link for \(item.name): \(reached.absoluteString)")
                }
                listMenu(reached)
                Button("Edit", action: onEdit)
                    .help("Change the name, source, or link")
                Button("Open") { NSWorkspace.shared.open(reached ?? (ready ? page : item.url)) }
                    .help("Open the page on show in your browser")
            }
            .buttonStyle(.chip())
            .padding(.horizontal, 10)
            .frame(height: 30)
            Rectangle()
                .fill(surface.stroke)
                .frame(height: 0.5)
            if ready {
                FoundryPageView(url: page, shared: $status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for the font’s page…")
                        .font(AppChrome.small)
                        .foregroundStyle(surface.half)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .task(id: store.fontPageKey(item)) {
                    await store.attachSpecimen(to: item)
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(surface.stroke, lineWidth: 0.5))
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Files the name in a list, with the page on show as its link.
    @ViewBuilder
    private func listMenu(_ reached: URL?) -> some View {
        if store.groups.isEmpty {
            Button("Add to list") { store.showNewGroup = true }
                .help("Make a list first, then add \(item.name) to it")
        } else {
            Menu {
                ForEach(store.menuGroups) { group in
                    Button(store.menuTitle(group)) {
                        store.addListLink(group.id, name: item.name, source: item.source, url: reached ?? page)
                    }
                }
                Divider()
                Button("New list…") { store.showNewGroup = true }
            } label: {
                Text("Add to list")
            }
            .chromeMenuChip(compact: true)
            .help("Add \(item.name) to one of your lists, with the page on show as its link. It stands there under Not in library.")
        }
    }

    private var page: URL {
        if !FoundryLookup.isDirectoryHost(item.url) {
            return item.url
        }
        return store.foundrySite(for: item) ?? item.url
    }
}

/// A foundry page inside a card, with what follows from clicking around in it: back, and keeping the page reached
/// as the link of the font.
struct LinkedPage: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.surface) private var surface
    var item: OutsideFont
    var page: URL
    var height: CGFloat?
    @State private var status = FoundryPageStatus()

    var body: some View {
        let reached = status.reached(from: page)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            if status.canGoBack || reached != nil {
                HStack(spacing: 6) {
                    if status.canGoBack {
                        IconChip(symbol: "chevron.left", help: "Back to the page before") {
                            status.backToken += 1
                        }
                    }
                    if let reached {
                        Button("Use this page") {
                            store.updateOutsideItem(item, name: item.name, source: item.source, url: reached)
                        }
                        .buttonStyle(.chip())
                        .help("Keep the page on show as the link for \(item.name)")
                        Text((reached.host ?? "") + reached.path)
                            .font(AppChrome.small)
                            .foregroundStyle(surface.half)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
            }
            FoundryPageView(url: page, shared: $status)
                .frame(height: height)
                .frame(maxHeight: height == nil ? .infinity : nil)
                .clipShape(shape)
                .overlay(shape.stroke(surface.stroke, lineWidth: 0.5))
        }
    }
}
