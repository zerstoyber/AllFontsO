import Foundation

struct FaceTables {
    var weightClass: Int
    var widthClass: Int
    var familyClass: Int
    var isItalic: Bool
    var isVariable: Bool
    var panose: [UInt8]
    var xHeight: Int
    var capHeight: Int
    var averageWidth: Int
    var contrast: Int
    var coversLatin: Bool
    var coversCyrillic: Bool
    var coversGreek: Bool
}

enum SfntReader {
    static func readFaces(at url: URL) -> [FaceTables] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let header = read(handle, offset: 0, count: 12), header.count == 12 else { return [] }

        if header.prefix(4) == Data("ttcf".utf8) {
            guard let countData = read(handle, offset: 8, count: 4), let count = countData.u32(0) else { return [] }
            let fontCount = Int(count)
            guard fontCount > 0, fontCount < 512 else { return [] }
            guard let offsetData = read(handle, offset: 12, count: fontCount * 4) else { return [] }
            return (0..<fontCount).compactMap { index in
                guard let faceOffset = offsetData.u32(index * 4) else { return nil }
                return readFace(handle, offset: UInt64(faceOffset))
            }
        }

        if let face = readFace(handle, offset: 0) {
            return [face]
        }
        return []
    }

    private static func readFace(_ handle: FileHandle, offset: UInt64) -> FaceTables? {
        guard let header = read(handle, offset: offset, count: 12), header.count == 12 else { return nil }
        let scaler = header.prefix(4)
        let known = scaler == Data([0x00, 0x01, 0x00, 0x00])
            || scaler == Data("OTTO".utf8)
            || scaler == Data("true".utf8)
            || scaler == Data("typ1".utf8)
        guard known, let tableCount = header.u16(4), tableCount > 0, tableCount < 512 else { return nil }

        guard let directory = read(handle, offset: offset + 12, count: Int(tableCount) * 16) else { return nil }
        var os2: (offset: UInt32, length: UInt32)?
        var head: (offset: UInt32, length: UInt32)?
        var variable = false
        for index in 0..<Int(tableCount) {
            let start = index * 16
            let tag = directory.subdata(in: start..<(start + 4))
            guard let tableOffset = directory.u32(start + 8), let length = directory.u32(start + 12) else { continue }
            if tag == Data("OS/2".utf8) {
                os2 = (tableOffset, length)
            } else if tag == Data("head".utf8) {
                head = (tableOffset, length)
            } else if tag == Data("fvar".utf8) {
                variable = true
            }
        }

        var unitsPerEm = 0
        if let head, let data = read(handle, offset: UInt64(head.offset), count: min(Int(head.length), 54)),
           let value = data.u16(18), value > 0 {
            unitsPerEm = Int(value)
        }

        var weight = 0
        var width = 0
        var familyClass = 0
        var italic = false
        var panose: [UInt8] = []
        var xHeight = 0
        var capHeight = 0
        var averageWidth = 0
        var contrast = 0
        var coversLatin = false
        var coversCyrillic = false
        var coversGreek = false
        if let os2 {
            let length = min(Int(os2.length), 128)
            if let data = read(handle, offset: UInt64(os2.offset), count: length) {
                if let value = data.u16(4) { weight = Int(value) }
                if let value = data.u16(6) { width = Int(value) }
                if let value = data.u16(30) { familyClass = Int(value >> 8) }
                if data.count >= 42 {
                    panose = Array(data[32..<42])
                    if panose.count > 4 { contrast = Int(panose[4]) }
                }
                if let selection = data.u16(62) {
                    italic = (selection & 1) != 0 || (selection & (1 << 9)) != 0
                }
                if let average = data.i16(2), average > 0 {
                    averageWidth = perMille(average, unitsPerEm: unitsPerEm)
                }
                if let version = data.u16(0), version >= 2, data.count >= 90 {
                    if let value = data.i16(86), value > 0 {
                        xHeight = perMille(value, unitsPerEm: unitsPerEm)
                    }
                    if let value = data.i16(88), value > 0 {
                        capHeight = perMille(value, unitsPerEm: unitsPerEm)
                    }
                }
                if let bits = data.u32(42) {
                    coversLatin = (bits & (1 << 1)) != 0 || (bits & (1 << 2)) != 0
                    coversGreek = (bits & (1 << 7)) != 0
                    coversCyrillic = (bits & (1 << 9)) != 0
                }
            }
        }

        return FaceTables(
            weightClass: weight,
            widthClass: width,
            familyClass: familyClass,
            isItalic: italic,
            isVariable: variable,
            panose: panose,
            xHeight: xHeight,
            capHeight: capHeight,
            averageWidth: averageWidth,
            contrast: contrast,
            coversLatin: coversLatin,
            coversCyrillic: coversCyrillic,
            coversGreek: coversGreek
        )
    }

    private static func perMille(_ units: Int, unitsPerEm: Int) -> Int {
        guard unitsPerEm > 0, units > 0 else { return 0 }
        return Int((Double(units) / Double(unitsPerEm) * 1000).rounded())
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) -> Data? {
        guard count > 0 else { return nil }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return (UInt16(self[startIndex + offset]) << 8) | UInt16(self[startIndex + offset + 1])
    }

    func i16(_ offset: Int) -> Int? {
        guard let value = u16(offset) else { return nil }
        return Int(Int16(bitPattern: value))
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = startIndex + offset
        return (UInt32(self[base]) << 24)
            | (UInt32(self[base + 1]) << 16)
            | (UInt32(self[base + 2]) << 8)
            | UInt32(self[base + 3])
    }
}
