import AppKit
import FontsoCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @State private var helpTopic: HelpTopic?
    @Environment(\.openWindow) private var openWindow
    @AppStorage("fontso.sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("fontso.previewCollapsed") private var previewCollapsed = false
    @StateObject private var chrome = WindowChrome()

    /// Room for the window buttons at the left of the middle column when the sidebar is folded to a strip.
    private var middleInset: CGFloat {
        sidebarCollapsed ? max(0, chrome.leadingInset - 28) : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            workspace
            statusBar
        }
        .background(TitleBarIntegration(chrome: chrome))
        .task { await store.bootstrap() }
        .onChange(of: store.sort) { _, _ in store.persistPreferences() }
        .onChange(of: store.sortAscending) { _, _ in store.persistPreferences() }
        .onChange(of: store.searchFields) { _, _ in store.persistPreferences() }
        .onChange(of: store.showTrials) { _, _ in store.persistPreferences() }
        .onChange(of: store.selection) { _, selection in
            guard !selection.isEmpty, !store.outsideSelection.isEmpty else { return }
            switch store.filter {
            case .shape, .news:
                break
            default:
                store.outsideSelection = []
            }
        }
        .onChange(of: store.filter) { old, new in
            store.loadResearchMessages()
            store.viewChanged(from: old, to: new)
            if old == .news(.fresh) || new == .news(.fresh) {
                store.markNewsVisited()
            }
            switch (old, new) {
            case (.shape, .shape):
                break
            case (.news(let previous), .news(let next)):
                if previous != next { store.outsideSelection = [] }
            default:
                store.outsideSelection = []
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            store.importProviders(providers)
            return true
        }
        .alert("Notice", isPresented: alertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
        .confirmationDialog(
            "Remove folder from the library?",
            isPresented: removalPresented,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let folder = store.folderPendingRemoval {
                    store.removeFolder(folder)
                }
                store.folderPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                store.folderPendingRemoval = nil
            }
        } message: {
            Text("The files stay on disk. Only the AllFontsO entry is removed.")
        }
        .alert(newGroupTitle, isPresented: Bindable(store).showNewGroup) {
            TextField("Name", text: Bindable(store).newGroupName)
            Button("Create") { store.commitNewGroup() }
            Button("Cancel", role: .cancel) {
                store.newGroupName = ""
                store.newGroupParent = 0
            }
        } message: {
            Text("Drag fonts from the font list, or from Research, onto the list. Lists can be dragged into each other to nest them.")
        }
        .alert("Rename list", isPresented: renamePresented) {
            TextField("Name", text: Bindable(store).renameGroupName)
            Button("Save") { store.commitRenameGroup() }
            Button("Cancel", role: .cancel) { store.groupPendingRename = nil }
        }
        .alert("Rename", isPresented: titleRenamePresented) {
            TextField("Name", text: Bindable(store).renameTitle)
            Button("Save") { store.commitRenameTitle() }
            Button("Cancel", role: .cancel) { store.titlePending = nil }
        }
        .sheet(isPresented: Bindable(store).showFoundries) {
            FoundriesView()
                .environment(store)
        }
        .onChange(of: store.showReview) { _, open in
            guard open else { return }
            openWindow(id: "review")
            store.showReview = false
        }
        .sheet(item: $helpTopic) { topic in
            HelpSheet(topic: topic)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fontsoShowHelp)) { note in
            if let topic = note.object as? HelpTopic {
                helpTopic = topic
            }
        }
    }

    private var newGroupTitle: String {
        guard store.newGroupParent != 0, let parent = store.groups.first(where: { $0.id == store.newGroupParent }) else {
            return "New list"
        }
        return "New list in \(parent.name)"
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if !store.isLibraryReady {
                ProgressView()
                    .controlSize(.small)
                Text("Opening the library…")
                    .lineLimit(1)
            } else if store.isScanning {
                if store.scanTotal > 0 {
                    ProgressView(value: Double(store.scanCompleted), total: Double(max(store.scanTotal, 1)))
                        .controlSize(.small)
                        .frame(width: 120)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(scanLabel)
                    .lineLimit(1)
                Button("Cancel") { store.cancelScan() }
                    .buttonStyle(.borderless)
                    .help("Stop reading the folders")
            } else {
                Text(store.summaryText)
            }
            Spacer()
            if store.isLibraryReady && !store.isScanning && !store.statusText.isEmpty {
                Text(store.statusText)
                    .lineLimit(1)
            }
            Button {
                store.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isScanning || store.folders.isEmpty)
            .help("Rescan")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var scanLabel: String {
        if store.scanTotal == 0 {
            return "Looking for font files…"
        }
        let name = store.scanFileName.isEmpty ? "" : " · \(store.scanFileName)"
        return "\(store.scanCompleted) of \(store.scanTotal)\(name)"
    }

    @ViewBuilder
    private var workspace: some View {
        if !store.isLibraryReady {
            LoadingColumns()
        } else if store.previewExpanded {
            SpecimenView()
                .environment(\.barLeadingInset, chrome.leadingInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                if sidebarCollapsed {
                    collapsedStrip("AllFontsO", symbol: "sidebar.left", help: "Show the sidebar", belowWindowButtons: true) {
                        sidebarCollapsed = false
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            columnTitle("AllFontsO")
                                .padding(.leading, chrome.leadingInset)
                            collapseButton(symbol: "sidebar.left", help: "Hide the sidebar") {
                                sidebarCollapsed = true
                            }
                        }
                        .frame(height: ColumnBarMetrics.height)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .background(WindowDragArea())
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.12))
                                .frame(height: 1)
                        }
                        SidebarView()
                    }
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                middleColumn
                    .environment(\.barLeadingInset, middleInset)
                    .frame(minWidth: 340, idealWidth: 480, maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .background(ColumnEqualizer())
                if previewCollapsed {
                    collapsedStrip("Preview", symbol: "sidebar.right", help: "Show the preview") {
                        previewCollapsed = false
                    }
                } else {
                    SpecimenView()
                        .frame(minWidth: 340, idealWidth: 480, maxWidth: .infinity)
                        .frame(maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A narrow stand-in for a collapsed column: one button to bring it back, and its name running down the side.
    private func collapsedStrip(_ title: String, symbol: String, help: String, belowWindowButtons: Bool = false, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            if belowWindowButtons, !chrome.fullScreen {
                // The window buttons sit here; the strip's own button moves under them.
                Color.clear
                    .frame(height: ColumnBarMetrics.height)
                    .background(WindowDragArea())
            }
            collapseButton(symbol: symbol, help: help, action: action)
                .frame(height: ColumnBarMetrics.height)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .rotationEffect(.degrees(90))
                .frame(width: 28, height: 120)
            Spacer()
        }
        .frame(width: 28)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private func collapseButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .help(help)
    }

    private var middleColumn: some View {
        VStack(spacing: 0) {
            switch store.filter {
            case .research:
                if store.mcpEnabled {
                    columnTitle("Chat")
                    ResearchHandledByMCPView()
                } else {
                    columnTitle(store.filterTitle)
                    ResearchChatView()
                }
            case .shape:
                columnTitle(store.filterTitle)
                ShapeView()
            case .news:
                columnTitle("News")
                NewsView()
            default:
                ListColumnBar()
                FontBrowserView()
            }
        }
    }

    private func columnTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.leading, middleInset)
            .frame(height: ColumnBarMetrics.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .background(WindowDragArea())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 1)
            }
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { store.groupPendingRename != nil },
            set: { if !$0 { store.groupPendingRename = nil } }
        )
    }

    private var titleRenamePresented: Binding<Bool> {
        Binding(
            get: { store.titlePending != nil },
            set: { if !$0 { store.titlePending = nil } }
        )
    }

    private var removalPresented: Binding<Bool> {
        Binding(
            get: { store.folderPendingRemoval != nil },
            set: { if !$0 { store.folderPendingRemoval = nil } }
        )
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case library
    case lists
    case research
    case folders

    var id: String { rawValue }

    static let defaultOrder = "library,lists,research,folders"

    var title: String {
        switch self {
        case .library: return "Library"
        case .lists: return "Lists"
        case .research: return "Research"
        case .folders: return "Source Folders"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "books.vertical"
        case .lists: return "list.bullet"
        case .research: return "brain"
        case .folders: return "folder"
        }
    }
}

