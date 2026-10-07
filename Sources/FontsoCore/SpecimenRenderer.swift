import CoreGraphics
import CoreGraphics
import CoreText
import Foundation

public enum SpecimenUnit: String, CaseIterable, Sendable {
    case point
    case pixel
    case rem

    public var title: String {
        switch self {
        case .point: return "pt"
        case .pixel: return "px"
        case .rem: return "rem"
        }
    }

    /// CSS pixel: 1 pt = 96/72 px. 1 rem = 16 px = 12 pt.
    public func display(from points: Double) -> Double {
        switch self {
        case .point: return points
        case .pixel: return points * 96 / 72
        case .rem: return points / 12
        }
    }

    public func points(from display: Double) -> Double {
        switch self {
        case .point: return display
        case .pixel: return display * 72 / 96
        case .rem: return display * 12
        }
    }
}

public struct SpecimenGlyphList: Equatable, Sendable {
    public var shown: String
    public var total: Int
}

public enum SpecimenCharacters {
    public static func glyphs(filePath: String, faceIndex: Int, limit: Int = 480) -> SpecimenGlyphList? {
        let url = WebfontUnpacker.openableURL(filePath) as CFURL
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor],
              descriptors.indices.contains(faceIndex) else {
            return nil
        }
        let font = CTFontCreateWithFontDescriptor(descriptors[faceIndex], 12, nil)
        let set = CTFontCopyCharacterSet(font)
        var shown: [UnicodeScalar] = []
        var total = 0
        for value in 0...0xFFFF {
            guard CFCharacterSetIsCharacterMember(set, UniChar(value)),
                  let scalar = UnicodeScalar(value),
                  isVisible(scalar) else { continue }
            total += 1
            if shown.count < limit {
                shown.append(scalar)
            }
        }
        return SpecimenGlyphList(shown: String(String.UnicodeScalarView(shown)), total: total)
    }

    private static func isVisible(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned:
            return false
        default:
            return true
        }
    }
}

public enum SpecimenText {
    public static let standard = """
The quick brown fox jumps over the lazy dog.
Handgloves 0123456789
"""

    public static let alphabet = """
ABCDEFGHIJKLMNOPQRSTUVWXYZ
abcdefghijklmnopqrstuvwxyz
0123456789
"""

    public static let casePair = "Aa Bb Cc Dd Ee Ff Gg Hh Ii Jj Kk Ll Mm Nn Oo Pp Qq Rr Ss Tt Uu Vv Ww Xx Yy Zz"
}

public enum SpecimenRenderer {
    public static func render(
        filePath: String,
        faceIndex: Int,
        text: String,
        pointSize: CGFloat,
        maxWidth: CGFloat,
        variations: [UInt32: Double]
    ) -> CGImage? {
        let url = WebfontUnpacker.openableURL(filePath) as CFURL
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor],
              descriptors.indices.contains(faceIndex) else {
            return nil
        }

        var descriptor = descriptors[faceIndex]
        for (tag, value) in variations {
            var raw = Int32(bitPattern: tag)
            guard let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &raw) else { continue }
            descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, number, value)
        }
        let font = CTFontCreateWithFontDescriptor(descriptor, pointSize, nil)

        let sample = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " " : text
        let attributed = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), sample as CFString)
        let range = CFRange(location: 0, length: CFAttributedStringGetLength(attributed))
        CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, font)
        CFAttributedStringSetAttribute(
            attributed,
            range,
            kCTForegroundColorAttributeName,
            CGColor(gray: 0.13, alpha: 1)
        )

        let alignment = CTTextAlignment.natural
        let lineBreak = CTLineBreakMode.byWordWrapping
        let paragraph: CTParagraphStyle = withUnsafePointer(to: alignment) { alignmentPointer in
            withUnsafePointer(to: lineBreak) { lineBreakPointer in
                let settings = [
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.size,
                        value: alignmentPointer
                    ),
                    CTParagraphStyleSetting(
                        spec: .lineBreakMode,
                        valueSize: MemoryLayout<CTLineBreakMode>.size,
                        value: lineBreakPointer
                    )
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        CFAttributedStringSetAttribute(attributed, range, kCTParagraphStyleAttributeName, paragraph)

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textWidth = max(160, maxWidth)
        let constraints = CGSize(width: textWidth, height: 4000)
        var fit = CFRange(location: 0, length: 0)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            constraints,
            &fit
        )
        let padding: CGFloat = 28
        let canvasWidth = ceil(textWidth + padding * 2)
        let canvasHeight = ceil(min(max(suggested.height, pointSize), 2400) + padding * 2)
        let scale: CGFloat = 2
        guard let context = CGContext(
            data: nil,
            width: Int(canvasWidth * scale),
            height: Int(canvasHeight * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(red: 0.965, green: 0.953, blue: 0.933, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

        let frameRect = CGRect(x: padding, y: padding, width: textWidth, height: canvasHeight - padding * 2)
        let path = CGPath(rect: frameRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }

    /// Specimen text on a transparent canvas. Newlines become extra lines, and the canvas includes ascenders and descenders.
    public static func line(
        filePath: String,
        faceIndex: Int,
        text: String,
        pointSize: CGFloat
    ) -> CGImage? {
        let url = WebfontUnpacker.openableURL(filePath) as CFURL
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor],
              descriptors.indices.contains(faceIndex) else {
            return nil
        }
        let font = CTFontCreateWithFontDescriptor(descriptors[faceIndex], pointSize, nil)
        let sample = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = sample.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        let pieces = rows.isEmpty ? [" "] : rows
        var lines: [CTLine] = []
        var widest: CGFloat = pointSize
        var ascent = CTFontGetAscent(font)
        var descent = CTFontGetDescent(font)
        for piece in pieces {
            let attributed = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
            CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), piece as CFString)
            let range = CFRange(location: 0, length: CFAttributedStringGetLength(attributed))
            CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, font)
            CFAttributedStringSetAttribute(
                attributed,
                range,
                kCTForegroundColorAttributeName,
                CGColor(gray: 0, alpha: 1)
            )
            let line = CTLineCreateWithAttributedString(attributed)
            var lineAscent: CGFloat = 0
            var lineDescent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil))
            ascent = max(ascent, lineAscent)
            descent = max(descent, lineDescent)
            if width > widest { widest = width }
            lines.append(line)
        }
        let pad = max(4, pointSize * 0.12)
        let rowHeight = ascent + descent + pad
        let canvasWidth = ceil(min(widest + 8, 3200))
        let canvasHeight = ceil(rowHeight * CGFloat(lines.count) + pad)
        let scale: CGFloat = 2
        guard let context = CGContext(
            data: nil,
            width: Int(canvasWidth * scale),
            height: Int(canvasHeight * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.clear(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        var baseline = canvasHeight - pad - ascent
        for line in lines {
            context.textPosition = CGPoint(x: 4, y: baseline)
            CTLineDraw(line, context)
            baseline -= rowHeight
        }
        return context.makeImage()
    }
}
