import CoreText
import Foundation

public enum FontActivationError: LocalizedError {
    case inUse
    case duplicateName
    case systemFont
    case unsupported
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .inUse:
            return "This font is in use by another app."
        case .duplicateName:
            return "A font with this PostScript name is already active. Deactivate the other one first."
        case .systemFont:
            return "System fonts cannot be deactivated."
        case .unsupported:
            return "macOS cannot read this file as a font."
        case .failed(let message):
            return message
        }
    }
}

public enum SystemFontLocations {
    private static let fontFolderRoots: [String] = [
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Fonts",
        "/Library/Fonts",
        "/Network/Library/Fonts"
    ]

    public static func isProtected(_ path: String) -> Bool {
        isProtected(normalized: normalizeFontPath(path))
    }

    public static func isFontFolderInstall(_ path: String) -> Bool {
        isFontFolderInstall(normalized: normalizeFontPath(path))
    }

    static func isProtected(normalized: String) -> Bool {
        normalized == "/System/Library/Fonts" || normalized.hasPrefix("/System/Library/Fonts/")
    }

    static func isFontFolderInstall(normalized: String) -> Bool {
        fontFolderRoots.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
    }
}

public enum FontActivator {
    /// Persistent scope keeps the font available to every app, including InDesign, until it is unregistered.
    public static func activate(filePath: String) throws {
        let path = WebfontUnpacker.readablePath(for: normalizeFontPath(filePath))
        if SystemFontLocations.isProtected(path) {
            return
        }
        if SystemFontLocations.isFontFolderInstall(path) {
            try setEnabled(filePath: path, enabled: true)
            return
        }
        try register(filePath: path)
    }

    public static func deactivate(filePath: String, postScriptNames: [String] = []) throws {
        let path = WebfontUnpacker.readablePath(for: normalizeFontPath(filePath))
        if SystemFontLocations.isProtected(path) {
            throw FontActivationError.systemFont
        }

        var targets: [String] = []
        if isPersistentlyRegistered(path) {
            targets.append(path)
        } else if SystemFontLocations.isFontFolderInstall(path) {
            try setEnabled(filePath: path, enabled: false)
        }

        for name in postScriptNames {
            guard let active = activeFileURL(postScriptName: name) else { continue }
            let activePath = normalizeFontPath(active.path)
            if activePath == path { continue }
            if SystemFontLocations.isProtected(activePath) {
                throw FontActivationError.failed("Apps are using the system font \(active.lastPathComponent), not this file.")
            }
            if !targets.contains(activePath) {
                targets.append(activePath)
            }
        }

        if targets.isEmpty {
            let names = activePostScriptNames()
            if postScriptNames.contains(where: { names.contains($0) }) {
                throw FontActivationError.failed("This style is active in the system, but not from this file. AllFontsO cannot find the loaded file.")
            }
            return
        }

        for target in targets {
            try unregister(filePath: target)
        }
    }

    /// Names currently visible to other apps, including fonts activated by another manager.
    public static func activePostScriptNames() -> Set<String> {
        Set(CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? [])
    }

    public static func activeFileURL(postScriptName: String) -> URL? {
        guard !postScriptName.isEmpty else { return nil }
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        guard (CTFontCopyPostScriptName(font) as String) == postScriptName else { return nil }
        guard let resolved = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL else { return nil }
        return URL(fileURLWithPath: normalizeFontPath(resolved.path))
    }

    public static func availability(
        filePath: String,
        postScriptName: String,
        activeNames: Set<String>? = nil
    ) -> Activation {
        let path = WebfontUnpacker.readablePath(for: normalizeFontPath(filePath))
        if SystemFontLocations.isProtected(path) {
            return .installed
        }
        let registered = isPersistentlyRegistered(path)
        if registered {
            return SystemFontLocations.isFontFolderInstall(path) ? .installed : .activated
        }

        let names = activeNames ?? activePostScriptNames()
        let nameIsActive = !postScriptName.isEmpty && names.contains(postScriptName)
        if SystemFontLocations.isFontFolderInstall(path) {
            if nameIsActive && resolves(filePath: path, postScriptName: postScriptName) {
                return .installed
            }
        }
        if nameIsActive {
            return .available
        }
        return .inactive
    }

    /// Same answer as `availability` for library paths, which are already normalized.
    /// A named style that no app can see is inactive, so Core Text is only asked about the active ones.
    public static func availability(libraryPath: String, postScriptName: String, activeNames: Set<String>) -> Activation {
        availability(libraryPath: libraryPath, postScriptName: postScriptName, activeNames: activeNames, registered: isPersistentlyRegistered)
    }

