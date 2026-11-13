import Foundation

public enum FontCategory: String, Codable, CaseIterable, Sendable, Hashable {
    case serif = "Serif"
    case sans = "Sans"
    case slab = "Slab Serif"
    case script = "Script"
    case display = "Display"
    case mono = "Monospace"
    case symbol = "Symbol"
    case trial = "Trial"
    case unclassified = "Unclassified"

    public static var typographic: [FontCategory] {
        allCases.filter { $0 != .trial && $0 != .unclassified }
    }

    public static func fromStored(_ raw: String) -> FontCategory {
        if let category = FontCategory(rawValue: raw) {
            return category
        }
        switch raw {
        case "Serifen": return .serif
        case "Serifenlos": return .sans
        case "Schreibschrift": return .script
        case "Symbole": return .symbol
        case "Nicht klassifiziert": return .unclassified
        default: return .unclassified
        }
    }

    public var sortIndex: Int {
        switch self {
        case .serif: return 0
        case .sans: return 1
        case .slab: return 2
        case .mono: return 3
        case .script: return 4
        case .display: return 5
        case .symbol: return 6
        case .trial: return 7
        case .unclassified: return 8
        }
    }
}

public enum Activation: String, Codable, Sendable, Hashable {
    case inactive
    case activated
    case available
    case installed

    public var isAvailableToApps: Bool {
        self != .inactive
    }

    public var label: String {
        switch self {
        case .inactive: return "Inactive"
        case .activated: return "Activated"
        case .available: return "Active"
        case .installed: return "Installed"
        }
    }
}

public struct VariationAxis: Codable, Hashable, Sendable, Identifiable {
    public var tag: UInt32
    public var name: String
    public var min: Double
    public var max: Double
    public var defaultValue: Double

    public var id: UInt32 { tag }

    public var tagName: String {
        let bytes = [
            UInt8((tag >> 24) & 0xFF),
            UInt8((tag >> 16) & 0xFF),
            UInt8((tag >> 8) & 0xFF),
            UInt8(tag & 0xFF)
        ]
        let scalars = bytes.compactMap(UnicodeScalar.init).filter { $0.value >= 32 && $0.value < 127 }
        guard scalars.count == 4 else { return name }
        return String(String.UnicodeScalarView(scalars))
    }
}

public struct FontFace: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var filePath: String
    public var faceIndex: Int
    public var family: String
    public var style: String
    public var fullName: String
    public var postscriptName: String
    public var version: String
    public var manufacturer: String
    public var designer: String
    public var copyright: String
    public var format: String
    public var isVariable: Bool
    public var weightClass: Int
    public var widthClass: Int
    public var category: FontCategory
    public var isItalic: Bool
    public var glyphCount: Int
    public var axes: [VariationAxis]
    public var fileSize: Int64
    public var modifiedAt: Date
    public var activation: Activation
    /// X-height in thousandths of the em. Zero means the font file did not record it.
    public var xHeight: Int
    /// Cap height in thousandths of the em. Zero means the font file did not record it.
    public var capHeight: Int
    /// Average character width in thousandths of the em.
    public var averageWidth: Int
    /// Panose contrast, 0 unknown through 9 very high.
    public var contrast: Int
    public var coversLatin: Bool
    public var coversCyrillic: Bool
    public var coversGreek: Bool
    /// Unpacked OpenType copy of a WOFF or WOFF2 file. Empty for ordinary fonts.
    public var unpackedPath: String
    /// How the category was decided, for Review.
    public var categorySource: CategorySource

    public init(
        id: Int64,
        filePath: String,
        faceIndex: Int,
        family: String,
        style: String,
        fullName: String,
        postscriptName: String,
        version: String,
        manufacturer: String,
        designer: String,
        copyright: String,
        format: String,
        isVariable: Bool,
        weightClass: Int,
        widthClass: Int,
        category: FontCategory,
        isItalic: Bool,
        glyphCount: Int,
        axes: [VariationAxis],
        fileSize: Int64,
        modifiedAt: Date,
        activation: Activation,
        xHeight: Int = 0,
        capHeight: Int = 0,
        averageWidth: Int = 0,
        contrast: Int = 0,
        coversLatin: Bool = false,
        coversCyrillic: Bool = false,
        coversGreek: Bool = false,
        unpackedPath: String = "",
        categorySource: CategorySource = .none
    ) {
        self.id = id
        self.filePath = filePath
        self.faceIndex = faceIndex
        self.family = family
        self.style = style
        self.fullName = fullName
        self.postscriptName = postscriptName
        self.version = version
        self.manufacturer = manufacturer
        self.designer = designer
        self.copyright = copyright
        self.format = format
        self.isVariable = isVariable
        self.weightClass = weightClass
        self.widthClass = widthClass
        self.category = category
        self.isItalic = isItalic
        self.glyphCount = glyphCount
        self.axes = axes
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.activation = activation
        self.xHeight = xHeight
        self.capHeight = capHeight
        self.averageWidth = averageWidth
        self.contrast = contrast
        self.coversLatin = coversLatin
        self.coversCyrillic = coversCyrillic
        self.coversGreek = coversGreek
        self.unpackedPath = unpackedPath
        self.categorySource = categorySource
    }

    public var isWebfont: Bool {
        let kind = format.lowercased()
        return kind == "woff" || kind == "woff2"
    }

    public var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }

    public var identity: String {
        FaceKey.make(path: filePath, index: faceIndex)
    }

    public var canActivate: Bool {
        !activation.isAvailableToApps
    }

    public var canDeactivate: Bool {
        activation.isAvailableToApps && !SystemFontLocations.isProtected(normalized: filePath)
    }

    public var scriptLabel: String {
        var parts: [String] = []
        if coversLatin { parts.append("Latin extended") }
        if coversGreek { parts.append("Greek") }
        if coversCyrillic { parts.append("Cyrillic") }
        return parts.isEmpty ? "Unknown" : parts.joined(separator: ", ")
    }

    public func perMilleLabel(_ value: Int) -> String {
        value > 0 ? "\(value)/1000" : "—"
    }

    public var isTrial: Bool {
        TrialMark.matches(family)
            || TrialMark.matches(style)
            || TrialMark.matches(fullName)
            || TrialMark.matches(postscriptName)
            || TrialMark.matches(filePath)
    }
}

