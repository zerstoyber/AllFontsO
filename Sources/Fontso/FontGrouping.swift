import FontsoCore
import SwiftUI

enum LibrarySort: String, CaseIterable, Identifiable {
    case automatic
    case family
    case foundry
    case designer
    case format
    case status
    case xHeight
    case capHeight
    case letterWidth
    case contrast
    case scripts
    case version
    case fileDate
    case added
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .family: return "Family"
        case .foundry: return "Foundry"
        case .designer: return "Designer"
        case .format: return "Format"
        case .status: return "Status"
        case .xHeight: return "X-height"
        case .capHeight: return "Cap height"
        case .letterWidth: return "Letter width"
        case .contrast: return "Contrast"
        case .scripts: return "Scripts"
        case .version: return "Version"
        case .fileDate: return "File date"
        case .added: return "Added"
        case .custom: return "Your order"
        }
    }

    /// Menu sections: how the fonts are ordered, what their letterforms measure, and what the files record.
    static let orderSection: [LibrarySort] = [.automatic, .family, .foundry, .designer]
    static let letterformSection: [LibrarySort] = [.xHeight, .capHeight, .letterWidth, .contrast]
    static let fileSection: [LibrarySort] = [.format, .status, .scripts, .version, .fileDate, .added]

    var isNumeric: Bool {
        switch self {
        case .xHeight, .capHeight, .letterWidth, .contrast, .fileDate, .added:
            return true
        default:
            return false
        }
    }

    func directionTitle(ascending: Bool) -> String {
        switch self {
        case .fileDate, .added:
            return ascending ? "Oldest first" : "Newest first"
        case .xHeight, .capHeight, .letterWidth, .contrast:
            return ascending ? "Low to high" : "High to low"
        case .custom:
            return ascending ? "As arranged" : "Reversed"
        default:
            return ascending ? "A to Z" : "Z to A"
        }
    }

    var hint: String {
        switch self {
        case .automatic: return "Category, then family. Styles by weight."
        case .family: return "Alphabetical by family name."
        case .foundry: return "Grouped by foundry."
        case .designer: return "Grouped by designer."
        case .format: return "OTF first, then TTF and collections."
        case .status: return "Activated fonts first."
        case .xHeight: return "Families by the x-height of the regular cut."
        case .capHeight: return "Families by cap height."
        case .letterWidth: return "Families by average letter width."
        case .contrast: return "Families by stroke contrast, from none to very high."
        case .scripts: return "Grouped by Latin extended, Greek, and Cyrillic."
        case .version: return "By the version recorded in the font."
        case .fileDate: return "By the date of the font file."
        case .added: return "By the order the fonts were added to the library."
        case .custom: return "Your own order inside a list."
        }
    }
}

enum NewsLane: String, Hashable {
    case fresh
    case seen
}

/// Narrows the list to one file format. A font has exactly one, so the choices exclude each other.
enum FormatFilter: String, CaseIterable, Identifiable {
    case any
    case otf
    case ttf
    case webfont

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "Any format"
        case .otf: return "Only OTF"
        case .ttf: return "Only TTF"
        case .webfont: return "Only webfonts"
        }
    }

    func admits(_ face: FontFace) -> Bool {
        switch self {
        case .any: return true
        case .otf:
            let format = face.format.lowercased()
            return format == "otf" || format == "otc"
        case .ttf:
            let format = face.format.lowercased()
            return format == "ttf" || format == "ttc"
        case .webfont: return face.isWebfont
        }
    }
}

enum LibraryFilter: Hashable {
    case all
    case available
    case inactive
    case variable
    case webfonts
    case desktop
    case favorites
    case licensed
    case category(FontCategory)
    case folder(Int64)
    case group(Int64)
    case research(Int64)
    case compare(Int64)
    case shape(Int64)
    case news(NewsLane)
}

struct BrowseGroup: Identifiable {
    var id: String
    var title: String
    var families: [BrowseFamily]
}

struct BrowseFamily: Identifiable {
    var name: String
    var representative: FontFace
    var faces: [FontFace]
    var fileCount: Int
    var customOrdered = false
    var id: String { name }
}

struct BrowseChild: Identifiable {
    var id: Int64
    var face: FontFace
    var title: String
    var subtitle: String
}

struct FontSection: Identifiable {
    enum RowStyle {
        case style
        case family
    }

    var id: String
    var title: String
    var detail: String
    var faces: [FontFace]
    var rowStyle: RowStyle
}