struct SidebarView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("fontso.sidebar.order") private var orderRaw = SidebarSection.defaultOrder
    @AppStorage("fontso.sidebar.collapsed") private var collapsedRaw = ""

    var body: some View {
        ColumnScroll {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(orderedSections) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        sectionHeader(section)
                        if isExpanded(section) {
                            sectionRows(section)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
    }

    private var orderedSections: [SidebarSection] {
        let parsed = orderRaw.split(separator: ",").compactMap { SidebarSection(rawValue: String($0)) }
        var seen = Set(parsed.map(\.rawValue))
        var items = parsed
        for section in SidebarSection.allCases where seen.insert(section.rawValue).inserted {
            items.append(section)
        }
        return items
    }

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: ",").map(String.init))
    }

    private func isExpanded(_ section: SidebarSection) -> Bool {
        !collapsed.contains(section.rawValue)
    }

    private func toggle(_ section: SidebarSection) {
        var next = collapsed
        if next.contains(section.rawValue) {
            next.remove(section.rawValue)
        } else {
            next.insert(section.rawValue)
        }
        collapsedRaw = next.sorted().joined(separator: ",")
    }

    private func moveSection(_ source: String, before target: String) {
        guard source != target, SidebarSection(rawValue: source) != nil else { return }
        var items = orderedSections.map(\.rawValue)
        guard let from = items.firstIndex(of: source) else { return }
        items.remove(at: from)
        let index = items.firstIndex(of: target) ?? items.count
        items.insert(source, at: index)
        orderRaw = items.joined(separator: ",")
    }

    private func sectionHeader(_ section: SidebarSection) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded(section) ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: section.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(section) }
            .help(isExpanded(section) ? "Collapse" : "Expand")
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Drag to reorder this section")
                .draggable(section.rawValue)
            if let add = addAction(section) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help(add.help)
                    .contentShape(Circle())
                    .highPriorityGesture(TapGesture().onEnded { add.perform() })
            }
        }
        .padding(.vertical, 4)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first else { return false }
            moveSection(raw, before: section.rawValue)
            return true
        }
    }

    private func addAction(_ section: SidebarSection) -> (help: String, perform: () -> Void)? {
        switch section {
        case .lists:
            return ("New list", { store.showNewGroup = true })
        case .research:
            return nil
        case .folders:
            return ("New source folder", { store.createSourceFolder() })
        default:
            return nil
        }
    }

    @ViewBuilder
    private func sectionRows(_ section: SidebarSection) -> some View {
        switch section {
        case .library:
            sidebarRow("All fonts", filter: .all, count: store.count(.all))
            sidebarRow("Available", filter: .available, count: store.count(.available))
            sidebarRow("Inactive", filter: .inactive, count: store.count(.inactive))
            sidebarRow("Variable fonts", filter: .variable, count: store.count(.variable))
            sidebarRow("Webfonts", filter: .webfonts, count: store.count(.webfonts))
            sidebarRow("OTF, TTF", filter: .desktop, count: store.count(.desktop))
                .help("OTF, TTF, TTC, OTC, and dfont.")
            sidebarRow("Trial", filter: .category(.trial), count: store.count(.category(.trial)))
            dropRow("Favorites", filter: .favorites, count: store.count(.favorites)) { items, _ in
                store.setFavorites(items.flatMap(\.identities), on: true)
                return true
            }
            sidebarRow("Licensed", filter: .licensed, count: store.count(.licensed))
                .help("Cuts with a license note. Enter the project under Info › License in the preview.")
            subsectionLabel("Categories", help: "", add: nil)
                .help("Sans, serif, slab, script, display, and the rest, from the font's own classification.")
            ForEach(FontCategory.allCases.filter { $0 != .trial }, id: \.self) { category in
                sidebarRow(category.rawValue, filter: .category(category), count: store.count(.category(category)))
            }
        case .lists:
            groupRows(parent: 0, depth: 0)
        case .research:
            subsectionLabel("Shape", help: "New shape search") { store.createShapeSearch() }
            if store.shapeSearches.isEmpty {
                Text("No shape searches yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .padding(.vertical, 4)
            }
            ForEach(store.orderedShapeSearches) { search in
                dropRow(
                    search.title,
                    filter: .shape(search.id),
                    count: nil,
                    dragItem: FontDragItem(sidebarKind: "shapes", sidebarID: search.id)
                ) { items, edge in
                    if let moved = items.first(where: { $0.sidebarKind == "shapes" }) {
                        store.moveSidebarItem(kind: "shapes", id: moved.sidebarID, onto: search.id, edge: edge)
                        return true
                    }
                    return store.keepShapeReference(search.id, identities: items.flatMap(\.identities))
                }
                    .help("Drop a font here to keep it as the reference. Drag the row to rearrange.")
                    .contextMenu {
                        Button("Rename") { store.beginRenameShape(search) }
                        Button("Delete search", role: .destructive) { store.deleteShapeSearch(search) }
                    }
            }
            if store.mcpEnabled {
                subsectionLabel("Chats", help: "", add: nil)
                mutedRow("Handled by your own AI", symbol: "point.3.connected.trianglepath.dotted", filter: .research(0))
                    .help("MCP is on. Your own AI program drives AllFontsO; switch it off under Model to chat here again.")
            } else {
                subsectionLabel("Chats", help: "New research chat") { store.createResearchChat() }
            }
            if store.researchChats.isEmpty, !store.mcpEnabled {
                Text("No chats yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .padding(.vertical, 4)
            }
            ForEach(store.mcpEnabled ? [] : store.orderedResearchChats) { chat in
                dropRow(
                    chat.title,
                    filter: .research(chat.id),
                    count: nil,
                    dragItem: FontDragItem(sidebarKind: "chats", sidebarID: chat.id)
                ) { items, edge in
                    if let moved = items.first(where: { $0.sidebarKind == "chats" }) {
                        store.moveSidebarItem(kind: "chats", id: moved.sidebarID, onto: chat.id, edge: edge)
                        return true
                    }
                    store.filter = .research(chat.id)
                    let lists = items.map(\.listName).filter { !$0.isEmpty }
                    if lists.isEmpty {
                        store.queueResearchReference(items.flatMap(\.identities))
                    } else {
                        store.queueResearchList(lists[0])
                    }
                    return true
                }
                .contextMenu {
                    Button("Rename") { store.beginRenameChat(chat) }
                    Button("Delete chat", role: .destructive) {
                        store.deleteResearchChat(chat)
                    }
                }
            }
            Text("News")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .padding(.leading, 6)
            SidebarDropRow(title: "New", filter: .news(.fresh), count: store.noticeCount(.fresh), badge: store.hasUnvisitedNews, onDrop: nil)
                .help("Releases and names you have not marked as seen.")
            sidebarRow("Old", filter: .news(.seen), count: store.noticeCount(.seen))
                .help("Releases and names marked as seen.")
        case .folders:
            ForEach(store.folders) { folder in
                sidebarRow(folder.displayName, filter: .folder(folder.id), count: store.count(.folder(folder.id)))
                    .help(folder.path)
                    .contextMenu {
                        Button("Reveal in Finder") { store.reveal(path: folder.path) }
                        Button("Remove from library", role: .destructive) {
                            store.folderPendingRemoval = folder
                        }
                    }
            }
        }
    }

    private func subsectionLabel(_ title: String, help: String, add: (() -> Void)?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let add {
                Button(action: add) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(help)
            }
        }
        .padding(.top, 10)
        .padding(.leading, 6)
    }

    private func sidebarRow(_ title: String, filter: LibraryFilter, count: Int?) -> some View {
        sidebarButton(title, filter: filter, count: count)
    }

    /// A grey, italic row for a state rather than a list. Tapping still opens the matching column.
    private func mutedRow(_ title: String, symbol: String, filter: LibraryFilter) -> some View {
        let selected = store.filter == filter
        return HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
            Text(title)
                .italic()
                .lineLimit(1)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected ? Color.secondary.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .onTapGesture { store.filter = filter }
    }

    private func dropRow(
        _ title: String,
        filter: LibraryFilter,
        count: Int?,
        dragItem: FontDragItem? = nil,
        onDrop: @escaping ([FontDragItem], DropEdge) -> Bool
    ) -> some View {
        SidebarDropRow(title: title, filter: filter, count: count, dragItem: dragItem, onDrop: onDrop)
    }

    /// The lists inside `parent`, each followed by its own sub-lists. Lists can be dropped onto the middle of
    /// another list to nest them, and fonts dropped on a list join that list.
    private func groupRows(parent: Int64, depth: Int) -> AnyView {
        let children = store.childGroups(of: parent)
        return AnyView(
            ForEach(children) { group in
                let hasChildren = store.hasChildGroups(group.id)
                let collapsed = store.collapsedGroups.contains(group.id)
                SidebarDropRow(
                    title: group.name,
                    filter: .group(group.id),
                    count: store.count(.group(group.id)),
                    dragItem: FontDragItem(
                        identities: store.listOrder[group.id] ?? Array(store.membership[group.id, default: []]),
                        listName: group.name,
                        sidebarKind: "groups",
                        sidebarID: group.id
                    ),
                    // A sub-list starts where its parent's title starts: past the parent's chevron.
                    indent: CGFloat(depth) * 20,
                    nested: depth > 0,
                    disclosure: hasChildren ? !collapsed : nil,
                    allowsInside: true,
                    onDisclose: { store.toggleGroupCollapsed(group.id) },
                    onDrop: { items, edge in
                        if let moved = items.first(where: { $0.sidebarKind == "groups" }) {
                            store.moveSidebarItem(kind: "groups", id: moved.sidebarID, onto: group.id, edge: edge)
                            return true
                        }
                        store.addToGroup(group.id, identities: items.flatMap(\.identities))
                        for item in items {
                            guard !item.outsideName.isEmpty, let url = URL(string: item.outsideURL) else { continue }
                            store.addListLink(group.id, name: item.outsideName, source: item.outsideSource, url: url)
                        }
                        return true
                    }
                )
                .contextMenu {
                    Button("Rename") {
                        store.renameGroupName = group.name
                        store.groupPendingRename = group
                    }
                    Button("New sub-list…") {
                        store.newGroupParent = group.id
                        store.showNewGroup = true
                    }
                    if group.parentID != 0 {
                        Button("Move to top level") { store.setGroupParent(group.id, parentID: 0) }
                    }
                    let targets = store.orderedGroups.filter { $0.id != group.id && $0.id != group.parentID && !store.listScope(group.id).contains($0.id) }
                    if !targets.isEmpty {
                        Menu("Move into") {
                            ForEach(targets) { target in
                                Button(store.groupPath(target.id).map(\.name).joined(separator: " › ")) {
                                    store.setGroupParent(group.id, parentID: target.id)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Delete list", role: .destructive) { store.deleteGroup(group) }
                }
                if hasChildren, !collapsed {
                    groupRows(parent: group.id, depth: depth + 1)
                }
            }
        )
    }

    private func sidebarButton(_ title: String, filter: LibraryFilter, count: Int?) -> some View {
        SidebarDropRow(title: title, filter: filter, count: count, onDrop: nil)
    }

}

private struct SidebarDropRow: View {
    @Environment(LibraryStore.self) private var store
    var title: String
    var filter: LibraryFilter
    var count: Int?
    var dragItem: FontDragItem? = nil
    var badge = false
    /// Nested rows sit further in.
    var indent: CGFloat = 0
    /// Sub-lists are set a little smaller, so the main lists stay the landmarks.
    var nested = false
    /// A chevron for rows with children: true when open, false when folded, nil for rows without children.
    var disclosure: Bool? = nil
    /// Rows of the same kind dropped onto the middle go inside this row.
    var allowsInside = false
    var onDisclose: (() -> Void)? = nil
    var onDrop: (([FontDragItem], DropEdge) -> Bool)?
    @State private var targeted = false
    @State private var confirmed = false

    /// Rows of this kind can be dropped above or below this one to rearrange the section.
    private var reorderKind: String { dragItem?.sidebarKind ?? "" }

    var body: some View {
        if let onDrop {
            row
                .modifier(InsertionDrop(
                    isReorder: { items in isReorder(items) },
                    hoveringOthers: { targeted = $0 },
                    allowsInside: allowsInside,
                    perform: { items, edge in
                        let accepted = onDrop(items, edge)
                        if accepted, !isReorder(items) {
                            confirmed = true
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                confirmed = false
                            }
                        }
                        return accepted
                    }
                ))
        } else {
            row
        }
    }

    private func isReorder(_ items: [FontDragItem]) -> Bool {
        !reorderKind.isEmpty && items.contains { $0.sidebarKind == reorderKind && $0.sidebarID != dragItem?.sidebarID }
    }

    private var row: some View {
        let selected = store.filter == filter
        let highlighted = targeted || confirmed
        return HStack {
            if let disclosure {
                Button {
                    onDisclose?()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(disclosure ? 90 : 0))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected || highlighted ? Color.white.opacity(0.9) : Color.secondary)
                .help(disclosure ? "Fold sub-lists away" : "Show sub-lists")
            }
            Text(title)
                .lineLimit(1)
            if badge {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .help("New since you last looked")
            }
            Spacer()
            if confirmed {
                Image(systemName: "checkmark.circle.fill")
                    .imageScale(.small)
            }
            if let count {
                Text("\(count)")
                    .foregroundStyle(selected || highlighted ? Color.white.opacity(0.85) : Color.secondary)
                    .monospacedDigit()
            }
        }
        .font(nested ? .callout : nil)
        .padding(.vertical, nested ? 3 : 4)
        .padding(.horizontal, 6)
        .padding(.leading, indent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowFill(selected: selected), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white, lineWidth: 2)
            }
        }
        .foregroundStyle(selected || highlighted ? Color.white : Color.primary)
        .modifier(OptionalListDrag(item: dragItem))
        .onTapGesture {
            store.filter = filter
        }
    }

    private func rowFill(selected: Bool) -> Color {
        if confirmed { return Color.green.opacity(0.85) }
        if targeted { return Color.accentColor.opacity(0.85) }
        if selected { return Color.accentColor }
        return Color.clear
    }
}

