import AppKit
import FontsoCore
import SwiftUI
import UniformTypeIdentifiers

struct TitlePending: Equatable {
    enum Kind: Equatable {
        case chat
        case shape
    }

    var kind: Kind
    var itemID: Int64
}

private struct LibrarySnapshot: Sendable {
    var folders: [FontFolder]
    var fonts: [FontFace]
    var chats: [ResearchChat]
    var shapes: [ShapeSearch]
    var foundries: [FoundryEntry]
    var faces: [Int64: [String]]
    var notices: [FoundryNotice]
}

/// One license of a cut: the project it is used in and, when the license has one, its last day.
struct FontLicense: Hashable, Identifiable {
    var project: String
    var until: Date?
    var id: String { project }

    /// The last day has passed.
    var expired: Bool {
        guard let until else { return false }
        return until < Calendar.current.startOfDay(for: Date())
    }

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// The licenses of a font in a few words, for the tag beside its name.
struct LicenseNote: Equatable {
    var text: String
    /// The same without the word License, for a place that already says it.
    var short: String
    var expired: Bool
    /// Every project with its end date, one to a line.
    var help: String
}

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case preview, compare, shape, playground
    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: return "Preview"
        case .compare: return "Compare"
        case .shape: return "Shape"
        case .playground: return "Playground"
        }
    }

    var help: String {
        switch self {
        case .preview: return "The clicked list or library view, every font stacked"
        case .compare: return "Align and Overlay using pinned fonts"
        case .shape: return "Find fonts by proportion, or mix the pinned cuts letter by letter"
        case .playground: return "Free page of text blocks"
        }
    }
}

enum CompareMode: String, CaseIterable, Identifiable {
    case align, overlay
    var id: String { rawValue }

    var title: String {
        switch self {
        case .align: return "Align"
        case .overlay: return "Overlay"
        }
    }

    var help: String {
        switch self {
        case .align: return "The pinned fonts side by side on one baseline, to compare x-height and cap height"
        case .overlay: return "The pinned fonts laid over each other, each in its own colour"
        }
    }
}

/// What Shape shows under the pinned fonts.
enum ShapeMode: String, CaseIterable, Identifiable {
    case match, mix
    var id: String { rawValue }

    var title: String {
        switch self {
        case .match: return "Match"
        case .mix: return "Mix"
        }
    }

    var help: String {
        switch self {
        case .match: return "The library ranked by how close each family comes to the reference"
        case .mix: return "The sample text with every letter in its own cut"
        }
    }
}

@MainActor
@Observable
final class LibraryStore {
    var folders: [FontFolder] = [] { didSet { touchLibrary() } }
    var fonts: [FontFace] = [] {
        didSet {
            fontsRevision += 1
            if !suppressLibraryTouch { touchLibrary() }
        }
    }
    var selection: Set<Int64> = []
    var filter: LibraryFilter = .all
    var sort: LibrarySort
    var sortAscending: Bool
    var searchFields: Set<SearchScope>
    var query = ""
    var showTrials: Bool
    // Each filter bumps the list revision, so the grouped list rebuilds along with the visible faces.
    var onlyActive = false { didSet { listRevision += 1 } }
    var onlyVariable = false { didSet { listRevision += 1 } }
    var onlyLicensed = false { didSet { listRevision += 1 } }
    var formatFilter = FormatFilter.any { didSet { listRevision += 1 } }
    /// The licenses of each cut, keyed by face identity: one for every project it is used in. Cuts without an
    /// entry count as unlicensed.
    var licenses: [String: [FontLicense]] = [:] { didSet { touchLibrary() } }
    /// The axis values set by hand for a variable font, by cut. Each font keeps its own; nothing here means the
    /// values of the named instance.
    var axisValues: [Int64: [UInt32: Double]] = [:]

    func setAxis(_ tag: UInt32, to value: Double?, for face: FontFace) {
        var values = axisValues[face.id] ?? [:]
        values[tag] = value
        axisValues[face.id] = values.isEmpty ? nil : values
    }

    /// A font from the news that was clicked under a list in the navigation, shown once that list has opened.
    @ObservationIgnored var pendingOutside: OutsideFont?
    private(set) var countFamilies = UserDefaults.standard.object(forKey: "fontso.countFamilies") as? Bool ?? true
    @ObservationIgnored private var librarySort: LibrarySort = .automatic
    var searchFocusToken = 0
    var favoriteKeys: Set<String> = [] { didSet { touchLibrary() } }
    var notes: [String: String] = [:]
    var standardMembership: [String: Set<FontCategory>] = [:] { didSet { touchLibrary() } }
    var groups: [FontGroup] = [] {
        didSet {
            scopeCache = [:]
            touchLibrary()
        }
    }
    var listLinks: [Int64: [OutsideFont]] = [:]
    var membership: [Int64: Set<String>] = [:] { didSet { touchLibrary() } }
    var listOrder: [Int64: [String]] = [:]
    var showNewGroup = false
    var newGroupName = ""
    /// The list a new list goes into; 0 for the top level.
    var newGroupParent: Int64 = 0
    /// Lists whose sub-lists are folded away in the sidebar.
    var collapsedGroups: Set<Int64> = LibraryStore.loadCollapsedGroups() {
        didSet {
            UserDefaults.standard.set(collapsedGroups.map { NSNumber(value: $0) }, forKey: "fontso.collapsedGroups")
        }
    }
    @ObservationIgnored private var scopeCache: [Int64: [Int64]] = [:]
    var groupPendingRename: FontGroup?
    var renameGroupName = ""
    var isScanning = false
    var isLibraryReady = false
    var scanCompleted = 0
    var scanTotal = 0
    var scanFileName = ""
    var statusText = ""
    var alertMessage: String?
    var previewExpanded = false
    /// Right-hand workspace: Preview shows the clicked source; Compare / Shape / Playground use pinned fonts.
    var workspaceTab: WorkspaceTab = WorkspaceTab(rawValue: UserDefaults.standard.string(forKey: "fontso.workspaceTab") ?? "") ?? .preview {
        didSet { UserDefaults.standard.set(workspaceTab.rawValue, forKey: "fontso.workspaceTab") }
    }
    var compareMode: CompareMode = CompareMode(rawValue: UserDefaults.standard.string(forKey: "fontso.compareMode") ?? "") ?? .align {
        didSet { UserDefaults.standard.set(compareMode.rawValue, forKey: "fontso.compareMode") }
    }
    var shapeMode: ShapeMode = ShapeMode(rawValue: UserDefaults.standard.string(forKey: "fontso.shapeMode") ?? "") ?? .match {
        didSet { UserDefaults.standard.set(shapeMode.rawValue, forKey: "fontso.shapeMode") }
    }
    /// Scroll the stacked preview to this face after a click in the sidebar.
    var focusPreviewID: Int64?
    /// Lists whose member fonts are shown under the list row.
    var expandedFontLists: Set<Int64> = []
    /// Library views and source folders whose families are shown under their row.
    var expandedViews: Set<LibraryFilter> = []
    var folderPendingRemoval: FontFolder?
    var researchChats: [ResearchChat] = []
    var shapeSearches: [ShapeSearch] = []
    var foundries: [FoundryEntry] = []
    var foundryFaces: [Int64: [String]] = [:]
    var notices: [FoundryNotice] = []
    var newsVisitedAt = Date(timeIntervalSinceReferenceDate: UserDefaults.standard.double(forKey: "fontso.news.visitedAt"))
    var outsideHits: [OutsideFont] = []
    var outsideSelection: [OutsideFont] = []
    var resolvedFontPages: Set<String> = []
    @ObservationIgnored private var resolvingPages: Set<String> = []
    var isIndexingFoundries = false
    var isReadingFoundries = false
    /// True while the followed foundries are read again for new names.
    var isCheckingNews = false
    /// When each followed foundry was last read, by host. Kept with the library, so it holds across launches.
    var foundryReadAt: [String: Date] = [:]
    /// Which way of reading each foundry was last read with. It counts up when AllFontsO learns to read sites
    /// more closely, so the names that turn up then are not taken for news.
    @ObservationIgnored private var foundryReader: [String: Int] = [:]
    private static let foundryReaderVersion = 2
    @ObservationIgnored private var foundryTriedAt: [String: Date] = [:]
    @ObservationIgnored private var newsTask: Task<Void, Never>?
    @ObservationIgnored private var newsTimer: Timer?
    /// A followed foundry is read again once its last reading is this old.
    static let newsInterval: TimeInterval = 6 * 60 * 60
    var foundryIndexNote = ""
    var showFoundries = false
    var showReview = false
    /// When each cut was last confirmed in Review, keyed by identity.
    var reviewMarks: [String: Date] = [:]
    var mcpEnabled = MCPSettings.enabled
    var mcpPort: UInt16?
    var mcpError: String?
    private let mcpServer = MCPServer()
    var titlePending: TitlePending?
    var renameTitle = ""
    var researchMessages: [ResearchMessage] = []
    var researchingChatID: Int64?
    /// A font name dropped onto a chat. The open Research field appends it.
    var researchReference = ""
    var compareLists: [FontGroup] = []
    var compareMembers: [Int64: [String]] = [:] { didSet { touchLibrary() } }
    var showNewCompare = false
    var newCompareName = ""
    var comparePendingRename: FontGroup?
    var renameCompareName = ""

    var isResearching: Bool {
        if case .research(let id) = filter {
            return researchingChatID == id
        }
        return false
    }

    private let database: FontDatabase?
    @ObservationIgnored private var scanToken = UUID()
    @ObservationIgnored private var cancelFlag: CancelFlag?

    init() {
        let stored = UserDefaults.standard.string(forKey: "fontso.sort") ?? LibrarySort.automatic.rawValue
        let restored = LibrarySort(rawValue: stored) ?? .automatic
        sort = restored == .custom ? .automatic : restored
        librarySort = restored == .custom ? .automatic : restored
        sortAscending = UserDefaults.standard.object(forKey: "fontso.sortAscending") as? Bool ?? true
        let storedFields = UserDefaults.standard.string(forKey: "fontso.searchFields")
            ?? UserDefaults.standard.string(forKey: "fontso.searchScope")
            ?? SearchScope.all.rawValue
        let fields = Set(storedFields.split(separator: ",").compactMap { SearchScope(rawValue: String($0)) })
        searchFields = fields.isEmpty ? [.all] : fields
        showTrials = UserDefaults.standard.object(forKey: "fontso.showTrials") as? Bool ?? true
        do {
            database = try FontDatabase.live()
        } catch {
            database = nil
            alertMessage = error.localizedDescription
        }
    }

    func bootstrap() async {
        guard let database else {
            isLibraryReady = true
            return
        }
        do {
            let snapshot = try await Task.detached {
                try database.seedStandardListsIfNeeded()
                return LibrarySnapshot(
                    folders: try database.allFolders(),
                    fonts: try database.allFonts(),
                    chats: try database.allResearchChats(),
                    shapes: try database.allShapeSearches(),
                    foundries: try database.allFoundries(),
                    faces: try database.watchedTypefaces(),
                    notices: try database.foundryNotices()
                )
            }.value
            folders = snapshot.folders
            fonts = snapshot.fonts
            researchChats = snapshot.chats
            shapeSearches = snapshot.shapes
            foundries = snapshot.foundries.sorted(by: foundryOrder)
            foundryFaces = snapshot.faces
            notices = snapshot.notices
            loadFoundryReadTimes()
            try reloadCollections()
            try importLegacyCompare()
            touchLibrary()
        } catch {
            alertMessage = error.localizedDescription
        }
        isLibraryReady = true
        startMCPIfEnabled()
        warmSearchIndex()
        if !folders.isEmpty {
            refreshLibrary()
        }
    }

    /// Folds every name once in the background so the first search answers at once.
    private func warmSearchIndex() {
        let faces = fonts
        guard !faces.isEmpty else { return }
        Task.detached(priority: .utility) {
            SearchIndex.shared.warm(faces)
        }
    }

    func persistPreferences() {
        UserDefaults.standard.set(sort.rawValue, forKey: "fontso.sort")
        UserDefaults.standard.set(sortAscending, forKey: "fontso.sortAscending")
        UserDefaults.standard.set(searchFields.map(\.rawValue).sorted().joined(separator: ","), forKey: "fontso.searchFields")
        UserDefaults.standard.set(showTrials, forKey: "fontso.showTrials")
    }

    func focusSearch() {
        searchFocusToken += 1
    }

    private var viewingTrialList: Bool {
        if case .category(.trial) = filter { return true }
        return false
    }

    var visibleFaces: [FontFace] {
        let key = "\(listRevision)|\(fonts.count)|\(query)|\(searchFields.map(\.rawValue).sorted().joined(separator: ","))|\(showTrials)|\(onlyActive)|\(onlyVariable)|\(onlyLicensed)|\(formatFilter.rawValue)|\(String(describing: filter))"
        if key == visibleKey { return visibleCache }
        let suppressTrials = !showTrials && !viewingTrialList
        let terms = SearchScope.terms(in: query)
        let wantActive = onlyActive
        let wantVariable = onlyVariable
        let wantLicensed = onlyLicensed
        let format = formatFilter
        func passes(_ face: FontFace) -> Bool {
            if suppressTrials && isTrial(face) { return false }
            if wantActive && !face.activation.isAvailableToApps { return false }
            if wantVariable && !face.isVariable { return false }
            if wantLicensed && !isLicensed(face) { return false }
            if !format.admits(face) { return false }
            return SearchScope.matches(face, terms: terms, fields: searchFields)
        }
        let result: [FontFace]
        if case .compare(let id) = filter {
            let known = facesKeyedByIdentity
            result = (compareMembers[id] ?? []).compactMap { known[$0] }.filter(passes)
        } else {
            result = fonts.filter { face in
                matches(filter, face: face) && passes(face)
            }
        }
        visibleKey = key
        visibleCache = result
        return result
    }

    @ObservationIgnored private var visibleKey = ""
    @ObservationIgnored private var visibleCache: [FontFace] = []

    /// How many of the view's fonts the search and filters currently hide, in the unit the user counts in.
    var filterFootprint: (shown: Int, total: Int) {
        let total = count(filter)
        if countFamilies {
            return (browseGroups.reduce(0) { $0 + $1.families.count }, total)
        }
        return (visibleFaces.count, total)
    }

    var activeFilterCount: Int {
        (showTrials ? 0 : 1) + (onlyActive ? 1 : 0) + (onlyVariable ? 1 : 0) + (onlyLicensed ? 1 : 0)
            + (formatFilter == .any ? 0 : 1)
    }

    /// The filters that are on right now, named the way the Filter menu names them.
    var activeFilterNames: [String] {
        var names: [String] = []
        if !showTrials { names.append("Hide trials") }
        if onlyActive { names.append("Only active") }
        if onlyVariable { names.append("Only variable") }
        if onlyLicensed { names.append("Only licensed") }
        if formatFilter != .any { names.append(formatFilter.title) }
        return names
    }

    func clearFilters() {
        showTrials = true
        onlyActive = false
        onlyVariable = false
        onlyLicensed = false
        formatFilter = .any
    }

    // MARK: - Licenses

    /// The licenses of a cut, in the order they were entered.
    func licenses(for face: FontFace) -> [FontLicense] {
        licenses[face.identity] ?? []
    }

