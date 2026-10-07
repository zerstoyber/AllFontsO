import CoreText
import Foundation

public struct FontCoverage: Equatable, Sendable, Identifiable {
    public var name: String
    public var present: Int
    public var total: Int

    public var id: String { name }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(present) / Double(total)
    }
}

public struct FontMeasure: Equatable, Sendable {
    public var xHeight: Double
    public var capHeight: Double
    public var width: Double
    public var slant: Double
    public var glyphCount: Int
    public var coverage: [FontCoverage]

    public init(
        xHeight: Double,
        capHeight: Double,
        width: Double,
        slant: Double,
        glyphCount: Int,
        coverage: [FontCoverage]
    ) {
        self.xHeight = xHeight
        self.capHeight = capHeight
        self.width = width
        self.slant = slant
        self.glyphCount = glyphCount
        self.coverage = coverage
    }
}

public enum FontMeasurer {
    /// X-height, cap height, and sample width as fractions of the em. Skips coverage probes so a whole shortlist can be compared quickly.
    public static func proportions(filePath: String, faceIndex: Int) -> (xHeight: Double, capHeight: Double, width: Double)? {
        guard let font = font(filePath: filePath, faceIndex: faceIndex) else { return nil }
        let size: CGFloat = 100
        let text = "Hamburgefonts" as CFString
        let attributed = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), text)
        let range = CFRange(location: 0, length: CFAttributedStringGetLength(attributed))
        CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, font)
        let advance = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
        return (
            xHeight: Double(CTFontGetXHeight(font) / size),
            capHeight: Double(CTFontGetCapHeight(font) / size),
            width: Double(advance / size)
        )
    }

    /// Measures one face at a shared size. X-height and cap height are fractions of the em. Width is the sample’s advance in ems.
    public static func measure(filePath: String, faceIndex: Int, sample: String) -> FontMeasure? {
        let size: CGFloat = 100
        guard let font = font(filePath: filePath, faceIndex: faceIndex, size: size) else { return nil }
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Hamburgefonts" : sample
        let attributed = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), text as CFString)
        let range = CFRange(location: 0, length: CFAttributedStringGetLength(attributed))
        CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, font)
        let line = CTLineCreateWithAttributedString(attributed)
        let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
        return FontMeasure(
            xHeight: Double(CTFontGetXHeight(font) / size),
            capHeight: Double(CTFontGetCapHeight(font) / size),
            width: Double(advance / size),
            slant: Double(CTFontGetSlantAngle(font)),
            glyphCount: CTFontGetGlyphCount(font),
            coverage: probes.map { name, characters in
                let counts = presentCount(characters, font: font)
                return FontCoverage(name: name, present: counts.0, total: counts.1)
            }
        )
    }

    private static func font(filePath: String, faceIndex: Int, size: CGFloat = 100) -> CTFont? {
        let url = WebfontUnpacker.openableURL(filePath) as CFURL
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor],
              descriptors.indices.contains(faceIndex) else {
            return nil
        }
        return CTFontCreateWithFontDescriptor(descriptors[faceIndex], size, nil)
    }

    private static func presentCount(_ text: String, font: CTFont) -> (Int, Int) {
        let scalars = text.unicodeScalars.filter { $0.value <= 0xFFFF }
        guard !scalars.isEmpty else { return (0, 0) }
        var characters = scalars.map { UniChar($0.value) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
        return (glyphs.filter { $0 != 0 }.count, characters.count)
    }

    private static let probes: [(String, String)] = [
        ("Latin", "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"),
        ("Extended", "ÄÖÜäöüßÀÁÂÃÉÍÓÚàèéñçøå"),
        ("Figures", "0123456789"),
        ("Punctuation", ".,;:!?-'\"()"),
        ("Cyrillic", "АБВГДЕЖЗИЙКЛабвгдежзийкл"),
        ("Greek", "ΑΒΓΔΕΖΗΘαβγδεζηθ")
    ]
}
