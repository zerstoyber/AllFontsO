import FontsoCore
import SwiftUI
import UniformTypeIdentifiers

struct FontBrowserView: View {
    @Environment(LibraryStore.self) private var store
    @FocusState private var searchFocused: Bool
    @State private var typedQuery = ""
    @State private var fileDropTargeted = false
    @State private var expandedFamilies: Set<String> = []
    @AppStorage("fontso.sampleText") private var listSample = SpecimenText.standard
    @AppStorage("fontso.listSampleSize") private var listSampleSize = 16.0
    @AppStorage("fontso.searchPanelOpen") private var searchPanelOpen = true

    static let sampleSizes: [Double] = [12, 16, 20, 24, 32, 40, 56]
    @State private var searchCardHeight: CGFloat = 220
    @State private var showAddOutside = false
    @State private var editingOutside: OutsideFont?
    @State private var outsideCollapsed = false
    @State private var insideCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            if showsSearchBar {
                searchHeader
            }
            if store.activeFilterCount > 0 {
                filterBanner
            }
            if store.isViewingList, store.sort != .custom {
                orderBanner
            }
            ZStack(alignment: .bottom) {
                browser
                if showsSearchBar {
                    SampleDock(
                        isOpen: $searchPanelOpen,
                        placeholder: "Sample text for the list…",
                        faceForCharacters: store.previewFace ?? store.browseGroups.flatMap(\.families).first?.representative
                    )
                    .reportOverlayHeight()
                }
            }
        }
        .onPreferenceChange(OverlayHeightKey.self) { searchCardHeight = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDrop(of: [UTType.fileURL], isTargeted: $fileDropTargeted) { providers in
            store.importProviders(providers)
            return true
        }
        .overlay {
            if fileDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppChrome.highlight, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: store.searchFocusToken) { _, _ in
            searchFocused = true
        }
        .onChange(of: expandedFamilies) { _, names in
            store.expandedFamilyNames = names
        }
        .sheet(item: $editingOutside) { editing in
            OutsideFontForm(editing: editing) { name, source, url in
                store.updateOutsideItem(editing, name: name, source: source, url: url)
            }
        }
    }

    private var showsSearchBar: Bool {
        !store.folders.isEmpty || !store.fonts.isEmpty
    }

    /// Search sits at the top of the column. Scope chips and the hit count appear once something is typed.
    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(searchPrompt, text: $typedQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .frame(minWidth: 80)
                    .onSubmit { store.query = typedQuery }
                    .task(id: typedQuery) {
                        guard typedQuery != store.query else { return }
                        if typedQuery.isEmpty {
                            store.query = ""
                            return
                        }
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        if !Task.isCancelled, typedQuery != store.query {
                            store.query = typedQuery
                        }
                    }
                    .onChange(of: store.query) { _, query in
                        if query != typedQuery { typedQuery = query }
                    }
                    .onAppear { typedQuery = store.query }
                if !typedQuery.isEmpty {
                    Button {
                        typedQuery = ""
                        store.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear the search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
            if !typedQuery.isEmpty {
                HStack(spacing: 6) {
                    ForEach(SearchScope.allCases) { scope in
                        scopeChip(scope)
                    }
                    Spacer(minLength: 8)
                    if !store.query.isEmpty {
                        let footprint = store.filterFootprint
                        Text("\(footprint.shown) of \(footprint.total) \(store.countUnit)")
                            .font(.uiCaption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .help("Shown out of all in this view. Switch between families and styles under Filter.")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func scopeChip(_ scope: SearchScope) -> some View {
        let active = scope == .all
            ? (store.searchFields.contains(.all) || store.searchFields.isEmpty)
            : store.searchFields.contains(scope)
        return Button {
            store.toggleSearchField(scope)
        } label: {
            Text(scope.title)
                .font(.uiCaption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(active ? AppChrome.highlight.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule())
                .foregroundStyle(active ? AppChrome.highlight : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(scope == .all ? "Search every field" : "Search the \(scope.title.lowercased()) field. Several can be on at once.")
    }

    /// Shown whenever a filter holds fonts back, so a short list is never mistaken for the whole view.
    private var filterBanner: some View {
        let footprint = store.filterFootprint
        let hidden = max(0, footprint.total - footprint.shown)
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
            Text("Filtered: \(store.activeFilterNames.joined(separator: " · ")) · \(hidden) \(store.countUnit) hidden")
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Clear filters") { store.clearFilters() }
                .buttonStyle(.borderless)
                .foregroundStyle(AppChrome.highlight)
                .help("Show everything this view holds again")
        }
        .font(.uiCaption)
        .foregroundStyle(AppChrome.highlight)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(AppChrome.highlight.opacity(0.12))
        .help("Only part of this view is shown. Open the Filter menu to change what is held back.")
    }

    /// Shown in a list whenever another sort hides the user's own arrangement.
    private var orderBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down")
            Text("Sorted by \(store.sort.title). Rearranging works in your own order.")
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Back to your order") { store.backToOwnOrder() }
                .buttonStyle(.borderless)
                .foregroundStyle(AppChrome.highlight)
                .help("Go back to the order you arranged by hand")
        }
        .font(.uiCaption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(AppChrome.highlight.opacity(0.08))
    }

    private var searchPrompt: String {
        if store.searchFields.contains(.all) || store.searchFields.count != 1 {
            return "Family, style, foundry, file…"
        }
        switch store.searchFields.first {
        case .family: return "Family name"
        case .style: return "Style, for example Bold"
        case .foundry: return "Foundry"
        case .designer: return "Designer"
        case .postscript: return "PostScript name"
        default: return "Family, style, foundry, file…"
        }
    }

    @ViewBuilder
    private var browser: some View {
        if store.folders.isEmpty && store.fonts.isEmpty && !store.isScanning {
            ContentUnavailableView {
                Label("No fonts", systemImage: "textformat")
            } description: {
                Text("Add a folder or drop it here. AllFontsO reads OTF, TTF, TTC, and variable fonts.")
            } actions: {
                Button("Add folder…") { store.addFolders() }
                    .buttonStyle(.borderedProminent)
                    .help("Choose a folder with fonts to add to the library")
            }
        } else if store.browseGroups.allSatisfy(\.families.isEmpty) && currentLinks.isEmpty && !(isGroupList && store.query.isEmpty) {
            if store.query.isEmpty {
                ContentUnavailableView {
                    Label("No fonts", systemImage: "tray")
                } description: {
                    Text(emptyFilterText)
                }
            } else {
                ContentUnavailableView.search(text: store.query)
            }
        } else {
            ScrollViewReader { scroller in
                fontList
                    .overlay(alignment: .trailing) {
                        if store.sort == .family, letterAnchors.count > 3 {
                            letterIndex(scroller)
                        }
                    }
                    .background(ArrowKeyCatcher { direction, flags in
                        step(direction, flags: flags, scroller: scroller)
                    })
            }
        }
    }

    /// One row the arrow keys can land on, in the order the list draws them.
    private enum NavigationRow: Equatable {
        case face(Int64, scroll: AnyHashable)
        case outside(OutsideFont)

        var scrollTarget: AnyHashable {
            switch self {
            case .face(_, let scroll): return scroll
            case .outside(let item): return AnyHashable(item.id)
            }
        }
    }

    private var navigationRows: [NavigationRow] {
        var rows: [NavigationRow] = []
        if isGroupList, !outsideCollapsed {
            rows += currentLinks.map { NavigationRow.outside($0) }
        }
        if isGroupList, insideCollapsed { return rows }
        for family in store.browseGroups.flatMap(\.families) {
            rows.append(.face(family.representative.id, scroll: AnyHashable(family.name)))
            if expandedFamilies.contains(family.name) {
                rows += FontGrouping.children(of: family).map { NavigationRow.face($0.id, scroll: AnyHashable($0.id)) }
            }
        }
        return rows
    }

    private func isSelected(_ row: NavigationRow) -> Bool {
        switch row {
        case .face(let id, _): return store.selection.contains(id)
        case .outside(let item): return store.outsideSelection.contains { $0.id == item.id }
        }
    }

    /// Up and down walk the rows; Shift keeps the rows already selected. Right opens the family under the selection, left closes it.
    private func step(_ direction: ArrowDirection, flags: NSEvent.ModifierFlags, scroller: ScrollViewProxy) -> Bool {
        let rows = navigationRows
        guard !rows.isEmpty else { return false }
        switch direction {
        case .right, .left:
            guard let current = rows.lastIndex(where: isSelected),
                  case .face(let id, _) = rows[current],
                  let family = store.browseGroups.lazy.flatMap(\.families).first(where: { $0.faces.contains { $0.id == id } })
            else { return false }
            if direction == .right {
                expandedFamilies.insert(family.name)
            } else {
                expandedFamilies.remove(family.name)
                store.selection = [family.representative.id]
            }
            return true
        case .down:
            let next = rows.lastIndex(where: isSelected).map { $0 + 1 } ?? 0
            guard next < rows.count else { return true }
            land(on: rows[next], extend: flags.contains(.shift), scroller: scroller)
            return true
        case .up:
            let previous = rows.firstIndex(where: isSelected).map { $0 - 1 } ?? rows.count - 1
            guard previous >= 0 else { return true }
            land(on: rows[previous], extend: flags.contains(.shift), scroller: scroller)
            return true
        }
    }

    private func land(on row: NavigationRow, extend: Bool, scroller: ScrollViewProxy) {
        switch row {
        case .face(let id, _):
            if extend {
                store.selection.insert(id)
            } else {
                store.selection = [id]
            }
            store.outsideSelection = []
        case .outside(let item):
            store.selection = []
            store.outsideSelection = [item]
        }
        withAnimation(.easeOut(duration: 0.12)) {
            scroller.scrollTo(row.scrollTarget, anchor: .center)
        }
    }

    private var letterAnchors: [(letter: String, family: String)] {
        var seen = Set<String>()
        var anchors: [(String, String)] = []
        for family in store.browseGroups.flatMap(\.families) {
            let first = family.name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "#"
            let letter = first.rangeOfCharacter(from: .letters) == nil ? "#" : first
            if seen.insert(letter).inserted {
                anchors.append((letter, family.name))
            }
        }
        return anchors
    }

    private func letterIndex(_ scroller: ScrollViewProxy) -> some View {
        VStack(spacing: 1) {
            ForEach(letterAnchors, id: \.letter) { anchor in
                Button {
                    withAnimation { scroller.scrollTo(anchor.family, anchor: .top) }
                } label: {
                    Text(anchor.letter)
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 13)
                }
                .buttonStyle(.plain)
                .help("Jump to \(anchor.letter)")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .padding(.trailing, 4)
        .padding(.bottom, scrollClearance)
    }

    private var fontList: some View {
            List(selection: Bindable(store).selection) {
                if case .group(let groupID) = store.filter {
                    Section {
                        if !outsideCollapsed {
                            ForEach(currentLinks) { item in
                                outsideRow(item, groupID: groupID)
                            }
                            Button {
                                showAddOutside = true
                            } label: {
                                Label("Add a font from outside the library…", systemImage: "plus.circle")
                                    .font(.uiCallout)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                            .selectionDisabled()
                            .listRowSeparator(.hidden)
                            .help("Keep a name and link here, for example a font you saw on a foundry site.")
                            .popover(isPresented: $showAddOutside, arrowEdge: .bottom) {
                                OutsideFontForm { name, source, url in
                                    store.addListLink(groupID, name: name, source: source, url: url)
                                }
                            }
                        }
                    } header: {
                        sectionHeader("Outside the library", symbol: "globe", count: currentLinks.count, collapsed: $outsideCollapsed)
                    }
                    Section {
                        if !insideCollapsed, store.browseGroups.allSatisfy(\.families.isEmpty), store.query.isEmpty {
                            Text(emptyFilterText)
                                .font(.uiCallout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 8)
                                .selectionDisabled()
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        sectionHeader(
                            "In the library",
                            symbol: "books.vertical",
                            count: store.browseGroups.reduce(0) { $0 + $1.families.count },
                            collapsed: $insideCollapsed
                        )
                    }
                }
                ForEach(isGroupList && insideCollapsed ? [] : store.browseGroups) { group in
                    Section {
                        ForEach(group.families) { family in
                            familyRow(family)
                                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                                .tag(family.representative.id)
                                .draggable(FontDragItem(identities: family.faces.map(\.identity)))
                                .modifier(ListReorderDrop(
                                    enabled: isGroupList && store.sort == .custom,
                                    family: family,
                                    move: { identities, edge in
                                        store.reorderList(moving: identities, nextTo: family.faces, edge: edge)
                                    }
                                ))
                                .contextMenu { rowMenu(family.representative, family: family) }
                            if expandedFamilies.contains(family.name) {
                                ForEach(FontGrouping.children(of: family)) { child in
                                    FontRow(
                                        face: child.face,
                                        style: .style,
                                        sample: listSample,
                                        sampleSize: listSampleSize,
                                        titleText: child.title,
                                        subtitleText: child.subtitle
                                    )
                                    .tag(child.id)
                                    .padding(.leading, 18)
                                    .draggable(FontDragItem(identities: store.identitiesForDrag(child.face, wholeFile: true)))
                                    .contextMenu { rowMenu(child.face) }
                                }
                            }
                        }
                    } header: {
                        if !group.title.isEmpty {
                            HStack(spacing: 6) {
                                Text(group.title)
                                Text("· \(group.families.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                Color.clear
                    .frame(height: scrollClearance)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
            .listStyle(.inset)
    }

    private var isGroupList: Bool {
        if case .group = store.filter { return true }
        return false
    }

    private var currentLinks: [OutsideFont] {
        guard case .group(let id) = store.filter else { return [] }
        return store.listLinks[id] ?? []
    }

    /// Clickable section title for the two halves of a list. The chevron shows whether it is open.
    private func sectionHeader(_ title: String, symbol: String, count: Int, collapsed: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                collapsed.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                    .font(.uiCaption2.weight(.semibold))
                    .frame(width: 10)
                Image(systemName: symbol)
                Text(title)
                Text("· \(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed.wrappedValue ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
    }

    /// A name kept in the list without a font file. Drawn with a globe, a dashed frame, and a Web tag so it reads apart from library fonts.
    private func outsideRow(_ item: OutsideFont, groupID: Int64) -> some View {
        let picked = store.outsideSelection.contains { $0.id == item.id }
        return Button {
            store.selection = []
            store.outsideSelection = [item]
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "globe")
                    .font(.uiCaption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    Text(item.source.isEmpty ? item.url.host() ?? "" : item.source)
                        .font(.uiCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("WEB")
                    .font(.uiCaption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                picked ? AppChrome.highlight.opacity(0.16) : Color.secondary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.secondary.opacity(picked ? 0 : 0.4))
            )
        }
        .buttonStyle(.plain)
        .selectionDisabled()
        .help("Saved as a name and link. The font file is not in the library.")
        .contextMenu {
            Button("Open page") { NSWorkspace.shared.open(item.url) }
            Button("Edit…") { editingOutside = item }
            Button("Remove from list", role: .destructive) {
                store.removeListLink(groupID, item: item)
            }
        }
    }

    private var scrollClearance: CGFloat {
        showsSearchBar ? searchCardHeight + 28 : 12
    }

    private func familyRow(_ family: BrowseFamily) -> some View {
        let expanded = expandedFamilies.contains(family.name)
        return HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 4) {
                activationDot(family)
                    .padding(.top, 4)
                Button {
                    if expanded {
                        expandedFamilies.remove(family.name)
                    } else {
                        expandedFamilies.insert(family.name)
                    }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.uiCaption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 12)
                }
                .buttonStyle(.borderless)
                .help(expanded ? "Hide styles" : "Show styles")
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(family.name)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(familyDetail(family))
                        .font(.uiCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !listSample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    FamilySample(face: family.representative, text: listSample, size: listSampleSize)
                }
            }
            Spacer(minLength: 8)
            if let project = licenseSummary(family) {
                LicenseMark(project: project)
            }
            if family.representative.isVariable {
                Text("VAR")
                    .font(.uiCaption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppChrome.highlight.opacity(0.14), in: Capsule())
            }
            Text(formatLabel(family))
                .font(.uiCaption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .help(formatHelp(family))
        }
        .padding(.vertical, 1)
    }

    /// The project(s) this family is licensed for, or nil when no cut carries a license.
    private func licenseSummary(_ family: BrowseFamily) -> String? {
        let projects = Array(Set(family.faces.map { store.license(for: $0) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !projects.isEmpty else { return nil }
        let licensed = family.faces.filter { store.isLicensed($0) }.count
        let scope = licensed == family.faces.count ? "" : " (\(licensed) of \(family.faces.count) styles)"
        return projects.joined(separator: ", ") + scope
    }

    private func activationDot(_ family: BrowseFamily) -> some View {
        let active = family.faces.filter(\.activation.isAvailableToApps).count
        let on = active > 0
        return Circle()
            .fill(on ? Color.green : Color.clear)
            .overlay(Circle().stroke(on ? Color.green : Color.secondary.opacity(0.55), lineWidth: 1))
            .frame(width: 8, height: 8)
            .help(activationHelp(active: active, total: family.faces.count))
    }

    private func activationHelp(active: Int, total: Int) -> String {
        if active == 0 { return "Inactive" }
        if active == total { return "Activated" }
        return "\(active) of \(total) styles activated"
    }

    private func formatLabel(_ family: BrowseFamily) -> String {
        let formats = Array(Set(family.faces.map { $0.format.lowercased() })).sorted()
        if formats.count <= 1 {
            return (formats.first ?? family.representative.format).uppercased()
        }
        if formats.count <= 3 {
            return formats.map { $0.uppercased() }.joined(separator: " · ")
        }
        return "Mixed"
    }

    private func formatHelp(_ family: BrowseFamily) -> String {
        let formats = Array(Set(family.faces.map { $0.format.uppercased() })).sorted()
        if formats.count <= 1 {
            return formats.first ?? ""
        }
        return "This family has more than one file format: \(formats.joined(separator: ", "))."
    }

    private func familyDetail(_ family: BrowseFamily) -> String {
        var parts: [String] = []
        let category = family.representative.category
        if category != .unclassified {
            parts.append(category.rawValue)
        }
        if family.faces.count == 1 {
            let style = family.faces[0].style.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(style.isEmpty ? "1 style" : style)
        } else {
            parts.append("\(family.faces.count) styles")
        }
        if family.fileCount > 1 && family.faces.count > 40 {
            parts.append("\(family.fileCount) files")
        }
        return parts.joined(separator: " · ")
    }

    private var emptyFilterText: String {
        switch store.filter {
        case .favorites:
            return "Mark fonts with the star. You can also drag them here."
        case .group:
            return "Drag fonts onto this list."
        case .compare:
            return "Open Compare from the sidebar."
        case .research:
            return "This view has no fonts."
        default:
            return "This view has no fonts."
        }
    }

    /// What "Remove from list" takes out: the whole family behind a family row, every selected family when the row is
    /// part of the selection, and just the cut (or the selected cuts) behind a style row.
    private func removal(_ face: FontFace, family: BrowseFamily?) -> (title: String, identities: [String]) {
        guard let family else {
            let identities = store.identitiesForDrag(face, wholeFile: true)
            let rows = store.selection.count
            let title = store.selection.contains(face.id) && rows > 1 ? "Remove \(rows) fonts from list" : "Remove from list"
            return (title, identities)
        }
        guard store.selection.contains(family.representative.id) else {
            return ("Remove family from list", family.faces.map(\.identity))
        }
        let families = store.browseGroups.flatMap(\.families).filter { store.selection.contains($0.representative.id) }
        var identities = families.flatMap { $0.faces.map(\.identity) }
        let covered = Set(identities)
        identities += store.selection.compactMap(store.face(id:)).map(\.identity).filter { !covered.contains($0) }
        let title = families.count > 1 ? "Remove \(families.count) families from list" : "Remove family from list"
        return (title, identities)
    }

    /// Context menu for a row. Given the family, the row stands for every cut of that family in the list.
    @ViewBuilder
    private func rowMenu(_ face: FontFace, family: BrowseFamily? = nil) -> some View {
        Button(store.isFavorite(face) ? "Remove favorite" : "Add to favorites") {
            store.toggleFavorite(face)
        }
        Menu("Add to list") {
            if store.groups.isEmpty {
                Button("New list…") { store.showNewGroup = true }
            }
            ForEach(store.menuGroups) { group in
                Button(store.menuTitle(group)) {
                    store.addToGroup(group.id, identities: store.identitiesForDrag(face))
                }
            }
        }
        if case .group = store.filter {
            let removal = removal(face, family: family)
            Button(removal.title) { store.removeFromCurrentGroup(removal.identities) }
        }
        Button(store.isPinned(face) ? "Unpin from preview" : "Pin in preview") {
            store.togglePin(face)
        }
        Button("Add to Playground") {
            store.addToPlayground([face.identity])
        }
        Divider()
        if face.canActivate {
            Button("Activate") { store.activate(paths: [face.filePath]) }
        }
        if face.canDeactivate {
            Button("Deactivate") { store.deactivate(paths: [face.filePath]) }
        }
        Button("Activate family") {
            let paths = store.cuts(in: face.family).filter { $0.family == face.family }.map(\.filePath)
            store.activate(paths: paths)
        }
        Divider()
        Button("Reveal in Finder") { store.reveal(face) }
    }
}

/// Smaller and larger sample text: a small A, a minus, a plus, a large A. No point sizes to read.
struct SampleSizeStepper: View {
    @Binding var size: Double

    private var index: Int {
        FontBrowserView.sampleSizes.firstIndex { $0 >= size } ?? FontBrowserView.sampleSizes.count - 1
    }

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", help: "Smaller sample text", disabled: index == 0) {
                size = FontBrowserView.sampleSizes[max(0, index - 1)]
            }
            Text("A")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18)
                .help("Sample text size: \(Int(size)) pt")
            stepButton("plus", help: "Larger sample text", disabled: index >= FontBrowserView.sampleSizes.count - 1) {
                size = FontBrowserView.sampleSizes[min(FontBrowserView.sampleSizes.count - 1, index + 1)]
            }
        }
        .frame(height: 20)
        .modifier(BarButtonChrome())
    }

    private func stepButton(_ symbol: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .opacity(disabled ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

/// The look of a small button in a column bar: a light fill with a hairline, so it reads as something to press.
struct BarButtonChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.18)))
    }
}

private struct FontRow: View {
    @Environment(LibraryStore.self) private var store
    let face: FontFace
    let style: FontSection.RowStyle
    var sample = ""
    var sampleSize = 20.0
    var titleText: String?
    var subtitleText: String?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                store.setActive(face, active: !face.activation.isAvailableToApps)
            } label: {
                Image(systemName: face.activation.isAvailableToApps ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(face.activation.isAvailableToApps ? AppChrome.highlight : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canToggle)
            .help(checkboxHelp)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    FamilySample(face: face, text: sample, size: sampleSize)
                }
                Text(subtitle)
                    .font(.uiCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if store.isLicensed(face) {
                LicenseMark(project: store.license(for: face))
            }
            if face.isVariable {
                badge("VAR")
            }
            Text(face.format.uppercased())
                .font(.uiCaption2.weight(.medium))
                .foregroundStyle(.secondary)
            Button {
                store.toggleFavorite(face)
            } label: {
                Image(systemName: store.isFavorite(face) ? "star.fill" : "star")
                    .foregroundStyle(store.isFavorite(face) ? Color.orange : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(store.isFavorite(face) ? "Remove favorite" : "Add to favorites")
        }
        .padding(.vertical, 2)
    }

    private var canToggle: Bool {
        face.canActivate || face.canDeactivate
    }

    private var checkboxHelp: String {
        switch face.activation {
        case .available:
            return "This style is active in the system, often through another font manager."
        case .activated:
            return "Activated by AllFontsO. Uncheck to unregister it."
        case .installed:
            return "Lives in a macOS Fonts folder."
        case .inactive:
            return "Activate"
        }
    }

    private var title: String {
        if let titleText { return titleText }
        switch style {
        case .style: return face.style
        case .family: return "\(face.family) \(face.style)"
        }
    }

    private var subtitle: String {
        if let subtitleText { return subtitleText }
        let weight = FontClassification.weightLabel(face.weightClass)
        if face.postscriptName.isEmpty { return weight }
        return "\(face.postscriptName) · \(weight)"
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.uiCaption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

struct ListColumnBar: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.barLeadingInset) private var barLeadingInset

    var body: some View {
        HStack(spacing: 8) {
            Text(store.filterTitle)
                .font(.uiHeadline)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            sortMenu
            directionButton
            filterMenu
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.leading, barLeadingInset)
        .frame(height: ColumnBarMetrics.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
        }
    }

    private var sortMenu: some View {
        Menu {
            if store.isViewingList {
                Section("Order") {
                    sortChoice(.custom)
                    ForEach(LibrarySort.orderSection) { sortChoice($0) }
                }
            } else {
                Section("Order") {
                    ForEach(LibrarySort.orderSection) { sortChoice($0) }
                }
            }
            Section("Letterform") {
                ForEach(LibrarySort.letterformSection) { sortChoice($0) }
            }
            Section("File") {
                ForEach(LibrarySort.fileSection) { sortChoice($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Sort:")
                    .foregroundStyle(.secondary)
                Text(store.sort.title)
            }
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(store.sort.hint)
    }

    private func sortChoice(_ item: LibrarySort) -> some View {
        Button {
            store.sort = item
        } label: {
            if store.sort == item {
                Label(item.title, systemImage: "checkmark")
            } else {
                Text(item.title)
            }
        }
    }

    private var directionButton: some View {
        Button {
            store.sortAscending.toggle()
        } label: {
            Image(systemName: store.sortAscending ? "arrow.up" : "arrow.down")
                .font(.uiCaption.weight(.semibold))
                .frame(width: 14)
        }
        .buttonStyle(.bordered)
        .help(store.sort.directionTitle(ascending: store.sortAscending) + ". Click to flip.")
    }

    private var filterMenu: some View {
        Menu {
            Toggle("Hide trials", isOn: Binding(get: { !store.showTrials }, set: { store.showTrials = !$0 }))
            Toggle("Only active", isOn: Bindable(store).onlyActive)
            Toggle("Only variable", isOn: Bindable(store).onlyVariable)
            Toggle("Only licensed", isOn: Bindable(store).onlyLicensed)
            Divider()
            Picker("Format", selection: Bindable(store).formatFilter) {
                ForEach(FormatFilter.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.inline)
            if store.activeFilterCount > 0 {
                Divider()
                Button("Clear filters") { store.clearFilters() }
            }
            Divider()
            Picker("Count", selection: Binding(get: { store.countFamilies }, set: { store.setCountFamilies($0) })) {
                Text("Count families").tag(true)
                Text("Count styles").tag(false)
            }
            .pickerStyle(.inline)
            if store.count(.category(.unclassified)) > 0 {
                Divider()
                Button("Sort unclassified fonts…") { store.sortUnclassified() }
                    .disabled(store.isScanning)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                Text(store.activeFilterCount > 0 ? "Filter · \(store.activeFilterCount)" : "Filter")
            }
            .foregroundStyle(store.activeFilterCount > 0 ? AppChrome.highlight : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Trials, active fonts, variable fonts, licensed fonts, file format.")
    }
}

enum SampleChoice: String, CaseIterable, Identifiable {
    case custom
    case pangram
    case alphabet
    case cases
    case characters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: return "Custom"
        case .pangram: return "Pangram"
        case .alphabet: return "Alphabet"
        case .cases: return "Upper and lower"
        case .characters: return "All characters"
        }
    }

    var text: String? {
        switch self {
        case .custom, .characters: return nil
        case .pangram: return SpecimenText.standard
        case .alphabet: return SpecimenText.alphabet
        case .cases: return SpecimenText.casePair
        }
    }

    static func matching(_ text: String) -> SampleChoice {
        if text == SpecimenText.standard { return .pangram }
        if text == SpecimenText.alphabet { return .alphabet }
        if text == SpecimenText.casePair { return .cases }
        return .custom
    }
}

/// Reorder targets only exist inside a list. The main library stays free of them.
/// Lets fonts be dropped above or below a family in a list that follows the user's own order. A line shows where they land.
private struct ListReorderDrop: ViewModifier {
    var enabled: Bool
    var family: BrowseFamily
    var move: ([String], DropEdge) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .modifier(InsertionDrop(
                    isReorder: { items in
                        let moving = Set(items.flatMap(\.identities))
                        return !moving.isEmpty && !moving.isSubset(of: family.faces.map(\.identity))
                    },
                    perform: { items, edge in
                        let moving = Set(items.flatMap(\.identities))
                        let target = Set(family.faces.map(\.identity))
                        if moving.isEmpty || moving.isSubset(of: target) { return false }
                        move(items.flatMap(\.identities), edge)
                        return true
                    }
                ))
        } else {
            content
        }
    }
}
