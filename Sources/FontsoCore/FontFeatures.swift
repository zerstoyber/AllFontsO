import CoreText
import Foundation

/// One switchable typographic feature of a font: an OpenType feature such as `smcp`, or an AAT selector in
/// older Apple fonts. Core Text reports both through the same list.
public struct FontFeature: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `tag` with `value` turns it on; value 0 turns it off.
        case openType(tag: String, value: Int)
        /// AAT feature type and selector; `offSelector` turns it off again where the font offers one.
        case aat(type: Int, selector: Int, offSelector: Int?)
    }

    public var id: String
    /// What Core Text calls it, for example "Small Caps".
    public var title: String
    /// The feature type it belongs to, for example "Letter Case".
    public var group: String
    public var kind: Kind
    /// On when the font is used without any settings.
    public var isDefault: Bool
    /// In an exclusive group only one selector is on at a time.
    public var isExclusive: Bool

    /// The four-letter OpenType tag, when there is one.
    public var tag: String? {
        if case .openType(let tag, _) = kind { return tag }
        return nil
    }

    /// The Core Text setting that puts this feature on or off. Nil when the font offers no way off.
    public func setting(on: Bool) -> [CFString: Any]? {
        switch kind {
        case .openType(let tag, let value):
            return [kCTFontOpenTypeFeatureTag: tag, kCTFontOpenTypeFeatureValue: on ? value : 0]
        case .aat(let type, let selector, let offSelector):
            if on { return [kCTFontFeatureTypeIdentifierKey: type, kCTFontFeatureSelectorIdentifierKey: selector] }
            guard let offSelector else { return nil }
            return [kCTFontFeatureTypeIdentifierKey: type, kCTFontFeatureSelectorIdentifierKey: offSelector]
        }
    }
}

