import Compression
import Foundation

/// Turns WOFF and WOFF2 into an OpenType file macOS can activate. The original file stays the library identity.
public enum WebfontUnpacker {
    public static func readablePath(for path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard ext == "woff" || ext == "woff2" else { return path }
        return cachedFont(at: URL(fileURLWithPath: path))?.path ?? path
    }

    public static func openableURL(_ path: String) -> URL {
        URL(fileURLWithPath: readablePath(for: path))
    }

    static func unpack(_ data: Data) -> Data? {
        guard data.count >= 4 else { return nil }
        let signature = data.prefix(4)
        if signature == Data("wOFF".utf8) { return unpackWOFF(data) }
        if signature == Data("wOF2".utf8) { return unpackWOFF2(data) }
        return nil
    }

    /// Rebuilds a transformed WOFF2 glyf table. Used to check the glyph decoder without a whole font.
    static func glyfTable(fromTransformed data: Data) -> Data? {
        rebuildGlyf(data)?.glyf
    }

    private static let lock = NSLock()

    private static func cachedFont(at url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let stamp = "\(stableHash(url.path))-\(size)-\(modified)"
        let directory = cacheDirectory()
        let ttf = directory.appendingPathComponent(stamp + ".ttf")
        let otf = directory.appendingPathComponent(stamp + ".otf")
        if FileManager.default.fileExists(atPath: ttf.path) { return ttf }
        if FileManager.default.fileExists(atPath: otf.path) { return otf }

        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: ttf.path) { return ttf }
        if FileManager.default.fileExists(atPath: otf.path) { return otf }
        guard let packed = try? Data(contentsOf: url), let sfnt = unpack(packed) else { return nil }
        let dest = sfnt.prefix(4) == Data("OTTO".utf8) ? otf : ttf
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try sfnt.write(to: dest, options: .atomic)
        } catch {
            return nil
        }
        return dest
    }

    private static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Fontso/webfonts", isDirectory: true)
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private extension WebfontUnpacker {
    static let knownTags = [
        "cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post",
        "cvt ", "fpgm", "glyf", "loca", "prep", "CFF ", "VORG", "EBDT",
        "EBLC", "gasp", "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea",
        "vmtx", "BASE", "GDEF", "GPOS", "GSUB", "EBSC", "JSTF", "MATH",
        "CBDT", "CBLC", "COLR", "CPAL", "SVG ", "sbix", "acnt", "avar",
        "bdat", "bloc", "bsln", "cvar", "fdsc", "feat", "fmtx", "fvar",
        "gvar", "hsty", "just", "lcar", "mort", "morx", "opbd", "prop",
        "trak", "Zapf", "Silf", "Glat", "Gloc", "Feat", "Sill"
    ]

    struct RawTable {
        var tag: Data
        var bytes: Data

        var name: String {
            String(data: tag, encoding: .isoLatin1) ?? ""
        }
    }

    static func unpackWOFF(_ data: Data) -> Data? {
        guard data.count >= 44, data.u32(0) == 0x774F4646 else { return nil }
        let flavor = data.u32(4)
        guard flavor != 0x74746366 else { return nil }
        let count = Int(data.u16(12))
        guard count > 0, count < 256, data.count >= 44 + count * 20 else { return nil }
        var tables: [RawTable] = []
        tables.reserveCapacity(count)
        for index in 0..<count {
            let entry = 44 + index * 20
            let tag = data.subdata(in: (data.startIndex + entry)..<(data.startIndex + entry + 4))
            let offset = Int(data.u32(entry + 4))
            let compressed = Int(data.u32(entry + 8))
            let original = Int(data.u32(entry + 12))
            guard offset >= 0, compressed >= 0, original >= 0, offset + compressed <= data.count else { return nil }
            let source = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + compressed))
            let bytes: Data
            if compressed == original {
                bytes = source
            } else if let inflated = inflate(source, expected: original, algorithm: COMPRESSION_ZLIB) {
                bytes = inflated
            } else {
                return nil
            }
            tables.append(RawTable(tag: tag, bytes: bytes))
        }
        return assemble(flavor: flavor, tables: tables)
    }

    struct WOFF2Entry {
        var tag: Data
        var streamLength: Int
        var transformed: Bool
        var version: Int
    }

    static func unpackWOFF2(_ data: Data) -> Data? {
        guard data.count >= 48, data.u32(0) == 0x774F4632 else { return nil }
        let flavor = data.u32(4)
        guard flavor != 0x74746366 else { return nil }
        let count = Int(data.u16(12))
        let compressedSize = Int(data.u32(20))
        guard count > 0, count < 256, compressedSize > 0 else { return nil }
        var cursor = Cursor(data: data, index: 48)
        var entries: [WOFF2Entry] = []
        for _ in 0..<count {
            guard let flags = cursor.u8() else { return nil }
            let index = Int(flags & 0x3F)
            let version = Int(flags >> 6)
            let tag: Data
            if index == 63 {
                guard let raw = cursor.bytes(4) else { return nil }
                tag = raw
            } else if knownTags.indices.contains(index) {
                tag = Data(knownTags[index].utf8)
            } else {
                return nil
            }
            guard let original = cursor.base128() else { return nil }
            let name = String(data: tag, encoding: .isoLatin1) ?? ""
            let transformed = (name == "glyf" || name == "loca") ? version != 3 : version != 0
            var streamLength = Int(original)
            if transformed {
                guard let transformedLength = cursor.base128() else { return nil }
                if name == "loca", transformedLength != 0 { return nil }
                streamLength = Int(transformedLength)
            }
            entries.append(WOFF2Entry(tag: tag, streamLength: streamLength, transformed: transformed, version: version))
        }
        guard cursor.index + compressedSize <= data.count else { return nil }
        let compressed = data.subdata(in: (data.startIndex + cursor.index)..<(data.startIndex + cursor.index + compressedSize))
        let plainLength = entries.reduce(0) { $0 + $1.streamLength }
        guard let plain = inflate(compressed, expected: plainLength, algorithm: COMPRESSION_BROTLI) else { return nil }
        var stream = Cursor(data: plain, index: 0)
        var tables: [RawTable] = []
        for entry in entries {
            guard let bytes = stream.bytes(entry.streamLength) else { return nil }
            tables.append(RawTable(tag: entry.tag, bytes: bytes))
        }
        guard stream.index == plain.count else { return nil }

        let glyfIndex = tables.firstIndex { $0.name == "glyf" }
        let locaIndex = tables.firstIndex { $0.name == "loca" }
        let glyfTransformed = glyfIndex.map { entries[$0].transformed } ?? false
        let locaTransformed = locaIndex.map { entries[$0].transformed } ?? false
        if glyfTransformed != locaTransformed { return nil }
        var xMins: [Int]?
        if glyfTransformed {
            guard let glyfIndex, let locaIndex, entries[glyfIndex].version == 0, entries[locaIndex].version == 0 else { return nil }
            guard let rebuilt = rebuildGlyf(tables[glyfIndex].bytes) else { return nil }
            tables[glyfIndex].bytes = rebuilt.glyf
            tables[locaIndex].bytes = rebuilt.loca
            xMins = rebuilt.xMins
            if let head = tables.firstIndex(where: { $0.name == "head" }), tables[head].bytes.count >= 52 {
                writeU16(UInt16(rebuilt.indexFormat), into: &tables[head].bytes, at: 50)
            }
        }

        if let hmtx = tables.firstIndex(where: { $0.name == "hmtx" }), entries[hmtx].transformed {
            guard entries[hmtx].version == 1 else { return nil }
            let mins = xMins ?? rawXMins(in: tables)
            guard let mins, let metrics = rebuildHmtx(tables[hmtx].bytes, xMins: mins, tables: tables) else { return nil }
            tables[hmtx].bytes = metrics
        }
        for entry in entries where entry.transformed {
            let name = String(data: entry.tag, encoding: .isoLatin1) ?? ""
            if name != "glyf" && name != "loca" && name != "hmtx" { return nil }
        }
        return assemble(flavor: flavor, tables: tables)
    }

    static func rawXMins(in tables: [RawTable]) -> [Int]? {
        guard let glyf = tables.first(where: { $0.name == "glyf" })?.bytes,
              let loca = tables.first(where: { $0.name == "loca" })?.bytes,
              let head = tables.first(where: { $0.name == "head" })?.bytes,
              let maxp = tables.first(where: { $0.name == "maxp" })?.bytes,
              head.count >= 52, maxp.count >= 6 else { return nil }
        let format = Int(head.u16(50))
        let glyphs = Int(maxp.u16(4))
        return xMins(glyf: glyf, loca: loca, indexFormat: format, glyphCount: glyphs)
    }

    static func xMins(glyf: Data, loca: Data, indexFormat: Int, glyphCount: Int) -> [Int]? {
        guard glyphCount >= 0 else { return nil }
        let entries = glyphCount + 1
        var offsets: [Int] = []
        offsets.reserveCapacity(entries)
        if indexFormat == 0 {
            guard loca.count >= entries * 2 else { return nil }
            for index in 0..<entries {
                offsets.append(Int(loca.u16(index * 2)) * 2)
            }
        } else {
            guard loca.count >= entries * 4 else { return nil }
            for index in 0..<entries {
                offsets.append(Int(loca.u32(index * 4)))
            }
        }
        var mins: [Int] = []
        mins.reserveCapacity(glyphCount)
        for index in 0..<glyphCount {
            let start = offsets[index]
            let end = offsets[index + 1]
            if end < start || start < 0 || start + 4 > glyf.count || end == start {
                mins.append(0)
            } else {
                mins.append(Int(glyf.i16(start + 2)))
            }
        }
        return mins
    }

    static func rebuildHmtx(_ data: Data, xMins: [Int], tables: [RawTable]) -> Data? {
        guard let hhea = tables.first(where: { $0.name == "hhea" })?.bytes, hhea.count >= 36, !data.isEmpty else { return nil }
        let flags = data[data.startIndex]
        guard flags & 0xFC == 0 else { return nil }
        let hasSideBearing = flags & 1 == 0
        let hasTailBearing = flags & 2 == 0
        guard !(hasSideBearing && hasTailBearing) else { return nil }
        let glyphCount = xMins.count
        let metrics = min(Int(hhea.u16(34)), glyphCount)
        guard metrics > 0 else { return nil }
        var cursor = Cursor(data: data, index: 1)
        guard let advances = cursor.bytes(metrics * 2) else { return nil }
        let bearings: Data
        if hasSideBearing {
            guard let stored = cursor.bytes(metrics * 2) else { return nil }
            bearings = stored
        } else {
            var built = Data()
            for index in 0..<metrics {
                appendI16(Int16(clamping: xMins[index]), to: &built)
            }
            bearings = built
        }
        let tailCount = glyphCount - metrics
        let tails: Data
        if hasTailBearing {
            guard let stored = cursor.bytes(tailCount * 2) else { return nil }
            tails = stored
        } else {
            var built = Data()
            for index in metrics..<glyphCount {
                appendI16(Int16(clamping: xMins[index]), to: &built)
            }
            tails = built
        }
        guard cursor.index == data.count else { return nil }
        var out = Data()
        for index in 0..<metrics {
            let start = advances.startIndex + index * 2
            out.append(advances[start])
            out.append(advances[start + 1])
            let bearing = bearings.startIndex + index * 2
            out.append(bearings[bearing])
            out.append(bearings[bearing + 1])
        }
        out.append(tails)
        return out
    }

    struct RebuiltGlyf {
        var glyf: Data
        var loca: Data
        var xMins: [Int]
        var indexFormat: Int
    }

    static func rebuildGlyf(_ data: Data) -> RebuiltGlyf? {
        guard data.count >= 36 else { return nil }
        let optionFlags = data.u16(2)
        let glyphCount = Int(data.u16(4))
        var indexFormat = Int(data.u16(6))
        let contourSize = Int(data.u32(8))
        let pointSize = Int(data.u32(12))
        let flagSize = Int(data.u32(16))
        let glyphSize = Int(data.u32(20))
        let compositeSize = Int(data.u32(24))
        let bboxSize = Int(data.u32(28))
        let instructionSize = Int(data.u32(32))
        var cursor = Cursor(data: data, index: 36)
        guard let contours = cursor.bytes(contourSize),
              let points = cursor.bytes(pointSize),
              let flags = cursor.bytes(flagSize),
              let glyphs = cursor.bytes(glyphSize),
              let composites = cursor.bytes(compositeSize),
              let boxes = cursor.bytes(bboxSize),
              let instructions = cursor.bytes(instructionSize) else { return nil }
        let overlapSize = (optionFlags & 1) == 0 ? 0 : (glyphCount + 7) >> 3
        guard let overlap = cursor.bytes(overlapSize), cursor.index == data.count else { return nil }
        guard contours.count == glyphCount * 2 else { return nil }
        let bitmapSize = ((glyphCount + 31) >> 5) << 2
        guard boxes.count >= bitmapSize else { return nil }

        var contourCursor = Cursor(data: contours, index: 0)
        var pointCursor = Cursor(data: points, index: 0)
        var flagCursor = Cursor(data: flags, index: 0)
        var glyphCursor = Cursor(data: glyphs, index: 0)
        var compositeCursor = Cursor(data: composites, index: 0)
        var boxCursor = Cursor(data: boxes, index: bitmapSize)
        var instructionCursor = Cursor(data: instructions, index: 0)

        var compiled = Data()
        var offsets = [0]
        var xMins: [Int] = []
        for glyphID in 0..<glyphCount {
            guard let contourValue = contourCursor.i16() else { return nil }
            let contours = Int(contourValue)
            let glyph: Data
            let xMin: Int
            if contours == 0 {
                glyph = Data()
                xMin = 0
            } else if contours < 0 {
                guard let composite = readComposite(&compositeCursor) else { return nil }
                guard case .value(let bounds) = readBounds(glyphID, boxes: boxes, bitmapSize: bitmapSize, cursor: &boxCursor, required: true) else { return nil }
                let program = composite.instructions ? readProgram(&glyphCursor, &instructionCursor) : Data()
                guard let program else { return nil }
                guard let bytes = compileComposite(contours: contourValue, bounds: bounds, components: composite.bytes, instructions: program) else { return nil }
                glyph = bytes
                xMin = bounds.xMin
            } else {
                guard let simple = readSimple(
                    contours: contours,
                    points: &pointCursor,
                    flags: &flagCursor,
                    glyphs: &glyphCursor,
                    instructions: &instructionCursor
                ) else { return nil }
                let overlapBit = overlapBitSet(overlap, glyphID)
                guard let box = readBounds(glyphID, boxes: boxes, bitmapSize: bitmapSize, cursor: &boxCursor, required: false) else { return nil }
                let bounds: Bounds
                switch box {
                case .omitted: bounds = simple.bounds
                case .value(let stored): bounds = stored
                }
                guard let bytes = compileSimple(contours: contourValue, bounds: bounds, simple: simple, overlap: overlapBit, instructions: simple.instructions) else { return nil }
                glyph = bytes
                xMin = bounds.xMin
            }
            compiled.append(glyph)
            offsets.append(compiled.count)
            xMins.append(xMin)
        }
        if indexFormat == 0, let last = offsets.last, last >= 0x20000 {
            indexFormat = 1
        }
        var loca = Data()
        if indexFormat == 0 {
            for offset in offsets {
                guard offset % 2 == 0 else { return nil }
                appendU16(UInt16(offset / 2), to: &loca)
            }
        } else {
            for offset in offsets {
                appendU32(UInt32(offset), to: &loca)
            }
        }
        return RebuiltGlyf(glyf: compiled, loca: loca, xMins: xMins, indexFormat: indexFormat)
    }

    struct Bounds {
        var xMin: Int
        var yMin: Int
        var xMax: Int
        var yMax: Int
    }

    struct SimpleGlyph {
        var endPoints: [Int]
        var onCurve: [Bool]
        var xs: [Int]
        var ys: [Int]
        var instructions: Data
        var bounds: Bounds
    }

    static func readSimple(
        contours: Int,
        points: inout Cursor,
        flags: inout Cursor,
        glyphs: inout Cursor,
        instructions: inout Cursor
    ) -> SimpleGlyph? {
        var endPoints: [Int] = []
        var end = -1
        for _ in 0..<contours {
            guard let count = points.u255() else { return nil }
            end += Int(count)
            endPoints.append(end)
        }
        guard let last = endPoints.last, last >= 0 else { return nil }
        let pointCount = last + 1
        guard let flagBytes = flags.bytes(pointCount) else { return nil }
        var xs: [Int] = []
        var ys: [Int] = []
        var onCurve: [Bool] = []
        xs.reserveCapacity(pointCount)
        var x = 0
        var y = 0
        var triplet = glyphs.index
        let tripletData = glyphs.data
        for index in 0..<pointCount {
            let raw = flagBytes[flagBytes.startIndex + index]
            let on = raw & 0x80 == 0
            let flag = Int(raw & 0x7F)
            let bytes: Int
            if flag < 84 { bytes = 1 }
            else if flag < 120 { bytes = 2 }
            else if flag < 124 { bytes = 3 }
            else { bytes = 4 }
            guard triplet + bytes <= tripletData.count else { return nil }
            let b0 = Int(tripletData[tripletData.startIndex + triplet])
            let b1 = bytes > 1 ? Int(tripletData[tripletData.startIndex + triplet + 1]) : 0
            let b2 = bytes > 2 ? Int(tripletData[tripletData.startIndex + triplet + 2]) : 0
            let b3 = bytes > 3 ? Int(tripletData[tripletData.startIndex + triplet + 3]) : 0
            let dx: Int
            let dy: Int
            if flag < 10 {
                dx = 0
                dy = signed(flag, ((flag & 14) << 7) + b0)
            } else if flag < 20 {
                dx = signed(flag, (((flag - 10) & 14) << 7) + b0)
                dy = 0
            } else if flag < 84 {
                let piece = flag - 20
                dx = signed(flag, 1 + (piece & 0x30) + (b0 >> 4))
                dy = signed(flag >> 1, 1 + ((piece & 0x0C) << 2) + (b0 & 0x0F))
            } else if flag < 120 {
                let piece = flag - 84
                dx = signed(flag, 1 + ((piece / 12) << 8) + b0)
                dy = signed(flag >> 1, 1 + (((piece % 12) >> 2) << 8) + b1)
            } else if flag < 124 {
                dx = signed(flag, (b0 << 4) + (b1 >> 4))
                dy = signed(flag >> 1, ((b1 & 0x0F) << 8) + b2)
            } else {
                dx = signed(flag, (b0 << 8) + b1)
                dy = signed(flag >> 1, (b2 << 8) + b3)
            }
            triplet += bytes
            x += dx
            y += dy
            xs.append(x)
            ys.append(y)
            onCurve.append(on)
        }
        glyphs.index = triplet
        guard let program = readProgram(&glyphs, &instructions) else { return nil }
        let bounds = Bounds(
            xMin: xs.min() ?? 0,
            yMin: ys.min() ?? 0,
            xMax: xs.max() ?? 0,
            yMax: ys.max() ?? 0
        )
        return SimpleGlyph(endPoints: endPoints, onCurve: onCurve, xs: xs, ys: ys, instructions: program, bounds: bounds)
    }

    static func signed(_ flag: Int, _ magnitude: Int) -> Int {
        flag & 1 == 0 ? -magnitude : magnitude
    }

    static func readProgram(_ glyphs: inout Cursor, _ instructions: inout Cursor) -> Data? {
        guard let length = glyphs.u255() else { return nil }
        return instructions.bytes(Int(length))
    }

    static func readComposite(_ cursor: inout Cursor) -> (bytes: Data, instructions: Bool)? {
        var bytes = Data()
        var more = true
        var instructions = false
        while more {
            guard let flags = cursor.u16() else { return nil }
            let flag = Int(flags)
            var size = 2
            size += (flag & 1) != 0 ? 4 : 2
            if flag & 8 != 0 { size += 2 }
            else if flag & 64 != 0 { size += 4 }
            else if flag & 128 != 0 { size += 8 }
            guard let rest = cursor.bytes(size) else { return nil }
            appendU16(flags, to: &bytes)
            bytes.append(rest)
            more = flag & 32 != 0
            if flag & 256 != 0 { instructions = true }
        }
        return (bytes, instructions)
    }

    enum BoxRead {
        case omitted
        case value(Bounds)
    }

    static func readBounds(_ glyphID: Int, boxes: Data, bitmapSize: Int, cursor: inout Cursor, required: Bool) -> BoxRead? {
        let byte = glyphID >> 3
        let listed = byte < bitmapSize && boxes[boxes.startIndex + byte] & (0x80 >> (glyphID & 7)) != 0
        if !listed { return required ? nil : .omitted }
        guard let xMin = cursor.i16(), let yMin = cursor.i16(), let xMax = cursor.i16(), let yMax = cursor.i16() else { return nil }
        return .value(Bounds(xMin: Int(xMin), yMin: Int(yMin), xMax: Int(xMax), yMax: Int(yMax)))
    }

    static func overlapBitSet(_ overlap: Data, _ glyphID: Int) -> Bool {
        let byte = glyphID >> 3
        guard byte < overlap.count else { return false }
        return overlap[overlap.startIndex + byte] & (0x80 >> (glyphID & 7)) != 0
    }

    static func compileSimple(contours: Int16, bounds: Bounds, simple: SimpleGlyph, overlap: Bool, instructions: Data) -> Data? {
        guard instructions.count <= 0xFFFF else { return nil }
        var out = Data()
        appendI16(contours, to: &out)
        appendBounds(bounds, to: &out)
        for end in simple.endPoints {
            guard let stored = UInt16(exactly: end) else { return nil }
            appendU16(stored, to: &out)
        }
        appendU16(UInt16(instructions.count), to: &out)
        out.append(instructions)
        var flagBytes = Data()
        var xBytes = Data()
        var yBytes = Data()
        var previousX = 0
        var previousY = 0
        for index in simple.xs.indices {
            var flag: UInt8 = simple.onCurve[index] ? 1 : 0
            if index == 0, overlap { flag |= 0x40 }
            let dx = simple.xs[index] - previousX
            let dy = simple.ys[index] - previousY
            previousX = simple.xs[index]
            previousY = simple.ys[index]
            if dx == 0 {
                flag |= 0x10
            } else {
                guard let stored = Int16(exactly: dx) else { return nil }
                appendI16(stored, to: &xBytes)
            }
            if dy == 0 {
                flag |= 0x20
            } else {
                guard let stored = Int16(exactly: dy) else { return nil }
                appendI16(stored, to: &yBytes)
            }
            flagBytes.append(flag)
        }
        out.append(flagBytes)
        out.append(xBytes)
        out.append(yBytes)
        pad(&out)
        return out
    }

    static func compileComposite(contours: Int16, bounds: Bounds, components: Data, instructions: Data) -> Data? {
        guard instructions.count <= 0xFFFF else { return nil }
        var out = Data()
        appendI16(contours, to: &out)
        appendBounds(bounds, to: &out)
        out.append(components)
        if instructionFlag(in: components) {
            appendU16(UInt16(instructions.count), to: &out)
            out.append(instructions)
        }
        pad(&out)
        return out
    }

    static func instructionFlag(in components: Data) -> Bool {
        var cursor = Cursor(data: components, index: 0)
        var flagged = false
        while cursor.index < components.count {
            guard let flags = cursor.u16() else { return flagged }
            let flag = Int(flags)
            var size = (flag & 1) != 0 ? 4 : 2
            if flag & 8 != 0 { size += 2 }
            else if flag & 64 != 0 { size += 4 }
            else if flag & 128 != 0 { size += 8 }
            guard cursor.bytes(size) != nil else { return flagged }
            if flag & 256 != 0 { flagged = true }
            if flag & 32 == 0 { break }
        }
        return flagged
    }

    static func appendBounds(_ bounds: Bounds, to data: inout Data) {
        appendI16(Int16(clamping: bounds.xMin), to: &data)
        appendI16(Int16(clamping: bounds.yMin), to: &data)
        appendI16(Int16(clamping: bounds.xMax), to: &data)
        appendI16(Int16(clamping: bounds.yMax), to: &data)
    }

    static func pad(_ data: inout Data) {
        while data.count % 4 != 0 { data.append(0) }
    }

    static func assemble(flavor: UInt32, tables: [RawTable]) -> Data {
        var working = tables.sorted { tagPrecedes($0.tag, $1.tag) }
        if let head = working.firstIndex(where: { $0.name == "head" }), working[head].bytes.count >= 12 {
            writeU32(0, into: &working[head].bytes, at: 8)
        }
        let count = working.count
        var power = 1
        var selector = 0
        while power * 2 <= count {
            power *= 2
            selector += 1
        }
        var font = Data()
        appendU32(flavor, to: &font)
        appendU16(UInt16(count), to: &font)
        appendU16(UInt16(power * 16), to: &font)
        appendU16(UInt16(selector), to: &font)
        appendU16(UInt16(count * 16 - power * 16), to: &font)
        var offset = 12 + count * 16
        var directory = Data()
        var body = Data()
        for table in working {
            var padded = table.bytes
            pad(&padded)
            appendTag(table.tag, to: &directory)
            appendU32(checksum(padded), to: &directory)
            appendU32(UInt32(offset), to: &directory)
            appendU32(UInt32(table.bytes.count), to: &directory)
            body.append(padded)
            offset += padded.count
        }
        font.append(directory)
        font.append(body)
        if let head = working.firstIndex(where: { $0.name == "head" }) {
            let entry = 12 + head * 16
            let headOffset = Int(font.u32(entry + 8))
            guard headOffset + 12 <= font.count else { return font }
            let adjustment = 0xB1B0AFBA &- checksum(font)
            writeU32(adjustment, into: &font, at: headOffset + 8)
        }
        return font
    }

    static func inflate(_ source: Data, expected: Int, algorithm: compression_algorithm) -> Data? {
        guard expected > 0, !source.isEmpty else { return expected == 0 ? Data() : nil }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: expected)
        defer { output.deallocate() }
        let written = source.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(output, expected, base, source.count, nil, algorithm)
        }
        guard written == expected else { return nil }
        return Data(bytes: output, count: written)
    }

    static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        var index = 0
        while index + 4 <= data.count {
            sum = sum &+ data.u32(index)
            index += 4
        }
        if index < data.count {
            var word: UInt32 = 0
            var shift: UInt32 = 24
            while index < data.count {
                word |= UInt32(data[data.startIndex + index]) << shift
                shift = shift &- 8
                index += 1
            }
            sum = sum &+ word
        }
        return sum
    }

    static func tagPrecedes(_ lhs: Data, _ rhs: Data) -> Bool {
        for index in 0..<4 {
            let left = lhs[lhs.startIndex + index]
            let right = rhs[rhs.startIndex + index]
            if left != right { return left < right }
        }
        return false
    }

    static func appendTag(_ tag: Data, to data: inout Data) {
        if tag.count >= 4 {
            data.append(tag.prefix(4))
        } else {
            data.append(tag)
            data.append(Data(repeating: 0x20, count: 4 - tag.count))
        }
    }

    static func appendU16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    static func appendU32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    static func appendI16(_ value: Int16, to data: inout Data) {
        appendU16(UInt16(bitPattern: value), to: &data)
    }

    static func writeU16(_ value: UInt16, into data: inout Data, at offset: Int) {
        let start = data.startIndex + offset
        data[start] = UInt8(value >> 8)
        data[start + 1] = UInt8(value & 0xFF)
    }

    static func writeU32(_ value: UInt32, into data: inout Data, at offset: Int) {
        let start = data.startIndex + offset
        data[start] = UInt8((value >> 24) & 0xFF)
        data[start + 1] = UInt8((value >> 16) & 0xFF)
        data[start + 2] = UInt8((value >> 8) & 0xFF)
        data[start + 3] = UInt8(value & 0xFF)
    }
}

