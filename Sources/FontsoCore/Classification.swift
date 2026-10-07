import Foundation

/// Where a font's category came from, so Review can show the least certain guesses first.
public enum CategorySource: String, Sendable, CaseIterable {
    /// The OS/2 family class the designer wrote into the file.
    case familyClass = "class"
    /// Panose numbers in the file.
    case panose
    /// Core Text's monospace trait.
    case trait
    /// A word in the family or style name.
    case name
    /// Measured from the letter shapes.
    case outline
    /// Nothing in the file gave a hint.
    case none
    /// Set by hand.
    case user

    public init(stored: String) {
        self = CategorySource(rawValue: stored) ?? .none
    }

    /// Higher means more trustworthy.
    public var confidence: Int {
        switch self {
        case .user: return 4
        case .familyClass: return 3
        case .panose, .trait: return 2
        case .name, .outline: return 1
        case .none: return 0
        }
    }

    /// Finishes the sentence "Filed under Sans …".
    public var reason: String {
        switch self {
        case .familyClass: return "from the family class the designer wrote into the file"
        case .panose: return "from the Panose numbers in the file"
        case .trait: return "because the system reports it as monospaced"
        case .name: return "because of a word in its name"
        case .outline: return "from the shape of its letters"
        case .none: return "by nobody: the file gives no hint"
        case .user: return "by you"
        }
    }
}

public enum FontClassification {
    public static func category(
        familyClass: Int,
        panose: [UInt8],
        monoTrait: Bool,
        names: [String] = []
    ) -> FontCategory {
        categoryWithSource(familyClass: familyClass, panose: panose, monoTrait: monoTrait, names: names).category
    }

    public static func categoryWithSource(
        familyClass: Int,
        panose: [UInt8],
        monoTrait: Bool,
        names: [String] = []
    ) -> (category: FontCategory, source: CategorySource) {
        var resolved = category(fromClass: familyClass)
        var source: CategorySource = .familyClass
        if resolved == .unclassified {
            resolved = category(fromPanose: panose)
            source = .panose
        }
        if monoTrait || isMonospaced(panose) {
            switch resolved {
            case .sans, .serif, .slab, .unclassified:
                return (.mono, isMonospaced(panose) ? .panose : .trait)
            default:
                break
            }
        }
        if resolved == .unclassified, let named = category(fromNames: names) {
            return (named, .name)
        }
        return (resolved, resolved == .unclassified ? .none : source)
    }

    /// Reads a category out of the family, style, or PostScript name when the font file itself has none.
    public static func category(fromNames names: [String]) -> FontCategory? {
        let folded = names.joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
            .lowercased()
        guard folded.contains(where: \.isLetter) else { return nil }
        func has(_ stem: String) -> Bool { folded.contains(stem) }

        if has("dingbat") || has("wingding") || has("webding") || has("ornament") || has("emoji") || has("pictogram") {
            return .symbol
        }
        if has("monospace") || has("monospaced") || has("typewriter") || has("semimono") || has("semi-mono") || has("semi mono") || has("mono") {
            return .mono
        }
        if has("blackletter") || has("calligraphy") || has("handwritten") || has("handwriting")
            || has("fraktur") || has("textura") || has("schwabacher") || has("schreibschrift")
            || has("roundhand") || has("cursive") || has("script") || has("brush") || has("chalk") || has("swash") {
            return .script
        }
        if has("clarendon") || has("egyptian") || has("slab") {
            return .slab
        }
        if has("headline") || has("display") || has("stencil") || has("fatface") {
            return .display
        }
        if has("sansserif") || has("sans-serif") || has("sans serif") || has("grotesque") || has("grotesk") || has("gothic") || has("sans") {
            return .sans
        }
        if has("antiqua") || has("serif") {
            return .serif
        }
        return nil
    }

    public static func weightClass(fromTrait trait: Double) -> Int {
        switch trait {
        case ..<(-0.7): return 100
        case ..<(-0.45): return 200
        case ..<(-0.15): return 300
        case ..<0.1: return 400
        case ..<0.27: return 500
        case ..<0.35: return 600
        case ..<0.5: return 700
        case ..<0.6: return 800
        default: return 900
        }
    }

    public static func weightLabel(_ value: Int) -> String {
        switch value {
        case 1...150: return "Thin"
        case 151...250: return "Extra Light"
        case 251...350: return "Light"
        case 351...450: return "Regular"
        case 451...550: return "Medium"
        case 551...650: return "Semibold"
        case 651...750: return "Bold"
        case 751...850: return "Extra Bold"
        case 851...1000: return "Black"
        default: return "—"
        }
    }

    public static func contrastLabel(_ value: Int) -> String {
        switch value {
        case 1: return "None"
        case 2: return "Very low"
        case 3: return "Low"
        case 4: return "Medium low"
        case 5: return "Medium"
        case 6: return "Medium high"
        case 7: return "High"
        case 8, 9: return "Very high"
        default: return "Unknown"
        }
    }

    public static func widthLabel(_ value: Int) -> String {
        switch value {
        case 1: return "Ultra Condensed"
        case 2: return "Extra Condensed"
        case 3: return "Condensed"
        case 4: return "Semi Condensed"
        case 5: return "Normal"
        case 6: return "Semi Expanded"
        case 7: return "Expanded"
        case 8: return "Extra Expanded"
        case 9: return "Ultra Expanded"
        default: return "—"
        }
    }

    private static func category(fromClass familyClass: Int) -> FontCategory {
        switch familyClass {
        case 1, 2, 3, 7: return .serif
        case 4, 5: return .slab
        case 8: return .sans
        case 9: return .display
        case 10: return .script
        case 12: return .symbol
        default: return .unclassified
        }
    }

    private static func category(fromPanose panose: [UInt8]) -> FontCategory {
        guard panose.count >= 2 else { return .unclassified }
        switch panose[0] {
        case 2:
            switch panose[1] {
            case 11, 12, 13, 14, 15: return .sans
            case 4, 5, 6: return .slab
            case 0, 1: return .unclassified
            default: return .serif
            }
        case 3: return .script
        case 4: return .display
        case 5: return .symbol
        default: return .unclassified
        }
    }

    private static func isMonospaced(_ panose: [UInt8]) -> Bool {
        panose.count >= 4 && panose[0] == 2 && panose[3] == 9
    }
}