public enum FontFeatures {
    /// The features a font file offers, in the order Core Text lists them. Cached per file and face.
    public static func list(filePath: String, faceIndex: Int) -> [FontFeature] {
        let key = "\(filePath)\n\(faceIndex)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let url = WebfontUnpacker.openableURL(filePath) as CFURL
        var result: [FontFeature] = []
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor], descriptors.indices.contains(faceIndex) {
            let font = CTFontCreateWithFontDescriptor(descriptors[faceIndex], 24, nil)
            result = list(font: font)
        }
        lock.lock()
        cache[key] = result
        lock.unlock()
        return result
    }

    public static func list(font: CTFont) -> [FontFeature] {
        let types = CTFontCopyFeatures(font) as? [[String: Any]] ?? []
        var result: [FontFeature] = []
        var seen: Set<String> = []
        for type in types {
            let typeID = type[kCTFontFeatureTypeIdentifierKey as String] as? Int ?? -1
            let groupName = type[kCTFontFeatureTypeNameKey as String] as? String ?? ""
            let exclusive = (type[kCTFontFeatureTypeExclusiveKey as String] as? Bool) ?? ((type[kCTFontFeatureTypeExclusiveKey as String] as? Int ?? 0) != 0)
            // "All Typographic Features" is the master switch, not a feature.
            guard typeID != 0 else { continue }
            let selectors = type[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]] ?? []
            let defaultSelector = selectors.first { isDefault($0) }?[kCTFontFeatureSelectorIdentifierKey as String] as? Int
            for selector in selectors {
                let name = selector[kCTFontFeatureSelectorNameKey as String] as? String ?? ""
                let selectorID = selector[kCTFontFeatureSelectorIdentifierKey as String] as? Int ?? -1
                let defaultOn = isDefault(selector)
                let tag = selector[kCTFontOpenTypeFeatureTag as String] as? String
                let value = selector[kCTFontOpenTypeFeatureValue as String] as? Int ?? 1
                if let tag {
                    // Kerning is not something to switch in a specimen; it belongs to the text engine.
                    guard tag != "kern", !hidden.contains(tag) else { continue }
                    let id = "ot:\(tag)"
                    guard seen.insert(id).inserted else { continue }
                    result.append(FontFeature(
                        id: id,
                        title: title(for: tag, fallback: name),
                        group: groupName,
                        kind: .openType(tag: tag, value: value),
                        isDefault: defaultOn,
                        isExclusive: exclusive
                    ))
                } else {
                    // AAT: in an exclusive group the default selector is the "off" position, so it is not listed itself.
                    if exclusive, defaultOn { continue }
                    guard selectorID >= 0, !name.isEmpty else { continue }
                    let off: Int?
                    if exclusive {
                        off = defaultSelector
                    } else {
                        off = selectorID % 2 == 0 ? selectorID + 1 : nil
                    }
                    let id = "aat:\(typeID):\(selectorID)"
                    guard seen.insert(id).inserted else { continue }
                    result.append(FontFeature(
                        id: id,
                        title: name,
                        group: groupName,
                        kind: .aat(type: typeID, selector: selectorID, offSelector: off),
                        isDefault: defaultOn,
                        isExclusive: exclusive
                    ))
                }
            }
        }
        return result
    }

    /// Core Text settings for a font: every feature whose switch differs from its default state.
    /// Turning on one member of an exclusive group turns its siblings off.
    public static func settings(_ features: [FontFeature], overrides: [String: Bool]) -> [[CFString: Any]] {
        var result: [[CFString: Any]] = []
        for feature in features {
            guard let wanted = overrides[feature.id], wanted != feature.isDefault else { continue }
            if let setting = feature.setting(on: wanted) {
                result.append(setting)
            }
        }
        return result
    }

    private static func isDefault(_ selector: [String: Any]) -> Bool {
        if let flag = selector[kCTFontFeatureSelectorDefaultKey as String] as? Bool { return flag }
        if let number = selector[kCTFontFeatureSelectorDefaultKey as String] as? Int { return number != 0 }
        return false
    }

    /// Readable names for the common OpenType tags; Core Text's own names are used for the rest.
    public static func title(for tag: String, fallback: String) -> String {
        if let known = names[tag] { return known }
        if tag.hasPrefix("ss"), let number = Int(tag.dropFirst(2)) { return "Stylistic set \(number)" }
        if tag.hasPrefix("cv"), let number = Int(tag.dropFirst(2)) { return "Character variant \(number)" }
        return fallback.isEmpty ? tag : fallback
    }

    private static let names: [String: String] = [
        "liga": "Standard ligatures",
        "dlig": "Discretionary ligatures",
        "hlig": "Historical ligatures",
        "clig": "Contextual ligatures",
        "rlig": "Required ligatures",
        "calt": "Contextual alternates",
        "salt": "Stylistic alternates",
        "swsh": "Swashes",
        "cswh": "Contextual swashes",
        "smcp": "Small caps",
        "c2sc": "Capitals to small caps",
        "pcap": "Petite caps",
        "c2pc": "Capitals to petite caps",
        "unic": "Unicase",
        "case": "Case-sensitive forms",
        "cpsp": "Capital spacing",
        "titl": "Titling",
        "onum": "Oldstyle figures",
        "lnum": "Lining figures",
        "pnum": "Proportional figures",
        "tnum": "Tabular figures",
        "frac": "Fractions",
        "afrc": "Alternative fractions",
        "numr": "Numerators",
        "dnom": "Denominators",
        "sups": "Superscript",
        "subs": "Subscript",
        "sinf": "Scientific inferiors",
        "ordn": "Ordinals",
        "zero": "Slashed zero",
        "hist": "Historical forms",
        "locl": "Localized forms",
        "ornm": "Ornaments",
        "aalt": "All alternates",
        "nalt": "Alternate annotation forms",
        "ital": "Italics",
        "size": "Optical size",
    ]

    /// Tags that are machinery rather than choices.
    private static let hidden: Set<String> = ["kern", "mark", "mkmk", "ccmp", "curs", "rvrn", "rclt", "size", "dist", "locl", "rlig", "abvm", "blwm"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [FontFeature]] = [:]
}