enum FontGrouping {
    static func browseGroups(
        faces: [FontFace],
        sort: LibrarySort,
        ascending: Bool,
        customOrder: [String] = []
    ) -> [BrowseGroup] {
        let families = families(from: faces)
        switch sort {
        case .automatic:
            let buckets = Dictionary(grouping: families) { $0.representative.category }
            let ordered = FontCategory.allCases.compactMap { category -> BrowseGroup? in
                guard let items = buckets[category], !items.isEmpty else { return nil }
                return BrowseGroup(id: category.rawValue, title: category.rawValue, families: sortFamilies(items, ascending: ascending))
            }
            return ascending ? ordered : ordered.reversed()
        case .family:
            return [BrowseGroup(id: "family", title: "", families: sortFamilies(families, ascending: ascending))]
        case .foundry:
            return grouped(families, missing: "Unknown foundry", ascending: ascending) { $0.representative.manufacturer }
        case .designer:
            return grouped(families, missing: "Unknown designer", ascending: ascending) { $0.representative.designer }
        case .format:
            return grouped(families, missing: "Unknown", ascending: ascending) { $0.representative.format.uppercased() }
        case .status:
            return grouped(families, missing: "Unknown", ascending: ascending) { $0.representative.activation.label }
        case .xHeight:
            return metricGroups(families, ascending: ascending) { $0.representative.xHeight }
        case .capHeight:
            return metricGroups(families, ascending: ascending) { $0.representative.capHeight }
        case .letterWidth:
            return metricGroups(families, ascending: ascending) { $0.representative.averageWidth }
        case .contrast:
            return contrastGroups(families, ascending: ascending)
        case .scripts:
            return grouped(families, missing: "Unknown", ascending: ascending) { $0.representative.scriptLabel }
        case .version:
            return [BrowseGroup(id: "version", title: "", families: sorted(families, ascending: ascending) { versionRank($0.representative.version).localizedStandardCompare(versionRank($1.representative.version)) == .orderedAscending })]
        case .fileDate:
            return [BrowseGroup(id: "fileDate", title: "", families: sorted(families, ascending: ascending) { $0.representative.modifiedAt < $1.representative.modifiedAt })]
        case .added:
            return [BrowseGroup(id: "added", title: "", families: sorted(families, ascending: ascending) { $0.representative.id < $1.representative.id })]
        case .custom:
            return [BrowseGroup(id: "custom", title: "", families: customFamilies(families, order: customOrder, ascending: ascending))]
        }
    }

