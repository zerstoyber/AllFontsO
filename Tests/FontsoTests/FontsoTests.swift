@testable import FontsoCore
import Compression
import XCTest

final class FontsoTests: XCTestCase {
    func testClassificationUsesOpenTypeClassAndPanose() {
        XCTAssertEqual(FontClassification.category(familyClass: 8, panose: [], monoTrait: false), .sans)
        XCTAssertEqual(FontClassification.category(familyClass: 10, panose: [], monoTrait: false), .script)
        XCTAssertEqual(FontClassification.category(familyClass: 5, panose: [], monoTrait: false), .slab)
        XCTAssertEqual(
            FontClassification.category(familyClass: 0, panose: [2, 11, 6, 4, 2, 2, 2, 2, 2, 4], monoTrait: false),
            .sans
        )
        XCTAssertEqual(
            FontClassification.category(familyClass: 8, panose: [2, 11, 5, 9, 2, 2, 2, 2, 2, 4], monoTrait: false),
            .mono
        )
    }

    func testArialMetadata() throws {
        let url = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
        let faces = FontIndexer.inspect(fileURL: url)
        let arial = try XCTUnwrap(faces.first)
        XCTAssertEqual(arial.family, "Arial")
        XCTAssertEqual(arial.postscriptName, "ArialMT")
        XCTAssertEqual(arial.weightClass, 400)
        XCTAssertEqual(arial.widthClass, 5)
        XCTAssertEqual(arial.category, .sans)
        XCTAssertFalse(arial.isItalic)
        XCTAssertFalse(arial.isVariable)
        XCTAssertGreaterThan(arial.glyphCount, 200)
        XCTAssertEqual(arial.activation, .installed)
        XCTAssertEqual(arial.xHeight, 519)
        XCTAssertEqual(arial.capHeight, 716)
        XCTAssertEqual(arial.averageWidth, 441)
        XCTAssertEqual(arial.contrast, 2)
        XCTAssertTrue(arial.coversLatin)
        XCTAssertTrue(arial.coversGreek)
        XCTAssertTrue(arial.coversCyrillic)
    }

    func testHelveticaCollectionHasSixFaces() {
        let url = URL(fileURLWithPath: "/System/Library/Fonts/Helvetica.ttc")
        let faces = FontIndexer.inspect(fileURL: url)
        XCTAssertEqual(faces.count, 6)
        XCTAssertTrue(faces.allSatisfy { $0.format == "ttc" })
    }

    func testNewYorkIsVariable() throws {
        let url = URL(fileURLWithPath: "/System/Library/Fonts/NewYork.ttf")
        let faces = FontIndexer.inspect(fileURL: url)
        let face = try XCTUnwrap(faces.first)
        XCTAssertTrue(face.isVariable)
        XCTAssertFalse(face.axes.isEmpty)
    }