    /// The projects a cut is licensed for, in one line.
    func license(for face: FontFace) -> String {
        licenses(for: face).map(\.project).joined(separator: ", ")
    }

    func isLicensed(_ face: FontFace) -> Bool {
        licenses[face.identity] != nil
    }

    /// Every project name in use, for picking one again.
    var licenseProjects: [String] {
        Array(Set(licenses.values.flatMap { $0.map(\.project) })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Records a project these cuts are licensed for, beside the projects they already have.
    func addLicense(_ project: String, for faces: [FontFace]) {
        guard let database else { return }
        let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = licenses
        do {
            for face in faces where !(updated[face.identity] ?? []).contains(where: { $0.project == trimmed }) {
                try database.addLicense(filePath: face.filePath, faceIndex: face.faceIndex, project: trimmed)
                updated[face.identity, default: []].append(FontLicense(project: trimmed, until: nil))
            }
            if updated != licenses { licenses = updated }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Takes the license for one project away from these cuts.
    func removeLicense(_ project: String, for faces: [FontFace]) {
        guard let database else { return }
        var updated = licenses
        do {
            for face in faces {
                guard var kept = updated[face.identity], kept.contains(where: { $0.project == project }) else { continue }
                try database.removeLicense(filePath: face.filePath, faceIndex: face.faceIndex, project: project)
                kept.removeAll { $0.project == project }
                updated[face.identity] = kept.isEmpty ? nil : kept
            }
            if updated != licenses { licenses = updated }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Sets until when these cuts' license for one project runs. Nil takes the end date away. Cuts without that
    /// license are skipped.
    func setLicenseEnd(_ date: Date?, project: String, for faces: [FontFace]) {
        guard let database else { return }
        let day = date.map { Calendar.current.startOfDay(for: $0) }
        var updated = licenses
        do {
            for face in faces {
                guard var kept = updated[face.identity], let index = kept.firstIndex(where: { $0.project == project }) else { continue }
                try database.setLicenseEnd(
                    filePath: face.filePath,
                    faceIndex: face.faceIndex,
                    project: project,
                    until: day?.timeIntervalSince1970 ?? 0
                )
                kept[index].until = day
                updated[face.identity] = kept
            }
            if updated != licenses { licenses = updated }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// A cut with a license whose last day has passed.
    func licenseExpired(_ face: FontFace) -> Bool {
        licenses(for: face).contains(where: \.expired)
    }

    /// What the licenses of these cuts come to, for a tag beside the name: expired, the next end date, or just licensed.
    func licenseNote(for faces: [FontFace]) -> LicenseNote? {
        var seen = Set<FontLicense>()
        let all = faces.flatMap { licenses(for: $0) }.filter { seen.insert($0).inserted }
        guard !all.isEmpty else { return nil }
        let lines = all.map { license -> String in
            guard let until = license.until else { return "\(license.project): no end date" }
            return "\(license.project): \(license.expired ? "expired" : "until") \(FontLicense.day.string(from: until))"
        }
        let help = lines.joined(separator: "\n")
        let expired = all.filter(\.expired)
        if let latest = expired.compactMap(\.until).max() {
            let day = FontLicense.day.string(from: latest)
            return expired.count == 1
                ? LicenseNote(text: "License expired \(day)", short: "expired \(day)", expired: true, help: help)
                : LicenseNote(text: "\(expired.count) licenses expired", short: "\(expired.count) expired", expired: true, help: help)
        }
        if let next = all.compactMap(\.until).min() {
            let day = FontLicense.day.string(from: next)
            return LicenseNote(text: "Licensed until \(day)", short: "until \(day)", expired: false, help: help)
        }
        return LicenseNote(text: "Licensed", short: "", expired: false, help: help)
    }

    /// How many cuts carry a license whose last day has passed.
    var expiredLicenseCount: Int {
        licenses.values.filter { $0.contains(where: \.expired) }.count
    }

    var isViewingList: Bool {
        if case .group = filter { return true }
        return false
    }

    /// Lists open in the user's own order; the library keeps its last sort. The search starts fresh in every view.
    func viewChanged(from old: LibraryFilter, to new: LibraryFilter) {
        if !query.isEmpty { query = "" }
        let wasList: Bool
        if case .group = old { wasList = true } else { wasList = false }
        let isList: Bool
        if case .group = new { isList = true } else { isList = false }
        if isList {
            if !wasList, sort != .custom { librarySort = sort }
            sort = .custom
        } else if wasList, sort == .custom {
            sort = librarySort
        } else if sort == .custom {
            sort = .automatic
        }
        switch new {
        case .research, .news:
            break
        case .shape:
            workspaceTab = .shape
        default:
            workspaceTab = pendingWorkspaceTab ?? .preview
        }
        pendingWorkspaceTab = nil
    }

    func backToOwnOrder() {
        guard isViewingList else { return }
        sort = .custom
    }

    // MARK: - Sidebar order

    /// The user's own order for lists, shape searches, and chats in the sidebar. Items without a saved place follow in their natural order.
    private var sidebarOrder: [String: [Int64]] = LibraryStore.loadSidebarOrder()

    private static let sidebarKinds = ["groups", "shapes", "chats"]

    private static func loadSidebarOrder() -> [String: [Int64]] {
        var loaded: [String: [Int64]] = [:]
        for kind in sidebarKinds {
            if let ids = UserDefaults.standard.array(forKey: "fontso.sidebarOrder.\(kind)") as? [Int64] {
                loaded[kind] = ids
            } else if let numbers = UserDefaults.standard.array(forKey: "fontso.sidebarOrder.\(kind)") as? [NSNumber] {
                loaded[kind] = numbers.map(\.int64Value)
            }
        }
        return loaded
    }

    private func arranged<T: Identifiable>(_ items: [T], kind: String) -> [T] where T.ID == Int64 {
        guard let order = sidebarOrder[kind], !order.isEmpty else { return items }
        var rank: [Int64: Int] = [:]
        for (index, id) in order.enumerated() where rank[id] == nil { rank[id] = index }
        return items.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? Int.max
            let right = rank[rhs.element.id] ?? Int.max
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    var orderedGroups: [FontGroup] { arranged(groups, kind: "groups") }
    var orderedShapeSearches: [ShapeSearch] { arranged(shapeSearches, kind: "shapes") }
    var orderedResearchChats: [ResearchChat] { arranged(researchChats, kind: "chats") }

    private static func loadCollapsedGroups() -> Set<Int64> {
        let numbers = UserDefaults.standard.array(forKey: "fontso.collapsedGroups") as? [NSNumber] ?? []
        return Set(numbers.map(\.int64Value))
    }

    // MARK: Nested lists

    /// The lists directly inside `parent` (0 for the top level), in sidebar order.
    func childGroups(of parent: Int64) -> [FontGroup] {
        orderedGroups.filter { $0.parentID == parent }
    }

    func hasChildGroups(_ id: Int64) -> Bool {
        groups.contains { $0.parentID == id }
    }

    /// All lists in sidebar order, parents before their sub-lists, for "Add to list" menus.
    var menuGroups: [FontGroup] {
        let order = sidebarOrder["groups"] ?? []
        if menuCacheGroups == groups, menuCacheOrder == order, let cached = menuCache {
            return cached
        }
        var result: [FontGroup] = []
        func walk(_ parent: Int64, depth: Int) {
            guard depth < 64 else { return }
            for group in childGroups(of: parent) {
                result.append(group)
                walk(group.id, depth: depth + 1)
            }
        }
        walk(0, depth: 0)
        // Lists whose parent vanished still show up.
        for group in orderedGroups where !result.contains(group) {
            result.append(group)
        }
        menuCacheGroups = groups
        menuCacheOrder = order
        menuCache = result
        return result
    }

    /// Every row's context menu asks for the lists, so they are walked once until the lists change.
    @ObservationIgnored private var menuCacheGroups: [FontGroup] = []
    @ObservationIgnored private var menuCacheOrder: [Int64] = []
    @ObservationIgnored private var menuCache: [FontGroup]?

    /// A menu title that shows where a nested list sits: "Client › Web".
    func menuTitle(_ group: FontGroup) -> String {
        let path = groupPath(group.id)
        return path.count > 1 ? path.map(\.name).joined(separator: " › ") : group.name
    }

    /// A list together with every list nested inside it, the list itself first.
    func listScope(_ id: Int64) -> [Int64] {
        if let cached = scopeCache[id] { return cached }
        var result = [id]
        var index = 0
        while index < result.count {
            let current = result[index]
            index += 1
            for group in groups where group.parentID == current && !result.contains(group.id) {
                result.append(group.id)
            }
        }
        scopeCache[id] = result
        return result
    }

    /// Whether a face sits in this list or in one of its sub-lists.
    func isInList(_ id: Int64, _ face: FontFace) -> Bool {
        listScope(id).contains { membership[$0, default: []].contains(face.identity) }
    }

    /// The names from the top level down to this list, for titles like "Client › Web".
    func groupPath(_ id: Int64) -> [FontGroup] {
        var path: [FontGroup] = []
        var current = id
        var guardCount = 0
        while let group = groups.first(where: { $0.id == current }), guardCount < 64 {
            path.insert(group, at: 0)
            current = group.parentID
            guardCount += 1
        }
        return path
    }

    /// Puts a list inside another list, or back on the top level with 0. Refuses cycles.
    func setGroupParent(_ id: Int64, parentID: Int64) {
        guard let database, id != parentID, !listScope(id).contains(parentID) else { return }
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].parentID != parentID else { return }
        do {
            try database.setGroupParent(id: id, parentID: parentID)
            groups[index].parentID = parentID
            collapsedGroups.remove(parentID)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func toggleGroupCollapsed(_ id: Int64) {
        if collapsedGroups.contains(id) {
            collapsedGroups.remove(id)
        } else {
            collapsedGroups.insert(id)
        }
    }

    /// Puts a sidebar row directly above or below another row of the same kind. Lists dropped onto the middle
    /// of another list move inside it; lists dropped above or below take that row's parent.
    func moveSidebarItem(kind: String, id: Int64, onto targetID: Int64, edge: DropEdge) {
        guard id != targetID else { return }
        if kind == "groups" {
            if edge == .inside {
                setGroupParent(id, parentID: targetID)
                return
            }
            if let target = groups.first(where: { $0.id == targetID }) {
                guard !listScope(id).contains(target.parentID) else { return }
                setGroupParent(id, parentID: target.parentID)
            }
        }
        var ids: [Int64]
        switch kind {
        case "groups": ids = orderedGroups.map(\.id)
        case "shapes": ids = orderedShapeSearches.map(\.id)
        case "chats": ids = orderedResearchChats.map(\.id)
        default: return
        }
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        guard let to = ids.firstIndex(of: targetID) else { return }
        ids.insert(id, at: edge == .above ? to : to + 1)
        sidebarOrder[kind] = ids
        UserDefaults.standard.set(ids.map { NSNumber(value: $0) }, forKey: "fontso.sidebarOrder.\(kind)")
    }

    /// When true, writing `fonts` does not rebuild the grouped list. Used to fill category sources without a hitch.
    @ObservationIgnored private var suppressLibraryTouch = false
    private var listRevision = 0
    /// Changes only when `fonts` itself changes, so lookups survive filters, favorites and licenses.
    private var fontsRevision = 0
    @ObservationIgnored private var lookupRevision = -1
    @ObservationIgnored private var facesByIdentity: [String: FontFace] = [:]
    @ObservationIgnored private var facesByID: [Int64: FontFace] = [:]

    private func refreshLookup() {
        guard lookupRevision != fontsRevision else { return }
        var byIdentity: [String: FontFace] = [:]
        var byID: [Int64: FontFace] = [:]
        byIdentity.reserveCapacity(fonts.count)
        byID.reserveCapacity(fonts.count)
        for face in fonts {
            byIdentity[face.identity] = face
            byID[face.id] = face
        }
        facesByIdentity = byIdentity
        facesByID = byID
        lookupRevision = fontsRevision
    }

    func face(identity: String) -> FontFace? {
        refreshLookup()
        return facesByIdentity[identity]
    }

    func face(id: Int64) -> FontFace? {
        refreshLookup()
        return facesByID[id]
    }

    func hasFace(identity: String) -> Bool {
        face(identity: identity) != nil
    }

    @ObservationIgnored private var byNameRevision = -1
    @ObservationIgnored private var byNameCache: [FontFace] = []

    /// The library in family, weight and style order, sorted once per library change.
    var fontsByName: [FontFace] {
        if byNameRevision != fontsRevision {
            byNameCache = fonts.sorted { lhs, rhs in
                let family = lhs.family.localizedStandardCompare(rhs.family)
                if family != .orderedSame { return family == .orderedAscending }
                if lhs.weightClass != rhs.weightClass { return lhs.weightClass < rhs.weightClass }
                return lhs.style.localizedStandardCompare(rhs.style) == .orderedAscending
            }
            byNameRevision = fontsRevision
        }
        return byNameCache
    }

    @ObservationIgnored private var trialRevision = -1
    @ObservationIgnored private var trialIDs: Set<Int64> = []

    /// `FontFace.isTrial` reads five names letter by letter, so the answer is kept per library change.
    func isTrial(_ face: FontFace) -> Bool {
        if trialRevision != fontsRevision {
            trialIDs = Set(fonts.lazy.filter(\.isTrial).map(\.id))
            trialRevision = fontsRevision
        }
        return trialIDs.contains(face.id)
    }

    /// Every face keyed by identity, built once per library change.
    var facesKeyedByIdentity: [String: FontFace] {
        refreshLookup()
        return facesByIdentity
    }
    @ObservationIgnored private var browseKey = ""
    @ObservationIgnored private var browseCache: [BrowseGroup] = []
    @ObservationIgnored private var browseStyleCount = 0
    @ObservationIgnored private var browseAvailable = 0
    @ObservationIgnored private var countToken = ""
    @ObservationIgnored private var countCache: [LibraryFilter: CountTally] = [:]

    /// Styles and distinct families behind one sidebar number, plus names kept outside the library.
    private struct CountTally {
        var styles = 0
        var families = Set<String>()
        var extra = 0

        mutating func add(_ face: FontFace) {
            add(family: face.family.lowercased())
        }

        mutating func add(family: String) {
            styles += 1
            families.insert(family)
        }
    }

    var browseGroups: [BrowseGroup] {
        let fields = searchFields.map(\.rawValue).sorted().joined(separator: ",")
        let key = "\(listRevision)|\(fonts.count)|\(query)|\(fields)|\(sort.rawValue)|\(sortAscending)|\(showTrials)|\(String(describing: filter))"
        if key == browseKey { return browseCache }
        let customOrder: [String]
        if sort == .custom, case .group(let id) = filter {
            // The list's own order first, then each sub-list's order in sidebar order.
            var order: [String] = []
            var seen: Set<String> = []
            for member in listScope(id) {
                for key in listOrder[member] ?? [] where seen.insert(key).inserted {
                    order.append(key)
                }
            }
            customOrder = order
        } else {
            customOrder = []
        }
        let groups = FontGrouping.browseGroups(
            faces: visibleFaces,
            sort: sort,
            ascending: sortAscending,
            customOrder: customOrder
        )
        var styles = 0
        var available = 0
        for group in groups {
            for family in group.families {
                styles += family.faces.count
                for face in family.faces where face.activation.isAvailableToApps {
                    available += 1
                }
            }
        }
        browseKey = key
        browseCache = groups
        browseStyleCount = styles
        browseAvailable = available
        return groups
    }

    /// Bumped with every change to the library's contents; the sidebar counts only rebuild on this one.
    private var contentRevision = 0

    private func touchLibrary() {
        listRevision += 1
        contentRevision += 1
    }

    var filterTitle: String {
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
        case .folder(let id):
            return folders.first { $0.id == id }?.displayName ?? "Folder"
        case .group(let id):
            let path = groupPath(id)
            return path.isEmpty ? "List" : path.map(\.name).joined(separator: " › ")
        case .research(let id):
            return researchChats.first { $0.id == id }?.title ?? "Research"
        case .compare(let id):
            return compareLists.first { $0.id == id }?.name ?? "Compare"
        case .shape(let id):
            return shapeSearches.first { $0.id == id }?.title ?? "Shape"
        case .news(let lane):
            return lane == .seen ? "Old" : "New"
        }
    }

    var summaryText: String {
        if case .research = filter {
            return isResearching ? "Looking through the library…" : "Research"
        }
        if case .shape = filter {
            return "Shape"
        }
        if case .news(let lane) = filter {
            return lane == .seen ? "Old" : "New"
        }
        let groups = browseGroups
        let families = groups.reduce(0) { $0 + $1.families.count }
        let visibleCount = browseStyleCount
        let available = browseAvailable
        let trials = showTrials ? "" : " · trials hidden"
        if !query.isEmpty {
            let field = searchFields.contains(.all) || searchFields.isEmpty
                ? "all fields"
                : searchFields.map(\.title).sorted().joined(separator: ", ")
            return "\(visibleCount) matches in \(field) · \(available) available\(trials)"
        }
        if case .all = filter, showTrials {
            return "\(fonts.count) fonts · \(families) families · \(available) available"
        }
        return "\(visibleCount) of \(fonts.count) fonts · \(available) available\(trials)"
    }

    @ObservationIgnored private var previewRevision = -1
    @ObservationIgnored private var previewSelection: Set<Int64> = []
    @ObservationIgnored private var previewKey = ""
    @ObservationIgnored private var previewCache: [FontFace] = []
    @ObservationIgnored private var previewHeadingCache: [Int64: String] = [:]
    /// Families the browser currently shows expanded; mirrored from the list so the preview knows a row means the whole family.
    var expandedFamilyNames: Set<String> = []

    /// Every cut of the clicked sidebar source, stacked in Preview. Pins are a separate working set.
    /// They come in the order the Sort menu asks for; a list keeps the order it was arranged in.
    var previewFaces: [FontFace] {
        refreshPreviewOrder()
        return previewCache
    }

    /// The first cut of every sort group that has a name, such as a category or a foundry, with that name.
    var previewHeadings: [Int64: String] {
        refreshPreviewOrder()
        return previewHeadingCache
    }

    private func refreshPreviewOrder() {
        let groups = browseGroups
        if previewKey == browseKey, !previewKey.isEmpty { return }
        var result: [FontFace] = []
        var headings: [Int64: String] = [:]
        result.reserveCapacity(groups.reduce(0) { $0 + $1.families.reduce(0) { $0 + $1.faces.count } })
        for group in groups {
            let start = result.count
            for family in group.families {
                if family.customOrdered {
                    result.append(contentsOf: family.faces)
                } else {
                    result.append(contentsOf: family.faces.sorted { lhs, rhs in
                        if lhs.weightClass != rhs.weightClass { return lhs.weightClass < rhs.weightClass }
                        if lhs.isItalic != rhs.isItalic { return !lhs.isItalic }
                        return lhs.style.localizedStandardCompare(rhs.style) == .orderedAscending
                    })
                }
            }
            if groups.count > 1, !group.title.isEmpty, result.count > start {
                headings[result[start].id] = group.title
            }
        }
        previewKey = browseKey
        previewCache = result
        previewHeadingCache = headings
    }

    /// Fonts from the news or the web that were saved in the open list. They have no file in the library.
    var previewListLinks: [OutsideFont] {
        guard case .group(let id) = filter else { return [] }
        let links = listLinks[id] ?? []
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return links }
        return links.filter { item in
            terms.allSatisfy { term in
                item.name.localizedCaseInsensitiveContains(term) || item.source.localizedCaseInsensitiveContains(term)
            }
        }
    }

    /// Whether the search or a filter is holding fonts back in the open view.
    var narrowsView: Bool {
        activeFilterCount > 0 || !query.isEmpty
    }

    var previewFace: FontFace? {
        if let id = selection.first, let face = face(id: id) { return face }
        return pinnedFaces.first ?? previewFaces.first
    }

    /// Fonts pinned for Compare, Shape, Mix, and Playground.
    var pinnedFaces: [FontFace] {
        pinnedIdentities.compactMap { face(identity: $0) }
    }

    /// The pin tray: Compare, Shape, Mix, and Playground work from these.
    var workingFaces: [FontFace] {
        pinnedFaces
    }

    // MARK: Review

    /// One family as Review sees it: its cuts, the category AllFontsO gave it, how sure that was, and when it was confirmed.
    struct ReviewFamily: Identifiable {
        var name: String
        var faces: [FontFace]
        var reviewedAt: Date?
        var id: String { name }

        /// The cut that stands for the family: upright, closest to regular.
        var lead: FontFace {
            faces.min { lhs, rhs in
                if lhs.isItalic != rhs.isItalic { return !lhs.isItalic }
                return abs(lhs.weightClass - 400) < abs(rhs.weightClass - 400)
            } ?? faces[0]
        }

        /// The least certain source among the cuts decides where the family sits in the queue.
        var source: CategorySource {
            faces.map(\.categorySource).min { $0.confidence < $1.confidence } ?? .none
        }

        var confidence: Int {
            lead.category == .unclassified ? -1 : source.confidence
        }
    }

    /// Every family, least certain first; confirmed families go to the back in the order they were confirmed.
    func reviewQueue() -> [ReviewFamily] {
        let grouped = Dictionary(grouping: fonts) { $0.family }
        var families = grouped.map { name, faces -> ReviewFamily in
            let marks = faces.map { reviewMarks[$0.identity] }
            let reviewed = marks.allSatisfy { $0 != nil } ? marks.compactMap { $0 }.min() : nil
            return ReviewFamily(name: name, faces: faces, reviewedAt: reviewed)
        }
        // A fixed shuffle per launch keeps the order stable while the window is open.
        var generator = SeededGenerator(seed: reviewSeed)
        families.shuffle(using: &generator)
        return families.sorted { lhs, rhs in
            switch (lhs.reviewedAt, rhs.reviewedAt) {
            case (nil, nil):
                return lhs.confidence < rhs.confidence
            case (nil, _):
                return true
            case (_, nil):
                return false
            case (let left?, let right?):
                return left < right
            }
        }
    }

    private let reviewSeed = UInt64.random(in: 1...UInt64.max)

    /// SplitMix64: a small generator with a seed, so one shuffle can be repeated.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    var reviewedFamilyCount: Int {
        reviewQueue().filter { $0.reviewedAt != nil }.count
    }

    func confirmReviewed(_ family: ReviewFamily) {
        guard let database else { return }
        let now = Date()
        do {
            try database.setReviewed(family.faces.map { ($0.filePath, $0.faceIndex) }, at: now)
            for face in family.faces {
                reviewMarks[face.identity] = now
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func resetReview() {
        guard let database else { return }
        do {
            try database.clearReviewMarks()
            reviewMarks = [:]
            statusText = "Review starts over. Every family is up again."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    @ObservationIgnored private var isFillingSources = false
    /// Bumped when sources were filled in, so an open review can re-rank its queue.
    var reviewSourcesVersion = 0

    /// Fonts indexed before sources were recorded carry none. Read the deciding metadata once,
    /// quietly in the background, so the review can rank them by certainty.
    func fillCategorySourcesIfNeeded() {
        guard let database, !isFillingSources, !isScanning else { return }
        let missing = fonts.filter { $0.categorySource == .none && $0.category != .unclassified }
        guard !missing.isEmpty else { return }
        isFillingSources = true
        let byPath = Dictionary(grouping: missing, by: \.filePath)
        Task.detached(priority: .utility) {
            var rows: [(id: Int64, source: CategorySource)] = []
            for (path, faces) in byPath {
                let hints = FontIndexer.categoryHints(filePath: path)
                for face in faces {
                    let hint = face.faceIndex < hints.count ? hints[face.faceIndex] : hints.first
                    let source: CategorySource
                    if let hint, hint.category == face.category {
                        source = hint.source
                    } else {
                        // The metadata did not decide it: the shape did, or the file went missing.
                        source = hints.isEmpty ? .none : .outline
                    }
                    rows.append((face.id, source))
                }
            }
            try? database.updateCategorySources(rows)
            let filled = rows
            await MainActor.run {
                self.isFillingSources = false
                guard !self.isScanning else { return }
                var map: [Int64: CategorySource] = [:]
                map.reserveCapacity(filled.count)
                for row in filled { map[row.id] = row.source }
                var updated = self.fonts
                for index in updated.indices {
                    if let source = map[updated[index].id] {
                        updated[index].categorySource = source
                    }
                }
                self.suppressLibraryTouch = true
                self.fonts = updated
                self.suppressLibraryTouch = false
                self.reviewSourcesVersion += 1
            }
        }
    }

    // MARK: Playground

    /// Puts fonts on the Playground page as new blocks, set in the current sample text.
    func addToPlayground(_ identities: [String]) {
        let known = Set(fonts.map(\.identity))
        var seen = Set<String>()
        let valid = identities.filter { known.contains($0) && seen.insert($0).inserted }
        guard !valid.isEmpty else { return }
        let text = UserDefaults.standard.string(forKey: "fontso.sampleText") ?? SpecimenText.standard
        let added = PlaygroundDocument.shared.add(identities: valid, text: text)
        statusText = added == 1 ? "Added to the Playground." : "\(added) fonts added to the Playground."
    }

    // MARK: Pinned preview fonts

    /// Fonts that stay in the preview whatever is selected, so other fonts can be browsed against them.
    var pinnedIdentities: [String] = (UserDefaults.standard.array(forKey: "fontso.pinned") as? [String]) ?? [] {
        didSet { UserDefaults.standard.set(pinnedIdentities, forKey: "fontso.pinned") }
    }

    func isPinned(_ face: FontFace) -> Bool {
        pinnedIdentities.contains(face.identity)
    }

    func togglePin(_ face: FontFace) {
        if let index = pinnedIdentities.firstIndex(of: face.identity) {
            pinnedIdentities.remove(at: index)
        } else {
            pinnedIdentities.append(face.identity)
        }
    }

    func unpinAll() {
        pinnedIdentities = []
    }

    /// Puts fonts at a place in the pinned row, pinning those that are not there yet. Without a target they go to the end.
    @discardableResult
    func placePinned(_ identities: [String], before target: String?) -> Bool {
        let valid = identities.filter { hasFace(identity: $0) }
        guard !valid.isEmpty else { return false }
        let fresh = valid.first { !pinnedIdentities.contains($0) }
        let order = PinOrder.place(valid, before: target, in: pinnedIdentities)
        if order != pinnedIdentities { pinnedIdentities = order }
        if let fresh, let face = face(identity: fresh) {
            selection = [face.id]
            outsideSelection = []
        }
        return true
    }

    /// Moves a pinned font by places to the left or right.
    func stepPinned(_ face: FontFace, by offset: Int) {
        let order = PinOrder.step(face.identity, by: offset, in: pinnedIdentities)
        if order != pinnedIdentities { pinnedIdentities = order }
    }

    /// Sorts the pinned fonts once. The order can be changed by hand afterwards.
    func sortPinned(_ key: PinOrder.Key) {
        let sorted = PinOrder.sorted(pinnedFaces, by: key).map(\.identity)
        // Pins whose file is away keep their place behind the others.
        let order = sorted + pinnedIdentities.filter { !sorted.contains($0) }
        if order != pinnedIdentities { pinnedIdentities = order }
    }

    func reversePinned() {
        pinnedIdentities.reverse()
    }

    /// Pins fonts so Compare, Shape, Mix, and Playground can use them.
    @discardableResult
    func addToPreview(_ identities: [String]) -> Bool {
        let valid = identities.filter { hasFace(identity: $0) }
        guard !valid.isEmpty else { return false }
        for identity in valid where !pinnedIdentities.contains(identity) {
            pinnedIdentities.append(identity)
        }
        if let first = valid.first, let face = face(identity: first) {
            selection = [face.id]
        }
        outsideSelection = []
        return true
    }

    /// Opens a mode of the preview. From a chat or the news it goes back to the library first, where the modes live.
    func openWorkspace(_ tab: WorkspaceTab) {
        switch filter {
        case .research, .news, .shape:
            // The view change that follows would open Preview; it opens this mode instead.
            pendingWorkspaceTab = tab
            filter = .all
        default:
            workspaceTab = tab
        }
    }

    @ObservationIgnored private var pendingWorkspaceTab: WorkspaceTab?

    /// Takes a font out of the pin tray.
    func removeFromPreview(_ face: FontFace) {
        pinnedIdentities.removeAll { $0 == face.identity }
    }

    /// Highlights a cut, opens its Info under the navigation, and scrolls the stacked preview to it.
    func selectInPreview(_ face: FontFace, scroll: Bool = true) {
        selection = [face.id]
        infoPanelOpen = true
        if scroll {
            focusPreviewID = face.id
        }
    }

    /// The Info panel under the navigation: everything about the selected cut.
    var infoPanelOpen = UserDefaults.standard.object(forKey: "fontso.infoPanelOpen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(infoPanelOpen, forKey: "fontso.infoPanelOpen") }
    }

    /// OpenType switches moved away from the font's defaults, by feature id. Set in Info, applied to every font
    /// in the preview, so "small caps on" carries over when comparing.
    var featureOverrides: [String: Bool] = [:]

    func faces(inList id: Int64) -> [FontFace] {
        let keys = listOrder[id] ?? Array(membership[id, default: []])
        return keys.compactMap { face(identity: $0) }
    }

    func listHasFonts(_ id: Int64) -> Bool {
        !(listOrder[id] ?? Array(membership[id, default: []])).isEmpty || !(listLinks[id] ?? []).isEmpty
    }

    func toggleFontList(_ id: Int64) {
        if expandedFontLists.contains(id) {
            expandedFontLists.remove(id)
        } else {
            expandedFontLists.insert(id)
        }
    }

    func toggleViewFonts(_ filter: LibraryFilter) {
        if expandedViews.contains(filter) {
            expandedViews.remove(filter)
        } else {
            expandedViews.insert(filter)
        }
    }

    /// One family as the navigation lists it under an open list or library view.
    struct NavigationFamily: Identifiable {
        var name: String
        var faces: [FontFace]
        var id: String { faces.first?.identity ?? name }

        /// The cut that stands for the family: upright, closest to regular.
        var lead: FontFace {
            faces.min { lhs, rhs in
                if lhs.isItalic != rhs.isItalic { return !lhs.isItalic }
                return abs(lhs.weightClass - 400) < abs(rhs.weightClass - 400)
            } ?? faces[0]
        }
    }

    @ObservationIgnored private var navigationFamilyToken = ""
    @ObservationIgnored private var navigationFamilyCache: [LibraryFilter: [NavigationFamily]] = [:]

    /// The families behind a row of the navigation. A list keeps its own order; a library view goes by name.
    func navigationFamilies(_ filter: LibraryFilter) -> [NavigationFamily] {
        if case .group(let id) = filter {
            var order: [String] = []
            var byFamily: [String: [FontFace]] = [:]
            for face in faces(inList: id) {
                let key = face.family.lowercased()
                if byFamily[key] == nil { order.append(key) }
                byFamily[key, default: []].append(face)
            }
            return order.compactMap { key in
                byFamily[key].map { NavigationFamily(name: $0[0].family, faces: $0) }
            }
        }
        let token = "\(contentRevision)|\(fonts.count)|\(favoriteKeys.count)|\(licenses.count)|\(standardMembership.count)|\(folders.count)"
        if token != navigationFamilyToken {
            navigationFamilyCache = [:]
            navigationFamilyToken = token
        }
        if let hit = navigationFamilyCache[filter] { return hit }
        var byFamily: [String: [FontFace]] = [:]
        for face in fonts where matches(filter, face: face) {
            byFamily[face.family.lowercased(), default: []].append(face)
        }
        let families = byFamily.values
            .map { NavigationFamily(name: $0[0].family, faces: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        navigationFamilyCache[filter] = families
        return families
    }

    /// A variable font file carries every named instance as its own face. In a family preview, each such file is one
    /// slice, shown with its default instance; static cuts stay as they are.
    static func oneSlicePerVariableFile(_ faces: [FontFace]) -> [FontFace] {
        var result: [FontFace] = []
        var variableFiles: [String: [FontFace]] = [:]
        var fileOrder: [String] = []
        for face in faces {
            guard face.isVariable else {
                result.append(face)
                continue
            }
            if variableFiles[face.filePath] == nil { fileOrder.append(face.filePath) }
            variableFiles[face.filePath, default: []].append(face)
        }
        for path in fileOrder {
            if let instance = defaultInstance(variableFiles[path] ?? []) {
                result.append(instance)
            }
        }
        return result
    }

    /// The instance that stands for a variable file: Regular or Italic by name, else the one nearest weight 400, else the first.
    static func defaultInstance(_ instances: [FontFace]) -> FontFace? {
        guard instances.count > 1 else { return instances.first }
        let named = instances.first { face in
            let style = face.style.lowercased()
            return style == "regular" || style == "italic" || style == "roman"
        }
        if let named { return named }
        return instances.min { lhs, rhs in
            let left = abs(lhs.weightClass - 400)
            let right = abs(rhs.weightClass - 400)
            if left != right { return left < right }
            return lhs.faceIndex < rhs.faceIndex
        }
    }

    /// The named instances stored for the same variable file as this face.
    func instances(of face: FontFace) -> [FontFace] {
        guard face.isVariable else { return [] }
        return fonts
            .filter { $0.filePath == face.filePath }
            .sorted { lhs, rhs in
                if lhs.weightClass != rhs.weightClass { return lhs.weightClass < rhs.weightClass }
                return lhs.faceIndex < rhs.faceIndex
            }
    }

    /// The number shown next to a view: families or styles, as the user prefers.
    func count(_ filter: LibraryFilter) -> Int {
        refreshCounts()
        guard let tally = countCache[filter] else { return 0 }
        return countFamilies ? tally.families.count + tally.extra : tally.styles + tally.extra
    }

    func styleCount(_ filter: LibraryFilter) -> Int {
        refreshCounts()
        guard let tally = countCache[filter] else { return 0 }
        return tally.styles + tally.extra
    }

    var countUnit: String {
        countFamilies ? "families" : "styles"
    }

    func setCountFamilies(_ families: Bool) {
        countFamilies = families
        UserDefaults.standard.set(families, forKey: "fontso.countFamilies")
    }

    private func refreshCounts() {
        let token = "\(contentRevision)|\(favoriteKeys.count)|\(licenses.count)|\(standardMembership.count)|\(membership.count)|\(folders.count)"
        if token != countToken {
            countCache = tallyCounts()
            countToken = token
        }
    }

    private func tallyCounts() -> [LibraryFilter: CountTally] {
        var counts: [LibraryFilter: CountTally] = [:]
        let folderPrefixes = folders.map { ($0.id, $0.path, $0.path + "/") }
        for face in fonts {
            let family = face.family.lowercased()
            let identity = face.identity
            func note(_ filter: LibraryFilter) {
                counts[filter, default: CountTally()].add(family: family)
            }
            note(.all)
            if face.activation.isAvailableToApps { note(.available) }
            if face.activation == .inactive { note(.inactive) }
            if face.isVariable { note(.variable) }
            if face.isWebfont { note(.webfonts) } else { note(.desktop) }
            if favoriteKeys.contains(identity) { note(.favorites) }
            if licenses[identity] != nil { note(.licensed) }
            let listed = standardMembership[identity] ?? listedCategories(face)
            var typed = false
            for category in listed where category != .unclassified {
                note(.category(category))
                if category != .trial { typed = true }
            }
            if !typed { note(.category(.unclassified)) }
            for (id, path, prefix) in folderPrefixes where face.filePath == path || face.filePath.hasPrefix(prefix) {
                note(.folder(id))
            }
        }
        let known = facesKeyedByIdentity
        for group in groups {
            var tally = CountTally()
            var seen: Set<String> = []
            for id in listScope(group.id) {
                for key in membership[id, default: []] where seen.insert(key).inserted {
                    if let face = known[key] { tally.add(face) }
                }
            }
            tally.extra = listLinks[group.id]?.count ?? 0
            counts[.group(group.id)] = tally
        }
        for (id, links) in listLinks where counts[.group(id)] == nil {
            var tally = CountTally()
            tally.extra = links.count
            counts[.group(id)] = tally
        }
        return counts
    }

    func addFolders() {
        let urls = chooseFolders(prompt: "Add", message: "Choose a folder of OTF, TTF, and variable fonts.")
        guard !urls.isEmpty, let database else { return }
        let broad = urls.contains { isBroadRoot($0) }
        do {
            for url in urls {
                try database.addFolder(path: url.path)
            }
            folders = try database.allFolders()
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        if broad {
            statusText = "Large folders: hidden folders and Library (except Fonts) are skipped."
        }
        refreshLibrary()
    }

    func removeFolder(_ folder: FontFolder) {
        guard let database else { return }
        do {
            try database.removeFolder(id: folder.id)
            folders = try database.allFolders()
            fonts = try database.allFonts()
            try reloadCollections()
            if case .folder(let id) = filter, id == folder.id {
                filter = .all
            }
            selection = selection.filter { face(id: $0) != nil }
            touchLibrary()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func rescan() {
        refreshLibrary()
    }

    private func refreshLibrary() {
        guard let database else { return }
        cancelFlag?.cancel()
        let flag = CancelFlag()
        cancelFlag = flag
        let token = UUID()
        scanToken = token
        isScanning = true
        scanCompleted = 0
        scanTotal = 0
        scanFileName = ""
        let folderPaths = folders.map(\.path)
        let stored = fonts.map {
            FontFileRecord(path: $0.filePath, fileSize: $0.fileSize, modifiedAt: $0.modifiedAt)
        }
        let currentFaces = fonts
        let previous = Set(fonts.filter { selection.contains($0.id) }.map(\.identity))

        Task.detached(priority: .userInitiated) {
            let listed = FontIndexer.listFontFiles(folders: folderPaths, shouldCancel: { flag.isCancelled })
            if listed.cancelled {
                await MainActor.run {
                    guard self.scanToken == token else { return }
                    self.isScanning = false
                    self.statusText = "Scan cancelled."
                }
                return
            }
            let delta = FontIndexer.changes(listings: listed.listings, stored: stored)
            let activeNames = FontActivator.activePostScriptNames()
            if delta.isEmpty {
                let updates = activationUpdates(in: currentFaces, activeNames: activeNames)
                do {
                    try database.updateActivation(updates)
                    await MainActor.run {
                        guard self.scanToken == token else { return }
                        self.applyActivation(updates)
                        self.isScanning = false
                        self.statusText = updates.isEmpty ? "Library is up to date." : "Activation updated."
                        self.fillProportionsIfNeeded()
                    }
                } catch {
                    await MainActor.run {
                        guard self.scanToken == token else { return }
                        self.isScanning = false
                        self.alertMessage = error.localizedDescription
                    }
                }
                return
            }

            let targets = delta.added + delta.updated
            FontShape.resetCache()
            var faces: [FontFace] = []
            var replacePaths = delta.removed
            var failed: [String] = []
            let total = targets.count
            for (index, record) in targets.enumerated() {
                if flag.isCancelled {
                    await MainActor.run {
                        guard self.scanToken == token else { return }
                        self.isScanning = false
                        self.statusText = "Scan cancelled."
                    }
                    return
                }
                if index % 4 == 0 || index == total - 1 {
                    let name = URL(fileURLWithPath: record.path).lastPathComponent
                    let completed = index
                    await MainActor.run {
                        guard self.scanToken == token else { return }
                        self.scanCompleted = completed
                        self.scanTotal = total
                        self.scanFileName = name
                    }
                }
                let inspected = FontIndexer.inspect(fileURL: URL(fileURLWithPath: record.path), activeNames: activeNames)
                if inspected.isEmpty {
                    failed.append(record.path)
                } else {
                    replacePaths.append(record.path)
                    faces.append(contentsOf: inspected)
                }
            }
            do {
                try database.applyLibraryChanges(removedPaths: replacePaths, faces: faces)
                var loaded = try database.allFonts()
                let updates = activationUpdates(in: loaded, activeNames: activeNames)
                for update in updates {
                    if let index = loaded.firstIndex(where: { $0.id == update.id }) {
                        loaded[index].activation = update.activation
                    }
                }
                try database.updateActivation(updates)
                let summary = libraryChangeSummary(delta, failed: failed.count)
                let published = loaded
                await MainActor.run {
                    guard self.scanToken == token else { return }
                    self.fonts = published
                    self.warmSearchIndex()
                    self.selection = Set(published.filter { previous.contains($0.identity) }.map(\.id))
                    try? self.reloadCollections()
                    self.touchLibrary()
                    self.isScanning = false
                    self.scanCompleted = total
                    self.statusText = summary
                    self.fillProportionsIfNeeded()
                }
            } catch {
                await MainActor.run {
                    guard self.scanToken == token else { return }
                    self.isScanning = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelScan() {
        cancelFlag?.cancel()
    }

    /// Reads x-height, cap height, letter width, contrast, and script coverage from font files already in the library.
    private func fillProportionsIfNeeded() {
        guard let database, !isScanning else { return }
        guard (try? database.meta("proportionScan")) != "2" else { return }
        let incomplete = Set(fonts.filter {
            $0.xHeight == 0 && $0.capHeight == 0 && $0.averageWidth == 0 && $0.contrast == 0
                && !$0.coversLatin && !$0.coversCyrillic && !$0.coversGreek
        }.map(\.filePath))
        let indexesByPath = Dictionary(grouping: fonts, by: \.filePath).mapValues { faces in
            faces.map(\.faceIndex)
        }
        let paths = Array(incomplete).sorted()
        guard !paths.isEmpty else {
            try? database.setMeta("proportionScan", "2")
            return
        }
        cancelFlag?.cancel()
        let flag = CancelFlag()
        cancelFlag = flag
        let token = UUID()
        scanToken = token
        isScanning = true
        scanCompleted = 0
        scanTotal = paths.count
        scanFileName = ""
        statusText = "Reading proportions…"

        Task.detached(priority: .userInitiated) {
            var batch: [(path: String, index: Int, proportions: FontProportions)] = []
            var failed = false
            func flush() throws {
                guard !batch.isEmpty else { return }
                try database.updateProportions(batch)
                batch.removeAll(keepingCapacity: true)
            }
            for (index, path) in paths.enumerated() {
                if flag.isCancelled { break }
                let rows = FontIndexer.proportions(filePath: path)
                if rows.count == 1, let only = rows.first {
                    for faceIndex in indexesByPath[path] ?? [0] {
                        batch.append((path, faceIndex, only))
                    }
                } else {
                    for (faceIndex, item) in rows.enumerated() {
                        batch.append((path, faceIndex, item))
                    }
                }
                if batch.count >= 1000 || index == paths.count - 1 {
                    do {
                        try flush()
                    } catch {
                        failed = true
                        break
                    }
                }
                if index % 400 == 0 || index == paths.count - 1 {
                    let completed = index + 1
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    await MainActor.run {
                        guard self.scanToken == token else { return }
                        self.scanCompleted = completed
                        self.scanTotal = paths.count
                        self.scanFileName = name
                    }
                }
            }
            let cancelled = flag.isCancelled || failed
            if !cancelled {
                try? database.setMeta("proportionScan", "2")
            }
            let loaded = try? database.allFonts()
            await MainActor.run {
                guard self.scanToken == token else { return }
                if let loaded {
                    self.fonts = loaded
                    self.touchLibrary()
                }
                self.isScanning = false
                self.statusText = cancelled ? "Proportion reading stopped." : "Proportions saved."
            }
        }
    }

    func sortUnclassified() {
        guard let database, !isScanning else { return }
        let jobs = categoryJobs(fonts.filter { $0.category == .unclassified })
        guard !jobs.isEmpty else {
            statusText = "Every font already has a category."
            return
        }
        cancelFlag?.cancel()
        let flag = CancelFlag()
        cancelFlag = flag
        let token = UUID()
        scanToken = token
        isScanning = true
        scanCompleted = 0
        scanTotal = jobs.count
        scanFileName = ""

        Task.detached(priority: .userInitiated) {
            var assigned: [String: String] = [:]
            for (index, job) in jobs.enumerated() {
                if flag.isCancelled { break }
                let category = FontClassification.category(fromNames: job.names)
                    ?? FontShape.measure(filePath: job.path, faceIndex: job.faceIndex)
                if category != .unclassified {
                    assigned[job.family] = category.rawValue
                }
                if index % 4 == 0 || index == jobs.count - 1 {
                    let completed = index + 1
                    let name = job.family
                    await MainActor.run {
                        guard self.scanToken == token else { return }
                        self.scanCompleted = completed
                        self.scanFileName = name
                    }
                }
            }
            let cancelled = flag.isCancelled
            let categories = assigned
            do {
                try database.updateCategories(categories)
                let listed = try database.standardLists()
                await MainActor.run {
                    guard self.scanToken == token else { return }
                    var moved = 0
                    var next = self.fonts
                    for index in next.indices {
                        guard next[index].category == .unclassified,
                              let raw = categories[next[index].family],
                              let category = FontCategory(rawValue: raw) else { continue }
                        next[index].category = category
                        moved += 1
                    }
                    self.fonts = next
                    self.standardMembership = listed
                    self.touchLibrary()
                    self.isScanning = false
                    let stayed = self.fonts.filter { $0.category == .unclassified }.count
                    self.statusText = cancelled
                        ? "Sort cancelled. \(moved) fonts were categorized. \(stayed) stayed unclassified."
                        : "Sorted \(moved) fonts into categories. \(stayed) stayed unclassified."
                }
            } catch {
                await MainActor.run {
                    guard self.scanToken == token else { return }
                    self.isScanning = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func categoryJobs(_ faces: [FontFace]) -> [CategoryJob] {
        Dictionary(grouping: faces, by: \.family).map { family, group in
            let face = group.min { lhs, rhs in
                let left = (lhs.isItalic ? 1_000 : 0) + abs(lhs.weightClass - 400)
                let right = (rhs.isItalic ? 1_000 : 0) + abs(rhs.weightClass - 400)
                return left < right
            } ?? group[0]
            return CategoryJob(
                family: family,
                path: face.filePath,
                faceIndex: face.faceIndex,
                names: [face.family, face.style, face.fullName, face.postscriptName]
            )
        }
        .sorted { $0.family.localizedStandardCompare($1.family) == .orderedAscending }
    }

    func activateSelection() {
        activate(paths: selectedPaths())
    }

    func deactivateSelection() {
        deactivate(paths: selectedPaths())
    }

    func activateVisible() {
        let paths = Array(Set(visibleFaces.map(\.filePath)))
        guard !paths.isEmpty else { return }
        if paths.count > 30 {
            let alert = NSAlert()
            alert.messageText = "Activate \(paths.count) font files?"
            alert.informativeText = "They will be available to InDesign and every other app."
            alert.addButton(withTitle: "Activate")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        activate(paths: paths)
    }

    func activate(paths: [String]) {
        scheduleActivation(paths: paths, enable: true)
    }

    func deactivate(paths: [String]) {
        scheduleActivation(paths: paths, enable: false)
    }

    /// List clicks run inside the table view. Updating the library in that callback makes AppKit drop the change.
    private func scheduleActivation(paths: [String], enable: Bool) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.changeActivation(paths: paths, enable: enable)
            }
        }
    }

    func toggle(_ face: FontFace) {
        setActive(face, active: !face.activation.isAvailableToApps)
    }

    func setActive(_ face: FontFace, active: Bool) {
        guard active ? face.canActivate : face.canDeactivate else { return }
        if active {
            activate(paths: [face.filePath])
        } else {
            deactivate(paths: [face.filePath])
        }
    }

    func reveal(_ face: FontFace) {
        reveal(path: face.filePath)
    }

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func organizeOnDisk() {
        let source = selection.isEmpty ? visibleFaces : fonts.filter { selection.contains($0.id) }
        let files = LibraryOrganizer.files(from: source).filter { !SystemFontLocations.isProtected($0.path) }
        guard !files.isEmpty else {
            alertMessage = "No fonts to organize. System fonts are left out."
            return
        }

        let alert = NSAlert()
        alert.messageText = "Organize fonts on disk"
        alert.informativeText = "\(files.count) files will be filed by category and family, for example Sans/Family/File.otf. Copy leaves the originals in place. Move takes them out of their current folders; activated fonts are deactivated first."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        let response = alert.runModal()
        let mode: OrganizeMode
        switch response {
        case .alertFirstButtonReturn: mode = .copy
        case .alertSecondButtonReturn: mode = .move
        default: return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Organize"
        panel.message = "Destination folder for the sorted library."
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        statusText = "Organizing fonts…"
        let snapshot = files
        Task.detached(priority: .userInitiated) {
            let result = LibraryOrganizer.organize(snapshot, to: destination, mode: mode)
            await MainActor.run {
                self.statusText = self.organizeSummary(result, mode: mode)
                if !result.failed.isEmpty {
                    let preview = result.failed.prefix(8).joined(separator: "\n")
                    let extra = result.failed.count > 8 ? "\nand \(result.failed.count - 8) more" : ""
                    self.alertMessage = preview + extra
                }
                if mode == .move {
                    try? self.database?.addFolder(path: destination.path)
                    if let folders = try? self.database?.allFolders() {
                        self.folders = folders
                    }
                    self.rescan()
                }
            }
        }
    }

    private func organizeSummary(_ result: OrganizeResult, mode: OrganizeMode) -> String {
        let verb = mode == .copy ? "copied" : "moved"
        var text = "\(result.written) files \(verb)"
        if result.skipped > 0 {
            text += ", \(result.skipped) skipped"
        }
        if !result.failed.isEmpty {
            text += ", \(result.failed.count) failed"
        }
        return text + "."
    }

    private func changeActivation(paths: [String], enable: Bool) {
        let requested = Set(paths)
        let facesByPath = Dictionary(grouping: fonts.filter { requested.contains($0.filePath) }, by: \.filePath)
        let unique = Array(requested).filter { path in
            if SystemFontLocations.isProtected(path) { return false }
            let faces = facesByPath[path] ?? []
            if enable {
                return faces.contains { $0.canActivate }
            }
            return faces.contains { $0.canDeactivate }
        }
        guard !unique.isEmpty else {
            statusText = enable ? "Nothing to activate." : "Nothing to deactivate."
            return
        }

        var failures: [String] = []
        for path in unique {
            do {
                let names = (facesByPath[path] ?? []).map(\.postscriptName)
                if enable {
                    try FontActivator.activate(filePath: path)
                } else {
                    try FontActivator.deactivate(filePath: path, postScriptNames: names)
                }
            } catch {
                failures.append("\(URL(fileURLWithPath: path).lastPathComponent): \(error.localizedDescription)")
            }
        }
        refreshActivation(for: unique)
        let touched = fonts.filter { unique.contains($0.filePath) }
        let filesOn = Set(touched.filter(\.activation.isAvailableToApps).map(\.filePath))
        let filesOff = Set(touched.filter { !$0.activation.isAvailableToApps }.map(\.filePath))
        if enable {
            statusText = filesOff.isEmpty
                ? "\(filesOn.count) activated."
                : "\(filesOn.count) activated, \(filesOff.count) not applied."
        } else {
            statusText = "\(filesOff.count) deactivated."
        }
        if !failures.isEmpty {
            let preview = failures.prefix(8).joined(separator: "\n")
            let extra = failures.count > 8 ? "\nand \(failures.count - 8) more" : ""
            alertMessage = preview + extra
        }
    }

    private func refreshActivation(for paths: [String]) {
        let set = Set(paths.map(normalizeFontPath))
        let activeNames = FontActivator.activePostScriptNames()
        var next = fonts
        let indices = next.indices.filter { set.contains(next[$0].filePath) }
        let states = FontActivator.availability(
            libraryFaces: indices.map { (next[$0].filePath, next[$0].postscriptName) },
            activeNames: activeNames
        )
        for (index, state) in zip(indices, states) {
            next[index].activation = state
        }
        fonts = next
        touchLibrary()
        let updated = fonts.filter { set.contains($0.filePath) }
        try? database?.updateActivation(updated)
    }

    private func selectedPaths() -> [String] {
        Array(Set(fonts.filter { selection.contains($0.id) }.map(\.filePath)))
    }

    private func matches(_ filter: LibraryFilter, face: FontFace) -> Bool {
        switch filter {
        case .all:
            return true
        case .available:
            return face.activation.isAvailableToApps
        case .inactive:
            return face.activation == .inactive
        case .variable:
            return face.isVariable
        case .webfonts:
            return face.isWebfont
        case .desktop:
            return !face.isWebfont
        case .favorites:
            return favoriteKeys.contains(face.identity)
        case .licensed:
            return isLicensed(face)
        case .category(let category):
            return isInStandardList(category, face)
        case .folder(let id):
            guard let folder = folders.first(where: { $0.id == id }) else { return false }
            return face.filePath == folder.path || face.filePath.hasPrefix(folder.path + "/")
        case .group(let id):
            return isInList(id, face)
        case .research, .compare, .shape, .news:
            return false
        }
    }

    private func matchesQuery(_ face: FontFace) -> Bool {
        SearchScope.matches(face, query: query, fields: searchFields)
    }

    func toggleSearchField(_ field: SearchScope) {
        if field == .all {
            searchFields = [.all]
            return
        }
        var next = searchFields
        next.remove(.all)
        if next.contains(field) {
            next.remove(field)
        } else {
            next.insert(field)
        }
        searchFields = next.isEmpty ? [.all] : next
    }

    @ObservationIgnored private var familyIndexRevision = -1
    @ObservationIgnored private var familyIndex: [String: [FontFace]] = [:]

    func cuts(in family: String) -> [FontFace] {
        if familyIndexRevision != fontsRevision {
            var grouped: [String: [FontFace]] = [:]
            grouped.reserveCapacity(fonts.count / 4)
            for face in fonts {
                grouped[face.family.lowercased(), default: []].append(face)
            }
            for key in grouped.keys {
                grouped[key]?.sort { lhs, rhs in
                    if lhs.isItalic != rhs.isItalic { return !lhs.isItalic }
                    if lhs.weightClass != rhs.weightClass { return lhs.weightClass < rhs.weightClass }
                    return lhs.style.localizedStandardCompare(rhs.style) == .orderedAscending
                }
            }
            familyIndex = grouped
            familyIndexRevision = fontsRevision
        }
        return familyIndex[family.lowercased()] ?? []
    }

    func isFavorite(_ face: FontFace) -> Bool {
        favoriteKeys.contains(face.identity)
    }

    func toggleFavorite(_ face: FontFace) {
        let identity = face.identity
        let on = !isFavorite(face)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.setFavorites([identity], on: on)
            }
        }
    }

    func setFavorites(_ keys: [String], on: Bool) {
        guard let database else { return }
        let known = Set(fonts.map(\.identity))
        let valid = keys.filter { known.contains($0) }
        do {
            for key in valid {
                guard let parsed = FaceKey.parse(key) else { continue }
                try database.setFavorite(filePath: parsed.path, faceIndex: parsed.index, isFavorite: on)
                if on {
                    favoriteKeys.insert(key)
                } else {
                    favoriteKeys.remove(key)
                }
            }
            touchLibrary()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func commitNewGroup() {
        let name = newGroupName
        let parent = groups.contains { $0.id == newGroupParent } ? newGroupParent : 0
        newGroupName = ""
        newGroupParent = 0
        guard let database else { return }
        do {
            let group = try database.createGroup(name: name, parentID: parent)
            groups.append(group)
            groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            membership[group.id] = []
            listOrder[group.id] = []
            collapsedGroups.remove(parent)
            filter = .group(group.id)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func commitRenameGroup() {
        guard let group = groupPendingRename, let database else { return }
        let name = renameGroupName
        groupPendingRename = nil
        do {
            try database.renameGroup(id: group.id, name: name)
            if let index = groups.firstIndex(where: { $0.id == group.id }) {
                groups[index].name = name.cleanedFontName
            }
            groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func loadResearchMessages() {
        guard let database, case .research(let id) = filter else {
            researchMessages = []
            return
        }
        researchMessages = (try? database.researchMessages(chatID: id)) ?? []
    }

    func createResearchChat() {
        guard let database, !mcpEnabled else { return }
        do {
            let chat = try database.createResearchChat(title: "New chat")
            researchChats.insert(chat, at: 0)
            researchMessages = []
            filter = .research(chat.id)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func beginRenameChat(_ chat: ResearchChat) {
        renameTitle = chat.title
        titlePending = TitlePending(kind: .chat, itemID: chat.id)
    }

    func beginRenameShape(_ search: ShapeSearch) {
        renameTitle = search.title
        titlePending = TitlePending(kind: .shape, itemID: search.id)
    }

    func commitRenameTitle() {
        guard let pending = titlePending, let database else { return }
        let name = renameTitle
        titlePending = nil
        let trimmed = name.cleanedFontName
        guard !trimmed.isEmpty else { return }
        do {
            switch pending.kind {
            case .chat:
                try database.renameResearchChat(id: pending.itemID, title: trimmed)
                if let index = researchChats.firstIndex(where: { $0.id == pending.itemID }) {
                    researchChats[index].title = trimmed
                }
            case .shape:
                try database.renameShapeSearch(id: pending.itemID, title: trimmed)
                if let index = shapeSearches.firstIndex(where: { $0.id == pending.itemID }) {
                    shapeSearches[index].title = trimmed
                }
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func createShapeSearch() {
        guard let database else { return }
        let face = previewFaces.first
        let title = face?.family ?? "New shape"
        do {
            let search = try database.createShapeSearch(
                title: title,
                referenceIdentity: face?.identity ?? "",
                query: face?.family ?? ""
            )
            shapeSearches.insert(search, at: 0)
            filter = .shape(search.id)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteShapeSearch(_ search: ShapeSearch) {
        guard let database else { return }
        do {
            try database.deleteShapeSearch(id: search.id)
            shapeSearches.removeAll { $0.id == search.id }
            if case .shape(let id) = filter, id == search.id {
                filter = .all
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    @discardableResult
    func keepShapeReference(_ searchID: Int64, identities: [String]) -> Bool {
        guard let identity = identities.first,
              let face = self.face(identity: identity),
              let search = shapeSearches.first(where: { $0.id == searchID }) else { return false }
        let previousTitle = search.title
        let previousQuery = search.query
        updateShapeSearch(searchID, referenceIdentity: face.identity, query: face.family)
        if previousTitle == "New shape" || previousTitle == previousQuery {
            renameTitle = face.family
            titlePending = TitlePending(kind: .shape, itemID: searchID)
            commitRenameTitle()
        }
        filter = .shape(searchID)
        selection = [face.id]
        outsideSelection = []
        return true
    }

    func updateShapeSearch(_ searchID: Int64, referenceIdentity: String, query: String) {
        guard let database else { return }
        do {
            try database.updateShapeSearch(id: searchID, referenceIdentity: referenceIdentity, query: query)
            if let index = shapeSearches.firstIndex(where: { $0.id == searchID }) {
                shapeSearches[index].referenceIdentity = referenceIdentity
                shapeSearches[index].query = query
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Keeps the chosen factors and letters with the shape search.
    func updateShapeTuning(_ searchID: Int64, tuning: MatchTuning) {
        guard let database,
              let index = shapeSearches.firstIndex(where: { $0.id == searchID }),
              shapeSearches[index].tuning != tuning else { return }
        shapeSearches[index].tuning = tuning
        do {
            try database.updateShapeTuning(id: searchID, tuning: tuning)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func indexFoundriesIfNeeded() {
        guard foundries.isEmpty, !isIndexingFoundries else { return }
        indexFoundries()
    }

    func indexFoundries() {
        guard !isIndexingFoundries else { return }
        isIndexingFoundries = true
        foundryIndexNote = "Reading the directories…"
        Task {
            let directory = await FoundryFetch.directoryHTML()
            let info = await FoundryFetch.infoHTML()
            let drafts = await Task.detached {
                FoundryLookup.catalog(directoryHTML: directory, infoHTML: info)
            }.value
            guard let database else {
                isIndexingFoundries = false
                return
            }
            if drafts.isEmpty {
                foundryIndexNote = "The directories did not answer."
                isIndexingFoundries = false
                return
            }
            do {
                try database.replaceFoundryCatalog(drafts)
                foundries = try database.allFoundries().sorted(by: foundryOrder)
                foundryFaces = try database.watchedTypefaces()
                notices = try database.foundryNotices()
                foundryIndexNote = "\(foundries.count) foundries"
            } catch {
                alertMessage = error.localizedDescription
                foundryIndexNote = ""
            }
            isIndexingFoundries = false
        }
    }

    func setFoundryWatched(_ foundry: FoundryEntry, watched: Bool) {
        guard let database, let index = foundries.firstIndex(where: { $0.id == foundry.id }) else { return }
        do {
            try database.setFoundryWatched(id: foundry.id, watched: watched)
            foundries[index].watched = watched
            foundries.sort(by: foundryOrder)
            if watched, (foundryFaces[foundry.id] ?? []).isEmpty {
                Task { await readTypefaces(of: foundry) }
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func addFoundry(name: String, website: String) {
        guard let database else { return }
        var text = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else {
            alertMessage = "That website is not a foundry address."
            return
        }
        do {
            let entry = try database.addFoundry(name: name, url: url)
            foundries = try database.allFoundries().sorted(by: foundryOrder)
            Task { await readTypefaces(of: entry) }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func markNoticeSeen(_ notice: FoundryNotice) {
        guard let database, let index = notices.firstIndex(where: { $0.id == notice.id }) else { return }
        do {
            try database.setNoticeSeen(id: notice.id, seen: true)
            notices[index].seen = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func dismissNotice(_ notice: FoundryNotice) {
        guard let database else { return }
        do {
            try database.dismissNotice(id: notice.id)
            notices.removeAll { $0.id == notice.id }
            outsideSelection.removeAll { $0.name == notice.name && $0.source == notice.foundryName }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func readNewFonts(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            outsideHits = []
            return
        }
        isReadingFoundries = true
        outsideHits = []
        defer { isReadingFoundries = false }
        var hits: [OutsideFont] = []
        if let html = await FoundryFetch.text(FoundryLookup.typecacheSearchURL(trimmed)), !Task.isCancelled {
            hits.append(contentsOf: FoundryLookup.typecache(html, query: trimmed))
        }
        let watched = foundries.filter(\.watched).prefix(8)
        for foundry in watched {
            if Task.isCancelled { break }
            guard let html = await FoundryFetch.text(foundry.url) else { continue }
            guard let page = FoundryLookup.typefacePage(on: foundry.url, name: trimmed, html: html) else { continue }
            if hits.contains(where: { $0.url == page }) { continue }
            hits.append(OutsideFont(
                name: trimmed,
                source: foundry.name,
                detail: "On the \(foundry.name) site.",
                url: page
            ))
            if let database {
                try? database.addFoundryTypeface(foundryID: foundry.id, name: trimmed)
                var faces = foundryFaces[foundry.id] ?? []
                if !faces.contains(trimmed) {
                    faces.append(trimmed)
                    foundryFaces[foundry.id] = faces
                }
            }
        }
        outsideHits = hits
    }

    /// Reads the followed foundries whose last reading is older than `newsInterval`, the longest unread first.
    /// With `force` every followed foundry is read now.
    func refreshWatchedFonts(force: Bool = false) async {
        let now = Date()
        let due = foundries.filter(\.watched).filter { foundry in
            if force { return true }
            // A site that did not answer is left alone for a while.
            if let tried = foundryTriedAt[foundry.host], now.timeIntervalSince(tried) < 15 * 60 { return false }
            guard let read = foundryReadAt[foundry.host] else { return true }
            return now.timeIntervalSince(read) > LibraryStore.newsInterval
        }.sorted { (foundryReadAt[$0.host] ?? .distantPast) < (foundryReadAt[$1.host] ?? .distantPast) }
        guard !due.isEmpty else { return }
        isCheckingNews = true
        defer { isCheckingNews = false }
        for foundry in due {
            if Task.isCancelled { return }
            foundryTriedAt[foundry.host] = Date()
            await readTypefaces(of: foundry)
        }
    }

    /// Looks for new names at the followed foundries. The reading runs on its own, so leaving News does not stop it.
    func checkNews(force: Bool = false) {
        guard newsTask == nil else { return }
        newsTask = Task { [weak self] in
            await self?.refreshWatchedFonts(force: force)
            self?.newsTask = nil
        }
    }

    /// Checks for news at launch and from then on every half hour; each foundry is read when its turn has come.
    func startNewsWatch() {
        checkNews()
        newsTimer?.invalidate()
        newsTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNews() }
        }
    }

    /// The latest reading of a followed foundry.
    var newsCheckedAt: Date? {
        foundries.filter(\.watched).compactMap { foundryReadAt[$0.host] }.max()
    }

    private func loadFoundryReadTimes() {
        guard let text = try? database?.meta("foundryReadAt"), let data = text.data(using: .utf8),
              let stored = try? JSONDecoder().decode([String: Double].self, from: data) else { return }
        foundryReadAt = stored.mapValues { Date(timeIntervalSince1970: $0) }
        if let text = try? database?.meta("foundryReader"), let data = text.data(using: .utf8),
           let versions = try? JSONDecoder().decode([String: Int].self, from: data) {
            foundryReader = versions
        }
    }

    private func saveFoundryReadTimes() {
        guard let data = try? JSONEncoder().encode(foundryReadAt.mapValues(\.timeIntervalSince1970)),
              let text = String(data: data, encoding: .utf8) else { return }
        try? database?.setMeta("foundryReadAt", text)
        if let data = try? JSONEncoder().encode(foundryReader), let text = String(data: data, encoding: .utf8) {
            try? database?.setMeta("foundryReader", text)
        }
    }

    func newsFonts() -> [OutsideFont] {
        let known = knownFamilyNames
        var cards: [OutsideFont] = []
        for foundry in foundries where foundry.watched {
            guard let url = URL(string: foundry.url.absoluteString) else { continue }
            for name in foundryFaces[foundry.id] ?? [] where !known.contains(foldedName(name)) {
                cards.append(OutsideFont(
                    name: name,
                    source: foundry.name,
                    detail: "New from \(foundry.name). Not in your library.",
                    url: url
                ))
            }
        }
        return cards
    }

    func suggestedFoundries(limit: Int = 8) -> [FoundryEntry] {
        let skipped = ["adobe", "apple", "microsoft", "monotype", "unknown", "fontso", "the", "and"]
        var mentions: [String: Int] = [:]
        for face in fonts {
            let name = foldedName(face.manufacturer)
            guard name.count >= 4, !skipped.contains(name) else { continue }
            mentions[name, default: 0] += 1
        }
        let open = foundries.filter { !$0.watched }
        let ranked = open.map { foundry -> (FoundryEntry, Int) in
            let name = foldedName(foundry.name)
            let score = mentions.reduce(0) { partial, item in
                guard item.key.contains(name) || name.contains(item.key) else { return partial }
                return partial + item.value
            }
            return (foundry, score)
        }
        let known = ranked.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
        if known.count >= 4 { return Array(known.prefix(limit)) }
        return Array((known + open).prefix(limit))
    }

    @ObservationIgnored private var knownFamilyToken = -1
    @ObservationIgnored private var knownFamilyCache: Set<String> = []

    /// Folded family names of everything in the library, cached until the library changes.
    var knownFamilyNames: Set<String> {
        if knownFamilyToken == fontsRevision, !knownFamilyCache.isEmpty || fonts.isEmpty {
            return knownFamilyCache
        }
        knownFamilyCache = Set(fonts.map { foldedName($0.family) })
        knownFamilyToken = fontsRevision
        return knownFamilyCache
    }

    func noticeCount(_ lane: NewsLane) -> Int {
        let known = knownFamilyNames
        return notices.filter { notice in
            guard !known.contains(foldedName(notice.name)) else { return false }
            return lane == .seen ? notice.seen : !notice.seen
        }.count
    }

    /// True when a notice arrived after the user last opened New. Looking is enough; marking is not required.
    var hasUnvisitedNews: Bool {
        let known = knownFamilyNames
        return notices.contains { notice in
            !notice.seen && notice.discoveredAt > newsVisitedAt && !known.contains(foldedName(notice.name))
        }
    }

    func markNewsVisited() {
        newsVisitedAt = Date()
        UserDefaults.standard.set(newsVisitedAt.timeIntervalSinceReferenceDate, forKey: "fontso.news.visitedAt")
    }

    func foundrySite(for item: OutsideFont) -> URL? {
        if let host = FoundryLookup.siteHost(item.url),
           let match = foundries.first(where: { $0.host == host }) {
            return match.url
        }
        let haystack = foldedName(item.source + " " + item.detail + " " + item.name)
        let matches = foundries.filter { foundry in
            let name = foldedName(foundry.name)
            return name.count >= 4 && haystack.contains(name)
        }
        return matches.max { $0.name.count < $1.name.count }?.url
    }

    func fontPageKey(_ item: OutsideFont) -> String {
        item.source + "\n" + item.name
    }

    func attachSpecimen(to item: OutsideFont) async {
        let key = fontPageKey(item)
        if resolvingPages.contains(key) { return }
        let deep = item.url.path.count > 1 && !FoundryLookup.isDirectoryHost(item.url)
        if deep, item.imageURL != nil {
            resolvedFontPages.insert(key)
            return
        }
        resolvingPages.insert(key)
        defer {
            resolvingPages.remove(key)
            resolvedFontPages.insert(key)
        }
        var url = item.url
        var image = item.imageURL
        if FoundryLookup.isDirectoryHost(url), let site = foundrySite(for: item) {
            url = site
        }
        if !FoundryLookup.isDirectoryHost(url), url.path.count <= 1,
           let page = await typefacePage(on: url, name: item.name) {
            url = page
        }
        if url.path.count <= 1 || FoundryLookup.isDirectoryHost(url),
           let html = await FoundryFetch.text(FoundryLookup.typecacheSearchURL(item.name)) {
            if image == nil {
                image = FoundryLookup.specimen(in: html, name: item.name)
            }
            if let page = FoundryLookup.specimenPage(in: html, name: item.name),
               !FoundryLookup.isDirectoryHost(page), page.path.count > 1 {
                let origin = FoundryLookup.siteHost(url)
                if origin == nil || FoundryLookup.siteHost(page) == origin {
                    url = FoundryLookup.secure(page)
                }
            }
        } else if image == nil, let html = await FoundryFetch.text(FoundryLookup.typecacheSearchURL(item.name)) {
            image = FoundryLookup.specimen(in: html, name: item.name)
        }
        guard url != item.url || (image != nil && item.imageURL == nil) else { return }
        let updated = OutsideFont(
            name: item.name,
            source: item.source,
            detail: item.detail,
            url: url,
            imageURL: image
        )
        // The page found for a name in the news is kept, so it opens straight away the next time.
        if url != item.url, url.path.count > 1,
           let index = notices.firstIndex(where: { $0.name == item.name && $0.foundryName == item.source && $0.url == item.url }) {
            try? database?.setNoticePage(id: notices[index].id, url: url)
            notices[index].url = url
        }
        if let index = outsideSelection.firstIndex(where: { $0.id == item.id }) {
            outsideSelection[index] = updated
        }
    }

    /// The page of a typeface on its foundry's site: a link on the front page, or, where the site builds its
    /// catalogue in the browser and names no link, one of the usual addresses that answers.
    private func typefacePage(on site: URL, name: String) async -> URL? {
        if let html = await FoundryFetch.text(site),
           let page = FoundryLookup.typefacePage(on: site, name: name, html: html) {
            return page
        }
        let candidates = FoundryLookup.candidatePages(on: site, name: name)
        guard !candidates.isEmpty else { return nil }
        let answers = await withTaskGroup(of: (Int, Bool).self) { group -> [Int: Bool] in
            for (index, candidate) in candidates.enumerated() {
                group.addTask { (index, await FoundryFetch.exists(candidate)) }
            }
            var found: [Int: Bool] = [:]
            for await (index, there) in group { found[index] = there }
            return found
        }
        guard let first = candidates.indices.first(where: { answers[$0] == true }) else { return nil }
        // A site that also answers a name no foundry has says yes to everything.
        if await FoundryFetch.exists(FoundryLookup.controlPage(for: candidates[first])) { return nil }
        return candidates[first]
    }

    func relatedFoundryFonts(for face: FontFace) -> [OutsideFont] {
        let maker = foldedName(face.manufacturer)
        guard maker.count >= 4 else { return [] }
        let known = knownFamilyNames
        let family = foldedName(face.family)
        var cards: [OutsideFont] = []
        for foundry in foundries {
            let name = foldedName(foundry.name)
            guard name.count >= 4, maker.contains(name) || name.contains(maker) else { continue }
            let fresh = (foundryFaces[foundry.id] ?? []).filter { typeface in
                let folded = foldedName(typeface)
                return folded != family && !known.contains(folded)
            }
            for typeface in fresh.prefix(8) where cards.count < 16 {
                cards.append(OutsideFont(
                    name: typeface,
                    source: foundry.name,
                    detail: "Also from \(foundry.name).",
                    url: foundry.url
                ))
            }
            if fresh.isEmpty, cards.count < 16 {
                let detail = foundry.watched
                    ? "This foundry is followed. Its other font names appear here after they are read."
                    : "This looks like the foundry behind the reference. Follow it to see its other fonts."
                cards.append(OutsideFont(
                    name: foundry.name,
                    source: foundry.sources,
                    detail: detail,
                    url: foundry.url
                ))
            }
        }
        return cards
    }

    func readTypefaces(of foundry: FoundryEntry) async {
        guard let database else { return }
        let site = FoundryLookup.secure(foundry.url)
        // The typefaces the foundry links on its own site, each with its page.
        var links: [FoundryTypefaceLink] = []
        var drafts: [FoundryNoticeDraft] = []
        var confirmed = false
        if let html = await FoundryFetch.text(site) {
            confirmed = true
            links = FoundryLookup.linkedTypefacePages(on: site, html: html)
            var feedXML: String?
            if let feed = FoundryLookup.feedURL(in: html, base: site) {
                feedXML = await FoundryFetch.text(feed)
            }
            if feedXML == nil {
                for candidate in FoundryLookup.commonFeedURLs(site) {
                    guard let xml = await FoundryFetch.text(candidate),
                          xml.contains("<rss") || xml.contains("<feed") else { continue }
                    feedXML = xml
                    break
                }
            }
            if let feedXML {
                for item in FoundryLookup.feedItems(in: feedXML, base: site) {
                    drafts.append(FoundryNoticeDraft(name: item.title, url: FoundryLookup.secure(item.url), publishedAt: item.published))
                }
            }
        }
        var names = links.map(\.name)
        if let html = await FoundryFetch.text(FoundryLookup.typecacheSearchURL(foundry.name)) {
            let listed = FoundryLookup.typefaces(ofFoundry: foundry.name, in: html)
            if !listed.isEmpty { confirmed = true }
            for name in listed {
                if let index = names.firstIndex(where: { FoundryLookup.sameTypeface($0, name) }) {
                    // The directory writes the name by hand; the site's link may only have given its address.
                    names[index] = name
                } else {
                    names.append(name)
                }
            }
        }
        guard confirmed else { return }
        let stored = Array(names.prefix(40))
        for name in stored where !drafts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            // Its own page where the site links one; the front page otherwise, until the page is looked up.
            let page = links.first { FoundryLookup.sameTypeface($0.name, name) }?.url ?? site
            drafts.append(FoundryNoticeDraft(name: name, url: page, publishedAt: nil))
        }
        do {
            try database.replaceFoundryTypefaces(foundryID: foundry.id, names: stored)
            // A foundry read before by an earlier way of reading: what the closer look finds now was there all
            // along, so it joins the older names instead of counting as news.
            let closerLook = foundryReadAt[foundry.host] != nil && foundryReader[foundry.host] != LibraryStore.foundryReaderVersion
            try database.syncFoundryNotices(host: foundry.host, drafts: Array(drafts.prefix(60)), known: closerLook)
            foundryFaces[foundry.id] = stored
            notices = try database.foundryNotices()
            foundryReadAt[foundry.host] = Date()
            foundryReader[foundry.host] = LibraryStore.foundryReaderVersion
            saveFoundryReadTimes()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func elsewhereFoundries(query: String) -> [OutsideFont] {
        let tokens = queryTokens(query)
        let known = knownFamilyNames
        var cards: [OutsideFont] = []
        for foundry in foundries {
            guard let url = URL(string: foundry.url.absoluteString) else { continue }
            guard !tokens.isEmpty else { continue }
            let faces = foundryFaces[foundry.id] ?? []
            let fresh = faces.filter { !known.contains(foldedName($0)) && queryTokensMatch(tokens, $0) }
            if queryTokensMatch(tokens, foundry.name), cards.count < 24 {
                let detail = foundry.watched
                    ? "Watched foundry. Not in your library."
                    : "Foundry. Not in your library."
                cards.append(OutsideFont(name: foundry.name, source: foundry.sources, detail: detail, url: url))
            }
            for face in fresh.prefix(4) where cards.count < 24 {
                cards.append(OutsideFont(
                    name: face,
                    source: foundry.name,
                    detail: "New from \(foundry.name). Not in your library.",
                    url: url
                ))
            }
        }
        return cards
    }

    private func foundryOrder(_ lhs: FoundryEntry, _ rhs: FoundryEntry) -> Bool {
        if lhs.watched != rhs.watched { return lhs.watched }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func queryTokens(_ query: String) -> [String] {
        foldedName(query)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    private func queryTokensMatch(_ tokens: [String], _ text: String) -> Bool {
        let haystack = foldedName(text)
        return tokens.allSatisfy { haystack.contains($0) }
    }

    private func foldedName(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 128 }) { return text.lowercased() }
        return text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    func deleteResearchChat(_ chat: ResearchChat) {
        guard let database else { return }
        do {
            try database.deleteResearchChat(id: chat.id)
            researchChats.removeAll { $0.id == chat.id }
            if case .research(let id) = filter, id == chat.id {
                filter = .all
                researchMessages = []
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func storeResearchImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fontso/Research", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(UUID().uuidString + ".png")
            try data.write(to: url)
            return url.path
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    func sendResearch(_ text: String, imagePath: String = "") {
        let trimmed = text.cleanedFontName
        let hasImage = !imagePath.isEmpty && FileManager.default.fileExists(atPath: imagePath)
        guard hasImage || !trimmed.isEmpty, let database, case .research(let chatID) = filter else { return }
        guard researchingChatID != chatID else { return }
        let body = trimmed.isEmpty ? "Find fonts that look like this picture." : trimmed
        do {
            let message = try database.addResearchMessage(
                chatID: chatID,
                role: "user",
                text: body,
                suggestions: [],
                imagePath: hasImage ? imagePath : ""
            )
            researchMessages.append(message)
            if researchChats.first(where: { $0.id == chatID })?.title == "New chat" {
                let title = hasImage && trimmed.isEmpty ? "Picture" : String(body.prefix(42))
                try database.renameResearchChat(id: chatID, title: title)
                if let index = researchChats.firstIndex(where: { $0.id == chatID }) {
                    researchChats[index].title = title
                }
            }
            moveResearchChatToFront(chatID)
        } catch {
            alertMessage = error.localizedDescription
            return
        }

        researchingChatID = chatID
        let history = researchMessages
        let faces = fonts
        let lists = groups.map { group in
            ResearchList(name: group.name, identities: listOrder[group.id] ?? Array(membership[group.id, default: []]))
        }
        let picture = hasImage ? imagePath : ""
        Task.detached(priority: .userInitiated) { [weak self] in
            let text: String
            let suggestions: [ResearchSuggestion]
            let listName: String?
            let listFamilies: [String]
            let listStyles: [String]
            let listReplaces: Bool
            if !picture.isEmpty, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: picture) as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                let turn = FontImageMatch.match(image: image, faces: faces, note: body)
                text = turn.text
                suggestions = turn.suggestions
                listName = turn.listName
                listFamilies = turn.listFamilies
                listStyles = turn.listStyles
                listReplaces = turn.listReplaces
            } else {
                do {
                    let turn = try await ResearchConnection.complete(history: history, faces: faces, lists: lists)
                    text = turn.text
                    suggestions = turn.suggestions
                    listName = turn.listName
                    listFamilies = turn.listFamilies
                    listStyles = turn.listStyles
                    listReplaces = turn.listReplaces
                } catch {
                    text = error.localizedDescription
                    suggestions = []
                    listName = nil
                    listFamilies = []
                    listStyles = []
                    listReplaces = false
                }
            }
            let store = self
            await MainActor.run {
                store?.finishResearch(
                    chatID: chatID,
                    text: text,
                    suggestions: suggestions,
                    listName: listName,
                    listFamilies: listFamilies,
                    listStyles: listStyles,
                    listReplaces: listReplaces
                )
            }
        }
    }

    func face(forFamily family: String) -> FontFace? {
        closestFace(in: cuts(in: family), hint: "")
    }

    func face(forFamily family: String, matching hint: String) -> FontFace? {
        let matches = cuts(in: family)
        let foldedHint = hint.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
        let hinted = matches.filter { face in
            let style = face.style.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            return !style.isEmpty && foldedHint.contains(style)
        }
        return closestFace(in: hinted.isEmpty ? matches : hinted, hint: foldedHint)
    }

    private func closestFace(in matches: [FontFace], hint: String) -> FontFace? {
        matches.min { lhs, rhs in
            if lhs.isItalic != rhs.isItalic { return !lhs.isItalic }
            if hint.contains("condens") {
                let leftNarrow = (1...4).contains(lhs.widthClass)
                let rightNarrow = (1...4).contains(rhs.widthClass)
                if leftNarrow != rightNarrow { return leftNarrow }
            }
            return abs(lhs.weightClass - 400) < abs(rhs.weightClass - 400)
        }
    }

    func focusFamily(_ family: String) {
        guard let face = face(forFamily: family) else { return }
        selection = [face.id]
    }

    func focusIdentity(_ identity: String) {
        guard let face = self.face(identity: identity) else { return }
        selection = [face.id]
    }

    func listedCategories(_ face: FontFace) -> Set<FontCategory> {
        if let stored = standardMembership[face.identity] {
            return stored
        }
        var set: Set<FontCategory> = []
        if FontCategory.typographic.contains(face.category) {
            set.insert(face.category)
        }
        if isTrial(face) {
            set.insert(.trial)
        }
        return set
    }

    func isInStandardList(_ category: FontCategory, _ face: FontFace) -> Bool {
        let listed = listedCategories(face)
        if category == .unclassified {
            return !listed.contains { FontCategory.typographic.contains($0) }
        }
        return listed.contains(category)
    }

    func standardListLabel(_ face: FontFace) -> String {
        let names = FontCategory.allCases
            .filter { $0 != .unclassified && isInStandardList($0, face) }
            .map(\.rawValue)
        return names.isEmpty ? FontCategory.unclassified.rawValue : names.joined(separator: ", ")
    }

    func toggleStandardList(_ category: FontCategory, for face: FontFace, familyWide: Bool) {
        guard let database else { return }
        let targets = familyWide ? cuts(in: face.family).filter { $0.family == face.family } : [face]
        let enabled = !isInStandardList(category, face)
        var edits: [(path: String, index: Int, id: Int64, primary: String?)] = []
        var nextLists: [String: Set<FontCategory>] = [:]
        var nextPrimary: [Int64: FontCategory] = [:]
        for target in targets {
            var set = listedCategories(target)
            var primary: String?
            if category == .unclassified {
                set = set.filter { $0 == .trial }
                primary = FontCategory.unclassified.rawValue
                nextPrimary[target.id] = .unclassified
            } else if enabled {
                set.insert(category)
                if category != .trial {
                    primary = category.rawValue
                    nextPrimary[target.id] = category
                }
            } else {
                set.remove(category)
                if category != .trial && (target.category == category || !set.contains(target.category)) {
                    let fallback = FontCategory.typographic.first { set.contains($0) } ?? .unclassified
                    primary = fallback.rawValue
                    nextPrimary[target.id] = fallback
                }
            }
            edits.append((target.filePath, target.faceIndex, target.id, primary))
            nextLists[target.identity] = set
        }
        do {
            try database.applyStandardLists(category: category.rawValue, enabled: enabled, faces: edits)
            for (identity, set) in nextLists {
                standardMembership[identity] = set
            }
            if !nextPrimary.isEmpty {
                var next = fonts
                for index in next.indices {
                    if let category = nextPrimary[next[index].id] {
                        next[index].category = category
                    }
                }
                fonts = next
            }
            touchLibrary()
            if category == .unclassified {
                statusText = targets.count > 1
                    ? "\(targets.count) styles of \(face.family) filed in Unclassified."
                    : "\(face.family) \(face.style) filed in Unclassified."
            } else if enabled {
                statusText = targets.count > 1
                    ? "\(category.rawValue) added to \(targets.count) styles of \(face.family)."
                    : "\(category.rawValue) added to \(face.family) \(face.style)."
            } else {
                statusText = targets.count > 1
                    ? "\(category.rawValue) removed from \(targets.count) styles of \(face.family)."
                    : "\(category.rawValue) removed from \(face.family) \(face.style)."
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func setNote(_ text: String, for face: FontFace) {
        guard let database else { return }
        if text.isEmpty {
            notes.removeValue(forKey: face.identity)
        } else {
            notes[face.identity] = text
        }
        do {
            try database.setNote(filePath: face.filePath, faceIndex: face.faceIndex, body: text)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func familyFaceCount(_ face: FontFace) -> Int {
        fonts.reduce(into: 0) { count, item in
            if item.family == face.family { count += 1 }
        }
    }

    func lists(containing face: FontFace) -> [FontGroup] {
        groups.filter { membership[$0.id, default: []].contains(face.identity) }
    }

    func compareCount(_ id: Int64) -> Int {
        let known = Set(fonts.map(\.identity))
        return (compareMembers[id] ?? []).filter { known.contains($0) }.count
    }

    var compareFaces: [FontFace] {
        guard case .compare(let id) = filter else { return [] }
        let known = Dictionary(uniqueKeysWithValues: fonts.map { ($0.identity, $0) })
        return (compareMembers[id] ?? []).compactMap { known[$0] }
    }

    func addToCompare(_ identities: [String], listID: Int64? = nil) {
        let target = listID ?? currentCompareID ?? compareLists.first?.id
        guard let target, let database else {
            showNewCompare = true
            return
        }
        let known = Set(fonts.map(\.identity))
        var next = compareMembers[target] ?? []
        var added = 0
        for identity in identities where known.contains(identity) && !next.contains(identity) {
            next.append(identity)
            added += 1
        }
        do {
            if added > 0 {
                try database.addCompareMembers(listID: target, keys: next.filter { !compareMembers[target, default: []].contains($0) })
            }
            compareMembers[target] = next
            filter = .compare(target)
            if added > 0 {
                let name = compareLists.first { $0.id == target }?.name ?? "Compare"
                statusText = "\(added) added to “\(name)”."
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func addSelectionToCompare() {
        let identities = fonts.filter { selection.contains($0.id) }.map(\.identity)
        addToCompare(identities)
    }

    func removeFromCompare(_ identity: String) {
        guard case .compare(let id) = filter, let database else { return }
        do {
            try database.removeCompareMembers(listID: id, keys: [identity])
            compareMembers[id]?.removeAll { $0 == identity }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func clearCompare() {
        guard case .compare(let id) = filter, let database else { return }
        do {
            try database.clearCompareList(id: id)
            compareMembers[id] = []
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func commitNewCompare() {
        let name = newCompareName
        newCompareName = ""
        guard let database else { return }
        do {
            let list = try database.createCompareList(name: name)
            compareLists.append(list)
            compareLists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            compareMembers[list.id] = []
            filter = .compare(list.id)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func commitRenameCompare() {
        guard let list = comparePendingRename, let database else { return }
        let name = renameCompareName
        comparePendingRename = nil
        do {
            try database.renameCompareList(id: list.id, name: name)
            if let index = compareLists.firstIndex(where: { $0.id == list.id }) {
                compareLists[index] = FontGroup(id: list.id, name: name.cleanedFontName)
            }
            compareLists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteCompareList(_ list: FontGroup) {
        guard let database else { return }
        do {
            try database.deleteCompareList(id: list.id)
            compareLists.removeAll { $0.id == list.id }
            compareMembers[list.id] = nil
            if case .compare(let id) = filter, id == list.id {
                filter = .all
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func createSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as source"
        panel.message = "Create a new folder with New Folder, then choose it. An empty folder can be a source."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let database else { return }
        do {
            try database.addFolder(path: url.path)
            folders = try database.allFolders()
            let path = normalizeFontPath(url.path)
            if let folder = folders.first(where: { normalizeFontPath($0.path) == path }) {
                filter = .folder(folder.id)
            }
            if folderContainsFonts(url) {
                rescan()
            } else {
                statusText = "Empty source folder added."
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private var currentCompareID: Int64? {
        if case .compare(let id) = filter { return id }
        return nil
    }

    private func importLegacyCompare() throws {
        guard compareLists.isEmpty, let database else { return }
        guard let data = UserDefaults.standard.data(forKey: "fontso.compare"),
              let keys = try? JSONDecoder().decode([String].self, from: data),
              !keys.isEmpty else { return }
        let list = try database.createCompareList(name: "Compare")
        try database.addCompareMembers(listID: list.id, keys: keys)
        UserDefaults.standard.removeObject(forKey: "fontso.compare")
        compareLists = [list]
        compareMembers[list.id] = keys
    }

    private func folderContainsFonts(_ url: URL) -> Bool {
        let extensions = FontIndexer.extensions
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let file as URL in enumerator {
            if extensions.contains(file.pathExtension.lowercased()) {
                return true
            }
        }
        return false
    }

    private func finishResearch(
        chatID: Int64,
        text: String,
        suggestions: [ResearchSuggestion],
        listName: String? = nil,
        listFamilies: [String] = [],
        listStyles: [String] = [],
        listReplaces: Bool = false
    ) {
        defer {
            if researchingChatID == chatID {
                researchingChatID = nil
            }
        }
        guard let database else { return }
        do {
            let message = try database.addResearchMessage(
                chatID: chatID,
                role: "assistant",
                text: text,
                suggestions: suggestions
            )
            if case .research(let current) = filter, current == chatID {
                researchMessages.append(message)
            }
            if suggestions.contains(where: { $0.role == "show" }), let family = suggestions.first?.family {
                focusFamily(family)
            }
            if let listName, !listFamilies.isEmpty {
                fileIntoList(name: listName, families: listFamilies, styles: listStyles, replacing: listReplaces)
            }
            moveResearchChatToFront(chatID)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func moveResearchChatToFront(_ id: Int64) {
        guard let index = researchChats.firstIndex(where: { $0.id == id }) else { return }
        var chat = researchChats.remove(at: index)
        chat.updatedAt = Date()
        researchChats.insert(chat, at: 0)
    }

    func deleteGroup(_ group: FontGroup) {
        guard let database else { return }
        do {
            try database.deleteGroup(id: group.id)
            // Sub-lists move up one level, as the database did.
            for index in groups.indices where groups[index].parentID == group.id {
                groups[index].parentID = group.parentID
            }
            groups.removeAll { $0.id == group.id }
            collapsedGroups.remove(group.id)
            membership[group.id] = nil
            listOrder[group.id] = nil
            listLinks[group.id] = nil
            if case .group(let id) = filter, id == group.id {
                filter = .all
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func fileIntoList(name: String, families: [String], styles: [String] = [], replacing: Bool = false) {
        guard let database else { return }
        let trimmed = name.cleanedFontName
        guard !trimmed.isEmpty else { return }
        let group: FontGroup
        if let existing = groups.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            group = existing
        } else {
            do {
                group = try database.createGroup(name: trimmed)
                groups.append(group)
                groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                membership[group.id] = []
                listOrder[group.id] = []
            } catch {
                alertMessage = error.localizedDescription
                return
            }
        }
        var seen = Set<String>()
        let keys = families.enumerated().flatMap { index, family in
            let style = index < styles.count ? styles[index] : ""
            return fonts.filter { face in
                guard face.family.caseInsensitiveCompare(family) == .orderedSame else { return false }
                return faceMatches(face, style: style)
            }.map(\.identity)
        }.filter { seen.insert($0).inserted }
        if !keys.isEmpty {
            addToGroup(group.id, identities: keys)
        }
        let cuts = styles.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard replacing else { return }
        let keep = Set(keys)
        let extras = Array(membership[group.id, default: []].subtracting(keep))
        guard !extras.isEmpty else { return }
        do {
            try database.removeMembers(groupID: group.id, keys: extras)
            membership[group.id]?.subtract(extras)
            listOrder[group.id]?.removeAll { extras.contains($0) }
            touchLibrary()
            statusText = cuts
                ? "“\(group.name)” now has \(keys.count) cuts."
                : "“\(group.name)” now has \(Set(families).count) families."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// An empty style means the whole family. A named style matches that cut, including "Light Condensed" for "Condensed".
    private func faceMatches(_ face: FontFace, style: String) -> Bool {
        let wanted = style.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted.isEmpty { return true }
        if face.style.caseInsensitiveCompare(wanted) == .orderedSame { return true }
        let foldedStyle = face.style.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
        let words = wanted
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }
        let asksItalic = words.contains { $0 == "italic" || $0 == "oblique" }
        if face.isItalic && !asksItalic { return false }
        return words.allSatisfy { foldedStyle.contains($0) }
    }

    func queueResearchList(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        researchReference = "Liste \(trimmed)"
        statusText = "\(trimmed) added to the chat."
    }

    func queueResearchReference(_ identities: [String]) {
        let phrase = researchPhrase(for: identities)
        guard !phrase.isEmpty else { return }
        researchReference = phrase
        statusText = "\(phrase) added to the chat."
    }

    func researchPhrase(for identities: [String]) -> String {
        var faces: [FontFace] = []
        var seen = Set<String>()
        for identity in identities {
            guard seen.insert(identity).inserted,
                  let face = self.face(identity: identity) else { continue }
            faces.append(face)
        }
        let grouped = Dictionary(grouping: faces, by: \.family)
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { family in
            let cuts = grouped[family] ?? []
            let familyCount = self.cuts(in: family).count
            if cuts.count > 1 && cuts.count == familyCount {
                return family
            }
            return cuts.map { cut in
                if cut.style.isEmpty || cut.style.compare("Regular", options: .caseInsensitive) == .orderedSame {
                    return cut.fullName.isEmpty ? cut.family : cut.fullName
                }
                return "\(cut.family) \(cut.style)"
            }.joined(separator: ", ")
        }.joined(separator: ", ")
    }

    func addListLink(_ groupID: Int64, name: String, source: String, url: URL) {
        guard let database else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        do {
            try database.addGroupLink(groupID: groupID, name: trimmed, source: source, url: url)
            var items = listLinks[groupID] ?? []
            if !items.contains(where: { $0.name == trimmed && $0.url == url }) {
                items.append(OutsideFont(
                    name: trimmed,
                    source: source,
                    detail: "Saved in this list. Not in your library.",
                    url: url
                ))
                listLinks[groupID] = items
            }
            touchLibrary()
            if let list = groups.first(where: { $0.id == groupID }) {
                statusText = "\(trimmed) added to \(list.name)."
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Corrects an outside item wherever it lives: in every list that saved it, in the news, and in the current selection.
    func updateOutsideItem(_ item: OutsideFont, name: String, source: String, url: URL) {
        guard let database else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        let updated = OutsideFont(name: trimmed, source: source, detail: item.detail, url: url, imageURL: item.imageURL)
        do {
            var touched = false
            if listLinks.values.contains(where: { $0.contains { $0.name == item.name && $0.url == item.url } }) {
                try database.updateGroupLinks(name: item.name, url: item.url, name: trimmed, source: source, url: url)
                for (groupID, items) in listLinks {
                    guard items.contains(where: { $0.name == item.name && $0.url == item.url }) else { continue }
                    var changed = items.filter { !($0.name == item.name && $0.url == item.url) }
                    if !changed.contains(where: { $0.name == trimmed && $0.url == url }) {
                        changed.append(OutsideFont(name: trimmed, source: source, detail: "Saved in this list. Not in your library.", url: url))
                    }
                    listLinks[groupID] = changed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                }
                touched = true
            }
            if let index = notices.firstIndex(where: { $0.name == item.name && $0.url == item.url }) {
                try database.updateNotice(id: notices[index].id, name: trimmed, url: url)
                notices[index].name = trimmed
                notices[index].url = url
                touched = true
            }
            if let index = outsideSelection.firstIndex(where: { $0.id == item.id }) {
                outsideSelection[index] = updated
            }
            if touched { touchLibrary() }
            statusText = "\(trimmed) updated."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func removeListLink(_ groupID: Int64, item: OutsideFont) {
        guard let database else { return }
        do {
            try database.removeGroupLink(groupID: groupID, name: item.name, url: item.url)
            listLinks[groupID]?.removeAll { $0.name == item.name && $0.url == item.url }
            outsideSelection.removeAll { $0.name == item.name && $0.url == item.url }
            touchLibrary()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func addToGroup(_ groupID: Int64, identities: [String]) {
        guard let database else { return }
        let known = Set(fonts.map(\.identity))
        var seen = Set<String>()
        let valid = identities.filter { known.contains($0) && seen.insert($0).inserted }
        guard !valid.isEmpty else { return }
        do {
            try database.addMembers(groupID: groupID, keys: valid)
            membership[groupID, default: []].formUnion(valid)
            var order = listOrder[groupID] ?? []
            for key in valid where !order.contains(key) {
                order.append(key)
            }
            listOrder[groupID] = order
            touchLibrary()
            let name = groups.first { $0.id == groupID }?.name ?? "List"
            statusText = "\(valid.count) added to “\(name)”."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Moves fonts in the open list so they sit directly above or below the given family. Fonts new to the list are added there.
    func reorderList(moving identities: [String], nextTo faces: [FontFace], edge: DropEdge) {
        guard case .group(let groupID) = filter, let database else { return }
        let known = Set(fonts.map(\.identity))
        var seen = Set<String>()
        let moving = identities.filter { known.contains($0) && seen.insert($0).inserted }
        guard !moving.isEmpty else { return }
        let target = Set(faces.map(\.identity))
        if Set(moving).isSubset(of: target) { return }
        var members = membership[groupID] ?? []
        let newcomers = moving.filter { !members.contains($0) }
        var order = listOrder[groupID] ?? Array(members)
        do {
            if !newcomers.isEmpty {
                try database.addMembers(groupID: groupID, keys: newcomers)
                members.formUnion(newcomers)
                membership[groupID] = members
                for key in newcomers where !order.contains(key) {
                    order.append(key)
                }
            }
            order.removeAll { moving.contains($0) }
            let positions = faces.compactMap { face in order.firstIndex(of: face.identity) }
            let insertAt: Int
            switch edge {
            case .above: insertAt = positions.min() ?? order.count
            case .below, .inside: insertAt = positions.max().map { $0 + 1 } ?? order.count
            }
            order.insert(contentsOf: moving, at: insertAt)
            try database.setMemberOrder(groupID: groupID, keys: order)
            listOrder[groupID] = order
            sort = .custom
            touchLibrary()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Takes fonts out of the open list and out of its sub-lists, so they leave the view.
    func removeFromCurrentGroup(_ identities: [String]) {
        guard case .group(let groupID) = filter else { return }
        for id in listScope(groupID) where !membership[id, default: []].isDisjoint(with: identities) {
            removeFromGroup(id, identities: identities)
        }
    }

    func removeFromGroup(_ groupID: Int64, identities: [String]) {
        guard let database, !identities.isEmpty else { return }
        do {
            try database.removeMembers(groupID: groupID, keys: identities)
            membership[groupID]?.subtract(identities)
            listOrder[groupID]?.removeAll { identities.contains($0) }
            touchLibrary()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// The list with this name, created when there is none yet.
    func ensureGroup(named name: String) throws -> FontGroup {
        let trimmed = name.cleanedFontName
        guard !trimmed.isEmpty else { throw FontsoError.message("Give the list a name.") }
        if let existing = groups.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        guard let database else { throw FontsoError.message("The library is not open yet.") }
        let group = try database.createGroup(name: trimmed)
        groups.append(group)
        groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        membership[group.id] = []
        listOrder[group.id] = []
        return group
    }

    // MARK: - MCP

    /// Lets another program drive AllFontsO over MCP. Starts the local server only when the user switched it on.
    func setMCPEnabled(_ enabled: Bool) {
        MCPSettings.enabled = enabled
        mcpEnabled = enabled
        if enabled {
            mcpServer.start(store: self)
            mcpPort = mcpServer.port
            mcpError = mcpServer.lastError
        } else {
            mcpServer.stop()
            mcpPort = nil
            mcpError = nil
            if case .research(let id) = filter, !researchChats.contains(where: { $0.id == id }) {
                if let first = researchChats.first {
                    filter = .research(first.id)
                } else {
                    filter = .all
                }
            }
        }
    }

    func startMCPIfEnabled() {
        guard MCPSettings.enabled else {
            try? FileManager.default.removeItem(at: MCPSettings.portFile)
            return
        }
        setMCPEnabled(true)
    }

    /// What a drag from this row carries: the whole selection when the row is part of it, else the row itself.
    /// With `wholeFile`, a variable instance brings every named instance of its file along.
    func identitiesForDrag(_ face: FontFace, wholeFile: Bool = false) -> [String] {
        if selection.contains(face.id) {
            let selected = fonts.filter { selection.contains($0.id) }
            if !selected.isEmpty {
                return wholeFile ? widenToFiles(selected) : selected.map(\.identity)
            }
        }
        if wholeFile, face.isVariable {
            return instances(of: face).map(\.identity)
        }
        return [face.identity]
    }

    private func widenToFiles(_ faces: [FontFace]) -> [String] {
        var seen = Set<String>()
        var identities: [String] = []
        for face in faces {
            let group = face.isVariable ? instances(of: face) : [face]
            for member in group where seen.insert(member.identity).inserted {
                identities.append(member.identity)
            }
        }
        return identities
    }

    func importProviders(_ providers: [NSItemProvider]) {
        let box = DropBox()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let url = Self.url(from: item) {
                    box.add(url)
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            let urls = box.urls
            Task { @MainActor in
                self?.importURLs(urls)
            }
        }
    }

    private func importURLs(_ urls: [URL]) {
        guard let database, !urls.isEmpty else { return }
        var foldersToAdd: [String] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                foldersToAdd.append(url.path)
            } else if FontIndexer.extensions.contains(url.pathExtension.lowercased()) {
                foldersToAdd.append(url.deletingLastPathComponent().path)
            }
        }
        let unique = Array(Set(foldersToAdd.map(normalizeFontPath)))
        guard !unique.isEmpty else {
            statusText = "No font folders in the drop."
            return
        }
        do {
            for path in unique {
                try database.addFolder(path: path)
            }
            folders = try database.allFolders()
            statusText = unique.count == 1 ? "Folder added." : "\(unique.count) folders added."
            rescan()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func applyActivation(_ updates: [FontFace]) {
        guard !updates.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0.activation) })
        var next = fonts
        for index in next.indices {
            if let activation = byID[next[index].id] {
                next[index].activation = activation
            }
        }
        fonts = next
    }

    nonisolated private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }

    private func reloadCollections() throws {
        guard let database else { return }
        favoriteKeys = try database.favoriteKeys()
        notes = try database.allNotes()
        licenses = try database.allLicenseRecords().mapValues { records in
            records.map { FontLicense(project: $0.project, until: $0.validUntil > 0 ? Date(timeIntervalSince1970: $0.validUntil) : nil) }
        }
        standardMembership = try database.standardLists()
        reviewMarks = try database.reviewMarks()
        groups = try database.allGroups()
        membership = try database.membership()
        listOrder = try database.memberOrder()
        listLinks = try database.allGroupLinks()
        compareLists = try database.allCompareLists()
        compareMembers = try database.compareMembership()
    }

    private func chooseFolders(prompt: String, message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = prompt
        panel.message = message
        NSApp.activate()
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    private func isBroadRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == "/" || path == "/Users" || path == home
    }
}

private final class DropBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func add(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func activationUpdates(in faces: [FontFace], activeNames: Set<String>) -> [FontFace] {
    let states = FontActivator.availability(
        libraryFaces: faces.map { ($0.filePath, $0.postscriptName) },
        activeNames: activeNames
    )
    return zip(faces, states).compactMap { face, next in
        guard next != face.activation else { return nil }
        var copy = face
        copy.activation = next
        return copy
    }
}

private func libraryChangeSummary(_ delta: FontLibraryChanges, failed: Int) -> String {
    var parts: [String] = []
    if !delta.added.isEmpty {
        parts.append("\(delta.added.count) new")
    }
    if !delta.updated.isEmpty {
        parts.append("\(delta.updated.count) updated")
    }
    if !delta.removed.isEmpty {
        parts.append("\(delta.removed.count) removed")
    }
    var text = parts.isEmpty ? "Library updated" : parts.joined(separator: ", ")
    if failed > 0 {
        text += ". \(failed) \(failed == 1 ? "file" : "files") could not be read"
    }
    return text + "."
}

private struct CategoryJob: Sendable {
    var family: String
    var path: String
    var faceIndex: Int
    var names: [String]
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