    /// The rows under an opened family. Static cuts are one row each; a variable file is one row, since activation and
    /// the file itself are shared by all its named instances.
    static func children(of family: BrowseFamily) -> [BrowseChild] {
        let statics = family.faces.filter { !$0.isVariable }
        let variableFiles = Dictionary(grouping: family.faces.filter(\.isVariable), by: \.filePath)
        let variableRows = variableFiles.values.map(variableChild).sorted { lhs, rhs in
            if lhs.face.isItalic != rhs.face.isItalic { return !lhs.face.isItalic }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        if statics.count + variableRows.count <= 40 {
            let ordered = family.customOrdered ? statics : byStyle(statics)
            return ordered.map { face in
                BrowseChild(id: face.id, face: face, title: face.style, subtitle: face.postscriptName)
            } + variableRows
        }
        let files = Dictionary(grouping: statics, by: \.filePath)
        return files.values.map { items in
            let face = items.min(by: isCloserToRegular) ?? items[0]
            let subtitle = items.count == 1 ? face.style : "\(items.count) styles"
            return BrowseChild(id: face.id, face: face, title: face.fileName, subtitle: subtitle)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        + variableRows
    }

    /// One row for a variable file, named after its default instance and counting the rest.
    private static func variableChild(_ instances: [FontFace]) -> BrowseChild {
        let face = instances.min(by: isCloserToRegular) ?? instances[0]
        guard instances.count > 1 else {
            return BrowseChild(id: face.id, face: face, title: face.style, subtitle: face.fileName)
        }
        let title = face.isItalic ? "Variable Italic" : "Variable"
        let sorted = instances.sorted { $0.weightClass < $1.weightClass }
        let range = sorted.count > 1 && sorted.first?.style != sorted.last?.style
            ? "\(sorted[0].style) – \(sorted[sorted.count - 1].style)"
            : face.style
        return BrowseChild(id: face.id, face: face, title: title, subtitle: "\(instances.count) instances · \(range)")
    }

    private static func families(from faces: [FontFace]) -> [BrowseFamily] {
        Dictionary(grouping: faces, by: \.family).map { name, items in
            let representative = items.min(by: isCloserToRegular) ?? items[0]
            return BrowseFamily(
                name: name,
                representative: representative,
                faces: items,
                fileCount: Set(items.map(\.filePath)).count
            )
        }
    }

    private static func isCloserToRegular(_ face: FontFace, _ other: FontFace) -> Bool {
        if face.isItalic != other.isItalic { return !face.isItalic }
        return abs(face.weightClass - 400) < abs(other.weightClass - 400)
    }

    private static func customFamilies(_ families: [BrowseFamily], order: [String], ascending: Bool) -> [BrowseFamily] {
        if order.isEmpty { return sortFamilies(families, ascending: ascending) }
        var index: [String: Int] = [:]
        for (offset, key) in order.enumerated() where index[key] == nil {
            index[key] = offset
        }
        let arranged = families.map { family -> BrowseFamily in
            var next = family
            next.faces.sort { (index[$0.identity] ?? Int.max) < (index[$1.identity] ?? Int.max) }
            next.customOrdered = true
            return next
        }
        return arranged.sorted { lhs, rhs in
            let left = lhs.faces.compactMap { index[$0.identity] }.min() ?? Int.max
            let right = rhs.faces.compactMap { index[$0.identity] }.min() ?? Int.max
            if left != right { return ascending ? left < right : left > right }
            let name = lhs.name.localizedStandardCompare(rhs.name)
            return ascending ? name == .orderedAscending : name == .orderedDescending
        }
    }

    private static func metricGroups(
        _ families: [BrowseFamily],
        ascending: Bool,
        value: (BrowseFamily) -> Int
    ) -> [BrowseGroup] {
        let buckets = Dictionary(grouping: families) { family -> String in
            let number = value(family)
            guard number > 0 else { return "Unknown" }
            let lower = (number / 50) * 50
            return "\(lower)–\(lower + 49)"
        }
        let titles = buckets.keys.sorted { lhs, rhs in
            if lhs == "Unknown" { return false }
            if rhs == "Unknown" { return true }
            let left = Int(lhs.prefix { $0.isNumber }) ?? 0
            let right = Int(rhs.prefix { $0.isNumber }) ?? 0
            if left != right { return ascending ? left < right : left > right }
            return lhs < rhs
        }
        return titles.map { title in
            let items = (buckets[title] ?? []).sorted { lhs, rhs in
                let left = value(lhs)
                let right = value(rhs)
                if left != right { return ascending ? left < right : left > right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return BrowseGroup(id: title, title: title, families: items)
        }
    }

    private static func contrastGroups(_ families: [BrowseFamily], ascending: Bool) -> [BrowseGroup] {
        let buckets = Dictionary(grouping: families) { $0.representative.contrast }
        let keys = buckets.keys.sorted { lhs, rhs in
            if lhs == 0 { return false }
            if rhs == 0 { return true }
            return ascending ? lhs < rhs : lhs > rhs
        }
        return keys.map { key in
            BrowseGroup(
                id: "contrast:\(key)",
                title: FontClassification.contrastLabel(key),
                families: sortFamilies(buckets[key] ?? [], ascending: true)
            )
        }
    }

    private static func versionRank(_ version: String) -> String {
        let parts = version.split { !$0.isNumber }.compactMap { Int($0) }
        if parts.isEmpty { return version.lowercased() }
        return parts.map { String(format: "%08d", $0) }.joined(separator: ".")
    }

    private static func sorted(
        _ families: [BrowseFamily],
        ascending: Bool,
        by areInOrder: (BrowseFamily, BrowseFamily) -> Bool
    ) -> [BrowseFamily] {
        families.sorted { lhs, rhs in
            let ordered = areInOrder(lhs, rhs)
            if areInOrder(rhs, lhs) == ordered {
                let name = lhs.name.localizedStandardCompare(rhs.name)
                return ascending ? name == .orderedAscending : name == .orderedDescending
            }
            return ascending ? ordered : !ordered
        }
    }

    private static func sortFamilies(_ families: [BrowseFamily], ascending: Bool) -> [BrowseFamily] {
        families.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func grouped(
        _ families: [BrowseFamily],
        missing: String,
        ascending: Bool,
        key: (BrowseFamily) -> String
    ) -> [BrowseGroup] {
        let buckets = Dictionary(grouping: families) { family -> String in
            let value = key(family).cleanedFontName
            return value.isEmpty ? missing : value
        }
        let titles = buckets.keys.sorted { lhs, rhs in
            let order = lhs.localizedStandardCompare(rhs)
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return titles.map { title in
            BrowseGroup(id: title, title: title, families: sortFamilies(buckets[title] ?? [], ascending: true))
        }
    }

    static func sections(faces: [FontFace], sort: LibrarySort, ascending: Bool) -> [FontSection] {
        switch sort {
        case .automatic, .family:
            return familySections(faces, showCategory: true, orderByCategory: sort == .automatic, ascending: ascending)
        case .foundry:
            return keyedSections(faces, missing: "Unknown foundry", rowStyle: .family, ascending: ascending) { $0.manufacturer }
        case .designer:
            return keyedSections(faces, missing: "Unknown designer", rowStyle: .family, ascending: ascending) { $0.designer }
        case .format:
            return ordered(formatSections(faces), ascending: ascending)
        case .status:
            return ordered(statusSections(faces), ascending: ascending)
        case .xHeight, .capHeight, .letterWidth, .contrast, .scripts, .version, .fileDate, .added:
            return familySections(faces, showCategory: false, orderByCategory: false, ascending: ascending)
        case .custom:
            return familySections(faces, showCategory: false, orderByCategory: false, ascending: ascending)
        }
    }

    private static func familySections(_ faces: [FontFace], showCategory: Bool, orderByCategory: Bool, ascending: Bool) -> [FontSection] {
        let groups = Dictionary(grouping: faces, by: \.family)
        let keys = groups.keys.sorted { lhs, rhs in
            if orderByCategory {
                let left = groups[lhs]?.first?.category.sortIndex ?? 0
                let right = groups[rhs]?.first?.category.sortIndex ?? 0
                if left != right { return ascending ? left < right : left > right }
            }
            let order = lhs.localizedStandardCompare(rhs)
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return keys.map { family in
            let items = byStyle(groups[family] ?? [])
            let category = items.first?.category.rawValue ?? ""
            return FontSection(
                id: "family:\(category):\(family)",
                title: family,
                detail: showCategory ? category : "",
                faces: items,
                rowStyle: .style
            )
        }
    }

    private static func keyedSections(
        _ faces: [FontFace],
        missing: String,
        rowStyle: FontSection.RowStyle,
        ascending: Bool,
        key: (FontFace) -> String
    ) -> [FontSection] {
        let groups = Dictionary(grouping: faces) { face -> String in
            let value = key(face).cleanedFontName
            return value.isEmpty ? missing : value
        }
        return groups.keys.sorted { lhs, rhs in
            let order = lhs.localizedStandardCompare(rhs)
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }.map { title in
            FontSection(
                id: "key:\(title)",
                title: title,
                detail: "",
                faces: byStyle(groups[title] ?? []),
                rowStyle: rowStyle
            )
        }
    }

    private static func formatSections(_ faces: [FontFace]) -> [FontSection] {
        let order = ["otf", "ttf", "woff", "woff2", "ttc", "otc", "dfont"]
        let groups = Dictionary(grouping: faces, by: \.format)
        let keys = groups.keys.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs) ?? 100
            let right = order.firstIndex(of: rhs) ?? 100
            if left != right { return left < right }
            return lhs < rhs
        }
        return keys.map { format in
            FontSection(
                id: "format:\(format)",
                title: format.uppercased(),
                detail: "",
                faces: byStyle(groups[format] ?? []),
                rowStyle: .family
            )
        }
    }

    private static func statusSections(_ faces: [FontFace]) -> [FontSection] {
        let order: [Activation] = [.activated, .available, .installed, .inactive]
        return order.compactMap { status in
            let items = byStyle(faces.filter { $0.activation == status })
            guard !items.isEmpty else { return nil }
            return FontSection(
                id: "status:\(status.rawValue)",
                title: status.label,
                detail: "",
                faces: items,
                rowStyle: .family
            )
        }
    }

    private static func ordered(_ sections: [FontSection], ascending: Bool) -> [FontSection] {
        ascending ? sections : sections.reversed()
    }

    private static func byStyle(_ faces: [FontFace]) -> [FontFace] {
        faces.sorted { lhs, rhs in
            let family = lhs.family.localizedStandardCompare(rhs.family)
            if family != .orderedSame { return family == .orderedAscending }
            if lhs.weightClass != rhs.weightClass { return lhs.weightClass < rhs.weightClass }
            if lhs.isItalic != rhs.isItalic { return !lhs.isItalic }
            return lhs.style.localizedStandardCompare(rhs.style) == .orderedAscending
        }
    }
}