public enum TrialMark {
    public static func matches(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let first = scalars[index].value
            if first == 116 || first == 84, let end = trialEnd(in: scalars, from: index) {
                let before = index == scalars.startIndex ? nil : scalars[scalars.index(before: index)]
                let after = end == scalars.endIndex ? nil : scalars[end]
                if separatesBefore(before, start: scalars[index]) && separatesAfter(after) {
                    return true
                }
            }
            index = scalars.index(after: index)
        }
        return false
    }

    private static let trialLetters: [UInt32] = [116, 114, 105, 97, 108]

    private static func trialEnd(in scalars: String.UnicodeScalarView, from start: String.UnicodeScalarIndex) -> String.UnicodeScalarIndex? {
        var index = start
        for expected in trialLetters {
            guard index < scalars.endIndex else { return nil }
            let value = scalars[index].value
            let folded = (value >= 65 && value <= 90) ? value + 32 : value
            guard folded == expected else { return nil }
            index = scalars.index(after: index)
        }
        return index
    }

    private static func separatesBefore(_ before: UnicodeScalar?, start: UnicodeScalar) -> Bool {
        guard let before else { return true }
        if !CharacterSet.letters.contains(before) { return true }
        return CharacterSet.lowercaseLetters.contains(before) && CharacterSet.uppercaseLetters.contains(start)
    }

    private static func separatesAfter(_ after: UnicodeScalar?) -> Bool {
        guard let after else { return true }
        if !CharacterSet.letters.contains(after) { return true }
        return CharacterSet.uppercaseLetters.contains(after)
    }
}

public enum FaceKey {
    public static func make(path: String, index: Int) -> String {
        "\(path)\n\(index)"
    }

    public static func parse(_ key: String) -> (path: String, index: Int)? {
        guard let newline = key.lastIndex(of: "\n") else { return nil }
        let path = String(key[..<newline])
        let indexPart = key[key.index(after: newline)...]
        guard !path.isEmpty, let index = Int(indexPart) else { return nil }
        return (path, index)
    }
}

/// One license of a cut: the project it was bought for, and until when it runs.
public struct LicenseRecord: Sendable, Equatable {
    public var project: String
    /// Seconds since 1970. Zero for a license with no end date.
    public var validUntil: Double

    public init(project: String, validUntil: Double) {
        self.project = project
        self.validUntil = validUntil
    }
}

public struct FontGroup: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    /// The list this one sits in; 0 for top-level lists.
    public var parentID: Int64

    public init(id: Int64, name: String, parentID: Int64 = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

public struct FontFolder: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var path: String
    public var addedAt: Date

    public var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

public struct ScanProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var currentFile: String

    public init(completed: Int, total: Int, currentFile: String) {
        self.completed = completed
        self.total = total
        self.currentFile = currentFile
    }
}

