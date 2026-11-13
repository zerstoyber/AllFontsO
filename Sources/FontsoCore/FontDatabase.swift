import Foundation
import SQLite3

public final class FontDatabase: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fontso.database")
    private var handle: OpaquePointer?

    public init(fileURL: URL) throws {
        let path = fileURL.path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw FontsoError.message("The library could not be opened.")
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA foreign_keys = ON;")
        try migrate()
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    public static func live() throws -> FontDatabase {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("Fontso", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))
    }

    public func allFolders() throws -> [FontFolder] {
        try queue.sync { try readFolders() }
    }

    public func addFolder(path: String) throws {
        let path = normalizeFontPath(path)
        try queue.sync {
            try run(
                "INSERT OR IGNORE INTO folders (path, added_at) VALUES (?, ?);",
                bindings: { statement in
                    bind(statement, 1, path)
                    sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                }
            )
        }
    }

    public func removeFolder(id: Int64) throws {
        try queue.sync {
            let folders = try readFolders()
            guard let folder = folders.first(where: { $0.id == id }) else { return }
            let remaining = folders.filter { $0.id != id }.map(\.path)
            let fonts = try readFonts()
            try exec("BEGIN IMMEDIATE;")
            do {
                try run("DELETE FROM folders WHERE id = ?;", bindings: { sqlite3_bind_int64($0, 1, id) })
                for font in fonts where !covers(font.filePath, folders: remaining) && covers(font.filePath, folders: [folder.path]) {
                    try run("DELETE FROM fonts WHERE id = ?;", bindings: { sqlite3_bind_int64($0, 1, font.id) })
                }
                try pruneCollections()
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func updateCategories(_ categories: [String: String]) throws {
        guard !categories.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                for (family, category) in categories {
                    try run(
                        "UPDATE fonts SET category = ? WHERE family = ? AND category = 'Unclassified';",
                        bindings: { statement in
                            bind(statement, 1, category)
                            bind(statement, 2, family)
                        }
                    )
                    try run(
                        """
                        INSERT OR IGNORE INTO standard_memberships (file_path, face_index, category)
                        SELECT file_path, face_index, ? FROM fonts WHERE family = ? AND category = ?;
                        """,
                        bindings: { statement in
                            bind(statement, 1, category)
                            bind(statement, 2, family)
                            bind(statement, 3, category)
                        }
                    )
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func applyLibraryChanges(removedPaths: [String], faces: [FontFace]) throws {
        let paths = Array(Set(removedPaths + faces.map(\.filePath)))
        guard !paths.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                for path in paths {
                    try run("DELETE FROM fonts WHERE file_path = ?;", bindings: { bind($0, 1, path) })
                }
                for face in faces {
                    try insert(face)
                }
                try pruneCollections()
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func replaceFonts(_ faces: [FontFace]) throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                try exec("DELETE FROM fonts;")
                for face in faces {
                    try insert(face)
                }
                try pruneCollections()
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func allFonts() throws -> [FontFace] {
        try queue.sync { try readFonts() }
    }

    public func setCategory(_ category: String, ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                for id in ids {
                    try assignPrimaryCategory(category, id: id)
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func standardLists() throws -> [String: Set<FontCategory>] {
        try queue.sync {
            let rows = try query("SELECT file_path, face_index, category FROM standard_memberships;") { statement in
                (
                    FaceKey.make(path: columnText(statement, 0), index: Int(sqlite3_column_int(statement, 1))),
                    FontCategory.fromStored(columnText(statement, 2))
                )
            }
            var lists: [String: Set<FontCategory>] = [:]
            for (key, category) in rows where category != .unclassified {
                lists[key, default: []].insert(category)
            }
            return lists
        }
    }

    public func meta(_ key: String) throws -> String? {
        try queue.sync {
            try query(
                "SELECT value FROM library_meta WHERE key = ?;",
                bindings: { self.bind($0, 1, key) },
                map: { self.columnText($0, 0) }
            ).first
        }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try queue.sync {
            try run(
                "INSERT INTO library_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                bindings: { statement in
                    bind(statement, 1, key)
                    bind(statement, 2, value)
                }
            )
        }
    }

    public func updateProportions(_ rows: [(path: String, index: Int, proportions: FontProportions)]) throws {
        guard !rows.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                for row in rows {
                    try run(
                        """
                        UPDATE fonts
                        SET x_height = ?, cap_height = ?, avg_width = ?, contrast = ?,
                            covers_latin = ?, covers_cyrillic = ?, covers_greek = ?
                        WHERE file_path = ? AND face_index = ?;
                        """,
                        bindings: { statement in
                            sqlite3_bind_int(statement, 1, Int32(row.proportions.xHeight))
                            sqlite3_bind_int(statement, 2, Int32(row.proportions.capHeight))
                            sqlite3_bind_int(statement, 3, Int32(row.proportions.averageWidth))
                            sqlite3_bind_int(statement, 4, Int32(row.proportions.contrast))
                            sqlite3_bind_int(statement, 5, row.proportions.coversLatin ? 1 : 0)
                            sqlite3_bind_int(statement, 6, row.proportions.coversCyrillic ? 1 : 0)
                            sqlite3_bind_int(statement, 7, row.proportions.coversGreek ? 1 : 0)
                            bind(statement, 8, row.path)
                            sqlite3_bind_int(statement, 9, Int32(row.index))
                        }
                    )
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func seedStandardListsIfNeeded() throws {
        try queue.sync {
            let flagged = try query("SELECT value FROM library_meta WHERE key = 'standardListsSeeded';") { statement in
                columnText(statement, 0)
            }
            guard flagged.first != "1" else { return }
            let faces = try readFonts()
            try exec("BEGIN IMMEDIATE;")
            do {
                for face in faces {
                    try insertInitialMemberships(face)
                }
                try run(
                    "INSERT INTO library_meta (key, value) VALUES ('standardListsSeeded', '1') ON CONFLICT(key) DO UPDATE SET value = '1';",
                    bindings: { _ in }
                )
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Adds or removes one standard list. `primary` updates the typographic category column when it is set.
    public func applyStandardLists(
        category: String,
        enabled: Bool,
        faces: [(path: String, index: Int, id: Int64, primary: String?)]
    ) throws {
        guard !faces.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                for face in faces {
                    if category == FontCategory.unclassified.rawValue {
                        try deleteTypographicMemberships(path: face.path, index: face.index)
                        try setPrimaryCategory(FontCategory.unclassified.rawValue, id: face.id)
                    } else if enabled {
                        try insertMembership(path: face.path, index: face.index, category: category)
                        if let primary = face.primary {
                            try setPrimaryCategory(primary, id: face.id)
                        }
                    } else {
                        try deleteMembership(path: face.path, index: face.index, category: category)
                        if let primary = face.primary {
                            try setPrimaryCategory(primary, id: face.id)
                        }
                    }
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func updateActivation(_ faces: [FontFace]) throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                for face in faces {
                    try run(
                        "UPDATE fonts SET activation = ? WHERE id = ?;",
                        bindings: { statement in
                            bind(statement, 1, face.activation.rawValue)
                            sqlite3_bind_int64(statement, 2, face.id)
                        }
                    )
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func allNotes() throws -> [String: String] {
        try queue.sync {
            let rows = try query("SELECT file_path, face_index, body FROM notes;") { statement in
                (FaceKey.make(path: columnText(statement, 0), index: Int(sqlite3_column_int(statement, 1))), columnText(statement, 2))
            }
            return Dictionary(uniqueKeysWithValues: rows)
        }
    }

    public func setNote(filePath: String, faceIndex: Int, body: String) throws {
        try queue.sync {
            if body.isEmpty {
                try run(
                    "DELETE FROM notes WHERE file_path = ? AND face_index = ?;",
                    bindings: { statement in
                        bind(statement, 1, filePath)
                        sqlite3_bind_int(statement, 2, Int32(faceIndex))
                    }
                )
            } else {
                try run(
                    """
                    INSERT INTO notes (file_path, face_index, body, updated_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(file_path, face_index) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at;
                    """,
                    bindings: { statement in
                        bind(statement, 1, filePath)
                        sqlite3_bind_int(statement, 2, Int32(faceIndex))
                        bind(statement, 3, body)
                        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
                    }
                )
            }
        }
    }

    /// The licenses of every cut, keyed by face identity, in the order they were entered. A cut can be licensed
    /// for several projects, each with its own end date.
    public func allLicenseRecords() throws -> [String: [LicenseRecord]] {
        try queue.sync {
            let rows = try query("SELECT file_path, face_index, project, valid_until FROM licenses ORDER BY rowid;") { statement in
                (
                    FaceKey.make(path: columnText(statement, 0), index: Int(sqlite3_column_int(statement, 1))),
                    LicenseRecord(project: columnText(statement, 2), validUntil: sqlite3_column_double(statement, 3))
                )
            }
            var result: [String: [LicenseRecord]] = [:]
            for (key, record) in rows { result[key, default: []].append(record) }
            return result
        }
    }

    /// Records a project a cut is licensed for, beside the ones it already has. A project it has stays as it is.
    public func addLicense(filePath: String, faceIndex: Int, project: String) throws {
        guard !project.isEmpty else { return }
        try queue.sync {
            try run(
                "INSERT OR IGNORE INTO licenses (file_path, face_index, project, updated_at, valid_until) VALUES (?, ?, ?, ?, 0);",
                bindings: { statement in
                    bind(statement, 1, filePath)
                    sqlite3_bind_int(statement, 2, Int32(faceIndex))
                    bind(statement, 3, project)
                    sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
                }
            )
        }
    }

    /// Takes the license for one project away from a cut. Without a project, every license of the cut goes.
    public func removeLicense(filePath: String, faceIndex: Int, project: String? = nil) throws {
        try queue.sync {
            try run(
                project == nil
                    ? "DELETE FROM licenses WHERE file_path = ? AND face_index = ?;"
                    : "DELETE FROM licenses WHERE file_path = ? AND face_index = ? AND project = ?;",
                bindings: { statement in
                    bind(statement, 1, filePath)
                    sqlite3_bind_int(statement, 2, Int32(faceIndex))
                    if let project { bind(statement, 3, project) }
                }
            )
        }
    }

    /// Records until when a cut's license for one project runs. Zero means it has no end date.
    public func setLicenseEnd(filePath: String, faceIndex: Int, project: String, until: Double) throws {
        try queue.sync {
            try run(
                "UPDATE licenses SET valid_until = ?, updated_at = ? WHERE file_path = ? AND face_index = ? AND project = ?;",
                bindings: { statement in
                    sqlite3_bind_double(statement, 1, max(0, until))
                    sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                    bind(statement, 3, filePath)
                    sqlite3_bind_int(statement, 4, Int32(faceIndex))
                    bind(statement, 5, project)
                }
            )
        }
    }

    public func favoriteKeys() throws -> Set<String> {
        try queue.sync {
            let rows = try query("SELECT file_path, face_index FROM favorites;") { statement in
                FaceKey.make(path: columnText(statement, 0), index: Int(sqlite3_column_int(statement, 1)))
            }
            return Set(rows)
        }
    }

    public func setFavorite(filePath: String, faceIndex: Int, isFavorite: Bool) throws {
        try queue.sync {
            if isFavorite {
                try run(
                    "INSERT OR IGNORE INTO favorites (file_path, face_index, created_at) VALUES (?, ?, ?);",
                    bindings: { statement in
                        bind(statement, 1, filePath)
                        sqlite3_bind_int(statement, 2, Int32(faceIndex))
                        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
                    }
                )
            } else {
                try run(
                    "DELETE FROM favorites WHERE file_path = ? AND face_index = ?;",
                    bindings: { statement in
                        bind(statement, 1, filePath)
                        sqlite3_bind_int(statement, 2, Int32(faceIndex))
                    }
                )
            }
        }
    }

    public func allGroups() throws -> [FontGroup] {
        try queue.sync {
            try query("SELECT id, name, parent_id FROM groups ORDER BY name COLLATE NOCASE;") { statement in
                FontGroup(
                    id: sqlite3_column_int64(statement, 0),
                    name: columnText(statement, 1),
                    parentID: sqlite3_column_int64(statement, 2)
                )
            }
        }
    }

    public func createGroup(name: String, parentID: Int64 = 0) throws -> FontGroup {
        let trimmed = name.cleanedFontName
        guard !trimmed.isEmpty else {
            throw FontsoError.message("A list needs a name.")
        }
        return try queue.sync {
            do {
                try run(
                    "INSERT INTO groups (name, created_at, parent_id) VALUES (?, ?, ?);",
                    bindings: { statement in
                        bind(statement, 1, trimmed)
                        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                        sqlite3_bind_int64(statement, 3, parentID)
                    }
                )
            } catch {
                throw FontsoError.message("A list with this name already exists.")
            }
            guard let handle else { throw FontsoError.message("The library is not open.") }
            return FontGroup(id: sqlite3_last_insert_rowid(handle), name: trimmed, parentID: parentID)
        }
    }

    /// Moves a list into another list (or to the top level with 0).
    public func setGroupParent(id: Int64, parentID: Int64) throws {
        try queue.sync {
            try run(
                "UPDATE groups SET parent_id = ? WHERE id = ?;",
                bindings: { statement in
                    sqlite3_bind_int64(statement, 1, parentID)
                    sqlite3_bind_int64(statement, 2, id)
                }
            )
        }
    }

    public func renameGroup(id: Int64, name: String) throws {
        let trimmed = name.cleanedFontName
        guard !trimmed.isEmpty else {
            throw FontsoError.message("A list needs a name.")
        }
        try queue.sync {
            do {
                try run(
                    "UPDATE groups SET name = ? WHERE id = ?;",
                    bindings: { statement in
                        bind(statement, 1, trimmed)
                        sqlite3_bind_int64(statement, 2, id)
                    }
                )
            } catch {
                throw FontsoError.message("A list with this name already exists.")
            }
        }
    }

    public func deleteGroup(id: Int64) throws {
        try queue.sync {
            let parent = try query("SELECT parent_id FROM groups WHERE id = ?;", bindings: { sqlite3_bind_int64($0, 1, id) }) {
                sqlite3_column_int64($0, 0)
            }.first ?? 0
            try run(
                "UPDATE groups SET parent_id = ? WHERE parent_id = ?;",
                bindings: { statement in
                    sqlite3_bind_int64(statement, 1, parent)
                    sqlite3_bind_int64(statement, 2, id)
                }
            )
            try run("DELETE FROM group_links WHERE group_id = ?;", bindings: { sqlite3_bind_int64($0, 1, id) })
            try run("DELETE FROM groups WHERE id = ?;", bindings: { sqlite3_bind_int64($0, 1, id) })
        }
    }

    public func addGroupLink(groupID: Int64, name: String, source: String, url: URL) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        try queue.sync {
            try run(
                "INSERT OR IGNORE INTO group_links (group_id, name, source, url) VALUES (?, ?, ?, ?);",
                bindings: { statement in
                    sqlite3_bind_int64(statement, 1, groupID)
                    bind(statement, 2, trimmed)
                    bind(statement, 3, source)
                    bind(statement, 4, url.absoluteString)
                }
            )
        }
    }

    /// Changes a saved link in place: name, source, or address, in every list that holds it.
    public func updateGroupLinks(name oldName: String, url oldURL: URL, name: String, source: String, url: URL) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        try queue.sync {
            try run(
                "UPDATE OR REPLACE group_links SET name = ?, source = ?, url = ? WHERE name = ? AND url = ?;",
                bindings: { statement in
                    bind(statement, 1, trimmed)
                    bind(statement, 2, source)
                    bind(statement, 3, url.absoluteString)
                    bind(statement, 4, oldName)
                    bind(statement, 5, oldURL.absoluteString)
                }
            )
        }
    }

    public func removeGroupLink(groupID: Int64, name: String, url: URL) throws {
        try queue.sync {
            try run(
                "DELETE FROM group_links WHERE group_id = ? AND name = ? AND url = ?;",
                bindings: { statement in
                    sqlite3_bind_int64(statement, 1, groupID)
                    bind(statement, 2, name)
                    bind(statement, 3, url.absoluteString)
                }
            )
        }
    }

    public func allGroupLinks() throws -> [Int64: [OutsideFont]] {
        try queue.sync {
            let rows = try query(
                "SELECT group_id, name, source, url FROM group_links ORDER BY name;"
            ) { statement in
                (
                    sqlite3_column_int64(statement, 0),
                    columnText(statement, 1),
                    columnText(statement, 2),
                    columnText(statement, 3)
                )
            }
            var grouped: [Int64: [OutsideFont]] = [:]
            for row in rows {
                guard let url = URL(string: row.3) else { continue }
                grouped[row.0, default: []].append(OutsideFont(
                    name: row.1,
                    source: row.2,
                    detail: "Saved in this list. Not in your library.",
                    url: url
                ))
            }
            return grouped
        }
    }

    public func allCompareLists() throws -> [FontGroup] {
        try queue.sync {
            try query("SELECT id, name FROM compare_lists ORDER BY name COLLATE NOCASE;") { statement in
                FontGroup(id: sqlite3_column_int64(statement, 0), name: columnText(statement, 1))
            }
        }
    }

    public func createCompareList(name: String) throws -> FontGroup {
        let trimmed = name.cleanedFontName
        guard !trimmed.isEmpty else {
            throw FontsoError.message("A compare list needs a name.")
        }
        return try queue.sync {
            do {
                try run(
                    "INSERT INTO compare_lists (name, created_at) VALUES (?, ?);",
                    bindings: { statement in
                        bind(statement, 1, trimmed)
                        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                    }
                )
            } catch {
                throw FontsoError.message("A compare list with this name already exists.")
            }
            guard let handle else { throw FontsoError.message("The library is not open.") }
            return FontGroup(id: sqlite3_last_insert_rowid(handle), name: trimmed)
        }
    }

    public func renameCompareList(id: Int64, name: String) throws {
        let trimmed = name.cleanedFontName
        guard !trimmed.isEmpty else {
            throw FontsoError.message("A compare list needs a name.")
        }
        try queue.sync {
            do {
                try run(
                    "UPDATE compare_lists SET name = ? WHERE id = ?;",
                    bindings: { statement in
                        bind(statement, 1, trimmed)
                        sqlite3_bind_int64(statement, 2, id)
                    }
                )
            } catch {
                throw FontsoError.message("A compare list with this name already exists.")
            }
        }
    }

    public func deleteCompareList(id: Int64) throws {
        try queue.sync {
            try run("DELETE FROM compare_lists WHERE id = ?;", bindings: { sqlite3_bind_int64($0, 1, id) })
        }
    }

    public func compareMembership() throws -> [Int64: [String]] {
        try queue.sync {
            var result: [Int64: [String]] = [:]
            let rows = try query(
                """
                SELECT list_id, file_path, face_index
                FROM compare_members
                ORDER BY position, rowid;
                """
            ) { statement -> (Int64, String) in
                let key = FaceKey.make(path: columnText(statement, 1), index: Int(sqlite3_column_int(statement, 2)))
                return (sqlite3_column_int64(statement, 0), key)
            }
            for (listID, key) in rows {
                result[listID, default: []].append(key)
            }
            return result
        }
    }

    public func addCompareMembers(listID: Int64, keys: [String]) throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                let existing = try query(
                    "SELECT COALESCE(MAX(position), 0) FROM compare_members WHERE list_id = ?;",
                    bindings: { sqlite3_bind_int64($0, 1, listID) }
                ) { statement -> Int in
                    Int(sqlite3_column_int(statement, 0))
                }
                var position = existing.first ?? 0
                for key in keys {
                    guard let parsed = FaceKey.parse(key) else { continue }
                    position += 1
                    try run(
                        """
                        INSERT OR IGNORE INTO compare_members (list_id, file_path, face_index, position)
                        VALUES (?, ?, ?, ?);
                        """,
                        bindings: { statement in
                            sqlite3_bind_int64(statement, 1, listID)
                            bind(statement, 2, parsed.path)
                            sqlite3_bind_int(statement, 3, Int32(parsed.index))
                            sqlite3_bind_int(statement, 4, Int32(position))
                        }
                    )
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func removeCompareMembers(listID: Int64, keys: [String]) throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                for key in keys {
                    guard let parsed = FaceKey.parse(key) else { continue }
                    try run(
                        "DELETE FROM compare_members WHERE list_id = ? AND file_path = ? AND face_index = ?;",
                        bindings: { statement in
                            sqlite3_bind_int64(statement, 1, listID)
                            bind(statement, 2, parsed.path)
                            sqlite3_bind_int(statement, 3, Int32(parsed.index))
                        }
                    )
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func clearCompareList(id: Int64) throws {
        try queue.sync {
            try run("DELETE FROM compare_members WHERE list_id = ?;", bindings: { sqlite3_bind_int64($0, 1, id) })
        }
    }

    public func membership() throws -> [Int64: Set<String>] {
        try queue.sync {
            var result: [Int64: Set<String>] = [:]
            let rows = try query("SELECT group_id, file_path, face_index FROM group_members;") { statement -> (Int64, String) in
                let key = FaceKey.make(path: columnText(statement, 1), index: Int(sqlite3_column_int(statement, 2)))
                return (sqlite3_column_int64(statement, 0), key)
            }
            for (groupID, key) in rows {
                result[groupID, default: []].insert(key)
            }
            return result
        }
    }

    public func memberOrder() throws -> [Int64: [String]] {
        try queue.sync {
            var result: [Int64: [String]] = [:]
            let rows = try query(
                """
                SELECT group_id, file_path, face_index
                FROM group_members
                ORDER BY position, rowid;
                """
            ) { statement -> (Int64, String) in
                let key = FaceKey.make(path: columnText(statement, 1), index: Int(sqlite3_column_int(statement, 2)))
                return (sqlite3_column_int64(statement, 0), key)
            }
            for (groupID, key) in rows {
                result[groupID, default: []].append(key)
            }
            return result
        }
    }

    public func addMembers(groupID: Int64, keys: [String]) throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                let existing = try query(
                    "SELECT COALESCE(MAX(position), 0) FROM group_members WHERE group_id = ?;",
                    bindings: { sqlite3_bind_int64($0, 1, groupID) }
                ) { statement -> Int in
                    Int(sqlite3_column_int(statement, 0))
                }
                var position = existing.first ?? 0
                for key in keys {
                    guard let parsed = FaceKey.parse(key) else { continue }
                    position += 1
                    try run(
                        """
                        INSERT OR IGNORE INTO group_members (group_id, file_path, face_index, position)
                        VALUES (?, ?, ?, ?);
                        """,
                        bindings: { statement in
                            sqlite3_bind_int64(statement, 1, groupID)
                            bind(statement, 2, parsed.path)
                            sqlite3_bind_int(statement, 3, Int32(parsed.index))
                            sqlite3_bind_int(statement, 4, Int32(position))
                        }
                    )
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func setMemberOrder(groupID: Int64, keys: [String]) throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                for (offset, key) in keys.enumerated() {
                    guard let parsed = FaceKey.parse(key) else { continue }
                    try run(
                        """
                        UPDATE group_members
                        SET position = ?
                        WHERE group_id = ? AND file_path = ? AND face_index = ?;
                        """,
                        bindings: { statement in
                            sqlite3_bind_int(statement, 1, Int32(offset + 1))
                            sqlite3_bind_int64(statement, 2, groupID)
                            bind(statement, 3, parsed.path)
                            sqlite3_bind_int(statement, 4, Int32(parsed.index))
                        }
                    )
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func removeMembers(groupID: Int64, keys: [String]) throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                for key in keys {
                    guard let parsed = FaceKey.parse(key) else { continue }
                    try run(
                        "DELETE FROM group_members WHERE group_id = ? AND file_path = ? AND face_index = ?;",
                        bindings: { statement in
                            sqlite3_bind_int64(statement, 1, groupID)
                            bind(statement, 2, parsed.path)
                            sqlite3_bind_int(statement, 3, Int32(parsed.index))
                        }
                    )
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func allResearchChats() throws -> [ResearchChat] {
        try queue.sync {
            try query(
                "SELECT id, title, updated_at FROM research_chats ORDER BY updated_at DESC;"
            ) { statement in
                ResearchChat(
                    id: sqlite3_column_int64(statement, 0),
                    title: columnText(statement, 1),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                )
            }
        }
    }

    public func createResearchChat(title: String) throws -> ResearchChat {
        let now = Date()
        return try queue.sync {
            try run(
                "INSERT INTO research_chats (title, created_at, updated_at) VALUES (?, ?, ?);",
                bindings: { statement in
                    bind(statement, 1, title)
                    sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
                }
            )
            guard let handle else { throw FontsoError.message("The library is not open.") }
            return ResearchChat(id: sqlite3_last_insert_rowid(handle), title: title, updatedAt: now)
        }
    }

    public func renameResearchChat(id: Int64, title: String) throws {
        let trimmed = title.cleanedFontName
        guard !trimmed.isEmpty else { return }
        try queue.sync {
            try run(
                "UPDATE research_chats SET title = ?, updated_at = ? WHERE id = ?;",
                bindings: { statement in
                    bind(statement, 1, trimmed)
                    sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                    sqlite3_bind_int64(statement, 3, id)
                }
            )
        }
    }

    public func deleteResearchChat(id: Int64) throws {
        try queue.sync {
            try run("DELETE FROM research_chats WHERE id = ?;", bindings: { sqlite3_bind_int64($0, 1, id) })
        }
    }

    public func allShapeSearches() throws -> [ShapeSearch] {
        try queue.sync {
            try query(
                "SELECT id, title, reference_identity, query, updated_at, tuning FROM shape_searches ORDER BY updated_at DESC;"
            ) { statement in
                ShapeSearch(
                    id: sqlite3_column_int64(statement, 0),
                    title: columnText(statement, 1),
                    referenceIdentity: columnText(statement, 2),
                    query: columnText(statement, 3),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    tuning: MatchTuning.decode(columnText(statement, 5))
                )
            }
        }
    }

    public func createShapeSearch(title: String, referenceIdentity: String, query: String) throws -> ShapeSearch {
        let now = Date()
        let trimmed = title.cleanedFontName.isEmpty ? "New shape" : title.cleanedFontName
        return try queue.sync {
            try run(
                """
                INSERT INTO shape_searches (title, reference_identity, query, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?);
                """,
                bindings: { statement in
                    bind(statement, 1, trimmed)
                    bind(statement, 2, referenceIdentity)
                    bind(statement, 3, query)
                    sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 5, now.timeIntervalSince1970)
                }
            )
            guard let handle else { throw FontsoError.message("The library is not open.") }
            return ShapeSearch(
                id: sqlite3_last_insert_rowid(handle),
                title: trimmed,
                referenceIdentity: referenceIdentity,
                query: query,
                updatedAt: now
            )
        }
    }

    public func renameShapeSearch(id: Int64, title: String) throws {
        let trimmed = title.cleanedFontName
        guard !trimmed.isEmpty else { return }
        try queue.sync {
            try run(
                "UPDATE shape_searches SET title = ? WHERE id = ?;",
                bindings: { statement in
                    bind(statement, 1, trimmed)
                    sqlite3_bind_int64(statement, 2, id)
                }
            )
        }
    }

    public func updateShapeSearch(id: Int64, referenceIdentity: String, query: String) throws {
        try queue.sync {
            try run(
                "UPDATE shape_searches SET reference_identity = ?, query = ?, updated_at = ? WHERE id = ?;",
                bindings: { statement in
                    bind(statement, 1, referenceIdentity)
                    bind(statement, 2, query)
                    sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
                    sqlite3_bind_int64(statement, 4, id)
                }
            )
        }
    }

    public func updateShapeTuning(id: Int64, tuning: MatchTuning) throws {
        try queue.sync {
            try run(
                "UPDATE shape_searches SET tuning = ? WHERE id = ?;",
                bindings: { statement in
                    bind(statement, 1, tuning.isStandard ? "" : tuning.json)
                    sqlite3_bind_int64(statement, 2, id)
                }
            )
        }
    }

    public func deleteShapeSearch(id: Int64) throws {
        try queue.sync {
            try run("DELETE FROM shape_searches WHERE id = ?;", bindings: { sqlite3_bind_int64($0, 1, id) })
        }
    }

    public func allFoundries() throws -> [FoundryEntry] {
        try queue.sync {
            try query(
                "SELECT id, name, host, url, sources, watched FROM foundries;"
            ) { statement in
                FoundryEntry(
                    id: sqlite3_column_int64(statement, 0),
                    name: columnText(statement, 1),
                    host: columnText(statement, 2),
                    url: URL(string: columnText(statement, 3)) ?? URL(string: "https://\(columnText(statement, 2))")!,
                    sources: columnText(statement, 4),
                    watched: sqlite3_column_int(statement, 5) != 0
                )
            }
        }
    }

    public func watchedTypefaces() throws -> [Int64: [String]] {
        try queue.sync {
            let rows = try query(
                """
                SELECT foundry_faces.foundry_id, foundry_faces.name
                FROM foundry_faces
                JOIN foundries ON foundries.id = foundry_faces.foundry_id
                WHERE foundries.watched = 1
                ORDER BY foundry_faces.name;
                """
            ) { statement in
                (sqlite3_column_int64(statement, 0), columnText(statement, 1))
            }
            var grouped: [Int64: [String]] = [:]
            for row in rows {
                grouped[row.0, default: []].append(row.1)
            }
            return grouped
        }
    }

    public func replaceFoundryCatalog(_ drafts: [FoundryDraft]) throws {
        try queue.sync {
            let previous = try query("SELECT id, name, host, url, sources, watched FROM foundries;") { statement in
                (
                    sqlite3_column_int64(statement, 0),
                    columnText(statement, 1),
                    columnText(statement, 2),
                    columnText(statement, 3),
                    columnText(statement, 4),
                    sqlite3_column_int(statement, 5) != 0
                )
            }
            var facesByHost: [String: [String]] = [:]
            var watchedHosts = Set<String>()
            var custom: [(name: String, host: String, url: String, sources: String, watched: Bool)] = []
            for row in previous {
                if row.5 { watchedHosts.insert(row.2) }
                let keepFaces = row.5 || row.4.contains("Added")
                if keepFaces {
                    let names = try query(
                        "SELECT name FROM foundry_faces WHERE foundry_id = ?;",
                        bindings: { sqlite3_bind_int64($0, 1, row.0) }
                    ) { columnText($0, 0) }
                    facesByHost[row.2] = names
                }
                if row.4.contains("Added") {
                    custom.append((row.1, row.2, row.3, row.4, row.5))
                }
            }
            let draftHosts = Set(drafts.map(\.host))
            try exec("BEGIN;")
            do {
                try exec("DELETE FROM foundries;")
                for draft in drafts {
                    let sources = draft.sources.joined(separator: ", ")
                    try run(
                        "INSERT INTO foundries (name, host, url, sources, watched) VALUES (?, ?, ?, ?, ?);",
                        bindings: { statement in
                            bind(statement, 1, draft.name)
                            bind(statement, 2, draft.host)
                            bind(statement, 3, draft.url.absoluteString)
                            bind(statement, 4, sources)
                            sqlite3_bind_int(statement, 5, watchedHosts.contains(draft.host) ? 1 : 0)
                        }
                    )
                    guard let handle else { throw FontsoError.message("The library is not open.") }
                    let id = sqlite3_last_insert_rowid(handle)
                    for name in facesByHost[draft.host] ?? [] {
                        try run(
                            "INSERT OR IGNORE INTO foundry_faces (foundry_id, name) VALUES (?, ?);",
                            bindings: { statement in
                                sqlite3_bind_int64(statement, 1, id)
                                bind(statement, 2, name)
                            }
                        )
                    }
                }
                for item in custom where !draftHosts.contains(item.host) {
                    try run(
                        "INSERT INTO foundries (name, host, url, sources, watched) VALUES (?, ?, ?, ?, ?);",
                        bindings: { statement in
                            bind(statement, 1, item.name)
                            bind(statement, 2, item.host)
                            bind(statement, 3, item.url)
                            bind(statement, 4, item.sources)
                            sqlite3_bind_int(statement, 5, item.watched ? 1 : 0)
                        }
                    )
                    guard let handle else { throw FontsoError.message("The library is not open.") }
                    let id = sqlite3_last_insert_rowid(handle)
                    for name in facesByHost[item.host] ?? [] {
                        try run(
                            "INSERT OR IGNORE INTO foundry_faces (foundry_id, name) VALUES (?, ?);",
                            bindings: { statement in
                                sqlite3_bind_int64(statement, 1, id)
                                bind(statement, 2, name)
                            }
                        )
                    }
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func setFoundryWatched(id: Int64, watched: Bool) throws {
        try queue.sync {
            try run(
                "UPDATE foundries SET watched = ? WHERE id = ?;",
                bindings: { statement in
                    sqlite3_bind_int(statement, 1, watched ? 1 : 0)
                    sqlite3_bind_int64(statement, 2, id)
                }
            )
        }
    }

    public func replaceFoundryTypefaces(foundryID: Int64, names: [String]) throws {
        try queue.sync {
            try exec("BEGIN;")
            do {
                try run(
                    "DELETE FROM foundry_faces WHERE foundry_id = ?;",
                    bindings: { sqlite3_bind_int64($0, 1, foundryID) }
                )
                for name in names {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.count >= 2 else { continue }
                    try run(
                        "INSERT OR IGNORE INTO foundry_faces (foundry_id, name) VALUES (?, ?);",
                        bindings: { statement in
                            sqlite3_bind_int64(statement, 1, foundryID)
                            bind(statement, 2, trimmed)
                        }
                    )
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func addFoundry(name: String, url: URL) throws -> FoundryEntry {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { throw FontsoError.message("The foundry needs a name.") }
        guard let host = FoundryLookup.siteHost(url) else {
            throw FontsoError.message("That website is not a foundry address.")
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.path = "/"
        parts?.query = nil
        parts?.fragment = nil
        let root = parts?.url ?? url
        return try queue.sync {
            let existing = try query(
                "SELECT id FROM foundries WHERE host = ?;",
                bindings: { self.bind($0, 1, host) }
            ) { sqlite3_column_int64($0, 0) }
            if let id = existing.first {
                try run(
                    """
                    UPDATE foundries
                    SET name = ?, url = ?, watched = 1,
                        sources = CASE WHEN instr(sources, 'Added') > 0 THEN sources ELSE sources || ', Added' END
                    WHERE id = ?;
                    """,
                    bindings: { statement in
                        bind(statement, 1, trimmed)
                        bind(statement, 2, root.absoluteString)
                        sqlite3_bind_int64(statement, 3, id)
                    }
                )
            } else {
                try run(
                    "INSERT INTO foundries (name, host, url, sources, watched) VALUES (?, ?, ?, 'Added', 1);",
                    bindings: { statement in
                        bind(statement, 1, trimmed)
                        bind(statement, 2, host)
                        bind(statement, 3, root.absoluteString)
                    }
                )
            }
            return try foundry(host: host)
        }
    }

    public func addFoundryTypeface(foundryID: Int64, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        try queue.sync {
            try run(
                "INSERT OR IGNORE INTO foundry_faces (foundry_id, name) VALUES (?, ?);",
                bindings: { statement in
                    sqlite3_bind_int64(statement, 1, foundryID)
                    bind(statement, 2, trimmed)
                }
            )
        }
    }

    public func foundryNotices() throws -> [FoundryNotice] {
        try queue.sync {
            try query(
                """
                SELECT foundry_notices.id, foundry_notices.foundry_host, foundries.name,
                       foundry_notices.name, foundry_notices.url, foundry_notices.published_at,
                       foundry_notices.seen, foundry_notices.discovered_at
                FROM foundry_notices
                JOIN foundries ON foundries.host = foundry_notices.foundry_host
                WHERE foundries.watched = 1 AND foundry_notices.dismissed = 0
                ORDER BY foundry_notices.discovered_at DESC, foundry_notices.name;
                """
            ) { statement in
                let published = sqlite3_column_double(statement, 5)
                let address = columnText(statement, 4)
                return FoundryNotice(
                    id: sqlite3_column_int64(statement, 0),
                    foundryHost: columnText(statement, 1),
                    foundryName: columnText(statement, 2),
                    name: columnText(statement, 3),
                    url: URL(string: address) ?? URL(string: "https://\(columnText(statement, 1))")!,
                    publishedAt: published > 0 ? Date(timeIntervalSince1970: published) : nil,
                    seen: sqlite3_column_int(statement, 6) != 0,
                    discoveredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
                )
            }
        }
    }

    public func upsertFoundryNotices(host: String, url: URL, names: [String], notes: [FoundryReleaseNote]) throws {
        let now = Date().timeIntervalSince1970
        let foldedNotes = notes.map { note in
            (date: note.date, text: noticeFold(note.text))
        }
        try queue.sync {
            for name in names {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2 else { continue }
                let folded = noticeFold(trimmed)
                let published = foldedNotes.first { $0.text.contains(folded) }?.date.timeIntervalSince1970 ?? 0
                try run(
                    """
                    INSERT INTO foundry_notices (foundry_host, name, url, published_at, seen, dismissed, discovered_at)
                    VALUES (?, ?, ?, ?, 0, 0, ?)
                    ON CONFLICT(foundry_host, name) DO UPDATE SET
                        url = excluded.url,
                        published_at = CASE
                            WHEN excluded.published_at > 0 THEN excluded.published_at
                            ELSE foundry_notices.published_at
                        END;
                    """,
                    bindings: { statement in
                        bind(statement, 1, host)
                        bind(statement, 2, trimmed)
                        bind(statement, 3, url.absoluteString)
                        sqlite3_bind_double(statement, 4, published)
                        sqlite3_bind_double(statement, 5, now)
                    }
                )
            }
        }
    }

    /// Brings the notices of one foundry in line with what its site shows now. A name that is still there keeps
    /// the day it was first found, so only what is really new counts as new; a name the site dropped goes, unless
    /// it was marked, removed, or corrected by hand.
    /// With `known`, names this read finds for the first time go in as seen: they are the foundry's catalogue, read
    /// more closely than before, and no news.
    public func syncFoundryNotices(host: String, drafts: [FoundryNoticeDraft], known catalogue: Bool = false) throws {
        let now = Date().timeIntervalSince1970
        func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        // Lines about fonts are no typefaces: they are not taken in, and the ones stored by earlier reads go.
        let drafts = drafts.filter { FoundryLookup.isTypefaceName($0.name) }
        let current = Set(drafts.map { key($0.name) })
        try queue.sync {
            try exec("BEGIN;")
            do {
                struct Row {
                    var id: Int64
                    var name: String
                    var url: String
                    var kept: Bool
                    var edited: Bool
                }
                let rows = try query(
                    "SELECT id, name, url, seen, dismissed, edited FROM foundry_notices WHERE foundry_host = ?;",
                    bindings: { self.bind($0, 1, host) },
                    map: { statement in
                        Row(
                            id: sqlite3_column_int64(statement, 0),
                            name: self.columnText(statement, 1),
                            url: self.columnText(statement, 2),
                            kept: sqlite3_column_int(statement, 3) != 0 || sqlite3_column_int(statement, 4) != 0,
                            edited: sqlite3_column_int(statement, 5) != 0
                        )
                    }
                )
                var known: [String: Row] = [:]
                for row in rows {
                    let gone = !current.contains(key(row.name))
                    if !row.edited, gone, !row.kept || !FoundryLookup.isTypefaceName(row.name) {
                        try run(
                            "DELETE FROM foundry_notices WHERE id = ?;",
                            bindings: { sqlite3_bind_int64($0, 1, row.id) }
                        )
                    } else if known[key(row.name)] == nil {
                        known[key(row.name)] = row
                    }
                }
                for draft in drafts {
                    let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.count >= 2 else { continue }
                    let published = draft.publishedAt?.timeIntervalSince1970 ?? 0
                    if let row = known[key(trimmed)] {
                        // A link corrected by hand stays, and so does the page of a font once it is known: the
                        // foundry's front page does not take its place.
                        let old = URL(string: row.url)
                        let keepsPage = draft.url.path.count <= 1 && (old?.path.count ?? 0) > 1
                        let address = row.edited || keepsPage ? row.url : draft.url.absoluteString
                        try run(
                            """
                            UPDATE foundry_notices SET url = ?,
                                published_at = CASE WHEN ? > 0 THEN ? ELSE published_at END
                            WHERE id = ?;
                            """,
                            bindings: { statement in
                                bind(statement, 1, address)
                                sqlite3_bind_double(statement, 2, published)
                                sqlite3_bind_double(statement, 3, published)
                                sqlite3_bind_int64(statement, 4, row.id)
                            }
                        )
                        continue
                    }
                    try run(
                        """
                        INSERT OR IGNORE INTO foundry_notices (foundry_host, name, url, published_at, seen, dismissed, discovered_at)
                        VALUES (?, ?, ?, ?, ?, 0, ?);
                        """,
                        bindings: { statement in
                            bind(statement, 1, host)
                            bind(statement, 2, trimmed)
                            bind(statement, 3, draft.url.absoluteString)
                            sqlite3_bind_double(statement, 4, published)
                            sqlite3_bind_int(statement, 5, catalogue ? 1 : 0)
                            sqlite3_bind_double(statement, 6, now)
                        }
                    )
                    known[key(trimmed)] = Row(id: 0, name: trimmed, url: draft.url.absoluteString, kept: false, edited: true)
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// The page found for a notice that only had the foundry's front page. It is no correction by hand, so the
    /// foundry's own link may still replace it.
    public func setNoticePage(id: Int64, url: URL) throws {
        try queue.sync {
            try run(
                "UPDATE foundry_notices SET url = ? WHERE id = ? AND edited = 0;",
                bindings: { statement in
                    bind(statement, 1, url.absoluteString)
                    sqlite3_bind_int64(statement, 2, id)
                }
            )
        }
    }

    public func setNoticeSeen(id: Int64, seen: Bool) throws {
        try queue.sync {
            try run(
                "UPDATE foundry_notices SET seen = ? WHERE id = ?;",
                bindings: { statement in
                    sqlite3_bind_int(statement, 1, seen ? 1 : 0)
                    sqlite3_bind_int64(statement, 2, id)
                }
            )
        }
    }

    /// Corrects a news item's name or link by hand. The row is marked so a refresh keeps the correction.
    public func updateNotice(id: Int64, name: String, url: URL) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        try queue.sync {
            try run(
                "UPDATE foundry_notices SET name = ?, url = ?, edited = 1 WHERE id = ?;",
                bindings: { statement in
                    bind(statement, 1, trimmed)
                    bind(statement, 2, url.absoluteString)
                    sqlite3_bind_int64(statement, 3, id)
                }
            )
        }
    }

    public func dismissNotice(id: Int64) throws {
        try queue.sync {
            try run(
                "UPDATE foundry_notices SET dismissed = 1 WHERE id = ?;",
                bindings: { sqlite3_bind_int64($0, 1, id) }
            )
        }
    }

    private func foundry(host: String) throws -> FoundryEntry {
        let rows = try query(
            "SELECT id, name, host, url, sources, watched FROM foundries WHERE host = ?;",
            bindings: { self.bind($0, 1, host) }
        ) { statement in
            FoundryEntry(
                id: sqlite3_column_int64(statement, 0),
                name: columnText(statement, 1),
                host: columnText(statement, 2),
                url: URL(string: columnText(statement, 3)) ?? URL(string: "https://\(host)")!,
                sources: columnText(statement, 4),
                watched: sqlite3_column_int(statement, 5) != 0
            )
        }
        guard let entry = rows.first else { throw FontsoError.message("The foundry could not be saved.") }
        return entry
    }

    private func noticeFold(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    public func researchMessages(chatID: Int64) throws -> [ResearchMessage] {
        try queue.sync {
            try query(
                """
                SELECT id, chat_id, role, body, suggestions_json, created_at, image_path
                FROM research_messages
                WHERE chat_id = ?
                ORDER BY id;
                """,
                bindings: { sqlite3_bind_int64($0, 1, chatID) }
            ) { statement in
                let data = Data(columnText(statement, 4).utf8)
                let suggestions = (try? JSONDecoder().decode([ResearchSuggestion].self, from: data)) ?? []
                return ResearchMessage(
                    id: sqlite3_column_int64(statement, 0),
                    chatID: sqlite3_column_int64(statement, 1),
                    role: columnText(statement, 2),
                    text: columnText(statement, 3),
                    suggestions: suggestions,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    imagePath: columnText(statement, 6)
                )
            }
        }
    }

    public func addResearchMessage(
        chatID: Int64,
        role: String,
        text: String,
        suggestions: [ResearchSuggestion],
        imagePath: String = ""
    ) throws -> ResearchMessage {
        let now = Date()
        let payload = (try? JSONEncoder().encode(suggestions)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return try queue.sync {
            try run(
                """
                INSERT INTO research_messages (chat_id, role, body, suggestions_json, created_at, image_path)
                VALUES (?, ?, ?, ?, ?, ?);
                """,
                bindings: { statement in
                    sqlite3_bind_int64(statement, 1, chatID)
                    bind(statement, 2, role)
                    bind(statement, 3, text)
                    bind(statement, 4, payload)
                    sqlite3_bind_double(statement, 5, now.timeIntervalSince1970)
                    bind(statement, 6, imagePath)
                }
            )
            try run(
                "UPDATE research_chats SET updated_at = ? WHERE id = ?;",
                bindings: { statement in
                    sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                    sqlite3_bind_int64(statement, 2, chatID)
                }
            )
            guard let handle else { throw FontsoError.message("The library is not open.") }
            return ResearchMessage(
                id: sqlite3_last_insert_rowid(handle),
                chatID: chatID,
                role: role,
                text: text,
                suggestions: suggestions,
                createdAt: now,
                imagePath: imagePath
            )
        }
    }

    private func migrate() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS folders (
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                added_at REAL NOT NULL
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS fonts (
                id INTEGER PRIMARY KEY,
                file_path TEXT NOT NULL,
                face_index INTEGER NOT NULL,
                family TEXT NOT NULL,
                style TEXT NOT NULL,
                full_name TEXT NOT NULL,
                postscript_name TEXT NOT NULL,
                version TEXT NOT NULL,
                manufacturer TEXT NOT NULL,
                designer TEXT NOT NULL,
                copyright TEXT NOT NULL,
                format TEXT NOT NULL,
                is_variable INTEGER NOT NULL,
                weight_class INTEGER NOT NULL,
                width_class INTEGER NOT NULL,
                category TEXT NOT NULL,
                is_italic INTEGER NOT NULL,
                glyph_count INTEGER NOT NULL,
                axes_json TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                modified_at REAL NOT NULL,
                activation TEXT NOT NULL,
                UNIQUE(file_path, face_index)
            );
            """
        )
        try exec("CREATE INDEX IF NOT EXISTS fonts_family ON fonts(family);")
        try exec("CREATE INDEX IF NOT EXISTS fonts_category ON fonts(category);")
        try exec(
            """
            CREATE TABLE IF NOT EXISTS favorites (
                file_path TEXT NOT NULL,
                face_index INTEGER NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY (file_path, face_index)
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS notes (
                file_path TEXT NOT NULL,
                face_index INTEGER NOT NULL,
                body TEXT NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (file_path, face_index)
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS licenses (
                file_path TEXT NOT NULL,
                face_index INTEGER NOT NULL,
                project TEXT NOT NULL,
                updated_at REAL NOT NULL,
                valid_until REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (file_path, face_index, project)
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS standard_memberships (
                file_path TEXT NOT NULL,
                face_index INTEGER NOT NULL,
                category TEXT NOT NULL,
                PRIMARY KEY (file_path, face_index, category)
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS library_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS groups (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS group_links (
                group_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                source TEXT NOT NULL,
                url TEXT NOT NULL,
                PRIMARY KEY (group_id, name, url)
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS group_members (
                group_id INTEGER NOT NULL,
                file_path TEXT NOT NULL,
                face_index INTEGER NOT NULL,
                position INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (group_id, file_path, face_index),
                FOREIGN KEY (group_id) REFERENCES groups(id) ON DELETE CASCADE
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS compare_lists (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS compare_members (
                list_id INTEGER NOT NULL,
                file_path TEXT NOT NULL,
                face_index INTEGER NOT NULL,
                position INTEGER NOT NULL,
                PRIMARY KEY (list_id, file_path, face_index),
                FOREIGN KEY (list_id) REFERENCES compare_lists(id) ON DELETE CASCADE
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS research_chats (
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS research_messages (
                id INTEGER PRIMARY KEY,
                chat_id INTEGER NOT NULL,
                role TEXT NOT NULL,
                body TEXT NOT NULL,
                suggestions_json TEXT NOT NULL,
                created_at REAL NOT NULL,
                FOREIGN KEY (chat_id) REFERENCES research_chats(id) ON DELETE CASCADE
            );
            """
        )
        let licenseColumns = try query("PRAGMA table_info(licenses);") { statement in
            columnText(statement, 1)
        }
        if !licenseColumns.contains("valid_until") {
            try exec("ALTER TABLE licenses ADD COLUMN valid_until REAL NOT NULL DEFAULT 0;")
        }
        // A cut used to carry one license. The table is rebuilt once, so it can carry one for each project.
        let licenseKey = try query("PRAGMA table_info(licenses);") { statement in
            (columnText(statement, 1), Int(sqlite3_column_int(statement, 5)))
        }
        if licenseKey.contains(where: { $0.0 == "project" && $0.1 == 0 }) {
            try exec("BEGIN IMMEDIATE;")
            do {
                try exec(
                    """
                    CREATE TABLE licenses_by_project (
                        file_path TEXT NOT NULL,
                        face_index INTEGER NOT NULL,
                        project TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        valid_until REAL NOT NULL DEFAULT 0,
                        PRIMARY KEY (file_path, face_index, project)
                    );
                    """
                )
                try exec(
                    """
                    INSERT INTO licenses_by_project (file_path, face_index, project, updated_at, valid_until)
                    SELECT file_path, face_index, project, updated_at, valid_until FROM licenses ORDER BY rowid;
                    """
                )
                try exec("DROP TABLE licenses;")
                try exec("ALTER TABLE licenses_by_project RENAME TO licenses;")
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
        let messageColumns = try query("PRAGMA table_info(research_messages);") { statement in
            columnText(statement, 1)
        }
        if !messageColumns.contains("image_path") {
            try exec("ALTER TABLE research_messages ADD COLUMN image_path TEXT NOT NULL DEFAULT '';")
        }
        let memberColumns = try query("PRAGMA table_info(group_members);") { statement in
            columnText(statement, 1)
        }
        if !memberColumns.contains("position") {
            try exec("ALTER TABLE group_members ADD COLUMN position INTEGER NOT NULL DEFAULT 0;")
        }
        let groupColumns = try query("PRAGMA table_info(groups);") { statement in
            columnText(statement, 1)
        }
        if !groupColumns.contains("parent_id") {
            try exec("ALTER TABLE groups ADD COLUMN parent_id INTEGER NOT NULL DEFAULT 0;")
        }
        let noticeColumns = try query("PRAGMA table_info(foundry_notices);") { statement in
            columnText(statement, 1)
        }
        if !noticeColumns.isEmpty, !noticeColumns.contains("edited") {
            try exec("ALTER TABLE foundry_notices ADD COLUMN edited INTEGER NOT NULL DEFAULT 0;")
        }
        let fontColumns = try query("PRAGMA table_info(fonts);") { statement in
            columnText(statement, 1)
        }
        if !fontColumns.contains("unpacked_path") {
            try exec("ALTER TABLE fonts ADD COLUMN unpacked_path TEXT NOT NULL DEFAULT '';")
        }
        if !fontColumns.contains("category_source") {
            try exec("ALTER TABLE fonts ADD COLUMN category_source TEXT NOT NULL DEFAULT '';")
        }
        try exec(
            """
            CREATE TABLE IF NOT EXISTS review_marks (
                file_path TEXT NOT NULL,
                face_index INTEGER NOT NULL,
                reviewed_at REAL NOT NULL,
                PRIMARY KEY (file_path, face_index)
            );
            """
        )
        if !fontColumns.contains("x_height") {
            try exec("ALTER TABLE fonts ADD COLUMN x_height INTEGER NOT NULL DEFAULT 0;")
            try exec("ALTER TABLE fonts ADD COLUMN cap_height INTEGER NOT NULL DEFAULT 0;")
            try exec("ALTER TABLE fonts ADD COLUMN avg_width INTEGER NOT NULL DEFAULT 0;")
            try exec("ALTER TABLE fonts ADD COLUMN contrast INTEGER NOT NULL DEFAULT 0;")
            try exec("ALTER TABLE fonts ADD COLUMN covers_latin INTEGER NOT NULL DEFAULT 0;")
            try exec("ALTER TABLE fonts ADD COLUMN covers_cyrillic INTEGER NOT NULL DEFAULT 0;")
            try exec("ALTER TABLE fonts ADD COLUMN covers_greek INTEGER NOT NULL DEFAULT 0;")
        }
        try exec(
            """
            CREATE TABLE IF NOT EXISTS shape_searches (
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                reference_identity TEXT NOT NULL DEFAULT '',
                query TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """
        )
        let shapeColumns = try query("PRAGMA table_info(shape_searches);") { statement in
            columnText(statement, 1)
        }
        if !shapeColumns.contains("tuning") {
            try exec("ALTER TABLE shape_searches ADD COLUMN tuning TEXT NOT NULL DEFAULT '';")
        }
        try exec(
            """
            CREATE TABLE IF NOT EXISTS foundries (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                host TEXT NOT NULL UNIQUE,
                url TEXT NOT NULL,
                sources TEXT NOT NULL,
                watched INTEGER NOT NULL DEFAULT 0
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS foundry_faces (
                foundry_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                PRIMARY KEY (foundry_id, name),
                FOREIGN KEY (foundry_id) REFERENCES foundries(id) ON DELETE CASCADE
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS foundry_notices (
                id INTEGER PRIMARY KEY,
                foundry_host TEXT NOT NULL,
                name TEXT NOT NULL,
                url TEXT NOT NULL,
                published_at REAL NOT NULL DEFAULT 0,
                seen INTEGER NOT NULL DEFAULT 0,
                dismissed INTEGER NOT NULL DEFAULT 0,
                discovered_at REAL NOT NULL,
                edited INTEGER NOT NULL DEFAULT 0,
                UNIQUE(foundry_host, name)
            );
            """
        )
    }

    private func pruneCollections() throws {
        try exec(
            """
            DELETE FROM favorites
            WHERE NOT EXISTS (
                SELECT 1 FROM fonts
                WHERE fonts.file_path = favorites.file_path AND fonts.face_index = favorites.face_index
            );
            """
        )
        try exec(
            """
            DELETE FROM notes
            WHERE NOT EXISTS (
                SELECT 1 FROM fonts
                WHERE fonts.file_path = notes.file_path AND fonts.face_index = notes.face_index
            );
            """
        )
        try exec(
            """
            DELETE FROM standard_memberships
            WHERE NOT EXISTS (
                SELECT 1 FROM fonts
                WHERE fonts.file_path = standard_memberships.file_path
                  AND fonts.face_index = standard_memberships.face_index
            );
            """
        )
        try exec(
            """
            DELETE FROM group_members
            WHERE NOT EXISTS (
                SELECT 1 FROM fonts
                WHERE fonts.file_path = group_members.file_path AND fonts.face_index = group_members.face_index
            );
            """
        )
        try exec(
            """
            DELETE FROM compare_members
            WHERE NOT EXISTS (
                SELECT 1 FROM fonts
                WHERE fonts.file_path = compare_members.file_path AND fonts.face_index = compare_members.face_index
            );
            """
        )
    }

    private func insert(_ face: FontFace) throws {
        let axes = (try? JSONEncoder().encode(face.axes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try run(
            """
            INSERT INTO fonts (
                file_path, face_index, family, style, full_name, postscript_name, version,
                manufacturer, designer, copyright, format, is_variable, weight_class, width_class,
                category, is_italic, glyph_count, axes_json, file_size, modified_at, activation,
                x_height, cap_height, avg_width, contrast, covers_latin, covers_cyrillic, covers_greek,
                unpacked_path, category_source
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: { statement in
                bind(statement, 1, face.filePath)
                sqlite3_bind_int(statement, 2, Int32(face.faceIndex))
                bind(statement, 3, face.family)
                bind(statement, 4, face.style)
                bind(statement, 5, face.fullName)
                bind(statement, 6, face.postscriptName)
                bind(statement, 7, face.version)
                bind(statement, 8, face.manufacturer)
                bind(statement, 9, face.designer)
                bind(statement, 10, face.copyright)
                bind(statement, 11, face.format)
                sqlite3_bind_int(statement, 12, face.isVariable ? 1 : 0)
                sqlite3_bind_int(statement, 13, Int32(face.weightClass))
                sqlite3_bind_int(statement, 14, Int32(face.widthClass))
                bind(statement, 15, face.category.rawValue)
                sqlite3_bind_int(statement, 16, face.isItalic ? 1 : 0)
                sqlite3_bind_int(statement, 17, Int32(face.glyphCount))
                bind(statement, 18, axes)
                sqlite3_bind_int64(statement, 19, face.fileSize)
                sqlite3_bind_double(statement, 20, face.modifiedAt.timeIntervalSince1970)
                bind(statement, 21, face.activation.rawValue)
                sqlite3_bind_int(statement, 22, Int32(face.xHeight))
                sqlite3_bind_int(statement, 23, Int32(face.capHeight))
                sqlite3_bind_int(statement, 24, Int32(face.averageWidth))
                sqlite3_bind_int(statement, 25, Int32(face.contrast))
                sqlite3_bind_int(statement, 26, face.coversLatin ? 1 : 0)
                sqlite3_bind_int(statement, 27, face.coversCyrillic ? 1 : 0)
                sqlite3_bind_int(statement, 28, face.coversGreek ? 1 : 0)
                bind(statement, 29, face.unpackedPath)
                bind(statement, 30, face.categorySource.rawValue)
            }
        )
        try ensureInitialMemberships(face)
    }

    private func ensureInitialMemberships(_ face: FontFace) throws {
        let count = try query(
            "SELECT COUNT(*) FROM standard_memberships WHERE file_path = ? AND face_index = ?;",
            bindings: { statement in
                self.bind(statement, 1, face.filePath)
                sqlite3_bind_int(statement, 2, Int32(face.faceIndex))
            },
            map: { statement in Int(sqlite3_column_int(statement, 0)) }
        ).first ?? 0
        guard count == 0 else { return }
        try insertInitialMemberships(face)
    }

    private func insertInitialMemberships(_ face: FontFace) throws {
        if FontCategory.typographic.contains(face.category) {
            try insertMembership(path: face.filePath, index: face.faceIndex, category: face.category.rawValue)
        }
        if face.isTrial {
            try insertMembership(path: face.filePath, index: face.faceIndex, category: FontCategory.trial.rawValue)
        }
    }

    private func insertMembership(path: String, index: Int, category: String) throws {
        try run(
            "INSERT OR IGNORE INTO standard_memberships (file_path, face_index, category) VALUES (?, ?, ?);",
            bindings: { statement in
                bind(statement, 1, path)
                sqlite3_bind_int(statement, 2, Int32(index))
                bind(statement, 3, category)
            }
        )
    }

    private func deleteMembership(path: String, index: Int, category: String) throws {
        try run(
            "DELETE FROM standard_memberships WHERE file_path = ? AND face_index = ? AND category = ?;",
            bindings: { statement in
                bind(statement, 1, path)
                sqlite3_bind_int(statement, 2, Int32(index))
                bind(statement, 3, category)
            }
        )
    }

    private func deleteTypographicMemberships(path: String, index: Int) throws {
        let lists = FontCategory.typographic.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        try run(
            "DELETE FROM standard_memberships WHERE file_path = ? AND face_index = ? AND category IN (\(lists));",
            bindings: { statement in
                bind(statement, 1, path)
                sqlite3_bind_int(statement, 2, Int32(index))
            }
        )
    }

    private func setPrimaryCategory(_ category: String, id: Int64) throws {
        // A category set by hand outranks every guess from the file.
        try run(
            "UPDATE fonts SET category = ?, category_source = ? WHERE id = ?;",
            bindings: { statement in
                bind(statement, 1, category)
                bind(statement, 2, CategorySource.user.rawValue)
                sqlite3_bind_int64(statement, 3, id)
            }
        )
    }

    // MARK: Review

    /// When each face was last confirmed in Review, keyed like the standard lists.
    public func reviewMarks() throws -> [String: Date] {
        try queue.sync {
            let rows = try query("SELECT file_path, face_index, reviewed_at FROM review_marks;") { statement in
                (
                    FaceKey.make(path: columnText(statement, 0), index: Int(sqlite3_column_int(statement, 1))),
                    Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                )
            }
            return Dictionary(rows, uniquingKeysWith: { _, last in last })
        }
    }

    public func setReviewed(_ faces: [(path: String, index: Int)], at date: Date = Date()) throws {
        guard !faces.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                for face in faces {
                    try run(
                        """
                        INSERT INTO review_marks (file_path, face_index, reviewed_at) VALUES (?, ?, ?)
                        ON CONFLICT(file_path, face_index) DO UPDATE SET reviewed_at = excluded.reviewed_at;
                        """,
                        bindings: { statement in
                            bind(statement, 1, face.path)
                            sqlite3_bind_int(statement, 2, Int32(face.index))
                            sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
                        }
                    )
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func clearReviewMarks() throws {
        try queue.sync { try exec("DELETE FROM review_marks;") }
    }

    /// Records where a category came from for rows indexed before sources were stored.
    /// Rows the user already decided on keep their `user` source.
    public func updateCategorySources(_ rows: [(id: Int64, source: CategorySource)]) throws {
        guard !rows.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                for row in rows {
                    try run(
                        "UPDATE fonts SET category_source = ? WHERE id = ? AND category_source != 'user';",
                        bindings: { statement in
                            bind(statement, 1, row.source.rawValue)
                            sqlite3_bind_int64(statement, 2, row.id)
                        }
                    )
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    private func assignPrimaryCategory(_ category: String, id: Int64) throws {
        guard let located = try query(
            "SELECT file_path, face_index FROM fonts WHERE id = ?;",
            bindings: { statement in sqlite3_bind_int64(statement, 1, id) },
            map: { statement in (self.columnText(statement, 0), Int(sqlite3_column_int(statement, 1))) }
        ).first else { return }
        try setPrimaryCategory(category, id: id)
        try deleteTypographicMemberships(path: located.0, index: located.1)
        if FontCategory.typographic.contains(FontCategory.fromStored(category)) {
            try insertMembership(path: located.0, index: located.1, category: category)
        }
    }

    private func readFolders() throws -> [FontFolder] {
        try query("SELECT id, path, added_at FROM folders ORDER BY path COLLATE NOCASE;") { statement in
            FontFolder(
                id: sqlite3_column_int64(statement, 0),
                path: columnText(statement, 1),
                addedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            )
        }
    }

    private func readFonts() throws -> [FontFace] {
        try query(
            """
            SELECT id, file_path, face_index, family, style, full_name, postscript_name, version,
                   manufacturer, designer, copyright, format, is_variable, weight_class, width_class,
                   category, is_italic, glyph_count, axes_json, file_size, modified_at, activation,
                   x_height, cap_height, avg_width, contrast, covers_latin, covers_cyrillic, covers_greek,
                   unpacked_path, category_source
            FROM fonts
            ORDER BY family COLLATE NOCASE, weight_class, is_italic, style COLLATE NOCASE;
            """
        ) { statement in
            let axesData = Data(columnText(statement, 18).utf8)
            let axes = (try? JSONDecoder().decode([VariationAxis].self, from: axesData)) ?? []
            return FontFace(
                id: sqlite3_column_int64(statement, 0),
                filePath: columnText(statement, 1),
                faceIndex: Int(sqlite3_column_int(statement, 2)),
                family: columnText(statement, 3),
                style: columnText(statement, 4),
                fullName: columnText(statement, 5),
                postscriptName: columnText(statement, 6),
                version: columnText(statement, 7),
                manufacturer: columnText(statement, 8),
                designer: columnText(statement, 9),
                copyright: columnText(statement, 10),
                format: columnText(statement, 11),
                isVariable: sqlite3_column_int(statement, 12) != 0,
                weightClass: Int(sqlite3_column_int(statement, 13)),
                widthClass: Int(sqlite3_column_int(statement, 14)),
                category: FontCategory.fromStored(columnText(statement, 15)),
                isItalic: sqlite3_column_int(statement, 16) != 0,
                glyphCount: Int(sqlite3_column_int(statement, 17)),
                axes: axes,
                fileSize: sqlite3_column_int64(statement, 19),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 20)),
                activation: Activation(rawValue: columnText(statement, 21)) ?? .inactive,
                xHeight: Int(sqlite3_column_int(statement, 22)),
                capHeight: Int(sqlite3_column_int(statement, 23)),
                averageWidth: Int(sqlite3_column_int(statement, 24)),
                contrast: Int(sqlite3_column_int(statement, 25)),
                coversLatin: sqlite3_column_int(statement, 26) != 0,
                coversCyrillic: sqlite3_column_int(statement, 27) != 0,
                coversGreek: sqlite3_column_int(statement, 28) != 0,
                unpackedPath: columnText(statement, 29),
                categorySource: CategorySource(stored: columnText(statement, 30))
            )
        }
    }

    private func covers(_ path: String, folders: [String]) -> Bool {
        folders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func exec(_ sql: String) throws {
        guard let handle else { throw FontsoError.message("The library is not open.") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if code != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "SQLite error \(code)"
            sqlite3_free(errorPointer)
            throw FontsoError.message(message)
        }
    }

    private func run(_ sql: String, bindings: (OpaquePointer) -> Void) throws {
        guard let handle else { throw FontsoError.message("The library is not open.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FontsoError.message(databaseMessage())
        }
        defer { sqlite3_finalize(statement) }
        bindings(statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw FontsoError.message(databaseMessage())
        }
    }

    private func query<T>(_ sql: String, bindings: ((OpaquePointer) -> Void)? = nil, map: (OpaquePointer) -> T) throws -> [T] {
        guard let handle else { throw FontsoError.message("The library is not open.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FontsoError.message(databaseMessage())
        }
        defer { sqlite3_finalize(statement) }
        bindings?(statement)
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(map(statement))
        }
        return rows
    }

    private func databaseMessage() -> String {
        guard let handle else { return "The library is not open." }
        return String(cString: sqlite3_errmsg(handle))
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        value.withCString { pointer in
            _ = sqlite3_bind_text(statement, index, pointer, -1, transientDestructor)
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