private struct OptionalListDrag: ViewModifier {
    var item: FontDragItem?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let item {
            content
                .draggable(item)
                .help(item.listName.isEmpty ? "Drag to rearrange" : "Drag to rearrange, or into the chat")
        } else {
            content
        }
    }
}

enum ColumnBarMetrics {
    static let height: CGFloat = 48
}

/// At launch, gives the list and the preview the same width. Dragging the divider afterwards stays as the user left it.
private struct ColumnEqualizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { EqualizeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class EqualizeView: NSView {
    private var done = false

    override func layout() {
        super.layout()
        guard !done, let split = ancestorSplitView(), split.subviews.count >= 3, let content = window?.contentView else { return }
        let width = split.bounds.width
        guard width > 700, abs(width - content.bounds.width) < 2 else { return }
        done = true
        let sidebar = split.subviews[0].frame.width
        let half = (width - sidebar - split.dividerThickness * 2) / 2
        split.setPosition(sidebar, ofDividerAt: 0)
        split.setPosition(sidebar + split.dividerThickness + half, ofDividerAt: 1)
    }

    private func ancestorSplitView() -> NSSplitView? {
        var view: NSView? = superview
        while let current = view {
            if let split = current as? NSSplitView { return split }
            view = current.superview
        }
        return nil
    }
}

private struct LoadingColumns: View {
    @State private var dim = false