    /// Checks many library faces at once. Faces that share a file ask the font registry about it only once.
    public static func availability(libraryFaces faces: [(path: String, postScriptName: String)], activeNames: Set<String>) -> [Activation] {
        var known: [String: Bool] = [:]
        func registered(_ path: String) -> Bool {
            if let cached = known[path] { return cached }
            let value = isPersistentlyRegistered(path)
            known[path] = value
            return value
        }
        return faces.map { face in
            availability(libraryPath: face.path, postScriptName: face.postScriptName, activeNames: activeNames, registered: registered)
        }
    }

    private static func availability(
        libraryPath: String,
        postScriptName: String,
        activeNames: Set<String>,
        registered: (String) -> Bool
    ) -> Activation {
        if SystemFontLocations.isProtected(normalized: libraryPath) {
            return .installed
        }
        if !postScriptName.isEmpty && !activeNames.contains(postScriptName) {
            return .inactive
        }
        let path = WebfontUnpacker.readablePath(for: libraryPath)
        if SystemFontLocations.isProtected(normalized: path) {
            return .installed
        }
        let folderInstall = SystemFontLocations.isFontFolderInstall(normalized: path)
        if registered(path) {
            return folderInstall ? .installed : .activated
        }
        let nameIsActive = !postScriptName.isEmpty
        if folderInstall && nameIsActive && resolves(filePath: path, postScriptName: postScriptName) {
            return .installed
        }
        return nameIsActive ? .available : .inactive
    }

    private static func isPersistentlyRegistered(_ path: String) -> Bool {
        let scope = CTFontManagerGetScopeForURL(URL(fileURLWithPath: path) as CFURL)
        return scope.rawValue == CTFontManagerScope.persistent.rawValue
            || scope.rawValue == CTFontManagerScope.session.rawValue
    }

    private static func register(filePath: String) throws {
        var unmanaged: Unmanaged<CFError>?
        let url = URL(fileURLWithPath: filePath) as CFURL
        if CTFontManagerRegisterFontsForURL(url, .persistent, &unmanaged) {
            return
        }
        try throwIfNeeded(unmanaged, ignoring: [.alreadyRegistered])
    }

    private static func unregister(filePath: String) throws {
        let url = URL(fileURLWithPath: filePath) as CFURL
        var persistentError: Unmanaged<CFError>?
        if CTFontManagerUnregisterFontsForURL(url, .persistent, &persistentError) {
            return
        }
        let persistent = capture(persistentError)
        if persistent?.code == .notRegistered {
            var sessionError: Unmanaged<CFError>?
            if CTFontManagerUnregisterFontsForURL(url, .session, &sessionError) {
                return
            }
            let session = capture(sessionError)
            if session == nil || session?.code == .notRegistered {
                return
            }
            try throwCaptured(session)
        }
        try throwCaptured(persistent)
    }

    private static func setEnabled(filePath: String, enabled: Bool) throws {
        let url = URL(fileURLWithPath: filePath) as CFURL
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) else {
            throw FontActivationError.unsupported
        }
        CTFontManagerEnableFontDescriptors(descriptors, enabled)
    }

    private static func resolves(filePath: String, postScriptName: String) -> Bool {
        guard !postScriptName.isEmpty else { return false }
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        let actual = CTFontCopyPostScriptName(font) as String
        guard actual == postScriptName else { return false }
        guard let resolved = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL else { return false }
        return normalizeFontPath(resolved.path) == filePath
    }

    private struct CapturedFontError {
        var code: CTFontManagerError?
        var description: String
    }

    private static func capture(_ unmanaged: Unmanaged<CFError>?) -> CapturedFontError? {
        guard let unmanaged else { return nil }
        let error = unmanaged.takeRetainedValue()
        return CapturedFontError(
            code: CTFontManagerError(rawValue: CFErrorGetCode(error)),
            description: (CFErrorCopyDescription(error) as String?) ?? "Unknown error."
        )
    }

    private static func throwIfNeeded(_ unmanaged: Unmanaged<CFError>?, ignoring: [CTFontManagerError]) throws {
        let captured = capture(unmanaged)
        if let code = captured?.code, ignoring.contains(code) {
            return
        }
        try throwCaptured(captured)
    }

    private static func throwCaptured(_ captured: CapturedFontError?) throws {
        guard let captured else {
            throw FontActivationError.failed("The font could not be changed.")
        }
        switch captured.code {
        case .inUse:
            throw FontActivationError.inUse
        case .duplicatedName:
            throw FontActivationError.duplicateName
        case .systemRequired:
            throw FontActivationError.systemFont
        case .unrecognizedFormat, .invalidFontData:
            throw FontActivationError.unsupported
        case .alreadyRegistered, .notRegistered:
            return
        default:
            throw FontActivationError.failed(captured.description)
        }
    }
}
