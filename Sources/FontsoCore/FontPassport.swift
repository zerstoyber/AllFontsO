import Foundation

/// A short English description of how a family looks, from measurements already on the face.
/// Words stay coarse so a search can match them; the numbers stay beside them so two families in the same band are still distinct.
public enum FontPassport {
    public enum ContrastBand: String, Sendable {
        case low
        case moderate
        case high
    }

    public enum XHeightBand: String, Sendable {
        case low
        case moderate
        case high
    }

    public static func contrastBand(_ value: Int) -> ContrastBand? {
        switch value {
        case 1...3: return .low
        case 4...6: return .moderate
        case 7...9: return .high
        default: return nil
        }
    }

    public static func xHeightBand(_ value: Int) -> XHeightBand? {
        guard value > 0 else { return nil }
        if value < 480 { return .low }
        if value < 540 { return .moderate }
        return .high
    }

    public static func isNarrow(widthClass: Int, averageWidth: Int) -> Bool {
        if (1...4).contains(widthClass) { return true }
        return (widthClass == 0 || widthClass == 5) && averageWidth > 0 && averageWidth < 400
    }

    public static func isWide(widthClass: Int, averageWidth: Int) -> Bool {
        if (6...9).contains(widthClass) { return true }
        return (widthClass == 0 || widthClass == 5) && averageWidth > 520
    }

    public static func hasWidth(widthClass: Int, averageWidth: Int) -> Bool {
        widthClass > 0 || averageWidth > 0
    }

    /// OS/2 width word, or a measured stand-in when the class is missing or claims normal. Nil when the family is simply normal.
    public static func widthWord(widthClass: Int, averageWidth: Int) -> String? {
        if (1...4).contains(widthClass) || (6...9).contains(widthClass) {
            return FontClassification.widthLabel(widthClass).lowercased()
        }
        if averageWidth > 0, averageWidth < 400 { return "condensed" }
        if averageWidth > 520 { return "expanded" }
        return nil
    }

    public static func form(
        contrast: Int,
        xHeight: Int,
        widthClass: Int,
        averageWidth: Int,
        coversCyrillic: Bool = false,
        coversGreek: Bool = false,
        weightRange: ClosedRange<Int>? = nil
    ) -> String {
        var parts: [String] = []
        if let band = contrastBand(contrast) {
            parts.append("\(band.rawValue) contrast \(contrast)")
        }
        if xHeight > 0 {
            parts.append("x-height \(xHeight)")
        }
        if let width = widthWord(widthClass: widthClass, averageWidth: averageWidth) {
            parts.append(width)
        }
        if coversCyrillic { parts.append("Cyrillic") }
        if coversGreek { parts.append("Greek") }
        if let range = weightRange, range.lowerBound <= 300, range.upperBound >= 700 {
            parts.append("light to black")
        }
        return parts.joined(separator: ", ")
    }

    public static func form(of face: FontFace, familyFaces: [FontFace] = []) -> String {
        let group = familyFaces.isEmpty ? [face] : familyFaces
        let weights = group.map(\.weightClass)
        let range: ClosedRange<Int>? = {
            guard let min = weights.min(), let max = weights.max() else { return nil }
            return min...max
        }()
        return form(
            contrast: face.contrast,
            xHeight: face.xHeight,
            widthClass: face.widthClass,
            averageWidth: face.averageWidth,
            coversCyrillic: group.contains(where: \.coversCyrillic),
            coversGreek: group.contains(where: \.coversGreek),
            weightRange: range
        )
    }
}
