import CoreText
import Foundation

public struct FontProportions: Equatable, Sendable {
    public var xHeight: Int
    public var capHeight: Int
    public var averageWidth: Int
    public var contrast: Int
    public var coversLatin: Bool
    public var coversCyrillic: Bool
    public var coversGreek: Bool

    public init(
        xHeight: Int,
        capHeight: Int,
        averageWidth: Int,
        contrast: Int,
        coversLatin: Bool,
        coversCyrillic: Bool,
        coversGreek: Bool
    ) {
        self.xHeight = xHeight
        self.capHeight = capHeight
        self.averageWidth = averageWidth
        self.contrast = contrast
        self.coversLatin = coversLatin
        self.coversCyrillic = coversCyrillic
        self.coversGreek = coversGreek
    }
}

public struct FontFileRecord: Equatable, Sendable {
    public var path: String
    public var fileSize: Int64
    public var modifiedAt: Date

    public init(path: String, fileSize: Int64, modifiedAt: Date) {
        self.path = path
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }
}

public struct FontLibraryChanges: Equatable, Sendable {
    public var added: [FontFileRecord]
    public var updated: [FontFileRecord]
    public var removed: [String]

    public var isEmpty: Bool {
        added.isEmpty && updated.isEmpty && removed.isEmpty
    }
}

public struct FontFolderListing: Sendable {
    public var folder: String
    public var files: [FontFileRecord]
    public var available: Bool

    public init(folder: String, files: [FontFileRecord], available: Bool) {
        self.folder = folder
        self.files = files
        self.available = available
    }
}

public enum FontIndexer {
    public static let extensions: Set<String> = ["otf", "ttf", "ttc", "otc", "dfont", "woff", "woff2"]

    /// Compares the files on disk with the library. A folder that cannot be opened does not count as deleted fonts.
    public static func changes(listings: [FontFolderListing], stored: [FontFileRecord]) -> FontLibraryChanges {
        var known: [String: FontFileRecord] = [:]
        for record in stored where known[record.path] == nil {
            known[record.path] = record
        }
        var seen = Set<String>()
        var added: [FontFileRecord] = []
        var updated: [FontFileRecord] = []
        for listing in listings where listing.available {
            for file in listing.files {
                let path = normalizeFontPath(file.path)
                guard seen.insert(path).inserted else { continue }
                let normalized = FontFileRecord(path: path, fileSize: file.fileSize, modifiedAt: file.modifiedAt)
                if let existing = known[path] {
                    if !sameFile(existing, normalized) {
                        updated.append(normalized)
                    }
                } else {
                    added.append(normalized)
                }
            }
        }
        let availableFolders = listings.filter(\.available).map { normalizeFontPath($0.folder) }
        let removed = known.keys.filter { path in
            !seen.contains(path) && availableFolders.contains { folderCovers(path, folder: $0) }
        }.sorted()
        return FontLibraryChanges(added: added, updated: updated, removed: removed)
    }

    public static func listFontFiles(
        folders: [String],
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) -> (listings: [FontFolderListing], cancelled: Bool) {
        if shouldCancel() { return ([], true) }
        var listings: [FontFolderListing] = []
        for folder in folders {
            if shouldCancel() { return (listings, true) }
            let root = URL(fileURLWithPath: folder)
            guard scanRoot(root, fileManager: .default) != nil else {
                listings.append(FontFolderListing(folder: normalizeFontPath(folder), files: [], available: false))
                continue
            }
            listings.append(FontFolderListing(
                folder: normalizeFontPath(folder),
                files: enumerateRecords(in: root),
                available: true
            ))
        }
        return (listings, false)
    }

