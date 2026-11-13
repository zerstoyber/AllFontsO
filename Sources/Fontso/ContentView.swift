import AppKit
import FontsoCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @State private var helpTopic: HelpTopic?
    @Environment(\.openWindow) private var openWindow
    @StateObject private var chrome = WindowChrome()
    @AppStorage("fontso.navigationWidth") private var navigationWidth = 333.0
    @State private var navigationDragStart: Double?
    @ObservedObject private var theme = PaperSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            workspace
                .padding(.horizontal, AppChrome.inset)
                .padding(.bottom, AppChrome.inset)
        }
        // The window buttons sit in the same row as the name and the buttons, so the content starts at the very top.
        .ignoresSafeArea(.container, edges: .top)
        .background(AppChrome.window)
        .background(TitleBarIntegration(chrome: chrome))
        .chromeDefaults()
        .task {
            await store.bootstrap()
            store.startNewsWatch()
        }
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
            if let pending = store.pendingOutside {
                store.pendingOutside = nil
                store.outsideSelection = [pending]
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

    /// One row: window buttons, name and version, what happened last, and the two buttons.
    private var titleBar: some View {
        HStack(spacing: 8) {
            Text("AllFontsO")
            Text(AppChrome.versionText)
            Spacer(minLength: 8)
            lastAction
            Button(store.previewExpanded ? "Show navigation" : "Hide navigation") {
                store.previewExpanded.toggle()
            }
            .buttonStyle(.chip(on: store.previewExpanded))
            .help(store.previewExpanded ? "Show the navigation beside the preview" : "Hide the navigation and give the preview the whole window")
            themeMenu
            Button("Rescan") { store.rescan() }
                .buttonStyle(.chip())
                .disabled(store.isScanning || store.folders.isEmpty)
                .help("Rescan the source folders")
        }
        .font(AppChrome.type(11))
        .foregroundStyle(AppChrome.muted)
        // In full screen there are no window buttons: the name lines up with the text of the navigation.
        .padding(.leading, chrome.fullScreen ? AppChrome.inset + 12 : chrome.leadingInset + 6)
        .padding(.trailing, AppChrome.inset)
        .frame(height: AppChrome.titleBarHeight)
        .background(AppChrome.window)
        .background(WindowDragArea())
    }

    /// Dark, light, or with the Mac, for the whole window.
    private var themeMenu: some View {
        Menu {
            ForEach(ThemeMode.allCases) { mode in
                Button {
                    theme.setMode(mode)
                } label: {
                    if theme.mode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            Text("Theme")
        }
        .chromeMenuChip(compact: true)
        .help("Dark, light, or the same as the Mac")
    }

    @ViewBuilder
    private var lastAction: some View {
        if !store.isLibraryReady {
            ProgressView()
                .controlSize(.mini)
            Text("Opening the library…")
                .lineLimit(1)
        } else if store.isScanning {
            if store.scanTotal > 0 {
                ProgressView(value: Double(store.scanCompleted), total: Double(max(store.scanTotal, 1)))
                    .controlSize(.mini)
                    .frame(width: 88)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(scanLabel)
                .lineLimit(1)
            Button("Cancel") { store.cancelScan() }
                .buttonStyle(.chip())
                .help("Stop reading the folders")
        } else if !store.statusText.isEmpty {
            Text(store.statusText)
                .lineLimit(1)
                .help("The last thing AllFontsO did")
        } else {
            Text(store.summaryText)
                .lineLimit(1)
        }
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
            workspacePane
                .environment(\.barLeadingInset, 0)
                .modifier(WorkspacePaper(themed: showsNews))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Two panels with open space between them. The space itself drags the navigation wider or narrower.
            HStack(spacing: 0) {
                // The navigation and, under it, Info: two panels of their own. The space between them sizes Info.
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        SidebarView()
                            .chromePanel()
                        SpecimenView(role: .info, infoLimit: max(140, proxy.size.height * 0.7))
                    }
                }
                .frame(width: min(420, max(260, navigationWidth)))
                .frame(maxHeight: .infinity)
                navigationGap
                workspacePane
                    .environment(\.barLeadingInset, 0)
                    .modifier(WorkspacePaper(themed: showsNews))
                    .frame(minWidth: 480, maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var navigationGap: some View {
        Color.clear
            .frame(width: AppChrome.gap)
            .frame(maxHeight: .infinity)
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
                        let start = navigationDragStart ?? min(420, max(260, navigationWidth))
                        navigationDragStart = start
                        navigationWidth = min(420, max(260, start + drag.translation.width))
                    }
                    .onEnded { _ in navigationDragStart = nil }
            )
            .help("Drag to make the navigation wider or narrower")
    }

    /// News and the chat are no previews of fonts: they keep the colours of the theme.
    private var showsNews: Bool {
        switch store.filter {
        case .news, .research: return true
        default: return false
        }
    }

    @ViewBuilder
    private var workspacePane: some View {
        switch store.filter {
        case .research:
            VStack(spacing: 0) {
                if store.mcpEnabled {
                    PaneTitle(title: "Chat", detail: "Your own AI")
                    ResearchHandledByMCPView()
                } else {
                    ResearchChatView()
                }
            }
        case .news:
            NewsView()
        default:
            SpecimenView()
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
    case folders
    case research
    case news

    var id: String { rawValue }

    static let defaultOrder = "library,lists,folders,research,news"

    var title: String {
        switch self {
        case .library: return "Library"
        case .lists: return "Lists"
        case .folders: return "Source Folders"
        case .research: return "Chats"
        case .news: return "News"
        }
    }
}

/// How far the navigation has scrolled and where its open rows sit. Only the title that floats under a section
/// header reads it, so scrolling redraws nothing else.
@Observable
final class NavigationScroll {
    /// The top of the rows inside the scroll view; negative once scrolled.
    var offset: CGFloat = 0
    /// Open lists and views by key: where their row sits among the rows, and how tall it is.
    var rows: [String: CGRect] = [:]

    static let space = "navigation"
    static let rowSpace = "navigationRows"

    /// The open list or view whose families are passing under its section's title, and how far its own title
    /// has been pushed up by the list's end.
    func floating(_ counts: [String: Int]) -> (key: String, lift: CGFloat)? {
        let header = SidebarMetrics.headerHeight
        for (key, count) in counts where count > 0 {
            guard let frame = rows[key] else { continue }
            let top = frame.minY + offset
            let end = top + frame.height + CGFloat(count) * SidebarMetrics.familyHeight
            if top < header - 0.5, end > header {
                return (key, min(0, end - header - frame.height))
            }
        }
        return nil
    }
}

struct SidebarView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("fontso.sidebar.order") private var orderRaw = SidebarSection.defaultOrder
    @AppStorage("fontso.sidebar.collapsed") private var collapsedRaw = ""
    @State private var scroll = NavigationScroll()
    /// The section a dragged section would land in front of; "end" for behind the last one.
    @State private var sectionTarget: String?

    var body: some View {
        let sections = orderedSections
        // Every section's title stays at the top while its rows scroll, and under it the title of the open list
        // or library view whose families are passing by.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    let owners = isExpanded(section) ? openOwners(section) : []
                    Section {
                        if isExpanded(section) {
                            sectionRows(section, owners: owners)
                        }
                        Color.clear.frame(height: 14)
                    } header: {
                        sectionHeader(section, owners: owners)
                    }
                }
                sectionEnd
            }
            .coordinateSpace(name: NavigationScroll.rowSpace)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.frame(in: .named(NavigationScroll.space)).minY, initial: true) { _, value in
                            scroll.offset = value
                        }
                }
            }
            .font(AppChrome.type())
            .foregroundStyle(AppChrome.ink)
            .padding(.horizontal, SidebarMetrics.edge)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .coordinateSpace(name: NavigationScroll.space)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        sectionTarget = nil
    }

    private func sectionHeader(_ section: SidebarSection, owners: [Owner]) -> some View {
        let targeted = sectionTarget == section.rawValue
        return HStack(spacing: 8) {
            HStack(spacing: 3.5) {
                ChromeChevron(open: isExpanded(section))
                Text(section.title)
                    .font(AppChrome.type(12, weight: .medium))
                    .foregroundStyle(AppChrome.ink)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(section) }
            .help(isExpanded(section) ? "Fold \(section.title) away" : "Show \(section.title)")
            if let add = addAction(section) {
                SidebarAddButton(help: add.help, action: add.perform)
            }
            Image(systemName: "equal")
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(AppChrome.half)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
                .modifier(RowHover(radius: 3))
                .help("Drag to move \(section.title) up or down")
                .draggable(section.rawValue) {
                    // What travels with the pointer: the section's title on a chip.
                    Text(section.title)
                        .font(AppChrome.type(12, weight: .medium))
                        .foregroundStyle(AppChrome.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppChrome.window, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
        }
        .padding(.leading, SidebarMetrics.textInset - 13.5)
        .padding(.trailing, SidebarMetrics.trailing - 2)
        .frame(height: SidebarMetrics.headerHeight)
        .background {
            Rectangle().fill(AppChrome.panel)
            if targeted {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(AppChrome.selection)
            }
        }
        .overlay(alignment: .top) {
            // Where a dragged section lands: in front of this one.
            if targeted {
                InsertionLine()
                    .offset(y: -3.5)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            PinnedRule(scroll: scroll, counts: Dictionary(uniqueKeysWithValues: owners.map { ($0.key, $0.rowCount) }))
        }
        // Behind the title, so it slides away under it when the last family of its list has passed.
        .background(alignment: .top) {
            if !owners.isEmpty {
                FloatingOwnerTitle(scroll: scroll, counts: Dictionary(uniqueKeysWithValues: owners.map { ($0.key, $0.rowCount) })) { key in
                    if let owner = owners.first(where: { $0.key == key }) {
                        ownerRow(owner)
                            .background { Rectangle().fill(AppChrome.panel) }
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(AppChrome.hairline).frame(height: 0.5)
                            }
                    }
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, SidebarSection(rawValue: raw) != nil else { return false }
            moveSection(raw, before: section.rawValue)
            return true
        } isTargeted: { inside in
            if inside {
                sectionTarget = section.rawValue
            } else if sectionTarget == section.rawValue {
                sectionTarget = nil
            }
        }
    }

    /// The room under the last section: a dragged section dropped here goes to the end.
    private var sectionEnd: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if sectionTarget == "end" {
                    InsertionLine()
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, SidebarSection(rawValue: raw) != nil else { return false }
                moveSection(raw, before: "")
                return true
            } isTargeted: { inside in
                if inside {
                    sectionTarget = "end"
                } else if sectionTarget == "end" {
                    sectionTarget = nil
                }
            }
    }

    // MARK: Open lists and views

    /// A row with its families folded open: a list, a library view, or a source folder.
    struct Owner {
        var key: String
        var title: String
        var filter: LibraryFilter
        var entry: ListEntry?
        var families: [LibraryStore.NavigationFamily]
        /// Fonts from the news saved in the list. They follow the families.
        var links: [OutsideFont] = []
        var indent: CGFloat

        var rowCount: Int { families.count + links.count }
    }

    static func ownerKey(_ filter: LibraryFilter) -> String {
        switch filter {
        case .group(let id): return "list:\(id)"
        case .folder(let id): return "folder:\(id)"
        case .category(let category): return "category:\(category.rawValue)"
        default: return "view:\(filter)"
        }
    }

    /// The rows of a section that are folded open, with their families.
    private func openOwners(_ section: SidebarSection) -> [Owner] {
        switch section {
        case .lists:
            return listEntries(parent: 0, depth: 0).filter(\.fontsOpen).map { entry in
                let filter = LibraryFilter.group(entry.group.id)
                return Owner(
                    key: Self.ownerKey(filter),
                    title: entry.group.name,
                    filter: filter,
                    entry: entry,
                    families: store.navigationFamilies(filter),
                    links: store.listLinks[entry.group.id] ?? [],
                    indent: CGFloat(entry.depth) * SidebarMetrics.step
                )
            }
        case .library, .folders:
            return store.expandedViews
                .filter { filter in
                    if case .folder = filter { return section == .folders }
                    return section == .library
                }
                .map { filter in
                    Owner(key: Self.ownerKey(filter), title: "", filter: filter, entry: nil, families: store.navigationFamilies(filter), indent: 0)
                }
        default:
            return []
        }
    }

    /// The row of an open list or view, as it also floats under the section title.
    @ViewBuilder
    private func ownerRow(_ owner: Owner) -> some View {
        if let entry = owner.entry {
            listRow(entry)
        } else if case .folder(let id) = owner.filter, let folder = store.folders.first(where: { $0.id == id }) {
            folderRow(folder)
        } else {
            viewRow(Self.viewTitle(owner.filter), filter: owner.filter)
        }
    }

    private static func viewTitle(_ filter: LibraryFilter) -> String {
        switch filter {
        case .all: return "All fonts"
        case .available: return "Available"
        case .inactive: return "Inactive"
        case .variable: return "Variable fonts"
        case .webfonts: return "Webfonts"
        case .desktop: return "OTF, TTF"
        case .favorites: return "Favorites"
        case .licensed: return "Licensed"
        case .category(let category): return category.rawValue
        default: return ""
        }
    }

    /// The families under an open row. Each can be clicked, dragged, and pinned.
    @ViewBuilder
    private func familyRows(_ owners: [Owner], filter: LibraryFilter) -> some View {
        let key = Self.ownerKey(filter)
        if let owner = owners.first(where: { $0.key == key }) {
            ForEach(owner.families) { family in
                SidebarFamilyRow(family: family, filter: filter, indent: owner.indent + SidebarMetrics.step)
            }
            ForEach(owner.links) { item in
                SidebarLinkRow(item: item, filter: filter, indent: owner.indent + SidebarMetrics.step)
            }
        }
    }

    /// A library view: click for the preview, the chevron for its families.
    private func viewRow(_ title: String, filter: LibraryFilter, warning: String? = nil, onDrop: (([FontDragItem], DropEdge) -> Bool)? = nil) -> some View {
        let count = store.count(filter)
        return SidebarDropRow(
            title: title,
            filter: filter,
            count: count,
            warning: warning,
            disclosure: count > 0 ? store.expandedViews.contains(filter) : nil,
            discloseHelp: "the families in \(title)",
            onDisclose: { store.toggleViewFonts(filter) },
            onDrop: onDrop
        )
    }

    /// What the mark on Licensed says while a license has run out.
    private var expiredLicenseWarning: String? {
        let count = store.expiredLicenseCount
        guard count > 0 else { return nil }
        return count == 1 ? "The license of 1 cut has expired." : "The licenses of \(count) cuts have expired."
    }

    /// Notes where the row of a list or view sits, so its title can float once the row itself has scrolled away.
    private func tracked<Row: View>(_ row: Row, _ filter: LibraryFilter) -> some View {
        let key = Self.ownerKey(filter)
        return row.background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.frame(in: .named(NavigationScroll.rowSpace)), initial: true) { _, frame in
                        if scroll.rows[key] != frame { scroll.rows[key] = frame }
                    }
            }
        }
    }

    private func folderRow(_ folder: FontFolder) -> some View {
        viewRow(folder.displayName, filter: .folder(folder.id))
            .help(folder.path)
            .contextMenu {
                Button("Reveal in Finder") { store.reveal(path: folder.path) }
                Button("Remove from library", role: .destructive) {
                    store.folderPendingRemoval = folder
                }
            }
    }

    private func addAction(_ section: SidebarSection) -> (help: String, perform: () -> Void)? {
        switch section {
        case .lists:
            return ("New list", { store.showNewGroup = true })
        case .research:
            return store.mcpEnabled ? nil : ("New research chat", { store.createResearchChat() })
        case .folders:
            return ("New source folder", { store.createSourceFolder() })
        default:
            return nil
        }
    }

    @ViewBuilder
    private func sectionRows(_ section: SidebarSection, owners: [Owner]) -> some View {
        switch section {
        case .library:
            ForEach([LibraryFilter.all, .available, .inactive, .variable, .webfonts], id: \.self) { filter in
                tracked(viewRow(Self.viewTitle(filter), filter: filter), filter)
                familyRows(owners, filter: filter)
            }
            tracked(viewRow("OTF, TTF", filter: .desktop), .desktop)
                .help("OTF, TTF, TTC, OTC, and dfont.")
            familyRows(owners, filter: .desktop)
            tracked(viewRow("Trial", filter: .category(.trial)), .category(.trial))
            familyRows(owners, filter: .category(.trial))
            tracked(
                viewRow("Favorites", filter: .favorites) { items, _ in
                    store.setFavorites(items.flatMap(\.identities), on: true)
                    return true
                },
                .favorites
            )
            familyRows(owners, filter: .favorites)
            tracked(viewRow("Licensed", filter: .licensed, warning: expiredLicenseWarning), .licensed)
                .help((expiredLicenseWarning.map { $0 + " " } ?? "") + "Cuts with a license. Select a cut and enter the project under Info › License.")
            familyRows(owners, filter: .licensed)
            subsectionLabel("Categories", help: "", add: nil)
                .help("Sans, serif, slab, script, display, and the rest, from the font's own classification.")
            ForEach(FontCategory.allCases.filter { $0 != .trial }, id: \.self) { category in
                tracked(viewRow(category.rawValue, filter: .category(category)), .category(category))
                familyRows(owners, filter: .category(category))
            }
        case .lists:
            ForEach(listEntries(parent: 0, depth: 0)) { entry in
                tracked(listRow(entry), .group(entry.group.id))
                if entry.fontsOpen {
                    familyRows(owners, filter: .group(entry.group.id))
                }
            }
        case .research:
            if store.mcpEnabled {
                mutedRow("Handled by your own AI", filter: .research(0))
                    .help("MCP is on. Your own AI program drives AllFontsO; switch it off under Model to chat here again.")
            }
            if store.researchChats.isEmpty, !store.mcpEnabled {
                Text("No chats yet.")
                    .font(AppChrome.type(11))
                    .foregroundStyle(AppChrome.muted)
                    .padding(.leading, SidebarMetrics.textInset)
                    .padding(.vertical, 3)
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
        case .news:
            SidebarDropRow(title: "New", filter: .news(.fresh), count: store.noticeCount(.fresh), badge: store.hasUnvisitedNews, onDrop: nil)
                .help("Releases and names you have not marked as seen.")
            sidebarRow("Old", filter: .news(.seen), count: store.noticeCount(.seen))
                .help("Releases and names marked as seen.")
        case .folders:
            ForEach(store.folders) { folder in
                tracked(folderRow(folder), .folder(folder.id))
                familyRows(owners, filter: .folder(folder.id))
            }
        }
    }

    private func subsectionLabel(_ title: String, help: String, add: (() -> Void)?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(AppChrome.type())
                .foregroundStyle(AppChrome.muted)
            Spacer(minLength: 4)
            if let add {
                SidebarAddButton(help: help, action: add)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .padding(.leading, SidebarMetrics.textInset)
        .padding(.trailing, SidebarMetrics.trailing + 20)
    }

    private func sidebarRow(_ title: String, filter: LibraryFilter, count: Int?) -> some View {
        SidebarDropRow(title: title, filter: filter, count: count, onDrop: nil)
    }

    /// A grey, italic row for a state rather than a list. Tapping still opens the matching column.
    private func mutedRow(_ title: String, filter: LibraryFilter) -> some View {
        let selected = store.filter == filter
        return HStack(spacing: 6) {
            Text(title)
                .italic()
                .lineLimit(1)
            Spacer()
        }
        .font(AppChrome.type())
        .foregroundStyle(selected ? AppChrome.ink : AppChrome.muted)
        .padding(.vertical, SidebarMetrics.rowPad)
        .padding(.leading, SidebarMetrics.textInset)
        .padding(.trailing, SidebarMetrics.trailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected ? AppChrome.selection : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .modifier(RowHover())
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

    /// One list in the navigation, with how deep it sits and what is folded open.
    struct ListEntry: Identifiable {
        var group: FontGroup
        var depth: Int
        var hasChildren: Bool
        var hasFonts: Bool
        var collapsed: Bool
        var fontsOpen: Bool
        var id: Int64 { group.id }
    }

    /// The lists inside `parent` in reading order, each followed by its own sub-lists unless they are folded away.
    private func listEntries(parent: Int64, depth: Int) -> [ListEntry] {
        var entries: [ListEntry] = []
        for group in store.childGroups(of: parent) {
            let hasChildren = store.hasChildGroups(group.id)
            let hasFonts = store.listHasFonts(group.id)
            let collapsed = store.collapsedGroups.contains(group.id)
            entries.append(ListEntry(
                group: group,
                depth: depth,
                hasChildren: hasChildren,
                hasFonts: hasFonts,
                collapsed: collapsed,
                fontsOpen: hasFonts && store.expandedFontLists.contains(group.id)
            ))
            if hasChildren, !collapsed {
                entries.append(contentsOf: listEntries(parent: group.id, depth: depth + 1))
            }
        }
        return entries
    }

    /// The row of a list. Lists can be dropped onto the middle of another list to nest them, and fonts dropped
    /// on a list join that list.
    private func listRow(_ entry: ListEntry) -> some View {
        let group = entry.group
        return SidebarDropRow(
            title: group.name,
            filter: .group(group.id),
            count: store.count(.group(group.id)),
            dragItem: FontDragItem(
                identities: store.listOrder[group.id] ?? Array(store.membership[group.id, default: []]),
                listName: group.name,
                sidebarKind: "groups",
                sidebarID: group.id
            ),
            indent: CGFloat(entry.depth) * SidebarMetrics.step,
            disclosure: (entry.hasFonts || entry.hasChildren) ? (entry.hasFonts ? entry.fontsOpen : !entry.collapsed) : nil,
            discloseHelp: entry.hasFonts ? "the families in \(group.name)" : "the lists inside \(group.name)",
            allowsInside: true,
            onDisclose: {
                if entry.hasFonts {
                    store.toggleFontList(group.id)
                } else {
                    store.toggleGroupCollapsed(group.id)
                }
            },
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
    }

}

private struct SidebarDropRow: View {
    @Environment(LibraryStore.self) private var store
    var title: String
    var filter: LibraryFilter
    var count: Int?
    var dragItem: FontDragItem? = nil
    var badge = false
    /// Something here needs a look, such as a license that has run out: a red mark, with this as its tooltip.
    var warning: String? = nil
    /// Nested rows sit further in.
    var indent: CGFloat = 0
    /// A chevron beside the count for rows with something inside: true when open, false when folded, nil otherwise.
    var disclosure: Bool? = nil
    /// What the chevron shows, for its tooltip.
    var discloseHelp = "what is inside"
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
        return HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
            if badge {
                Circle()
                    .fill(AppChrome.ink)
                    .frame(width: 6, height: 6)
                    .help("New since you last looked")
            }
            if let warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(LicenseTag.alarm)
                    .help(warning)
            }
            Spacer(minLength: 6)
            if confirmed {
                Text("Added")
                    .font(AppChrome.small)
                    .foregroundStyle(AppChrome.ink)
            }
            if let count {
                // The arrow and the number each keep their own column, so the arrows line up down the navigation.
                Group {
                    if let disclosure {
                        Button {
                            onDisclose?()
                        } label: {
                            ChromeChevron(open: disclosure, color: AppChrome.half)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(disclosure ? "Fold \(discloseHelp) away" : "Show \(discloseHelp)")
                    } else {
                        Color.clear.frame(width: 16, height: 16)
                    }
                }
                Text(AppChrome.count(count))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: SidebarMetrics.countWidth, alignment: .trailing)
            } else if let disclosure {
                Button {
                    onDisclose?()
                } label: {
                    ChromeChevron(open: disclosure, color: AppChrome.half)
                }
                .buttonStyle(.plain)
                .help(disclosure ? "Fold \(discloseHelp) away" : "Show \(discloseHelp)")
            }
        }
        .font(AppChrome.type(12, weight: selected ? .medium : .regular))
        .foregroundStyle(AppChrome.ink)
        .padding(.vertical, SidebarMetrics.rowPad)
        .padding(.leading, SidebarMetrics.textInset + indent)
        .padding(.trailing, SidebarMetrics.trailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowFill(selected: selected || highlighted), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .modifier(RowHover())
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(AppChrome.ink, lineWidth: 1)
            }
        }
        .modifier(OptionalListDrag(item: dragItem))
        .onTapGesture {
            store.filter = filter
        }
    }

    /// Grey for the open view, for a row a font hovers over, and for a row that just took a drop.
    private func rowFill(selected: Bool) -> Color {
        selected ? AppChrome.selection : Color.clear
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

/// One family under an open list or library view. A click shows it in the preview and in Info.
private struct SidebarFamilyRow: View {
    @Environment(LibraryStore.self) private var store
    var family: LibraryStore.NavigationFamily
    var filter: LibraryFilter
    var indent: CGFloat

    var body: some View {
        let faces = family.faces
        let selected = faces.contains { store.selection.contains($0.id) }
        let pinned = faces.allSatisfy { store.isPinned($0) }
        // A plain row, so it can be clicked and also dragged into the pin tray or onto a mode of the preview.
        HStack(spacing: 5) {
            Text(family.name)
                .lineLimit(1)
            Text(faces.count == 1 ? faces[0].style : "\(faces.count) styles")
                .opacity(0.7)
                .lineLimit(1)
                .layoutPriority(-1)
            if faces.contains(where: { store.licenseExpired($0) }) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(LicenseTag.alarm)
                    .help("A license of \(family.name) has expired. See Info › License.")
            }
            Spacer(minLength: 0)
        }
        .font(AppChrome.small)
        .foregroundStyle(selected ? AppChrome.ink : AppChrome.ink.opacity(0.47))
        .padding(.leading, SidebarMetrics.textInset + indent)
        .padding(.trailing, SidebarMetrics.trailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SidebarMetrics.familyHeight)
        .contentShape(Rectangle())
        .background(selected ? AppChrome.selection : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .modifier(RowHover(radius: 4))
        .onTapGesture {
            if store.filter != filter { store.filter = filter }
            store.selectInPreview(family.lead)
        }
        .draggable(FontDragItem(identities: faces.map(\.identity)))
        .help("Click to show \(family.name) in the preview and in Info. Drag it onto Pinned, Compare, Shape, or Playground.")
        .contextMenu {
            Button(pinned ? "Unpin" : (faces.count == 1 ? "Pin" : "Pin all \(faces.count) styles")) {
                if pinned {
                    let identities = Set(faces.map(\.identity))
                    store.pinnedIdentities.removeAll { identities.contains($0) }
                } else {
                    store.addToPreview(faces.map(\.identity))
                }
            }
            Button("Send to Playground") { store.addToPlayground([family.lead.identity]) }
        }
    }
}

/// A font outside the library that was saved in a list, from the news or by hand. It has no file, so it shows its page.
private struct SidebarLinkRow: View {
    @Environment(LibraryStore.self) private var store
    var item: OutsideFont
    var filter: LibraryFilter
    var indent: CGFloat

    var body: some View {
        let selected = store.filter == filter && store.outsideSelection.contains { $0.nameKey == item.nameKey }
        HStack(spacing: 5) {
            Text(item.name)
                .lineLimit(1)
            Text("Link")
                .opacity(0.7)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 0)
        }
        .font(AppChrome.small)
        .foregroundStyle(selected ? AppChrome.ink : AppChrome.ink.opacity(0.47))
        .padding(.leading, SidebarMetrics.textInset + indent)
        .padding(.trailing, SidebarMetrics.trailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SidebarMetrics.familyHeight)
        .contentShape(Rectangle())
        .background(selected ? AppChrome.selection : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .modifier(RowHover(radius: 4))
        .onTapGesture {
            if store.filter != filter {
                // Changing the view empties the outside selection; this one is put back once that has happened.
                store.pendingOutside = item
                store.filter = filter
            } else {
                store.outsideSelection = [item]
            }
        }
        .help("\(item.name) from \(item.source). It is not in your library; click to show its page.")
        .contextMenu {
            Button("Open in browser") { NSWorkspace.shared.open(item.url) }
            if case .group(let id) = filter {
                Button("Remove from list", role: .destructive) { store.removeListLink(id, item: item) }
            }
        }
    }
}

/// The title of the open list or view whose families are passing under a section title. It takes the place of
/// its own row once that has scrolled away, and leaves with the list's last family.
private struct FloatingOwnerTitle<Row: View>: View {
    var scroll: NavigationScroll
    /// Families per open row of this section.
    var counts: [String: Int]
    @ViewBuilder var row: (String) -> Row

    var body: some View {
        if let found = scroll.floating(counts) {
            row(found.key)
                .offset(y: SidebarMetrics.headerHeight + found.lift)
        }
    }
}

/// The hairline under a section title while it is held at the top and rows pass under it. With the title of an
/// open list held below it, that title carries the line.
private struct PinnedRule: View {
    var scroll: NavigationScroll
    var counts: [String: Int]

    var body: some View {
        GeometryReader { proxy in
            // At rest the first title sits a few points down; held, a title sits right at the top.
            let held = proxy.frame(in: .named(NavigationScroll.space)).maxY < SidebarMetrics.headerHeight + 1
            Rectangle()
                .fill(AppChrome.hairline)
                .opacity(held && scroll.floating(counts) == nil ? 1 : 0)
        }
        .frame(height: 0.5)
        .allowsHitTesting(false)
    }
}

/// The title at the top of a pane that is not the preview: a chat, the news.
struct PaneTitle<Trailing: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing
    @Environment(\.surface) private var surface

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AppChrome.type(12, weight: .medium))
                .foregroundStyle(surface.ink)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(AppChrome.type())
                    .foregroundStyle(surface.half)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(height: 27)
        .overlay(alignment: .bottom) {
            Rectangle().fill(surface.hairline).frame(height: 0.5)
        }
    }
}