public struct ScanResult: Sendable {
    public var faces: [FontFace]
    public var failedFiles: [String]

    public init(faces: [FontFace], failedFiles: [String]) {
        self.faces = faces
        self.failedFiles = failedFiles
    }
}

public struct ScanOutcome: Sendable {
    public var result: ScanResult
    public var cancelled: Bool

    public init(result: ScanResult, cancelled: Bool) {
        self.result = result
        self.cancelled = cancelled
    }
}

public enum FontsoError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

public func normalizeFontPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}

public extension String {
    var cleanedFontName: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }
}

/// The order of the pinned fonts: where a moved font lands, and the orders they can be sorted into.
public enum PinOrder {
    public enum Key: String, CaseIterable, Sendable {
        case name
        case weight
        case width
        case category

        public var title: String {
            switch self {
            case .name: return "Name"
            case .weight: return "Weight, light to bold"
            case .width: return "Width, narrow to wide"
            case .category: return "Category"
            }
        }
    }

    /// Puts `moved` in front of `target`, each taken from where it stood; fonts that were not in the order join it.
    /// Without a target they go to the end. A target that is itself moved keeps the place it had.
    public static func place(_ moved: [String], before target: String?, in order: [String]) -> [String] {
        var seen = Set<String>()
        let moved = moved.filter { seen.insert($0).inserted }
        guard !moved.isEmpty else { return order }
        var rest = order.filter { !seen.contains($0) }
        var index = rest.count
        if let target {
            if let at = rest.firstIndex(of: target) {
                index = at
            } else if let stood = order.firstIndex(of: target) {
                index = order[..<stood].filter { !seen.contains($0) }.count
            }
        }
        rest.insert(contentsOf: moved, at: index)
        return rest
    }

    /// Moves one font by places to the left (negative) or right, stopping at the ends.
    public static func step(_ identity: String, by offset: Int, in order: [String]) -> [String] {
        guard let from = order.firstIndex(of: identity) else { return order }
        let to = min(max(from + offset, 0), order.count - 1)
        guard to != from else { return order }
        var result = order
        result.remove(at: from)
        result.insert(identity, at: to)
        return result
    }

    /// The weight a cut is sorted by. Many files carry 400 whatever the cut is; then the style name decides.
    public static func weight(of face: FontFace) -> Int {
        guard face.weightClass == 400 || face.weightClass == 0 else { return face.weightClass }
        let style = face.style.lowercased().filter { $0.isLetter }
        let words: [(String, Int)] = [
            ("extralight", 200), ("ultralight", 200), ("thin", 100), ("hairline", 100),
            ("semibold", 600), ("demibold", 600), ("extrabold", 800), ("ultrabold", 800),
            ("light", 300), ("medium", 500), ("bold", 700), ("black", 900), ("heavy", 900),
            ("demi", 600), ("book", 350),
        ]
        return words.first { style.contains($0.0) }?.1 ?? 400
    }

    /// The fonts in a sorted order. Cuts of one family stay together, upright before italic, light before bold.
    public static func sorted(_ faces: [FontFace], by key: Key) -> [FontFace] {
        var weights: [String: Int] = [:]
        for face in faces { weights[face.identity] = weight(of: face) }
        func heft(_ face: FontFace) -> Int { weights[face.identity] ?? face.weightClass }
        func byName(_ lhs: FontFace, _ rhs: FontFace) -> Bool {
            let families = lhs.family.localizedStandardCompare(rhs.family)
            if families != .orderedSame { return families == .orderedAscending }
            if lhs.widthClass != rhs.widthClass { return lhs.widthClass < rhs.widthClass }
            if heft(lhs) != heft(rhs) { return heft(lhs) < heft(rhs) }
            if lhs.isItalic != rhs.isItalic { return !lhs.isItalic }
            return lhs.style.localizedStandardCompare(rhs.style) == .orderedAscending
        }
        return faces.sorted { lhs, rhs in
            switch key {
            case .name:
                return byName(lhs, rhs)
            case .weight:
                if heft(lhs) != heft(rhs) { return heft(lhs) < heft(rhs) }
                return byName(lhs, rhs)
            case .width:
                if lhs.widthClass != rhs.widthClass { return lhs.widthClass < rhs.widthClass }
                return byName(lhs, rhs)
            case .category:
                if lhs.category != rhs.category { return lhs.category.sortIndex < rhs.category.sortIndex }
                return byName(lhs, rhs)
            }
        }
    }
}