    public static func inspect(fileURL: URL, activeNames: Set<String>? = nil) -> [FontFace] {
        let path = normalizeFontPath(fileURL.path)
        let openPath = WebfontUnpacker.readablePath(for: path)
        let unpackedPath = openPath == path ? "" : openPath
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = Int64(values?.fileSize ?? 0)
        let modifiedAt = values?.contentModificationDate ?? Date()
        let reading = URL(fileURLWithPath: openPath)
        let metrics = SfntReader.readFaces(at: reading)
        let probed = FontProbe.read(url: reading)
        guard !probed.isEmpty else { return [] }

        let shared = metrics.count == 1 ? metrics[0] : nil
        return probed.enumerated().map { index, face in
            let metric = index < metrics.count ? metrics[index] : shared
            let familyName = face.family.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : face.family
            let familyClass = (metric?.familyClass ?? 0) != 0 ? (metric?.familyClass ?? 0) : face.traitClass
            let weight = (metric?.weightClass ?? 0) > 0 ? (metric?.weightClass ?? 400) : FontClassification.weightClass(fromTrait: face.weightTrait)
            let italic = (metric?.isItalic ?? false) || face.italicTrait
            var (category, source) = FontClassification.categoryWithSource(
                familyClass: familyClass,
                panose: metric?.panose ?? [],
                monoTrait: face.monoTrait,
                names: [familyName, face.style, face.fullName, face.postscriptName]
            )
            if category == .unclassified {
                category = FontShape.category(
                    family: familyName,
                    weight: weight,
                    italic: italic,
                    filePath: openPath,
                    faceIndex: index
                )
                source = category == .unclassified ? .none : .outline
            }
            let variable = (metric?.isVariable ?? false) || !face.axes.isEmpty
            let format = fileURL.pathExtension.lowercased()
            return FontFace(
                id: 0,
                filePath: path,
                faceIndex: index,
                family: familyName,
                style: face.style.isEmpty ? "Regular" : face.style,
                fullName: face.fullName,
                postscriptName: face.postscriptName,
                version: face.version,
                manufacturer: face.manufacturer,
                designer: face.designer,
                copyright: face.copyright,
                format: format.isEmpty ? "font" : format,
                isVariable: variable,
                weightClass: weight,
                widthClass: metric?.widthClass ?? 0,
                category: category,
                isItalic: italic,
                glyphCount: face.glyphCount,
                axes: face.axes,
                fileSize: fileSize,
                modifiedAt: modifiedAt,
                activation: FontActivator.availability(
                    filePath: path,
                    postScriptName: face.postscriptName,
                    activeNames: activeNames
                ),
                xHeight: metric?.xHeight ?? 0,
                capHeight: metric?.capHeight ?? 0,
                averageWidth: metric?.averageWidth ?? 0,
                contrast: metric?.contrast ?? 0,
                coversLatin: metric?.coversLatin ?? false,
                coversCyrillic: metric?.coversCyrillic ?? false,
                coversGreek: metric?.coversGreek ?? false,
                unpackedPath: unpackedPath,
                categorySource: source
            )
        }
    }

    /// X-height, cap height, average width, contrast, and script coverage from the font file. One entry per face, in file order.
    /// Re-reads only the metadata that decides a category, so libraries indexed before
    /// sources were recorded can learn where their categories came from without a rescan.
    /// Returns one entry per face in the file, in face order.
    public static func categoryHints(filePath: String) -> [(category: FontCategory, source: CategorySource)] {
        let reading = WebfontUnpacker.openableURL(filePath)
        let metrics = SfntReader.readFaces(at: reading)
        let probed = FontProbe.read(url: reading)
        let shared = metrics.count == 1 ? metrics[0] : nil
        return probed.enumerated().map { index, face in
            let metric = index < metrics.count ? metrics[index] : shared
            let familyClass = (metric?.familyClass ?? 0) != 0 ? (metric?.familyClass ?? 0) : face.traitClass
            return FontClassification.categoryWithSource(
                familyClass: familyClass,
                panose: metric?.panose ?? [],
                monoTrait: face.monoTrait,
                names: [face.family, face.style, face.fullName, face.postscriptName]
            )
        }
    }

    public static func proportions(filePath: String) -> [FontProportions] {
        SfntReader.readFaces(at: WebfontUnpacker.openableURL(filePath)).map { metric in
            FontProportions(
                xHeight: metric.xHeight,
                capHeight: metric.capHeight,
                averageWidth: metric.averageWidth,
                contrast: metric.contrast,
                coversLatin: metric.coversLatin,
                coversCyrillic: metric.coversCyrillic,
                coversGreek: metric.coversGreek
            )
        }
    }

    public static func scan(
        folders: [String],
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) -> ScanOutcome {
        if shouldCancel() {
            return ScanOutcome(result: ScanResult(faces: [], failedFiles: []), cancelled: true)
        }

        FontShape.resetCache()
        var files: [URL] = []
        var seen = Set<String>()
        for folder in folders {
            for url in enumerateFonts(in: URL(fileURLWithPath: folder)) {
                let path = normalizeFontPath(url.path)
                if seen.insert(path).inserted {
                    files.append(url)
                }
            }
            if shouldCancel() {
                return ScanOutcome(result: ScanResult(faces: [], failedFiles: []), cancelled: true)
            }
        }

        var faces: [FontFace] = []
        var failed: [String] = []
        let total = files.count
        let activeNames = FontActivator.activePostScriptNames()
        for (index, url) in files.enumerated() {
            if shouldCancel() {
                return ScanOutcome(result: ScanResult(faces: faces, failedFiles: failed), cancelled: true)
            }
            if index % 8 == 0 || index == total - 1 {
                progress(ScanProgress(completed: index, total: total, currentFile: url.lastPathComponent))
            }
            let inspected = inspect(fileURL: url, activeNames: activeNames)
            if inspected.isEmpty {
                failed.append(url.path)
            } else {
                faces.append(contentsOf: inspected)
            }
        }
        progress(ScanProgress(completed: total, total: total, currentFile: ""))
        return ScanOutcome(result: ScanResult(faces: faces, failedFiles: failed), cancelled: false)
    }

