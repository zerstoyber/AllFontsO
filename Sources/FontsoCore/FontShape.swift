import CoreGraphics
import CoreText
import Foundation

/// How round o is, and how wide n is, both as width divided by height.
public struct FormOutline: Sendable, Equatable {
    public var roundness: Double
    public var letterWidth: Double
}

/// One drawn letter, scaled to fit a square: its width against its height, and how much ink lands in each cell of a coarse grid.
public struct LetterShape: Sendable, Equatable {
    public static let grid = 16

    public var aspect: Double
    public var cells: [Float]
}

/// Classifies a face by looking at the letter shapes when the file has no category.
public enum FontShape {
    public static func measure(filePath: String, faceIndex: Int) -> FontCategory {
        let url = WebfontUnpacker.openableURL(filePath) as CFURL
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor],
              descriptors.indices.contains(faceIndex) else { return .unclassified }
        return classify(CTFontCreateWithFontDescriptor(descriptors[faceIndex], 200, nil))
    }

    public static func classify(_ font: CTFont) -> FontCategory {
        guard latinCount(font) >= 20 else { return .unclassified }
        if monospaced(font) { return .mono }
        if swashy(font) { return .script }
        if let widths = leftRunWidths(font, character: 108) {
            return serifKind(widths) ?? .sans
        }
        return .unclassified
    }

    /// One measurement per family. A later, more regular face can replace an earlier guess.
    public static func category(
        family: String,
        weight: Int,
        italic: Bool,
        filePath: String,
        faceIndex: Int
    ) -> FontCategory {
        let score = (italic ? 1_000 : 0) + abs(weight - 400)
        lock.lock()
        if let cached = cache[family], cached.score <= score {
            lock.unlock()
            return cached.category
        }
        lock.unlock()

        let measured = measure(filePath: filePath, faceIndex: faceIndex)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[family], cached.score <= score {
            return cached.category
        }
        cache[family] = Cached(category: measured, score: score)
        return measured
    }

    /// Width of o against its height, and width of n against its height. Nil when those letters have no path.
    public static func outline(filePath: String, faceIndex: Int) -> FormOutline? {
        let shapes = letterShapes(filePath: filePath, faceIndex: faceIndex, letters: [111, 110])
        guard let round = shapes[111], let stem = shapes[110] else { return nil }
        return FormOutline(roundness: round.aspect, letterWidth: stem.aspect)
    }

    /// Draws the given letters once per face and keeps them. Letters the font cannot draw are left out.
    public static func letterShapes(filePath: String, faceIndex: Int, letters: [UniChar]) -> [UniChar: LetterShape] {
        var result: [UniChar: LetterShape] = [:]
        var pending: [UniChar] = []
        lock.lock()
        for letter in letters {
            let key = letterKey(filePath, faceIndex, letter)
            if let cached = letterCache[key] {
                result[letter] = cached
            } else if !letterMisses.contains(key) {
                pending.append(letter)
            }
        }
        lock.unlock()
        guard !pending.isEmpty else { return result }

        let font = makeFont(filePath: filePath, faceIndex: faceIndex)
        for letter in pending {
            let measured = font.flatMap { readLetterShape($0, character: letter) }
            let key = letterKey(filePath, faceIndex, letter)
            lock.lock()
            if let measured {
                letterCache[key] = measured
                result[letter] = measured
            } else {
                letterMisses.insert(key)
            }
            lock.unlock()
        }
        return result
    }

    /// How far two drawn letters are apart, in match points. Identical drawings give 0, Arial against Helvetica
    /// stays under 4 for n and o, Arial against Times lands near 35 for n and 7 for o.
    public static func difference(_ lhs: LetterShape, _ rhs: LetterShape) -> Double {
        guard lhs.cells.count == rhs.cells.count, !lhs.cells.isEmpty else { return 20 }
        var total: Float = 0
        for index in lhs.cells.indices {
            total += abs(lhs.cells[index] - rhs.cells[index])
        }
        let mean = Double(total) / Double(lhs.cells.count)
        return mean * 90 + abs(lhs.aspect - rhs.aspect) * 16
    }

    public static func resetCache() {
        lock.lock()
        cache.removeAll()
        letterCache.removeAll()
        letterMisses.removeAll()
        lock.unlock()
    }

    private struct Cached {
        var category: FontCategory
        var score: Int
    }

    private static let lock = NSLock()
    private static var cache: [String: Cached] = [:]
    private static var letterCache: [String: LetterShape] = [:]
    private static var letterMisses: Set<String> = []

    private static func letterKey(_ filePath: String, _ faceIndex: Int, _ letter: UniChar) -> String {
        filePath + "\n" + String(faceIndex) + "\n" + String(letter)
    }

    private static func makeFont(filePath: String, faceIndex: Int) -> CTFont? {
        let url = WebfontUnpacker.openableURL(filePath) as CFURL
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor],
              descriptors.indices.contains(faceIndex) else { return nil }
        return CTFontCreateWithFontDescriptor(descriptors[faceIndex], 200, nil)
    }

    private static func readLetterShape(_ font: CTFont, character: UniChar) -> LetterShape? {
        guard let pixels = raster(font, character: character) else { return nil }
        let grid = LetterShape.grid
        let block = pixels.side / grid
        guard block > 0 else { return nil }
        var cells = [Float](repeating: 0, count: grid * grid)
        for gy in 0..<grid {
            for gx in 0..<grid {
                var ink = 0
                for y in (gy * block)..<((gy + 1) * block) {
                    let row = y * pixels.side
                    for x in (gx * block)..<((gx + 1) * block) where pixels.bytes[row + x] < 128 {
                        ink += 1
                    }
                }
                cells[gy * grid + gx] = Float(ink) / Float(block * block)
            }
        }
        return LetterShape(aspect: pixels.aspect, cells: cells)
    }

    private static func latinCount(_ font: CTFont) -> Int {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: letters.count)
        let found = letters.withUnsafeBufferPointer { characters in
            glyphs.withUnsafeMutableBufferPointer { slots in
                CTFontGetGlyphsForCharacters(font, characters.baseAddress!, slots.baseAddress!, letters.count)
            }
        }
        guard found else { return glyphs.filter { $0 != 0 }.count }
        return glyphs.filter { $0 != 0 }.count
    }

    private static func monospaced(_ font: CTFont) -> Bool {
        let widths = [UniChar(105), 110, 109, 87].compactMap { advance(font, $0) }
        guard widths.count == 4, let minWidth = widths.min(), let maxWidth = widths.max() else { return false }
        return maxWidth - minWidth < 0.8
    }

    private static func advance(_ font: CTFont, _ character: UniChar) -> CGFloat? {
        var character = character
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else { return nil }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width
    }

    private static func swashy(_ font: CTFont) -> Bool {
        guard let bounds = glyphBounds(font, character: 73) ?? glyphBounds(font, character: 110) else { return false }
        return bounds.width > bounds.height * 0.85
    }

    private static func glyphBounds(_ font: CTFont, character: UniChar) -> CGRect? {
        var character = character
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else { return nil }
        var transform = CGAffineTransform.identity
        guard let path = CTFontCreatePathForGlyph(font, glyph, &transform) else { return nil }
        let bounds = path.boundingBoxOfPath
        guard bounds.width > 0.5, bounds.height > 0.5 else { return nil }
        return bounds
    }

    private static func serifKind(_ widths: [Int]) -> FontCategory? {
        guard widths.count >= 8 else { return nil }
        let band = max(2, widths.count / 7)
        let top = Array(widths.prefix(band))
        let bottom = Array(widths.suffix(band))
        let mid = Array(widths.dropFirst(widths.count / 3).dropLast(widths.count / 3))
        guard !mid.isEmpty else { return nil }
        let stem = median(mid)
        guard stem > 0 else { return nil }
        let flare = max(top.max() ?? 0, bottom.max() ?? 0)
        guard flare >= stem + 2, Double(flare) >= Double(stem) * 1.4 else { return nil }
        let thick = Int((Double(flare) * 0.85).rounded(.down))
        let slabRun = max(longestRun(top, minimum: thick), longestRun(bottom, minimum: thick))
        return slabRun >= 6 ? .slab : .serif
    }

    private static func longestRun(_ values: [Int], minimum: Int) -> Int {
        var run = 0
        var best = 0
        for value in values {
            if value >= minimum {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
        return best
    }

    private struct Raster {
        var side: Int
        var bytes: [UInt8]
        /// Width of the glyph against its height, before it was scaled into the square.
        var aspect: Double
    }

    private static func leftRunWidths(_ font: CTFont, character: UniChar) -> [Int]? {
        guard let pixels = raster(font, character: character) else { return nil }
        var widths: [Int] = []
        for y in 0..<pixels.side {
            var x = 0
            while x < pixels.side && pixels.bytes[y * pixels.side + x] >= 128 { x += 1 }
            guard x < pixels.side else { continue }
            var count = 0
            while x < pixels.side && pixels.bytes[y * pixels.side + x] < 128 {
                count += 1
                x += 1
            }
            if count > 0 { widths.append(count) }
        }
        return widths.count >= 8 ? widths : nil
    }

    private static func raster(_ font: CTFont, character: UniChar) -> Raster? {
        var character = character
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else { return nil }
        var transform = CGAffineTransform.identity
        guard let path = CTFontCreatePathForGlyph(font, glyph, &transform) else { return nil }
        let bounds = path.boundingBoxOfPath
        guard bounds.width > 0.5, bounds.height > 0.5 else { return nil }

        let canvas = 96
        let pad = 4.0
        guard let context = CGContext(
            data: nil,
            width: canvas,
            height: canvas,
            bitsPerComponent: 8,
            bytesPerRow: canvas,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        context.setFillColor(gray: 0, alpha: 1)
        let scale = (CGFloat(canvas) - pad * 2) / max(bounds.width, bounds.height)
        context.translateBy(x: pad, y: pad)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.addPath(path)
        context.fillPath()

        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: canvas * canvas)
        return Raster(
            side: canvas,
            bytes: Array(UnsafeBufferPointer(start: pixels, count: canvas * canvas)),
            aspect: bounds.width / bounds.height
        )
    }

    private static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