    func testSpecimenRendersWithoutInstalling() {
        let image = SpecimenRenderer.render(
            filePath: "/System/Library/Fonts/Supplemental/Arial.ttf",
            faceIndex: 0,
            text: "Ha",
            pointSize: 32,
            maxWidth: 400,
            variations: [:]
        )
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image?.width ?? 0, 20)
    }

    func testDatabaseRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))
        try database.addFolder(path: directory.path)
        let folders = try database.allFolders()
        XCTAssertEqual(folders.count, 1)

        let face = sampleFace(path: directory.appendingPathComponent("Demo.otf").path)
        try database.replaceFonts([face])
        let loaded = try database.allFonts()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].family, "Demo")
        XCTAssertEqual(loaded[0].category, .sans)
        XCTAssertEqual(loaded[0].axes.first?.tagName, "wght")
        XCTAssertNotEqual(loaded[0].id, 0)

        try database.removeFolder(id: folders[0].id)
        XCTAssertTrue(try database.allFonts().isEmpty)
        XCTAssertTrue(try database.allFolders().isEmpty)
    }

    func testOrganizeCopiesIntoCategoryFolders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDir = directory.appendingPathComponent("in", isDirectory: true)
        let destination = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("Demo-Regular.otf")
        try Data("font".utf8).write(to: source)
        let face = sampleFace(path: source.path)
        let result = LibraryOrganizer.organize(
            [OrganizeFile(path: source.path, faces: [face])],
            to: destination,
            mode: .copy
        )
        XCTAssertEqual(result.written, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Sans/Demo/Demo-Regular.otf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testAvailabilityTreatsKnownPostScriptNameAsActive() {
        let path = "/tmp/Fontso-not-registered.otf"
        XCTAssertEqual(
            FontActivator.availability(filePath: path, postScriptName: "DefinitelyNotAFontXYZ", activeNames: ["DefinitelyNotAFontXYZ"]),
            .available
        )
        XCTAssertEqual(
            FontActivator.availability(filePath: path, postScriptName: "DefinitelyNotAFontXYZ", activeNames: []),
            .inactive
        )
    }

    func testTrialMarkReadsNameAndPath() {
        XCTAssertTrue(TrialMark.matches("Surt-TRIAL"))
        XCTAssertTrue(TrialMark.matches("ABCDiatypeCompressedUnlicensedTrial-Bold"))
        XCTAssertTrue(TrialMark.matches("Slussen Regular-Trial Compressed Thin"))
        XCTAssertFalse(TrialMark.matches("Industrial"))
        XCTAssertFalse(TrialMark.matches("Contrail"))
        XCTAssertFalse(TrialMark.matches("Times"))

        var retail = sampleFace(path: "/Fonts/Times.otf")
        retail.family = "Times"
        retail.fullName = "Times Regular"
        XCTAssertFalse(retail.isTrial)

        var named = sampleFace(path: "/Fonts/Retail.otf")
        named.family = "GT America Trial"
        XCTAssertTrue(named.isTrial)

        var folded = sampleFace(path: "/Fonts/Slussen Regular-Trial/Slussen.ttf")
        folded.family = "Slussen"
        folded.fullName = "Slussen Compressed Thin"
        folded.postscriptName = "Slussen-CompressedThin"
        XCTAssertTrue(folded.isTrial)
    }

    func testSearchScopeLimitsFields() {
        let face = sampleFace(path: "/tmp/Demo.otf")
        XCTAssertTrue(SearchScope.all.matches(face, query: "demo fontso"))
        XCTAssertTrue(SearchScope.foundry.matches(face, query: "Fontso"))
        XCTAssertFalse(SearchScope.family.matches(face, query: "Fontso"))
        XCTAssertTrue(SearchScope.style.matches(face, query: "regular"))
        XCTAssertTrue(SearchScope.postscript.matches(face, query: "Demo-Regular"))
        XCTAssertTrue(SearchScope.all.matches(face, query: "   "))
    }

    func testLibraryChangesIgnoreUntouchedFilesAndMissingFolders() {
        let folder = "/Fonts"
        let kept = FontFileRecord(path: "/Fonts/Kept.otf", fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 100))
        let edited = FontFileRecord(path: "/Fonts/Edited.otf", fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 100))
        let gone = FontFileRecord(path: "/Fonts/Gone.otf", fileSize: 4, modifiedAt: Date(timeIntervalSince1970: 100))
        let offline = FontFileRecord(path: "/Offline/Stay.otf", fileSize: 4, modifiedAt: Date(timeIntervalSince1970: 100))
        let added = FontFileRecord(path: "/Fonts/New.otf", fileSize: 8, modifiedAt: Date(timeIntervalSince1970: 200))
        let editedNow = FontFileRecord(path: edited.path, fileSize: 12, modifiedAt: edited.modifiedAt)
        let listings = [
            FontFolderListing(folder: folder, files: [kept, editedNow, added], available: true),
            FontFolderListing(folder: "/Offline", files: [], available: false)
        ]
        let changes = FontIndexer.changes(listings: listings, stored: [kept, edited, gone, offline])
        XCTAssertEqual(changes.added.map(\.path), ["/Fonts/New.otf"])
        XCTAssertEqual(changes.updated.map(\.path), ["/Fonts/Edited.otf"])
        XCTAssertEqual(changes.removed, ["/Fonts/Gone.otf"])
    }

    func testIncrementalChangesKeepFavoritesOnUntouchedFonts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))
        let kept = sampleFace(path: directory.appendingPathComponent("Kept.otf").path)
        var removed = sampleFace(path: directory.appendingPathComponent("Removed.otf").path)
        removed.family = "Removed"
        removed.postscriptName = "Removed-Regular"
        try database.replaceFonts([kept, removed])
        try database.setFavorite(filePath: kept.filePath, faceIndex: kept.faceIndex, isFavorite: true)
        try database.setFavorite(filePath: removed.filePath, faceIndex: removed.faceIndex, isFavorite: true)
        var added = sampleFace(path: directory.appendingPathComponent("Added.otf").path)
        added.family = "Added"
        added.postscriptName = "Added-Regular"
        try database.applyLibraryChanges(removedPaths: [removed.filePath], faces: [added])
        let faces = try database.allFonts()
        XCTAssertEqual(Set(faces.map(\.family)), ["Demo", "Added"])
        XCTAssertTrue(try database.favoriteKeys().contains(kept.identity))
        XCTAssertFalse(try database.favoriteKeys().contains(removed.identity))
    }

    func testNotesStayWithTheFontAcrossRescan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))
        let face = sampleFace(path: directory.appendingPathComponent("Demo.otf").path)
        try database.replaceFonts([face])
        try database.setNote(filePath: face.filePath, faceIndex: face.faceIndex, body: "Use for titles")
        try database.replaceFonts([face])
        XCTAssertEqual(try database.allNotes()[face.identity], "Use for titles")
        try database.replaceFonts([])
        XCTAssertTrue(try database.allNotes().isEmpty)
    }

    func testStandardListsCanCombineTrialWithAStyle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))
        var face = sampleFace(path: directory.appendingPathComponent("Demo.otf").path)
        face.category = .sans
        try database.replaceFonts([face])
        let stored = try XCTUnwrap(database.allFonts().first)
        try database.applyStandardLists(
            category: FontCategory.trial.rawValue,
            enabled: true,
            faces: [(stored.filePath, stored.faceIndex, stored.id, nil)]
        )
        try database.replaceFonts([stored])
        let lists = try database.standardLists()[stored.identity] ?? []
        XCTAssertTrue(lists.contains(.sans))
        XCTAssertTrue(lists.contains(.trial))
        XCTAssertEqual(try database.allFonts().first?.category, .sans)
    }

    func testStandardListAssignmentUpdatesTheChosenFace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))
        var face = sampleFace(path: directory.appendingPathComponent("Demo.otf").path)
        face.category = .unclassified
        try database.replaceFonts([face])
        let stored = try XCTUnwrap(database.allFonts().first)
        try database.setCategory(FontCategory.serif.rawValue, ids: [stored.id])
        XCTAssertEqual(try database.allFonts().first?.category, .serif)
    }

    func testFavoritesAndGroupsSurviveRescan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))
        let face = sampleFace(path: directory.appendingPathComponent("Demo.otf").path)
        try database.replaceFonts([face])
        try database.setFavorite(filePath: face.filePath, faceIndex: face.faceIndex, isFavorite: true)
        let group = try database.createGroup(name: "Kunden")
        try database.addMembers(groupID: group.id, keys: [face.identity])

        try database.replaceFonts([face])
        XCTAssertTrue(try database.favoriteKeys().contains(face.identity))
        XCTAssertEqual(try database.membership()[group.id], [face.identity])

        try database.replaceFonts([])
        XCTAssertTrue(try database.favoriteKeys().isEmpty)
        XCTAssertTrue(try database.membership()[group.id]?.isEmpty ?? true)
        XCTAssertEqual(try database.allGroups().map(\.name), ["Kunden"])
    }

    func testCompareListsKeepOrderAndSurviveRescan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))
        let first = sampleFace(path: directory.appendingPathComponent("First.otf").path)
        var second = sampleFace(path: directory.appendingPathComponent("Second.otf").path)
        second.family = "Second"
        second.postscriptName = "Second-Regular"
        try database.replaceFonts([first, second])
        let list = try database.createCompareList(name: "Wine label")
        try database.addCompareMembers(listID: list.id, keys: [second.identity, first.identity])
        try database.replaceFonts([first, second])
        XCTAssertEqual(try database.compareMembership()[list.id], [second.identity, first.identity])
        try database.replaceFonts([])
        XCTAssertTrue(try database.compareMembership()[list.id]?.isEmpty ?? true)
        XCTAssertEqual(try database.allCompareLists().map(\.name), ["Wine label"])
    }

    func testPassportPutsBandsBesideTheNumbers() {
        var lyon = sampleFace(path: "/tmp/lyon.otf")
        lyon.family = "Lyon"
        lyon.category = .serif
        lyon.contrast = 7
        lyon.xHeight = 450
        lyon.widthClass = 5
        lyon.manufacturer = "Commercial Type"
        XCTAssertEqual(FontPassport.form(of: lyon), "high contrast 7, x-height 450")
        XCTAssertEqual(FontPassport.xHeightBand(450), .low)

        var arial = sampleFace(path: "/tmp/arial.ttf")
        arial.family = "Arial"
        arial.contrast = 2
        arial.xHeight = 519
        arial.widthClass = 5
        arial.isVariable = false
        XCTAssertEqual(FontPassport.form(of: arial), "low contrast 2, x-height 519")

        var pochen = sampleFace(path: "/tmp/pochen.otf")
        pochen.widthClass = 3
        pochen.contrast = 2
        pochen.xHeight = 530
        XCTAssertEqual(FontPassport.form(of: pochen), "low contrast 2, x-height 530, condensed")
        XCTAssertEqual(FontPassport.widthWord(widthClass: 4, averageWidth: 0), "semi condensed")
        XCTAssertNil(FontPassport.widthWord(widthClass: 5, averageWidth: 441))
    }

    func testResearchRanksByContrastXHeightAndWidth() {
        func face(_ family: String, category: FontCategory, contrast: Int, xHeight: Int, width: Int) -> FontFace {
            var face = sampleFace(path: "/tmp/\(family).otf")
            face.family = family
            face.category = category
            face.contrast = contrast
            face.xHeight = xHeight
            face.widthClass = width
            face.isVariable = false
            return face
        }
        let lyon = face("Lyon", category: .serif, contrast: 7, xHeight: 450, width: 5)
        let times = face("Tiempos", category: .serif, contrast: 5, xHeight: 500, width: 5)
        let grotesk = face("Haas", category: .sans, contrast: 2, xHeight: 519, width: 5)
        let condensed = face("Pochen", category: .sans, contrast: 2, xHeight: 530, width: 3)
        let tall = face("Signage", category: .sans, contrast: 2, xHeight: 560, width: 5)
        let catalog = [lyon, times, grotesk, condensed, tall]

        let contrastHits = FontResearch.candidates(in: catalog, query: "a high contrast serif")
        XCTAssertEqual(contrastHits.first?.family, "Lyon")
        XCTAssertTrue(contrastHits.first?.line.contains("high contrast 7") == true)
        XCTAssertEqual(Set(contrastHits.prefix(2).map(\.category)), ["Serif"])

        let xHeightHits = FontResearch.candidates(in: catalog, query: "sans with a high x-height")
        XCTAssertEqual(xHeightHits.first?.family, "Signage")
        let germanX = FontResearch.candidates(in: catalog, query: "Sans mit hoher x-Höhe")
        XCTAssertEqual(germanX.first?.family, "Signage")

        let narrowHits = FontResearch.candidates(in: catalog, query: "eine schmale grotesk")
        XCTAssertEqual(narrowHits.first?.family, "Pochen")
        XCTAssertTrue(narrowHits.first?.line.contains("condensed") == true)
    }

    func testResearchRanksNamedFamilyFirst() {
        var serif = sampleFace(path: "/tmp/kepler.otf")
        serif.family = "Kepler"
        serif.category = .serif
        var sans = sampleFace(path: "/tmp/haas.otf")
        sans.family = "Neue Haas"
        sans.category = .sans
        let result = FontResearch.candidates(in: [serif, sans], query: "Kepler for a book")
        XCTAssertEqual(result.first?.family, "Kepler")
    }

    func testResearchFollowUpShowsAnotherFontAndFixesTypos() {
        let names = ["Louise", "Mistral Std", "Great Vibes", "Kepler"]
        let faces = names.map { name in
            var face = sampleFace(path: "/tmp/\(name).otf")
            face.family = name
            face.category = name == "Kepler" ? .serif : .script
            return face
        }
        let first = ResearchMessage(
            id: 1, chatID: 1, role: "assistant", text: "Louise",
            suggestions: [ResearchSuggestion(family: "Louise", role: "", reason: "")],
            createdAt: Date()
        )
        let more = ResearchDialogue.followUp(
            history: [first, userMessage("Ok gibt es noch andere schriften?")],
            faces: faces
        )
        XCTAssertFalse(more?.suggestions.map(\.family).contains("Louise") ?? true)
        XCTAssertFalse(more?.text.contains("am besten zusagt") ?? true)

        let same = ResearchDialogue.followUp(
            history: [first, userMessage("Das ist die selbe schrift?")],
            faces: faces
        )
        XCTAssertTrue(same?.text.contains("dieselbe") ?? false)

        let shown = ResearchDialogue.followUp(
            history: [userMessage("Kannst du mir bitte die schrift anzeigen Greate Vibes?")],
            faces: faces
        )
        XCTAssertEqual(shown?.suggestions.first?.family, "Great Vibes")

        let canned = "Die Schriftfamilie, die dir am besten zusagt, ist **Louise** von Velvetyne Type Foundry."
        XCTAssertTrue(ResearchDialogue.isCanned(canned))
        let repaired = ResearchDialogue.repair(canned, history: [first], faces: faces)
        XCTAssertFalse(repaired.suggestions.map(\.family).contains("Louise"))
    }

    func testFontMeasureReadsXHeightWidthAndCoverage() throws {
        let path = "/System/Library/Fonts/Supplemental/Arial.ttf"
        let measure = try XCTUnwrap(FontMeasurer.measure(filePath: path, faceIndex: 0, sample: "Hamburgefonts"))
        XCTAssertGreaterThan(measure.xHeight, 0.4)
        XCTAssertLessThan(measure.xHeight, 0.7)
        XCTAssertGreaterThan(measure.capHeight, measure.xHeight)
        XCTAssertGreaterThan(measure.width, 2)
        let latin = try XCTUnwrap(measure.coverage.first { $0.name == "Latin" })
        XCTAssertEqual(latin.present, latin.total)
        let figures = try XCTUnwrap(measure.coverage.first { $0.name == "Figures" })
        XCTAssertEqual(figures.present, figures.total)
    }

    func testSpecimenUnitsAndGlyphInventory() throws {
        XCTAssertEqual(SpecimenUnit.pixel.display(from: 48), 64, accuracy: 0.001)
        XCTAssertEqual(SpecimenUnit.rem.display(from: 48), 4, accuracy: 0.001)
        XCTAssertEqual(SpecimenUnit.pixel.points(from: 64), 48, accuracy: 0.001)
        let glyphs = try XCTUnwrap(
            SpecimenCharacters.glyphs(filePath: "/System/Library/Fonts/Supplemental/Arial.ttf", faceIndex: 0, limit: 80)
        )
        XCTAssertTrue(glyphs.shown.contains("A"))
        XCTAssertTrue(glyphs.shown.contains("0"))
        XCTAssertGreaterThan(glyphs.total, 80)
        XCTAssertEqual(glyphs.shown.count, 80)
    }

    func testSpecimenLineRendersASystemFont() throws {
        let path = "/System/Library/Fonts/Supplemental/Arial.ttf"
        let image = try XCTUnwrap(
            SpecimenRenderer.line(filePath: path, faceIndex: 0, text: "Handgloves", pointSize: 28)
        )
        XCTAssertGreaterThan(image.width, 40)
        XCTAssertGreaterThan(image.height, 20)
    }

    func testResearchPreviewRepeatsTheLastSuggestions() {
        let previous = ResearchMessage(
            id: 1, chatID: 1, role: "assistant",
            text: "In derselben Richtung wie Mistral Std: Solide Mirage, Deutsche Zierschrift und Yanone Tagesschrift.",
            suggestions: [
                ResearchSuggestion(family: "Solide Mirage", role: "", reason: ""),
                ResearchSuggestion(family: "Deutsche Zierschrift", role: "", reason: ""),
                ResearchSuggestion(family: "Yanone Tagesschrift", role: "", reason: "")
            ],
            createdAt: Date()
        )
        let dump = ResearchMessage(
            id: 3, chatID: 1, role: "assistant",
            text: "Aus der Bibliothek: DIN 1451 Std, Slussen und Baton Turbo.",
            suggestions: [ResearchSuggestion(family: "DIN 1451 Std", role: "", reason: "")],
            createdAt: Date()
        )
        let turn = ResearchDialogue.followUp(
            history: [
                previous,
                userMessage("Super danke."),
                dump,
                userMessage("Kannst du mir die schriften mal nebeneinander visualisieren?")
            ],
            faces: []
        )
        XCTAssertEqual(
            turn?.suggestions.map(\.family),
            ["Solide Mirage", "Deutsche Zierschrift", "Yanone Tagesschrift"]
        )
        XCTAssertEqual(turn?.suggestions.first?.role, "preview")
    }

    func testResearchLanguageFollowsGermanQuestion() {
        XCTAssertEqual(ResearchLanguage.detect("Kannst du deutsch?"), .german)
        XCTAssertTrue(ResearchLanguage.asksAboutGerman("Kannst du deutsch?"))
        XCTAssertFalse(ResearchLanguage.matches(.german, reply: "Sure, I can help you with that. What is the typeface for?"))
        XCTAssertFalse(ResearchLanguage.confirmsGerman("Sure, I can help you with that. What is the typeface for?"))
        XCTAssertTrue(ResearchLanguage.matches(.german, reply: "Ja, ich antworte auf Deutsch."))
        XCTAssertTrue(ResearchLanguage.confirmsGerman("Ja, ich antworte auf Deutsch."))
        XCTAssertFalse(ResearchLanguage.isFontRequest("Kannst du deutsch?"))
        XCTAssertTrue(ResearchLanguage.isFontRequest("Ich brauche eine Serifenschrift für ein Weinlabel."))
    }

    func testResearchMentionsOnlyNamedFamilies() {
        var kepler = sampleFace(path: "/tmp/kepler.otf")
        kepler.family = "Kepler"
        var sans = sampleFace(path: "/tmp/haas.otf")
        sans.family = "Neue Haas"
        let mentions = FontResearch.mentions(in: "I would try Kepler for the label, not a random sans.", faces: [kepler, sans])
        XCTAssertEqual(mentions.map(\.family), ["Kepler"])
    }

    func testResearchQueriesChangeTheShortlist() {
        let names = ["Aalto", "Kepler", "Recoleta", "Tiempos", "Canela"]
        let faces = names.map { name in
            var face = sampleFace(path: "/tmp/\(name).otf")
            face.family = name
            face.category = .serif
            return face
        }
        let wine = FontResearch.candidates(in: faces, query: "A serif for a wine label").map(\.family)
        let book = FontResearch.candidates(in: faces, query: "An elegant literary book serif").map(\.family)
        XCTAssertNotEqual(wine, book)
        let withoutKepler = FontResearch.candidates(in: faces, query: "A serif for a wine label", avoiding: ["Kepler"])
        XCTAssertFalse(withoutKepler.map(\.family).contains("Kepler"))
    }

    func testResearchRefusalBecomesALibraryPairing() {
        var mono = sampleFace(path: "/tmp/abc-mono.otf")
        mono.family = "ABC Mono"
        mono.category = .mono
        mono.manufacturer = "Dinamo"
        var serif = sampleFace(path: "/tmp/kepler.otf")
        serif.family = "Kepler"
        serif.category = .serif
        serif.manufacturer = "TypeTogether"
        let refusal = """
        Ich kann dir leider nicht helfen, eine bestimmte Schriftart oder Designvorlage zu erstellen, \
        da dies gegen meine Richtlinien verstößt.
        """
        let turn = ResearchDialogue.repair(
            refusal,
            history: [userMessage("Kannst du mir lieber eine Dinamo Font mit Mono als Headline geben und dann eine Serifenschrift als Fließtext schrift.")],
            faces: [mono, serif]
        )
        XCTAssertFalse(turn.text.localizedCaseInsensitiveContains("Richtlinien"))
        XCTAssertEqual(turn.suggestions.map(\.family), ["ABC Mono", "Kepler"])
        XCTAssertEqual(turn.suggestions.map(\.role), ["Headline", "Fließtext"])
    }

    func testResearchRanksByXHeightInsteadOfSkippingTheMeasurement() {
        defer { ResearchDialogue.metricsOverride = nil }
        func face(_ family: String, _ style: String, _ width: Int, _ weight: Int, _ path: String) -> FontFace {
            var face = sampleFace(path: path)
            face.family = family
            face.style = style
            face.fullName = "\(family) \(style)"
            face.widthClass = width
            face.weightClass = weight
            face.category = .sans
            return face
        }
        let obvious = face("Obviously Demo", "Condensed Super", 3, 390, "/tmp/obviously.otf")
        let close = face("Rabenau Pro", "Condensed", 3, 400, "/tmp/rabenau.otf")
        let trial = face("ABC Diatype Condensed Unlicensed Trial", "Condensed", 3, 400, "/tmp/diatype.otf")
        let regular = face("Helvetica", "Regular", 5, 400, "/tmp/helvetica.otf")
        let faces = [obvious, close, trial, regular]
        ResearchDialogue.metricsOverride = { path, _ in
            switch path {
            case "/tmp/obviously.otf": return (0.70, 0.74, 0.42)
            case "/tmp/rabenau.otf": return (0.69, 0.73, 0.44)
            case "/tmp/diatype.otf": return (0.48, 0.68, 0.40)
            default: return (0.52, 0.70, 0.62)
            }
        }
        let turn = ResearchDialogue.followUp(
            history: [userMessage("Kannst du die Auswahl in der Liste auf 20 beschränken die ähnliche Eigenschaften und aussehen haben wie obviously demo condesed super?")],
            faces: faces
        )
        XCTAssertEqual(turn?.suggestions.first?.family, "Rabenau Pro")
        XCTAssertFalse(turn?.suggestions.map(\.family).contains("Helvetica") ?? true)
        XCTAssertTrue(turn?.text.contains("X-Höhe 700/1000") ?? false)
        XCTAssertTrue(turn?.text.contains("Versalhöhe 740/1000") ?? false)
        XCTAssertFalse(turn?.text.contains("messe ich nicht") ?? true)
        XCTAssertEqual(turn?.listName, "Condensed")
        XCTAssertEqual(turn?.listReplaces, true)
        XCTAssertEqual(turn?.suggestions.first?.reason.contains("X-Höhe 690/1000"), true)
    }

    func testResearchRanksStoredXHeightWithoutOpeningFiles() {
        ResearchDialogue.metricsOverride = nil
        func face(_ family: String, _ style: String, _ width: Int, _ xHeight: Int, _ path: String) -> FontFace {
            var face = sampleFace(path: path)
            face.family = family
            face.style = style
            face.fullName = "\(family) \(style)"
            face.widthClass = width
            face.weightClass = 400
            face.category = .sans
            face.xHeight = xHeight
            face.capHeight = xHeight + 40
            face.averageWidth = 450
            return face
        }
        let faces = [
            face("Obviously Demo", "Condensed Super", 3, 700, "/tmp/obviously.otf"),
            face("Rabenau Pro", "Condensed", 3, 690, "/tmp/rabenau.otf"),
            face("ABC Diatype Condensed Unlicensed Trial", "Condensed", 3, 480, "/tmp/diatype.otf"),
            face("Helvetica", "Regular", 5, 520, "/tmp/helvetica.otf")
        ]
        let turn = ResearchDialogue.followUp(
            history: [userMessage("Schriften mit ähnlicher X-Höhe wie Obviously Demo Condensed Super")],
            faces: faces
        )
        XCTAssertEqual(turn?.suggestions.first?.family, "Rabenau Pro")
        XCTAssertFalse(turn?.suggestions.map(\.family).contains("Helvetica") ?? true)
        XCTAssertTrue(turn?.text.contains("X-Höhe 700/1000") ?? false)
    }

    func testResearchSaysWhetherShownFontsAreWebfonts() {
        var desktop = sampleFace(path: "/tmp/Arial.ttf")
        desktop.family = "Arial"
        desktop.format = "ttf"
        var web = sampleFace(path: "/tmp/Plex.woff2")
        web.family = "IBM Plex Sans"
        web.format = "woff2"
        let history = [
            userMessage("Such mir 5 Webfonts die Condensed sind."),
            ResearchMessage(
                id: 3,
                chatID: 1,
                role: "assistant",
                text: "Hier sind 5 Schriften.",
                suggestions: [
                    ResearchSuggestion(family: "Arial", role: "", reason: ""),
                    ResearchSuggestion(family: "IBM Plex Sans", role: "", reason: "")
                ],
                createdAt: Date()
            ),
            userMessage("Sind das webfonts also woff dateien?")
        ]
        let turn = ResearchDialogue.followUp(history: history, faces: [desktop, web])
        XCTAssertEqual(turn?.suggestions.map(\.family), ["Arial", "IBM Plex Sans"])
        XCTAssertTrue(turn?.text.contains("Nur ein Teil") == true)
        XCTAssertTrue(turn?.text.contains("Arial: TTF") == true)
        XCTAssertTrue(turn?.text.contains("IBM Plex Sans: WOFF2") == true)
        let repaired = ResearchDialogue.repair("Aus der Bibliothek: Tercia, Aeroport und Aeroport Mono.", history: history, faces: [desktop, web])
        XCTAssertFalse(repaired.text.contains("Tercia"))
        XCTAssertTrue(repaired.text.contains("WOFF2"))
    }

    func testResearchKeepsAWebfontFollowUpOnTheFontsAlreadyShown() {
        var plex = sampleFace(path: "/tmp/PlexCond.ttf")
        plex.family = "IBM Plex Sans Condensed"
        plex.format = "ttf"
        var gill = sampleFace(path: "/tmp/Gill.otf")
        gill.family = "Gill Sans MT Pro"
        gill.format = "otf"
        var medieval = sampleFace(path: "/tmp/Medieval.ttf")
        medieval.family = "MedievalSharp"
        medieval.format = "ttf"
        let shown = ResearchMessage(
            id: 3,
            chatID: 1,
            role: "assistant",
            text: "IBM Plex Sans Condensed und Gill Sans MT Pro liegen Arial am nächsten.",
            suggestions: [
                ResearchSuggestion(family: "IBM Plex Sans Condensed", role: "", reason: ""),
                ResearchSuggestion(family: "Gill Sans MT Pro", role: "", reason: "")
            ],
            createdAt: Date()
        )
        let ask = userMessage("Gibt es die auch als Webfont?")
        let turn = ResearchDialogue.followUp(history: [shown, ask], faces: [plex, gill, medieval])
        XCTAssertTrue(turn?.text.contains("IBM Plex Sans Condensed: TTF") == true)
        XCTAssertTrue(turn?.text.contains("Gill Sans MT Pro: OTF") == true)
        XCTAssertFalse(turn?.text.contains("MedievalSharp") == true)
        XCTAssertFalse(turn?.text.contains("Aus der Bibliothek") == true)
        let dump = ResearchMessage(
            id: 5,
            chatID: 1,
            role: "assistant",
            text: "Aus der Bibliothek: MedievalSharp.",
            suggestions: [ResearchSuggestion(family: "MedievalSharp", role: "", reason: "")],
            createdAt: Date()
        )
        let complaint = userMessage("Aber ich habe nach Webfonts gefragt!")
        let again = ResearchDialogue.followUp(
            history: [shown, ask, dump, complaint],
            faces: [plex, gill, medieval]
        )
        XCTAssertTrue(again?.text.contains("IBM Plex Sans Condensed") == true)
        XCTAssertFalse(again?.text.contains("MedievalSharp") == true)
    }

    func testResearchComparesOnlyTheFontsAlreadyShown() {
        var arial = sampleFace(path: "/tmp/Arial.ttf")
        arial.family = "Arial"
        arial.xHeight = 519
        var agenda = sampleFace(path: "/tmp/Agenda.otf")
        agenda.family = "Agenda"
        agenda.xHeight = 480
        var medieval = sampleFace(path: "/tmp/MedievalSharp.ttf")
        medieval.family = "MedievalSharp"
        medieval.xHeight = 519
        let shown = ResearchMessage(
            id: 3,
            chatID: 1,
            role: "assistant",
            text: "Agenda ist condensed.",
            suggestions: [ResearchSuggestion(family: "Agenda", role: "", reason: "MediumCondensed")],
            createdAt: Date()
        )
        let turn = ResearchDialogue.followUp(
            history: [shown, userMessage("Such mit mitte von welche die ähnlichkeiten zu Arial haben")],
            faces: [arial, agenda, medieval]
        )
        let names = turn?.suggestions.map(\.family) ?? []
        XCTAssertTrue(names.contains("Agenda"))
        XCTAssertFalse(names.contains("MedievalSharp"))
    }

    func testResearchAnswersAQuestionAboutItselfWithoutFonts() {
        var face = sampleFace(path: "/tmp/Pilcrow.otf")
        face.family = "Pilcrow Rounded"
        let question = "Wie kann ich dich besser auf dein Individuelles schriftenpaket eines benutzers dieses Programms vorbereiten. Welche Daten sind wichtig für um mit schriften umzugehen. Und hast du noch andere Ideen?"
        let turn = ResearchDialogue.followUp(history: [userMessage(question)], faces: [face])
        XCTAssertTrue(turn?.suggestions.isEmpty ?? false)
        XCTAssertFalse(turn?.text.contains("Pilcrow") ?? true)
        let repaired = ResearchDialogue.repair(
            "Aus der Bibliothek: Pilcrow Rounded, Founders Grotesk und GF Founders Script.",
            history: [userMessage(question)],
            faces: [face]
        )
        XCTAssertTrue(repaired.suggestions.isEmpty)
        XCTAssertFalse(repaired.text.contains("Pilcrow"))
    }

    func testResearchDoesNotTreatNotYetAsMoreFonts() {
        let shown = ResearchMessage(
            id: 3, chatID: 1, role: "assistant", text: "Obviously Demo Condensed Super",
            suggestions: [ResearchSuggestion(family: "Obviously Demo", role: "", reason: "Condensed Super")],
            createdAt: Date()
        )
        let turn = ResearchDialogue.followUp(
            history: [shown, userMessage("sie ist aber noch nicht unter \"lists\" sichtbar")],
            faces: []
        )
        XCTAssertTrue(turn?.text.contains("Neustart") ?? false)
        XCTAssertTrue(turn?.suggestions.isEmpty ?? false)
    }

    func testResearchFindsCondensedSuperAsOneCut() {
        func face(_ style: String) -> FontFace {
            var face = sampleFace(path: "/tmp/obviously-\(style).otf")
            face.family = "Obviously Demo"
            face.style = style
            face.fullName = "Obviously Demo \(style)"
            return face
        }
        let faces = [face("Compressed Light"), face("Condensed Super"), face("Condensed Super Italic")]
        let earlier = ResearchMessage(
            id: 3, chatID: 1, role: "assistant", text: "Obviously Demo",
            suggestions: [ResearchSuggestion(family: "Obviously Demo", role: "", reason: "")],
            createdAt: Date()
        )
        let shown = ResearchDialogue.followUp(
            history: [earlier, userMessage("Condensed Super")],
            faces: faces
        )
        XCTAssertEqual(shown?.suggestions.first?.reason, "Condensed Super")
        XCTAssertEqual(shown?.listStyles, [])
        let added = ResearchDialogue.followUp(
            history: [earlier, userMessage("füge Obviously Demo Cond Supr zur liste hinzu")],
            faces: faces
        )
        XCTAssertEqual(added?.listFamilies, ["Obviously Demo"])
        XCTAssertEqual(added?.listStyles, ["Condensed Super"])
        XCTAssertEqual(added?.listReplaces, false)
    }

    func testResearchKeepsIndividualCuts() {
        let shown = ResearchMessage(
            id: 4, chatID: 1, role: "assistant", text: "Diese 10 Schnitte liegen am nächsten.",
            suggestions: [ResearchSuggestion(family: "Digestive Demo", role: "", reason: "two · X-Höhe 650/1000 · Versalhöhe 750/1000")],
            createdAt: Date()
        )
        let turn = ResearchDialogue.followUp(
            history: [shown, userMessage("kannst du bitte die liste condensed leeren und dafür diese 10 schnitte hinzufügen?")],
            faces: []
        )
        XCTAssertEqual(turn?.listFamilies, ["Digestive Demo"])
        XCTAssertEqual(turn?.listStyles, ["two"])
        XCTAssertEqual(turn?.listReplaces, true)
        XCTAssertTrue(turn?.text.contains("Schnitte") ?? false)
    }

    func testResearchStoresOnlyTheCondensedCuts() {
        func face(_ family: String, _ style: String, _ width: Int) -> FontFace {
            var face = sampleFace(path: "/tmp/\(family)-\(style).otf")
            face.family = family
            face.style = style
            face.fullName = "\(family) \(style)"
            face.widthClass = width
            return face
        }
        let faces = [
            face("Barlow Condensed", "Thin", 3),
            face("Barlow Condensed", "Regular", 3),
            face("Interstate", "Regular", 5),
            face("Interstate", "Condensed", 3)
        ]
        let shown = ResearchMessage(
            id: 4,
            chatID: 1,
            role: "assistant",
            text: "Die Liste Condensed enthält Barlow Condensed und Interstate.",
            suggestions: [
                ResearchSuggestion(family: "Barlow Condensed", role: "", reason: "Thin, Regular"),
                ResearchSuggestion(family: "Interstate", role: "", reason: "Regular")
            ],
            createdAt: Date()
        )
        let turn = ResearchDialogue.followUp(
            history: [shown, userMessage("Kannst du bitte alle schriftschnitte entfernen die ich nicht brauche? ich möchte nur condensed schnitte haben!")],
            faces: faces
        )
        XCTAssertEqual(turn?.listName, "Condensed")
        XCTAssertEqual(turn?.listReplaces, true)
        XCTAssertEqual(turn?.listFamilies, ["Barlow Condensed", "Barlow Condensed", "Interstate"])
        XCTAssertEqual(turn?.listStyles, ["Thin", "Regular", "Condensed"])
        XCTAssertFalse(turn?.listStyles.contains("Regular") == true && turn?.listFamilies.last == "Interstate" && turn?.listStyles.last == "Regular")
    }

    func testResearchRetriesAListEditInsteadOfRefusing() {
        func face(_ family: String, _ style: String, _ width: Int) -> FontFace {
            var face = sampleFace(path: "/tmp/\(family)-\(style).otf")
            face.family = family
            face.style = style
            face.widthClass = width
            return face
        }
        let faces = [
            face("Barlow Condensed", "Thin", 3),
            face("Interstate", "Regular", 5),
            face("Interstate", "Condensed", 3)
        ]
        let shown = ResearchMessage(
            id: 4, chatID: 1, role: "assistant",
            text: "Barlow Condensed und Interstate sind in der Liste.",
            suggestions: [
                ResearchSuggestion(family: "Barlow Condensed", role: "", reason: "Thin"),
                ResearchSuggestion(family: "Interstate", role: "", reason: "Regular")
            ],
            createdAt: Date()
        )
        let ask = userMessage("Kannst du bitte alle schriftschnitte entfernen die ich nicht brauche? ich möchte nur condesed schnitte habe!")
        let refusal = ResearchMessage(
            id: 6, chatID: 1, role: "assistant",
            text: "Nein, ich kann Schnitte aus deiner Bibliothek nicht löschen oder entfernen.",
            suggestions: [ResearchSuggestion(family: "Agenda", role: "", reason: "MediumCondensed")],
            createdAt: Date()
        )
        let turn = ResearchDialogue.followUp(
            history: [shown, ask, refusal, userMessage("Kannst du das jetzt?")],
            faces: faces
        )
        XCTAssertEqual(turn?.listName, "Condensed")
        XCTAssertEqual(turn?.listReplaces, true)
        XCTAssertEqual(turn?.listFamilies, ["Barlow Condensed", "Interstate"])
        XCTAssertEqual(turn?.listStyles, ["Thin", "Condensed"])
        XCTAssertFalse(turn?.text.contains("löschen") ?? true)
        XCTAssertTrue(ResearchDialogue.isRefusal("Nein, ich kann Schnitte nicht löschen oder entfernen."))
    }

    func testResearchCleansTheNamedListEvenInANewChat() {
        func face(_ family: String, _ style: String, _ width: Int) -> FontFace {
            var face = sampleFace(path: "/tmp/\(family)-\(style).otf")
            face.family = family
            face.style = style
            face.widthClass = width
            return face
        }
        let thin = face("Barlow Condensed", "Thin", 3)
        let regular = face("Interstate", "Regular", 5)
        let condensed = face("Interstate", "Condensed", 3)
        let list = ResearchList(name: "Condensed", identities: [thin.identity, regular.identity, condensed.identity])
        let turn = ResearchDialogue.followUp(
            history: [userMessage("kannst du mir die liste \"Condesed\" nur mit condesed schnitten aufräumen?")],
            faces: [thin, regular, condensed],
            lists: [list]
        )
        XCTAssertEqual(turn?.listName, "Condensed")
        XCTAssertEqual(turn?.listReplaces, true)
        XCTAssertEqual(turn?.listFamilies, ["Barlow Condensed", "Interstate"])
        XCTAssertEqual(turn?.listStyles, ["Thin", "Condensed"])
        XCTAssertFalse(turn?.text.contains("keine") ?? true)
        XCTAssertFalse(turn?.text.contains("leider") ?? true)
    }

    func testResearchPacksTheShownFontsIntoTheNamedList() {
        let kept = ["Kept One", "Kept Two"]
        let shown = ResearchMessage(
            id: 4, chatID: 1, role: "assistant", text: "10 Condensed-Schnitte aus der Bibliothek.",
            suggestions: kept.map { ResearchSuggestion(family: $0, role: "", reason: "Condensed") },
            createdAt: Date()
        )
        var pochen = sampleFace(path: "/tmp/pochen.otf")
        pochen.family = "250908_Pochen"
        pochen.style = "Condensed"
        pochen.widthClass = 3
        let mistaken = ResearchMessage(
            id: 5, chatID: 1, role: "assistant",
            text: "Packen ist 250908_Pochen. Die Liste Condensed enthält 116 Schriften. Darunter Agenda und Akzidenz-Grotesk BQ.",
            suggestions: [ResearchSuggestion(family: "Agenda", role: "", reason: "")],
            createdAt: Date()
        )
        let turn = ResearchDialogue.followUp(
            history: [shown, mistaken, userMessage("ja kannst du mir bitte nur diese in die liste condensed packen?")],
            faces: [pochen]
        )
        XCTAssertEqual(turn?.listFamilies, kept)
        XCTAssertEqual(turn?.listName, "Condensed")
        XCTAssertEqual(turn?.listReplaces, true)
        XCTAssertFalse(turn?.text.contains("Pochen") ?? true)
        XCTAssertFalse(turn?.text.contains("116") ?? true)
    }

    func testResearchKeepsOnlyTheFontsJustShown() {
        let names = (1...10).map { "Kept \($0)" }
        let shown = ResearchMessage(
            id: 4,
            chatID: 1,
            role: "assistant",
            text: "10 Condensed-Schnitte aus der Bibliothek.",
            suggestions: names.map { ResearchSuggestion(family: $0, role: "", reason: "Condensed") },
            createdAt: Date()
        )
        let turn = ResearchDialogue.followUp(
            history: [shown, userMessage("due nehm ich. kannst du die condesed liste ausmisten un nur noch diese 10 drin lassen")],
            faces: []
        )
        XCTAssertEqual(turn?.listFamilies, names)
        XCTAssertEqual(turn?.listName, "Condensed")
        XCTAssertEqual(turn?.listReplaces, true)
        XCTAssertFalse(turn?.text.contains("Andere aus der Bibliothek") ?? true)
    }

    func testResearchPicksTenCondensedCutsDespiteTypos() {
        func face(_ family: String, _ style: String, _ width: Int, _ weight: Int = 400) -> FontFace {
            var face = sampleFace(path: "/tmp/\(family)-\(style).otf")
            face.family = family
            face.style = style
            face.fullName = "\(family) \(style)"
            face.widthClass = width
            face.weightClass = weight
            return face
        }
        var faces: [FontFace] = (1...12).map { index in
            face(String(format: "Family %02d", index), "Condensed", 3)
        }
        faces.append(face("Akzidenz-Grotesk BQ", "Condensed", 3))
        faces.append(face("Akzidenz-Grotesk BQ", "Bold Condensed", 3, 700))
        faces.append(face("Gill Sans MT Pro", "Condensed", 5))
        faces.append(face("Helvetica", "Regular", 5))
        let ask = userMessage("Kannst du mir 10 unterschiedliche condesed schriften heraussuchen")
        let list = ResearchDialogue.libraryAnswer(history: [ask], faces: faces)
        XCTAssertEqual(list?.suggestions.count, 10)
        XCTAssertEqual(list?.listFamilies.count, 10)
        XCTAssertTrue(list?.suggestions.allSatisfy { $0.reason.contains("Condensed") } ?? false)
        XCTAssertFalse(list?.text.contains("verwendet") ?? true)
        XCTAssertFalse(list?.listFamilies.contains("Helvetica") ?? true)
        let shown = ResearchMessage(
            id: 3,
            chatID: 1,
            role: "assistant",
            text: "Die folgenden Familien können für Condensed-Schriften verwendet werden.",
            suggestions: [
                ResearchSuggestion(family: "Akzidenz-Grotesk BQ", role: "", reason: ""),
                ResearchSuggestion(family: "Gill Sans MT Pro", role: "", reason: "")
            ],
            createdAt: Date()
        )
        let cuts = userMessage("kannst du mir auch die direkten condesed schnitte anzeigen")
        let detail = ResearchDialogue.libraryAnswer(history: [ask, shown, cuts], faces: faces)
        XCTAssertEqual(detail?.suggestions.map(\.family), ["Akzidenz-Grotesk BQ", "Gill Sans MT Pro"])
        XCTAssertTrue(detail?.suggestions.first?.reason.contains("Condensed") ?? false)
        XCTAssertTrue(detail?.suggestions.first?.reason.contains("Bold Condensed") ?? false)
        XCTAssertFalse(detail?.text.contains("unsafe") ?? true)
        let repaired = ResearchDialogue.repair("Detected content likely to be unsafe", history: [ask, shown, cuts], faces: faces)
        XCTAssertFalse(repaired.text.contains("unsafe"))
        XCTAssertFalse(repaired.suggestions.isEmpty)
    }

    func testResearchBuildsACondensedListFromTheLibrary() {
        func face(_ family: String, _ style: String, _ width: Int) -> FontFace {
            var face = sampleFace(path: "/tmp/\(family)-\(style).otf")
            face.family = family
            face.style = style
            face.fullName = "\(family) \(style)"
            face.widthClass = width
            return face
        }
        let faces = [
            face("Obviously Demo", "Condensed Black", 3),
            face("GT America", "Compressed", 2),
            face("NB Condensed", "Regular", 5),
            face("Helvetica", "Regular", 5)
        ]
        let ask = userMessage("Ich suche Condensed Schriften. Kannst du mir dafür eine Liste machen. Zum Beispiel mit Qbviously Demo condensed black")
        let list = ResearchDialogue.libraryAnswer(history: [ask], faces: faces)
        XCTAssertEqual(list?.listName, "Condensed")
        XCTAssertEqual(list?.listFamilies, ["Obviously Demo", "GT America", "NB Condensed"])
        XCTAssertTrue(list?.text.contains("Qbviously ist Obviously Demo") ?? false)
        XCTAssertFalse(list?.text.contains("Helvetica") ?? true)
        let books = """
        Hier sind einige Condensed Schriften, die du vielleicht interessieren könnten:
        1. Qbviously Demo - Ein Leitfaden zur Automatisierung von Datenanalyse.
        2. Condensed Chemistry - Eine Einführung in die Chemie.
        """
        let repaired = ResearchDialogue.repair(books, history: [ask], faces: faces)
        XCTAssertEqual(repaired.listName, "Condensed")
        XCTAssertFalse(repaired.text.contains("Chemie"))
        XCTAssertTrue(repaired.suggestions.contains { $0.family == "Obviously Demo" })
    }

    func testResearchBuildsAFrakturListAndAddsANamedFont() {
        let names = [
            "Fette Fraktur LT Std", "Gutenberg Textura", "Kleist-Fraktur",
            "UnifrakturCook", "Wilhelm Klingspor Gotisch LT Std", "SuperGroteskA-Rg"
        ]
        var faces = names.map { name in
            var face = sampleFace(path: "/tmp/\(name).otf")
            face.family = name
            face.fullName = name
            return face
        }
        var autobahn = sampleFace(path: "/tmp/autobahn.otf")
        autobahn.family = "Autobahn"
        autobahn.category = .serif
        faces.append(autobahn)
        let ask = userMessage("kannst du mir eine Liste erstellen mit Fraktur schriften?")
        let list = ResearchDialogue.libraryAnswer(history: [ask], faces: faces)
        XCTAssertEqual(list?.listName, "Fraktur")
        XCTAssertEqual(
            list?.listFamilies,
            ["Fette Fraktur LT Std", "Gutenberg Textura", "Kleist-Fraktur", "UnifrakturCook", "Wilhelm Klingspor Gotisch LT Std"]
        )
        XCTAssertFalse(list?.text.contains("ausschließlich") ?? true)
        let added = ResearchDialogue.followUp(
            history: [ask, userMessage("Kannst du die Autobahn noch mit hinzufügen?")],
            faces: faces
        )
        XCTAssertEqual(added?.listFamilies, ["Autobahn"])
        XCTAssertEqual(added?.listName, "Fraktur")
        XCTAssertFalse(added?.suggestions.contains { $0.family.contains("Grotesk") } ?? true)
    }

    func testResearchNamesDinamoABCFromTheLibrary() {
        var mono = sampleFace(path: "/tmp/abc-diatype-mono.otf")
        mono.family = "ABC Diatype Mono"
        mono.category = .mono
        mono.manufacturer = "Dinamo"
        var trial = sampleFace(path: "/tmp/abc-diatype-mono-trial.otf")
        trial.family = "ABC Diatype Mono Trial"
        trial.category = .mono
        trial.manufacturer = "Dinamo"
        var serif = sampleFace(path: "/tmp/recife.otf")
        serif.family = "Recife Text Trial"
        serif.category = .serif
        let turn = ResearchDialogue.libraryAnswer(
            history: [userMessage("Ich möchte aber einen schift des foundrys dinamo abc haben")],
            faces: [mono, trial, serif]
        )
        XCTAssertEqual(turn?.suggestions.first?.family, "ABC Diatype Mono")
        XCTAssertFalse(turn?.suggestions.contains { $0.family.contains("Recife") } ?? true)
        XCTAssertTrue(turn?.text.contains("Dinamo") ?? false)
    }

    func testResearchPairingIncludesSerifAndSans() {
        var serif = sampleFace(path: "/tmp/kepler.otf")
        serif.family = "Kepler"
        serif.category = .serif
        var sans = sampleFace(path: "/tmp/haas.otf")
        sans.family = "Neue Haas"
        sans.category = .sans
        let result = FontResearch.candidates(in: [serif, sans], query: "Pair a headline with body text")
        XCTAssertEqual(Set(result.map(\.category)), ["Serif", "Sans"])
    }

    func testImageMatchPrefersTheFaceThatWasRendered() throws {
        let root = "/System/Library/Fonts/Supplemental/"
        var times = sampleFace(path: root + "Times New Roman.ttf")
        times.family = "Times New Roman"
        var arial = sampleFace(path: root + "Arial.ttf")
        arial.family = "Arial"
        let image = SpecimenRenderer.line(filePath: times.filePath, faceIndex: 0, text: "Handgloves", pointSize: 64)
        let turn = FontImageMatch.match(image: try XCTUnwrap(image), faces: [times, arial], note: "Find fonts that look like this picture.")
        XCTAssertEqual(turn.suggestions.first?.family, "Times New Roman")
    }

    func testResearchChatRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))
        let chat = try database.createResearchChat(title: "New chat")
        let suggestion = ResearchSuggestion(family: "Kepler", role: "headline", reason: "Fits a wine label.")
        _ = try database.addResearchMessage(chatID: chat.id, role: "assistant", text: "Try Kepler.", suggestions: [suggestion])
        let loaded = try database.researchMessages(chatID: chat.id)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].suggestions.first?.family, "Kepler")
        try database.deleteResearchChat(id: chat.id)
        XCTAssertTrue(try database.allResearchChats().isEmpty)
    }

    func testSafePathComponentRejectsTraversal() {
        XCTAssertEqual(LibraryOrganizer.safePathComponent("../Geheim"), "..-Geheim")
        XCTAssertEqual(LibraryOrganizer.safePathComponent(".."), "Untitled")
        XCTAssertEqual(LibraryOrganizer.safePathComponent("  "), "Untitled")
    }

    func testNamesFillInAMissingCategory() {
        XCTAssertEqual(FontClassification.category(fromNames: ["Work Sans", "Regular"]), .sans)
        XCTAssertEqual(FontClassification.category(fromNames: ["TheSerif", "Light"]), .serif)
        XCTAssertEqual(FontClassification.category(fromNames: ["ABC Diatype Semi-Mono"]), .mono)
        XCTAssertEqual(FontClassification.category(fromNames: ["Fette Fraktur LT Std"]), .script)
        XCTAssertEqual(FontClassification.category(fromNames: ["GT Sectra Display"]), .display)
        XCTAssertEqual(FontClassification.category(fromNames: ["ZapfDingbats"]), .symbol)
        XCTAssertEqual(FontClassification.category(fromNames: ["Sans Serif"]), .sans)
        XCTAssertNil(FontClassification.category(fromNames: ["Slussen", "Regular"]))
        XCTAssertEqual(
            FontClassification.category(familyClass: 0, panose: [], monoTrait: false, names: ["Work Sans"]),
            .sans
        )
    }

    func testShapeSortsSystemFonts() {
        let root = "/System/Library/Fonts/Supplemental/"
        let samples: [(String, FontCategory)] = [
            ("Arial.ttf", .sans),
            ("Verdana.ttf", .sans),
            ("Times New Roman.ttf", .serif),
            ("Georgia.ttf", .serif),
            ("Courier New.ttf", .mono),
            ("Rockwell.ttc", .slab),
            ("AmericanTypewriter.ttc", .slab)
        ]
        for (name, expected) in samples {
            let path = root + name
            XCTAssertEqual(FontShape.measure(filePath: path, faceIndex: 0), expected, name)
        }
    }

    func testWebfontWOFFRoundTripKeepsArial() throws {
        let source = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
        let ttf = try Data(contentsOf: source)
        let woff = try XCTUnwrap(packedWOFF1(ttf))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fontso-arial.woff")
        try woff.write(to: file)
        let faces = FontIndexer.inspect(fileURL: file)
        XCTAssertEqual(faces.first?.family, "Arial")
        XCTAssertEqual(faces.first?.format, "woff")
        XCTAssertEqual(faces.first?.xHeight, 519)
        XCTAssertEqual(faces.first?.isWebfont, true)
        let unpacked = faces.first?.unpackedPath ?? ""
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpacked))
    }

    func testWebfontWOFF2RoundTripKeepsArial() throws {
        let source = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
        let ttf = try Data(contentsOf: source)
        let woff = try XCTUnwrap(packedWOFF2(ttf))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fontso-arial.woff2")
        try woff.write(to: file)
        let faces = FontIndexer.inspect(fileURL: file)
        XCTAssertEqual(faces.first?.family, "Arial")
        XCTAssertEqual(faces.first?.format, "woff2")
        XCTAssertEqual(faces.first?.xHeight, 519)
    }

    func testWebfontWOFF2RebuildsTransformedGlyf() throws {
        let transformed = transformedTriangle()
        let head = Data(count: 54)
        var hhea = Data(count: 36)
        hhea.writeBE(UInt16(1), at: 34)
        var maxp = Data(count: 6)
        maxp.writeBE(UInt16(1), at: 4)
        let hmtx = Data([0x03, 0x03, 0xE8])
        let tables: [(String, Data, Bool)] = [
            ("head", head, false),
            ("hhea", hhea, false),
            ("hmtx", hmtx, true),
            ("maxp", maxp, false),
            ("glyf", transformed, true),
            ("loca", Data(), true)
        ]
        var plain = Data()
        var directory = Data()
        for table in tables {
            plain.append(table.1)
            let version: UInt8
            if table.0 == "glyf" || table.0 == "loca" {
                version = table.2 ? 0 : 3
            } else {
                version = table.2 ? 1 : 0
            }
            directory.append(63 | (version << 6))
            directory.append(Data(table.0.utf8))
            directory.appendBase128(UInt32(max(table.1.count, 1)))
            if table.2 {
                directory.appendBase128(UInt32(table.1.count))
            }
        }
        let compressed = try XCTUnwrap(brotli(plain))
        var file = Data()
        file.append(Data("wOF2".utf8))
        file.append(contentsOf: [0x00, 0x01, 0x00, 0x00])
        file.appendBE(UInt32(0))
        file.appendBE(UInt16(tables.count))
        file.appendBE(UInt16(0))
        file.appendBE(UInt32(256))
        file.appendBE(UInt32(compressed.count))
        file.appendBE(UInt16(1))
        file.appendBE(UInt16(0))
        file.append(Data(repeating: 0, count: 20))
        file.append(directory)
        file.append(compressed)
        file.replaceBE(UInt32(file.count), at: 8)
        let sfnt = try XCTUnwrap(WebfontUnpacker.unpack(file))
        let stored = try XCTUnwrap(sfntTableList(sfnt))
        let glyf = try XCTUnwrap(stored.first { String(data: $0.tag, encoding: .ascii) == "glyf" }?.bytes)
        XCTAssertEqual(glyf.prefix(4), Data([0x00, 0x01, 0x00, 0x00]))
        let metrics = try XCTUnwrap(stored.first { String(data: $0.tag, encoding: .ascii) == "hmtx" }?.bytes)
        XCTAssertEqual(Array(metrics), [0x03, 0xE8, 0x00, 0x00])
        let rebuiltHead = try XCTUnwrap(stored.first { String(data: $0.tag, encoding: .ascii) == "head" }?.bytes)
        XCTAssertEqual(rebuiltHead.be16(50), 0)
    }

    private func transformedTriangle() -> Data {
        var data = Data()
        data.appendBE(UInt16(0))
        data.appendBE(UInt16(0))
        data.appendBE(UInt16(1))
        data.appendBE(UInt16(0))
        data.appendBE(UInt32(2))
        data.appendBE(UInt32(1))
        data.appendBE(UInt32(3))
        data.appendBE(UInt32(5))
        data.appendBE(UInt32(0))
        data.appendBE(UInt32(4))
        data.appendBE(UInt32(0))
        data.append(contentsOf: [0x00, 0x01])
        data.append(0x03)
        data.append(contentsOf: [0x01, 0x0B, 0x56])
        data.append(contentsOf: [0x00, 0x64, 0x31, 0x4F, 0x00])
        data.append(contentsOf: [0, 0, 0, 0])
        return data
    }

    func testWebfontRebuildsTransformedGlyph() throws {
        var data = Data()
        func u16(_ value: UInt16) {
            data.append(UInt8(value >> 8))
            data.append(UInt8(value & 0xFF))
        }
        func u32(_ value: UInt32) {
            data.append(UInt8((value >> 24) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }
        u16(0)
        u16(0)
        u16(1)
        u16(0)
        u32(2)
        u32(1)
        u32(3)
        u32(5)
        u32(0)
        u32(4)
        u32(0)
        data.append(contentsOf: [0x00, 0x01])
        data.append(0x03)
        data.append(contentsOf: [0x01, 0x0B, 0x56])
        data.append(contentsOf: [0x00, 0x64, 0x31, 0x4F, 0x00])
        data.append(contentsOf: [0, 0, 0, 0])
        let glyf = try XCTUnwrap(WebfontUnpacker.glyfTable(fromTransformed: data))
        XCTAssertEqual(Array(glyf.prefix(24)), [
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x64, 0x00, 0x50,
            0x00, 0x02, 0x00, 0x00, 0x31, 0x21, 0x01, 0x00, 0x64, 0xFF,
            0xCE, 0x00, 0x50, 0x00
        ])
    }

    private func packedWOFF1(_ sfnt: Data) -> Data? {
        guard let tables = sfntTableList(sfnt) else { return nil }
        var directory = Data()
        var body = Data()
        var offset = 44 + tables.count * 20
        for table in tables {
            let compressed = deflate(table.bytes) ?? table.bytes
            let stored = compressed.count < table.bytes.count ? compressed : table.bytes
            directory.append(table.tag)
            directory.appendBE(UInt32(offset))
            directory.appendBE(UInt32(stored.count))
            directory.appendBE(UInt32(table.bytes.count))
            directory.appendBE(UInt32(0))
            body.append(stored)
            offset += stored.count
            let pad = (4 - offset % 4) % 4
            body.append(Data(repeating: 0, count: pad))
            offset += pad
        }
        var file = Data()
        file.append(Data("wOFF".utf8))
        file.append(sfnt.prefix(4))
        file.appendBE(UInt32(44 + directory.count + body.count))
        file.appendBE(UInt16(tables.count))
        file.appendBE(UInt16(0))
        file.appendBE(UInt32(sfnt.count))
        file.appendBE(UInt16(1))
        file.appendBE(UInt16(0))
        file.append(Data(repeating: 0, count: 20))
        file.append(directory)
        file.append(body)
        return file
    }

    private func packedWOFF2(_ sfnt: Data) -> Data? {
        guard let tables = sfntTableList(sfnt) else { return nil }
        var plain = Data()
        var directory = Data()
        for table in tables {
            plain.append(table.bytes)
            let name = String(data: table.tag, encoding: .isoLatin1) ?? ""
            let nullVersion: UInt8 = (name == "glyf" || name == "loca") ? 3 : 0
            directory.append(63 | (nullVersion << 6))
            directory.append(table.tag)
            directory.appendBase128(UInt32(table.bytes.count))
        }
        guard let compressed = brotli(plain) else { return nil }
        var file = Data()
        file.append(Data("wOF2".utf8))
        file.append(sfnt.prefix(4))
        file.appendBE(UInt32(0))
        file.appendBE(UInt16(tables.count))
        file.appendBE(UInt16(0))
        file.appendBE(UInt32(sfnt.count))
        file.appendBE(UInt32(compressed.count))
        file.appendBE(UInt16(1))
        file.appendBE(UInt16(0))
        file.append(Data(repeating: 0, count: 20))
        file.append(directory)
        file.append(compressed)
        file.replaceBE(UInt32(file.count), at: 8)
        return file
    }

    private func sfntTableList(_ sfnt: Data) -> [(tag: Data, bytes: Data)]? {
        guard sfnt.count >= 12 else { return nil }
        let count = Int(sfnt.be16(4))
        guard sfnt.count >= 12 + count * 16 else { return nil }
        var tables: [(tag: Data, bytes: Data)] = []
        for index in 0..<count {
            let entry = 12 + index * 16
            let tag = sfnt.subdata(in: (sfnt.startIndex + entry)..<(sfnt.startIndex + entry + 4))
            let offset = Int(sfnt.be32(entry + 8))
            let length = Int(sfnt.be32(entry + 12))
            guard offset >= 0, length >= 0, offset + length <= sfnt.count else { return nil }
            let bytes = sfnt.subdata(in: (sfnt.startIndex + offset)..<(sfnt.startIndex + offset + length))
            tables.append((tag, bytes))
        }
        return tables
    }

    private func deflate(_ data: Data) -> Data? {
        encode(data, algorithm: COMPRESSION_ZLIB)
    }

    private func brotli(_ data: Data) -> Data? {
        encode(data, algorithm: COMPRESSION_BROTLI)
    }

    private func encode(_ data: Data, algorithm: compression_algorithm) -> Data? {
        let capacity = data.count + data.count / 4 + 64
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { output.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(output, capacity, base, data.count, nil, algorithm)
        }
        guard written > 0 else { return nil }
        return Data(bytes: output, count: written)
    }

    func testShapeRanksACloseSansAboveAScript() {
        let reference = proportionFace(
            id: 1, family: "Reference Sans", category: .sans,
            xHeight: 520, capHeight: 720, averageWidth: 450, contrast: 2
        )
        let close = proportionFace(
            id: 2, family: "Close Sans", category: .sans,
            xHeight: 530, capHeight: 710, averageWidth: 460, contrast: 2
        )
        let script = proportionFace(
            id: 3, family: "Far Script", category: .script,
            xHeight: 380, capHeight: 640, averageWidth: 620, contrast: 8, weight: 700
        )
        let sameFamily = proportionFace(
            id: 4, family: "Reference Sans", category: .sans,
            xHeight: 520, capHeight: 720, averageWidth: 450, contrast: 2, style: "Bold", weight: 700
        )
        let ranked = FormMatch.neighbors(of: reference, in: [reference, close, script, sameFamily])
        XCTAssertEqual(ranked.map(\.face.family), ["Close Sans"])
        XCTAssertGreaterThan(ranked[0].score, 70)
    }

    func testShapeReadsTheOutlineOfArial() throws {
        let outline = FontShape.outline(filePath: "/System/Library/Fonts/Supplemental/Arial.ttf", faceIndex: 0)
        let shape = try XCTUnwrap(outline)
        XCTAssertGreaterThan(shape.roundness, 0.7)
        XCTAssertLessThan(shape.roundness, 1.3)
        XCTAssertGreaterThan(shape.letterWidth, 0.3)
        XCTAssertLessThan(shape.letterWidth, 1.2)
    }

    func testFoundryPagesParseWithoutFontFiles() throws {
        let typecache = """
        <article class="clearfix"><a href="/Klim_Type_Foundry/"><dl>
        <dt>Klim Type Foundry</dt>
        <dd class="fonts"><span>Typefaces: </span>National&sbquo; Founders Grotesk&sbquo; Pitch</dd>
        </dl></a></article>
        """
        let fromCache = FoundryLookup.typecache(typecache, query: "founders grotesk")
        XCTAssertEqual(fromCache.map(\.name), ["Founders Grotesk"])
        let pictured = """
        <article class="clearfix"><a href="http://klim.co.nz/retail-fonts/founders-grotesk/">
        <figure><img src="/font-clusters/font_cluster_s/03_028_s.jpg"></figure></a>
        <dl><dt>Founders Grotesk</dt><dd>via Helvetica Alternatives</dd></dl></article>
        """
        let specimen = FoundryLookup.typecache(pictured, query: "founders grotesk")
        XCTAssertEqual(specimen.first?.imageURL?.absoluteString, "https://typecache.com/font-clusters/font_cluster/03_028.jpg")
        XCTAssertEqual(FoundryLookup.specimen(in: pictured, name: "Founders Grotesk")?.absoluteString, specimen.first?.imageURL?.absoluteString)
        XCTAssertEqual(FoundryLookup.specimenPage(in: pictured, name: "Founders Grotesk")?.host, "klim.co.nz")
        let withDirectory = """
        <article><a href="https://typecache.com/Klim_Type_Foundry/">Klim</a>
        <a href="https://klim.co.nz/retail-fonts/founders-grotesk/">
        <img src="/font-clusters/font_cluster_s/03_028_s.jpg"></a>
        <dt>Founders Grotesk</dt></article>
        """
        XCTAssertEqual(
            FoundryLookup.specimenPage(in: withDirectory, name: "Founders Grotesk")?.path,
            "/retail-fonts/founders-grotesk"
        )
        let displaay = """
        <a href="/typeface/aguzzo">Aguzzo</a>
        <a href="/typeface/avantt">Avantt</a>
        <a href="/about">About</a>
        """
        let avantt = FoundryLookup.typefacePage(on: URL(string: "https://displaay.net")!, name: "Avantt", html: displaay)
        XCTAssertEqual(avantt?.absoluteString, "https://displaay.net/typeface/avantt")
        XCTAssertEqual(FoundryLookup.linkedTypefaces(on: URL(string: "https://displaay.net")!, html: displaay), ["Aguzzo", "Avantt"])
        let releaseHTML = """
        <dt>News Fonts Release</dt>
        <dd><span>Date: </span>January 5, 2014</dd>
        <dd>New fonts from Displaay — Avantt.</dd>
        """
        let notes = FoundryLookup.releaseNotes(in: releaseHTML)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].text.contains("Avantt"))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        XCTAssertEqual(formatter.string(from: notes[0].date), "January 5, 2014")
        let klim = """
        <a href="/retail-fonts/founders-grotesk/">Founders Grotesk</a>
        <a href="/about">About</a>
        """
        let founders = FoundryLookup.typefacePage(on: URL(string: "https://klim.co.nz/")!, name: "Founders Grotesk", html: klim)
        XCTAssertEqual(founders?.path, "/retail-fonts/founders-grotesk")
        XCTAssertEqual(fromCache.first?.url.absoluteString, "https://typecache.com/Klim_Type_Foundry/")
        XCTAssertTrue(fromCache.first?.detail.contains("Not in your library") == true)
        XCTAssertFalse(typecache.contains(".otf"))

        let info = """
        <a href="https://typefoundries.info/">home</a>
        <a href="https://klim.co.nz/">Klim</a>
        """
        let fromInfo = FoundryLookup.foundriesInfo(info, query: "klim")
        XCTAssertEqual(fromInfo.map(\.name), ["Klim"])
        XCTAssertEqual(fromInfo.first?.url.host, "klim.co.nz")

        let directory = """
        <div class="foundry" data-sort-name="klim type">
          <a href="https://klim.co.nz">shot</a>
          <div class="foundry--name"><a href="https://klim.co.nz">Klim Type</a></div>
        </div>
        <div class="foundry" data-sort-name="other">
          <a href="https://example.com">Other</a>
        </div>
        """
        let fromDirectory = FoundryLookup.directory(directory, query: "klim")
        XCTAssertEqual(fromDirectory.map(\.name), ["Klim Type"])
        XCTAssertEqual(fromDirectory.first?.source, "Type Foundry Directory")

        let catalog = FoundryLookup.catalog(directoryHTML: directory, infoHTML: info)
        let klimDraft = try XCTUnwrap(catalog.first { $0.host == "klim.co.nz" })
        XCTAssertEqual(klimDraft.sources.sorted(), ["Type Foundry Directory", "typefoundries.info"])
        XCTAssertEqual(
            FoundryLookup.typefaces(ofFoundry: "Klim", in: typecache).sorted(),
            ["Founders Grotesk", "National", "Pitch"]
        )
        let mixed = """
        <article><dt>Type Together</dt><dd>Typefaces: Apercu, Baton</dd></article>
        <article><dt>Sharp Type</dt><dd>Typefaces: Sharp Sans</dd></article>
        """
        XCTAssertEqual(FoundryLookup.typefaces(ofFoundry: "Sharp Type", in: mixed), ["Sharp Sans"])
        let home = """
        <link rel="alternate" type="application/rss+xml" href="/feed">
        """
        XCTAssertEqual(
            FoundryLookup.feedURL(in: home, base: URL(string: "https://displaay.net")!)?.absoluteString,
            "https://displaay.net/feed"
        )
        let feed = """
        <rss><channel>
        <item>
          <title><![CDATA[Avantt]]></title>
          <link>https://displaay.net/typeface/avantt</link>
          <pubDate>Sun, 05 Jan 2014 00:00:00 +0000</pubDate>
        </item>
        <item>
          <title>Other foundry</title>
          <link>https://example.com/other</link>
          <pubDate>Mon, 06 Jan 2014 00:00:00 +0000</pubDate>
        </item>
        </channel></rss>
        """
        let posts = FoundryLookup.feedItems(in: feed, base: URL(string: "https://displaay.net")!)
        XCTAssertEqual(posts.map(\.title), ["Avantt", "Other foundry"])
        XCTAssertEqual(posts[0].url.path, "/typeface/avantt")
        XCTAssertNotNil(posts[0].published)
        XCTAssertEqual(posts[1].url.host, "example.com")
    }

    func testLicensesAndShapeTuningAreStored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))

        try database.setLicense(filePath: "/a.otf", faceIndex: 0, project: "Acme rebrand")
        try database.setLicense(filePath: "/a.otf", faceIndex: 1, project: "Acme rebrand")
        try database.setLicense(filePath: "/a.otf", faceIndex: 1, project: "")
        XCTAssertEqual(try database.allLicenses(), [FaceKey.make(path: "/a.otf", index: 0): "Acme rebrand"])

        let search = try database.createShapeSearch(title: "New shape", referenceIdentity: "a\n0", query: "Arial")
        var tuning = MatchTuning.standard
        tuning.capHeight = false
        tuning.letters = "Rg"
        try database.updateShapeTuning(id: search.id, tuning: tuning)
        XCTAssertEqual(try database.allShapeSearches().first?.tuning, tuning)
        XCTAssertEqual(tuning.letterList, ["R", "g"])
        XCTAssertEqual(MatchTuning.decode(""), .standard)
    }

    func testOpenTypeFeaturesAreListedAndTurnIntoSettings() throws {
        let arial = "/System/Library/Fonts/Supplemental/Arial.ttf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: arial), "Arial is not installed")
        let features = FontFeatures.list(filePath: arial, faceIndex: 0)
        let liga = try XCTUnwrap(features.first { $0.tag == "liga" })
        XCTAssertTrue(liga.isDefault, "Arial turns standard ligatures on by itself")
        XCTAssertEqual(liga.title, "Standard ligatures")
        XCTAssertFalse(features.contains { $0.tag == "kern" }, "kerning is not offered as a switch")

        // Leaving a feature at its default adds nothing; switching it adds one setting.
        XCTAssertTrue(FontFeatures.settings(features, overrides: [liga.id: true]).isEmpty)
        let off = FontFeatures.settings(features, overrides: [liga.id: false])
        XCTAssertEqual(off.count, 1)
        XCTAssertEqual(off.first?[kCTFontOpenTypeFeatureTag] as? String, "liga")
        XCTAssertEqual(off.first?[kCTFontOpenTypeFeatureValue] as? Int, 0)

        XCTAssertEqual(FontFeatures.title(for: "ss03", fallback: ""), "Stylistic set 3")
        XCTAssertEqual(FontFeatures.title(for: "zzzz", fallback: "Odd"), "Odd")
    }

    func testNestedListsKeepTheirParentAndMoveUpWhenDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))

        let client = try database.createGroup(name: "Client")
        let web = try database.createGroup(name: "Web", parentID: client.id)
        let icons = try database.createGroup(name: "Icons", parentID: web.id)
        XCTAssertEqual(client.parentID, 0)
        XCTAssertEqual(web.parentID, client.id)

        var loaded = Dictionary(uniqueKeysWithValues: try database.allGroups().map { ($0.id, $0.parentID) })
        XCTAssertEqual(loaded[web.id], client.id)
        XCTAssertEqual(loaded[icons.id], web.id)

        try database.setGroupParent(id: icons.id, parentID: 0)
        loaded = Dictionary(uniqueKeysWithValues: try database.allGroups().map { ($0.id, $0.parentID) })
        XCTAssertEqual(loaded[icons.id], 0)

        try database.setGroupParent(id: icons.id, parentID: web.id)
        try database.deleteGroup(id: web.id)
        loaded = Dictionary(uniqueKeysWithValues: try database.allGroups().map { ($0.id, $0.parentID) })
        XCTAssertNil(loaded[web.id])
        XCTAssertEqual(loaded[icons.id], client.id, "a deleted list's sub-lists move up to its parent")
    }

    func testShapeSearchesAndFoundryWatchSurviveARefresh() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))
        let search = try database.createShapeSearch(title: "New shape", referenceIdentity: "a\n0", query: "Arial")
        try database.renameShapeSearch(id: search.id, title: "Near Arial")
        let loaded = try database.allShapeSearches()
        XCTAssertEqual(loaded.map(\.title), ["Near Arial"])

        let klim = URL(string: "https://klim.co.nz")!
        let draft = FoundryDraft(name: "Klim Type", host: "klim.co.nz", url: klim, sources: ["Type Foundry Directory"])
        try database.replaceFoundryCatalog([draft])
        let stored = try XCTUnwrap(database.allFoundries().first)
        try database.setFoundryWatched(id: stored.id, watched: true)
        try database.replaceFoundryTypefaces(foundryID: stored.id, names: ["Söhne"])
        let renamed = FoundryDraft(name: "Klim", host: "klim.co.nz", url: klim, sources: ["Type Foundry Directory", "typefoundries.info"])
        try database.replaceFoundryCatalog([renamed])
        let again = try XCTUnwrap(database.allFoundries().first)
        XCTAssertTrue(again.watched)
        XCTAssertEqual(again.name, "Klim")
        XCTAssertEqual(try database.watchedTypefaces()[again.id], ["Söhne"])
    }

    func testCustomFoundriesAndNewsMarksSurviveARefresh() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))
        let added = try database.addFoundry(name: "Displaay", url: URL(string: "https://displaay.net/typeface/avantt")!)
        XCTAssertEqual(added.host, "displaay.net")
        XCTAssertEqual(added.url.path, "/")
        XCTAssertTrue(added.watched)
        XCTAssertTrue(added.sources.contains("Added"))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        let published = try XCTUnwrap(formatter.date(from: "January 5, 2014"))
        try database.upsertFoundryNotices(
            host: added.host,
            url: added.url,
            names: ["Avantt", "Azeret"],
            notes: [FoundryReleaseNote(date: published, text: "New fonts from Displaay — Avantt.")]
        )
        let notices = try database.foundryNotices()
        let avantt = try XCTUnwrap(notices.first { $0.name == "Avantt" })
        let azeret = try XCTUnwrap(notices.first { $0.name == "Azeret" })
        XCTAssertNotNil(avantt.publishedAt)
        XCTAssertNil(azeret.publishedAt)
        try database.setNoticeSeen(id: avantt.id, seen: true)
        try database.dismissNotice(id: azeret.id)

        let klim = URL(string: "https://klim.co.nz")!
        try database.replaceFoundryCatalog([
            FoundryDraft(name: "Klim", host: "klim.co.nz", url: klim, sources: ["Type Foundry Directory"])
        ])
        let hosts = Set(try database.allFoundries().map(\.host))
        XCTAssertTrue(hosts.contains("displaay.net"))
        XCTAssertTrue(hosts.contains("klim.co.nz"))
        let kept = try database.foundryNotices()
        XCTAssertEqual(kept.map(\.name), ["Avantt"])
        XCTAssertTrue(kept[0].seen)

        // A link corrected by hand survives the next sync from the foundry.
        let corrected = try XCTUnwrap(URL(string: "https://displaay.net/typeface/avantt-collection/"))
        try database.updateNotice(id: kept[0].id, name: "Avantt", url: corrected)
        try database.syncFoundryNotices(host: added.host, drafts: [
            FoundryNoticeDraft(name: "Avantt", url: added.url, publishedAt: nil)
        ])
        let synced = try XCTUnwrap(try database.foundryNotices().first { $0.name == "Avantt" })
        XCTAssertEqual(synced.url, corrected)

        // Saved links in lists can be corrected in place, in every list that holds them.
        let one = try database.createGroup(name: "One")
        let two = try database.createGroup(name: "Two")
        let page = try XCTUnwrap(URL(string: "https://example.com/old"))
        try database.addGroupLink(groupID: one.id, name: "Diatype", source: "Dinamo", url: page)
        try database.addGroupLink(groupID: two.id, name: "Diatype", source: "Dinamo", url: page)
        let newPage = try XCTUnwrap(URL(string: "https://abcdinamo.com/typefaces/diatype"))
        try database.updateGroupLinks(name: "Diatype", url: page, name: "ABC Diatype", source: "ABC Dinamo", url: newPage)
        let links = try database.allGroupLinks()
        XCTAssertEqual(links[one.id]?.map(\.name), ["ABC Diatype"])
        XCTAssertEqual(links[two.id]?.first?.url, newPage)
        XCTAssertEqual(links[two.id]?.first?.source, "ABC Dinamo")
    }

    func testCategorySourceFollowsTheDecisionAndReviewMarksPersist() throws {
        // The family class wins, then Panose, then a word in the name; nothing at all stays unclassified.
        let byClass = FontClassification.categoryWithSource(familyClass: 8, panose: [], monoTrait: false, names: ["Foo Serif"])
        XCTAssertEqual(byClass.category, .sans)
        XCTAssertEqual(byClass.source, .familyClass)
        let byPanose = FontClassification.categoryWithSource(familyClass: 0, panose: [2, 2, 5, 3, 5, 4, 5, 2, 3, 4], monoTrait: false)
        XCTAssertEqual(byPanose.category, .serif)
        XCTAssertEqual(byPanose.source, .panose)
        let byName = FontClassification.categoryWithSource(familyClass: 0, panose: [], monoTrait: false, names: ["Foo Grotesk"])
        XCTAssertEqual(byName.category, .sans)
        XCTAssertEqual(byName.source, .name)
        let byTrait = FontClassification.categoryWithSource(familyClass: 0, panose: [], monoTrait: true, names: ["Foo"])
        XCTAssertEqual(byTrait.category, .mono)
        XCTAssertEqual(byTrait.source, .trait)
        let nothing = FontClassification.categoryWithSource(familyClass: 0, panose: [], monoTrait: false, names: ["Foo"])
        XCTAssertEqual(nothing.category, .unclassified)
        XCTAssertEqual(nothing.source, .none)
        XCTAssertGreaterThan(CategorySource.familyClass.confidence, CategorySource.name.confidence)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try FontDatabase(fileURL: directory.appendingPathComponent("library.sqlite"))
        var face = proportionFace(id: 0, family: "Lyon", category: .serif, xHeight: 450, capHeight: 700, averageWidth: 520, contrast: 7)
        face.categorySource = .outline
        try database.replaceFonts([face])
        let stored = try XCTUnwrap(try database.allFonts().first)
        XCTAssertEqual(stored.categorySource, .outline, "the source travels with the row")

        // Filling in sources later reaches old rows and leaves the user's decisions alone.
        try database.updateCategorySources([(stored.id, .panose)])
        XCTAssertEqual(try database.allFonts().first?.categorySource, .panose)
        // A category set by hand is remembered as the user's decision.
        try database.setCategory(FontCategory.sans.rawValue, ids: [stored.id])
        XCTAssertEqual(try database.allFonts().first?.categorySource, .user)
        try database.updateCategorySources([(stored.id, .name)])
        XCTAssertEqual(try database.allFonts().first?.categorySource, .user)

        XCTAssertTrue(try database.reviewMarks().isEmpty)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try database.setReviewed([(stored.filePath, stored.faceIndex)], at: when)
        XCTAssertEqual(try database.reviewMarks()[stored.identity], when)
        // Rescanning the same file keeps the mark: it is keyed by path, not by row.
        try database.applyLibraryChanges(removedPaths: [], faces: [face])
        XCTAssertEqual(try database.reviewMarks()[stored.identity], when)
        try database.clearReviewMarks()
        XCTAssertTrue(try database.reviewMarks().isEmpty)
    }

    private func proportionFace(
        id: Int64,
        family: String,
        category: FontCategory,
        xHeight: Int,
        capHeight: Int,
        averageWidth: Int,
        contrast: Int,
        style: String = "Regular",
        weight: Int = 400
    ) -> FontFace {
        FontFace(
            id: id,
            filePath: "/tmp/\(family).otf",
            faceIndex: 0,
            family: family,
            style: style,
            fullName: family + " " + style,
            postscriptName: family,
            version: "1",
            manufacturer: "",
            designer: "",
            copyright: "",
            format: "otf",
            isVariable: false,
            weightClass: weight,
            widthClass: 5,
            category: category,
            isItalic: false,
            glyphCount: 200,
            axes: [],
            fileSize: 10,
            modifiedAt: Date(timeIntervalSince1970: 0),
            activation: .inactive,
            xHeight: xHeight,
            capHeight: capHeight,
            averageWidth: averageWidth,
            contrast: contrast
        )
    }

    private func userMessage(_ text: String) -> ResearchMessage {
        ResearchMessage(id: 2, chatID: 1, role: "user", text: text, suggestions: [], createdAt: Date())
    }

    private func sampleFace(path: String) -> FontFace {
        FontFace(
            id: 0,
            filePath: path,
            faceIndex: 0,
            family: "Demo",
            style: "Regular",
            fullName: "Demo Regular",
            postscriptName: "Demo-Regular",
            version: "1.000",
            manufacturer: "Fontso",
            designer: "",
            copyright: "",
            format: "otf",
            isVariable: true,
            weightClass: 400,
            widthClass: 5,
            category: .sans,
            isItalic: false,
            glyphCount: 120,
            axes: [VariationAxis(tag: 0x77676874, name: "Weight", min: 100, max: 900, defaultValue: 400)],
            fileSize: 4,
            modifiedAt: Date(timeIntervalSince1970: 0),
            activation: .inactive
        )
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBase128(_ value: UInt32) {
        var size = 1
        var rest = value
        while rest >= 128 {
            size += 1
            rest >>= 7
        }
        for index in 0..<size {
            var byte = UInt8((value >> (7 * (size - index - 1))) & 0x7F)
            if index < size - 1 { byte |= 0x80 }
            append(byte)
        }
    }

    mutating func writeBE(_ value: UInt16, at offset: Int) {
        let start = startIndex + offset
        self[start] = UInt8(value >> 8)
        self[start + 1] = UInt8(value & 0xFF)
    }

    mutating func replaceBE(_ value: UInt32, at offset: Int) {
        let start = startIndex + offset
        self[start] = UInt8((value >> 24) & 0xFF)
        self[start + 1] = UInt8((value >> 16) & 0xFF)
        self[start + 2] = UInt8((value >> 8) & 0xFF)
        self[start + 3] = UInt8(value & 0xFF)
    }

    func be16(_ offset: Int) -> UInt16 {
        let start = startIndex + offset
        return (UInt16(self[start]) << 8) | UInt16(self[start + 1])
    }

    func be32(_ offset: Int) -> UInt32 {
        let start = startIndex + offset
        return (UInt32(self[start]) << 24)
            | (UInt32(self[start + 1]) << 16)
            | (UInt32(self[start + 2]) << 8)
            | UInt32(self[start + 3])
    }
}