    static func enumerateFonts(in root: URL) -> [URL] {
        enumerateRecords(in: root).map { URL(fileURLWithPath: $0.path) }
    }

    private static func enumerateRecords(in root: URL) -> [FontFileRecord] {
        let fileManager = FileManager.default
        var pending = [scanRoot(root, fileManager: fileManager)].compactMap { $0 }
        var files: [FontFileRecord] = []
        var visited = Set<String>()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        while let directory = pending.popLast() {
            let directoryPath = normalizeFontPath(directory.path)
            guard visited.insert(directoryPath).inserted else { continue }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let item as URL in enumerator {
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    let name = item.lastPathComponent
                    if name == "Library" {
                        enumerator.skipDescendants()
                        if let fonts = scanRoot(item.appendingPathComponent("Fonts"), fileManager: fileManager) {
                            pending.append(fonts)
                        }
                    } else if skippedDirectoryNames.contains(name) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard extensions.contains(item.pathExtension.lowercased()) else { continue }
                let values = try? item.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                files.append(FontFileRecord(
                    path: normalizeFontPath(item.path),
                    fileSize: Int64(values?.fileSize ?? 0),
                    modifiedAt: values?.contentModificationDate ?? Date()
                ))
            }
        }
        return files
    }

    private static func sameFile(_ stored: FontFileRecord, _ file: FontFileRecord) -> Bool {
        stored.fileSize == file.fileSize && abs(stored.modifiedAt.timeIntervalSince(file.modifiedAt)) < 2
    }

    private static func folderCovers(_ path: String, folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    private static func scanRoot(_ url: URL, fileManager: FileManager) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        if url.lastPathComponent == "Library" {
            return scanRoot(url.appendingPathComponent("Fonts"), fileManager: fileManager)
        }
        return url
    }

    private static let skippedDirectoryNames: Set<String> = [
        "node_modules", ".build", "DerivedData", "Pods", "Carthage", "Applications",
        "Caches", "Logs", "__pycache__", ".swiftpm", "Fontso.app"
    ]
}

private struct ProbedFace {
    var family: String
    var style: String
    var fullName: String
    var postscriptName: String
    var version: String
    var manufacturer: String
    var designer: String
    var copyright: String
    var glyphCount: Int
    var axes: [VariationAxis]
    var weightTrait: Double
    var traitClass: Int
    var italicTrait: Bool
    var monoTrait: Bool
}

private enum FontProbe {
    static func read(url: URL) -> [ProbedFace] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return []
        }
        return descriptors.map(probe)
    }

    private static func probe(_ descriptor: CTFontDescriptor) -> ProbedFace {
        let font = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
        let traits = CTFontCopyTraits(font) as? [CFString: Any]
        let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        let weightTrait = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        return ProbedFace(
            family: name(font, kCTFontFamilyNameKey),
            style: name(font, kCTFontStyleNameKey),
            fullName: name(font, kCTFontFullNameKey),
            postscriptName: CTFontCopyPostScriptName(font) as String,
            version: name(font, kCTFontVersionNameKey),
            manufacturer: name(font, kCTFontManufacturerNameKey),
            designer: name(font, kCTFontDesignerNameKey),
            copyright: name(font, kCTFontCopyrightNameKey),
            glyphCount: CTFontGetGlyphCount(font),
            axes: variationAxes(font),
            weightTrait: weightTrait,
            traitClass: Int((symbolic & 0xF000_0000) >> 28),
            italicTrait: (symbolic & 1) != 0,
            monoTrait: (symbolic & UInt32(CTFontSymbolicTraits.traitMonoSpace.rawValue)) != 0
        )
    }

    private static func name(_ font: CTFont, _ key: CFString) -> String {
        (CTFontCopyName(font, key) as String?)?.cleanedFontName ?? ""
    }

    private static func variationAxes(_ font: CTFont) -> [VariationAxis] {
        guard let axes = CTFontCopyVariationAxes(font) as? [NSDictionary] else { return [] }
        return axes.compactMap { axis in
            let tag = (axis[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.uint32Value ?? 0
            guard tag != 0 else { return nil }
            return VariationAxis(
                tag: tag,
                name: (axis[kCTFontVariationAxisNameKey] as? String)?.cleanedFontName ?? "Axis",
                min: (axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.doubleValue ?? 0,
                max: (axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.doubleValue ?? 0,
                defaultValue: (axis[kCTFontVariationAxisDefaultValueKey] as? NSNumber)?.doubleValue ?? 0
            )
        }
    }
}