private struct Cursor {
    var data: Data
    var index: Int

    mutating func u8() -> UInt8? {
        guard index < data.count else { return nil }
        let value = data[data.startIndex + index]
        index += 1
        return value
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, index + count <= data.count else { return nil }
        let start = data.startIndex + index
        let slice = data.subdata(in: start..<(start + count))
        index += count
        return slice
    }

    mutating func u16() -> UInt16? {
        guard let raw = bytes(2), raw.count == 2 else { return nil }
        return (UInt16(raw[raw.startIndex]) << 8) | UInt16(raw[raw.startIndex + 1])
    }

    mutating func i16() -> Int16? {
        guard let value = u16() else { return nil }
        return Int16(bitPattern: value)
    }

    mutating func base128() -> UInt32? {
        guard let first = u8(), first != 0x80 else { return nil }
        index -= 1
        var result: UInt32 = 0
        for _ in 0..<5 {
            guard let code = u8() else { return nil }
            if result & 0xFE00_0000 != 0 { return nil }
            result = (result << 7) | UInt32(code & 0x7F)
            if code & 0x80 == 0 { return result }
        }
        return nil
    }

    mutating func u255() -> UInt16? {
        guard let code = u8() else { return nil }
        if code == 253 {
            guard let value = u16() else { return nil }
            return value
        }
        if code == 254 {
            guard let extra = u8() else { return nil }
            return 506 + UInt16(extra)
        }
        if code == 255 {
            guard let extra = u8() else { return nil }
            return 253 + UInt16(extra)
        }
        return UInt16(code)
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        let start = startIndex + offset
        return (UInt16(self[start]) << 8) | UInt16(self[start + 1])
    }

    func i16(_ offset: Int) -> Int16 {
        Int16(bitPattern: u16(offset))
    }

    func u32(_ offset: Int) -> UInt32 {
        let start = startIndex + offset
        return (UInt32(self[start]) << 24)
            | (UInt32(self[start + 1]) << 16)
            | (UInt32(self[start + 2]) << 8)
            | UInt32(self[start + 3])
    }
}
