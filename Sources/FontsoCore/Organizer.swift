import Foundation

public enum OrganizeMode: Sendable {
    case copy
    case move
}

public struct OrganizeFile: Sendable {
    public var path: String
    public var faces: [FontFace]

    public init(path: String, faces: [FontFace]) {
        self.path = path
        self.faces = faces
    }
}

public struct OrganizeResult: Sendable {
    public var written: Int
    public var skipped: Int
    public var failed: [String]

    public init(written: Int, skipped: Int, failed: [String]) {
        self.written = written
        self.skipped = skipped
        self.failed = failed
    }
}

public enum LibraryOrganizer {
    public static func files(from faces: [FontFace]) -> [OrganizeFile] {
        let grouped = Dictionary(grouping: faces, by: \.filePath)
        return grouped.keys.sorted().map { path in
            OrganizeFile(path: path, faces: grouped[path] ?? [])
        }
    }

    public static func relativeDirectory(for faces: [FontFace]) -> String {
        guard let first = faces.first else { return "Unclassified/Untitled" }
        let families = Set(faces.map(\.family))
        if families.count > 1 {
            let stem = URL(fileURLWithPath: first.filePath).deletingPathExtension().lastPathComponent
            return "Collections/\(safePathComponent(stem))"
        }
        let representative = faces.min { lhs, rhs in
            if lhs.isItalic != rhs.isItalic { return !lhs.isItalic }
            if lhs.weightClass != rhs.weightClass { return lhs.weightClass < rhs.weightClass }
            return lhs.style.localizedStandardCompare(rhs.style) == .orderedAscending
        } ?? first
        return "\(safePathComponent(representative.category.rawValue))/\(safePathComponent(representative.family))"
    }

    public static func organize(_ files: [OrganizeFile], to root: URL, mode: OrganizeMode) -> OrganizeResult {
        let fileManager = FileManager.default
        var written = 0
        var skipped = 0
        var failed: [String] = []
        var reserved = Set<String>()

        for file in files {
            let source = URL(fileURLWithPath: file.path)
            if SystemFontLocations.isProtected(source.path) {
                skipped += 1
                continue
            }
            guard fileManager.fileExists(atPath: source.path) else {
                failed.append("\(source.lastPathComponent): file missing")
                continue
            }
            if mode == .move && FontActivator.availability(filePath: source.path, postScriptName: file.faces.first?.postscriptName ?? "") == .activated {
                do {
                    try FontActivator.deactivate(filePath: source.path)
                } catch {
                    failed.append("\(source.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
            }

            let directory = root.appendingPathComponent(relativeDirectory(for: file.faces), isDirectory: true)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = uniqueDestination(
                    directory: directory,
                    fileName: source.lastPathComponent,
                    source: source,
                    reserved: &reserved,
                    fileManager: fileManager
                )
                if normalizeFontPath(destination.path) == normalizeFontPath(source.path) {
                    skipped += 1
                    continue
                }
                switch mode {
                case .copy:
                    try fileManager.copyItem(at: source, to: destination)
                case .move:
                    try fileManager.moveItem(at: source, to: destination)
                }
                written += 1
            } catch {
                failed.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return OrganizeResult(written: written, skipped: skipped, failed: failed)
    }

    static func safePathComponent(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "Untitled"
        }
        return String(cleaned.prefix(120))
    }

    private static func uniqueDestination(
        directory: URL,
        fileName: String,
        source: URL,
        reserved: inout Set<String>,
        fileManager: FileManager
    ) -> URL {
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var index = 1
        while true {
            let name: String
            if index == 1 {
                name = fileName
            } else if ext.isEmpty {
                name = "\(base) \(index)"
            } else {
                name = "\(base) \(index).\(ext)"
            }
            let candidate = directory.appendingPathComponent(name)
            let key = normalizeFontPath(candidate.path)
            let occupied = fileManager.fileExists(atPath: candidate.path) && normalizeFontPath(source.path) != key
            if !occupied && !reserved.contains(key) {
                reserved.insert(key)
                return candidate
            }
            if normalizeFontPath(source.path) == key {
                reserved.insert(key)
                return candidate
            }
            index += 1
            if index > 500 {
                reserved.insert(key)
                return candidate
            }
        }
    }
}