extension PaneTitle where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

/// Where things sit in the navigation, from the sketch: text 23.5 from the panel edge, counts 14.5 from the right,
/// and the grey of a selected row 4 in from both edges.
enum SidebarMetrics {
    static let edge: CGFloat = 4
    static let textInset: CGFloat = 19.5
    static let trailing: CGFloat = 10.5
    static let rowPad: CGFloat = 2.5
    /// How much further in a sub-list or a list's fonts sit.
    static let step: CGFloat = 12
    /// A section title. It stays at the top while its rows scroll.
    static let headerHeight: CGFloat = 26
    /// A family under an open list.
    static let familyHeight: CGFloat = 16
    /// The column of the numbers at the right; the arrows sit in front of it.
    static let countWidth: CGFloat = 40
}

/// The circled plus beside a section title.
private struct SidebarAddButton: View {
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus.circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(hovering ? AppChrome.ink : AppChrome.half)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct LoadingColumns: View {
    @State private var dim = false

    var body: some View {
        HStack(spacing: AppChrome.gap) {
            panel
                .frame(width: 333)
            panel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                dim = true
            }
        }
    }

    private var panel: some View {
        AppChrome.panel
            .opacity(dim ? 0.45 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .chromePanel()
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
            Button("Shape") { store.openWorkspace(.shape) }
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