    var body: some View {
        HSplitView {
            panel
                .frame(minWidth: 180, idealWidth: 210, maxWidth: 300)
            panel
                .frame(minWidth: 340, idealWidth: 480, maxWidth: .infinity)
            panel
                .frame(minWidth: 340, idealWidth: 480, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                dim = true
            }
        }
    }

    private var panel: some View {
        Color(nsColor: .windowBackgroundColor)
            .opacity(dim ? 0.45 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FontsoCommands: Commands {
    var store: LibraryStore

    var body: some Commands {
        CommandMenu("Library") {
            Button("Add folder…") { store.addFolders() }
                .keyboardShortcut("o")
            Button("Search") { store.focusSearch() }
                .keyboardShortcut("f")
            Button("Rescan") { store.rescan() }
                .keyboardShortcut("r")
                .disabled(store.folders.isEmpty)
            Divider()
            Button("Sort automatically") { store.sort = .automatic }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("New list…") { store.showNewGroup = true }
            Button("New shape search") { store.createShapeSearch() }
            Button("New research chat") { store.createResearchChat() }
                .disabled(store.mcpEnabled)
            Button("News") { store.filter = .news(.fresh) }
            Button("Foundries…") { store.showFoundries = true }
            Button("Review library…") { store.showReview = true }
            Button("Organize on disk…") { store.organizeOnDisk() }
            Divider()
            Button("Activate") { store.activateSelection() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(store.selection.isEmpty)
            Button("Deactivate") { store.deactivateSelection() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty)
            Button("Activate visible") { store.activateVisible() }
        }
        CommandGroup(replacing: .help) {
            Button("What you can do") { HelpWindow.show(.capabilities) }
            Divider()
            Button("Credits") { HelpWindow.show(.credits) }
        }
    }
}
