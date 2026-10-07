import Foundation

/// Case- and accent-insensitive folding with a fast path for plain ASCII, which most font names are.
public enum TextFold {
    public static func fold(_ value: String) -> String {
        if value.utf8.allSatisfy({ $0 < 128 }) {
            return value.lowercased()
        }
        return value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// Plain byte search, far cheaper than Foundation's `contains` for short names.
    public static func bytes(_ haystack: [UInt8], contain needle: [UInt8]) -> Bool {
        let count = needle.count
        guard count > 0 else { return true }
        guard haystack.count >= count else { return false }
        let first = needle[0]
        let last = haystack.count - count
        var index = 0
        while index <= last {
            if haystack[index] == first {
                var offset = 1
                while offset < count, haystack[index + offset] == needle[offset] {
                    offset += 1
                }
                if offset == count { return true }
            }
            index += 1
        }
        return false
    }
}

/// Folded search text per face, computed once and reused while the face stays unchanged.
public struct FaceSearchText: Sendable {
    public let family: String
    public let style: String
    public let fullName: String
    public let postscriptName: String
    public let manufacturer: String
    public let designer: String
    public let fileName: String
    public let category: String
    /// Every field joined with newlines, as UTF-8, for one quick scan per term.
    public let allBytes: [UInt8]
    public let familyBytes: [UInt8]
    public let styleBytes: [UInt8]
    public let manufacturerBytes: [UInt8]
    public let designerBytes: [UInt8]
    public let postscriptBytes: [UInt8]
    fileprivate let stamp: Double
    fileprivate let size: Int64
    fileprivate let rawFamily: String
    fileprivate let rawStyle: String
    fileprivate let rawPath: String

    fileprivate func describes(_ face: FontFace) -> Bool {
        stamp == face.modifiedAt.timeIntervalSinceReferenceDate
            && size == face.fileSize
            && rawFamily == face.family
            && rawStyle == face.style
            && rawPath == face.filePath
    }

    init(_ face: FontFace) {
        rawFamily = face.family
        rawStyle = face.style
        rawPath = face.filePath
        family = TextFold.fold(face.family)
        style = TextFold.fold(face.style)
        fullName = TextFold.fold(face.fullName)
        postscriptName = TextFold.fold(face.postscriptName)
        manufacturer = TextFold.fold(face.manufacturer)
        designer = TextFold.fold(face.designer)
        let slash = face.filePath.lastIndex(of: "/")
        let name = slash.map { String(face.filePath[face.filePath.index(after: $0)...]) } ?? face.filePath
        fileName = TextFold.fold(name)
        category = TextFold.fold(face.category.rawValue)
        allBytes = Array([family, style, fullName, postscriptName, manufacturer, designer, fileName, category].joined(separator: "\n").utf8)
        familyBytes = Array("\(family)\n\(fullName)".utf8)
        styleBytes = Array(style.utf8)
        manufacturerBytes = Array(manufacturer.utf8)
        designerBytes = Array(designer.utf8)
        postscriptBytes = Array(postscriptName.utf8)
        stamp = face.modifiedAt.timeIntervalSinceReferenceDate
        size = face.fileSize
    }
}

public final class SearchIndex: @unchecked Sendable {
    public static let shared = SearchIndex()

    private var entries: [Int64: FaceSearchText] = [:]
    private let lock = NSLock()

    public func text(for face: FontFace) -> FaceSearchText {
        lock.lock()
        if let hit = entries[face.id], hit.describes(face) {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let fresh = FaceSearchText(face)
        lock.lock()
        entries[face.id] = fresh
        lock.unlock()
        return fresh
    }

    /// Builds the entries for many faces at once, meant for a background task right after the library loads.
    public func warm(_ faces: [FontFace]) {
        var built: [Int64: FaceSearchText] = [:]
        built.reserveCapacity(faces.count)
        lock.lock()
        let existing = entries
        lock.unlock()
        for face in faces {
            if let hit = existing[face.id], hit.describes(face) {
                continue
            }
            built[face.id] = FaceSearchText(face)
        }
        guard !built.isEmpty else { return }
        lock.lock()
        entries.merge(built) { _, fresh in fresh }
        lock.unlock()
    }

    public func forget(ids: [Int64]) {
        lock.lock()
        for id in ids { entries[id] = nil }
        lock.unlock()
    }
}
