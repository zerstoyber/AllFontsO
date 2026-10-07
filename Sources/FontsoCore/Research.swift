import Foundation

public struct ShapeSearch: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var title: String
    public var referenceIdentity: String
    public var query: String
    public var updatedAt: Date
    /// Which measurements and letters this search compares.
    public var tuning: MatchTuning

    public init(
        id: Int64,
        title: String,
        referenceIdentity: String,
        query: String,
        updatedAt: Date,
        tuning: MatchTuning = .standard
    ) {
        self.id = id
        self.title = title
        self.referenceIdentity = referenceIdentity
        self.query = query
        self.updatedAt = updatedAt
        self.tuning = tuning
    }
}

public struct ResearchChat: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var title: String
    public var updatedAt: Date

    public init(id: Int64, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

public struct ResearchSuggestion: Codable, Hashable, Sendable, Identifiable {
    public var family: String
    public var role: String
    public var reason: String

    public var id: String { "\(family)\n\(role)\n\(reason)" }

    public init(family: String, role: String, reason: String) {
        self.family = family
        self.role = role
        self.reason = reason
    }
}

public struct ResearchMessage: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var chatID: Int64
    public var role: String
    public var text: String
    public var suggestions: [ResearchSuggestion]
    public var createdAt: Date

    public init(
        id: Int64,
        chatID: Int64,
        role: String,
        text: String,
        suggestions: [ResearchSuggestion],
        createdAt: Date,
        imagePath: String = ""
    ) {
        self.id = id
        self.chatID = chatID
        self.role = role
        self.text = text
        self.suggestions = suggestions
        self.createdAt = createdAt
        self.imagePath = imagePath
    }

    public var imagePath: String = ""
}

public struct FamilyCandidate: Hashable, Sendable {
    public var family: String
    public var category: String
    public var form: String
    public var foundry: String
    public var styles: String
    public var isVariable: Bool
    public var isAvailable: Bool
    public var isTrial: Bool

    public var line: String {
        let motion = isVariable ? "variable" : "static"
        let state = isTrial ? "trial" : (isAvailable ? "available" : "inactive")
        let maker = foundry.isEmpty ? "unknown foundry" : foundry
        return [family, category, form, styles, maker, motion, state]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }
}

public enum ResearchLanguage: Equatable {
    case german
    case english

    public static func detect(_ text: String) -> ResearchLanguage {
        let tokens = tokens(in: text)
        if text.range(of: "[äöüÄÖÜß]", options: .regularExpression) != nil {
            return .german
        }
        if tokens.contains(where: germanSignals.contains) {
            return .german
        }
        let common = tokens.filter(germanWords.contains)
        return common.count >= 2 ? .german : .english
    }

    public static func matches(_ language: ResearchLanguage, reply: String) -> Bool {
        switch language {
        case .english:
            return true
        case .german:
            return detect(reply) == .german
        }
    }

    public static func asksAboutGerman(_ text: String) -> Bool {
        let tokens = tokens(in: text)
        let asks = tokens.contains("kannst") || tokens.contains("sprichst") || tokens.contains("verstehst") || tokens.contains("kann")
        return asks && (tokens.contains("deutsch") || tokens.contains("deutsche") || tokens.contains("deutschen"))
    }

    public static func confirmsGerman(_ reply: String) -> Bool {
        let tokens = tokens(in: reply)
        return tokens.contains("ja") || tokens.contains("deutsch") || tokens.contains("kann") || tokens.contains("kannst")
    }

    public static func isFontRequest(_ text: String) -> Bool {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
        let keys = [
            "font", "schrift", "schnitt", "typeface", "serif", "serifen", "sans", "pairing", "paarung",
            "kombination", "logo", "plakat", "headline", "schriftart", "grotesk", "monospace",
            "x-height", "x-hohe", "kontrast", "contrast", "condensed", "schmal", "didone", "minuskel"
        ]
        return keys.contains { folded.contains($0) }
    }

    public var replyRule: String {
        switch self {
        case .german:
            return "Die letzte Nachricht ist Deutsch. Antworte ausschließlich auf Deutsch und genau auf diese Nachricht. Wechsle nicht das Thema und nicht die Sprache."
        case .english:
            return "Reply in the same language as the latest user message. Answer that message directly. Do not change the subject."
        }
    }

    private static let germanSignals: Set<String> = [
        "kannst", "deutsch", "deutsche", "deutschen", "möchte", "moechte", "bitte", "schrift", "schriften",
        "welche", "brauche", "für", "fuer", "nicht", "eine"
    ]

    private static let germanWords: Set<String> = [
        "ich", "du", "dir", "mir", "wir", "und", "der", "die", "das", "ein", "eine", "ist", "sind",
        "mit", "auf", "nicht", "für", "fuer", "was", "wie", "kann", "kannst", "deutsch", "habe", "hat"
    ]

    private static func tokens(in text: String) -> Set<String> {
        Set(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .split { !$0.isLetter }
            .map(String.init))
    }
}

public enum FontResearch {
    public static func mentions(in text: String, faces: [FontFace]) -> [ResearchSuggestion] {
        let foldedText = fold(text)
        let families = Array(Set(faces.map(\.family))).sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        var found: [ResearchSuggestion] = []
        var used = Set<String>()
        for family in families {
            let needle = fold(family)
            guard needle.count >= 3, !used.contains(needle), containsWord(needle, in: foldedText) else { continue }
            used.insert(needle)
            found.append(ResearchSuggestion(family: family, role: "", reason: ""))
            if found.count == 8 { break }
        }
        return found
    }

    public static func candidates(
        in faces: [FontFace],
        query: String,
        avoiding: [String] = [],
        limit: Int = 24
    ) -> [FamilyCandidate] {
        let buckets = families(from: faces, query: query)
        guard !buckets.isEmpty else { return [] }
        let folded = fold(query)
        let skipped = Set(avoiding.map(fold))
        let pairing = pairingWords.contains { folded.contains($0) }
        let wanted = wantedCategories(in: folded)
        let form = wantedForm(in: folded)
        let scored = buckets.map { bucket in
            (bucket: bucket, score: score(bucket, query: folded, wanted: wanted, form: form, skipped: skipped), mix: mix("\(folded)\n\(bucket.foldedFamily)"))
        }
        let ordered = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.mix != rhs.mix { return lhs.mix > rhs.mix }
            return lhs.bucket.family.localizedStandardCompare(rhs.bucket.family) == .orderedAscending
        }
        let fresh = ordered.filter { entry in
            let name = entry.bucket.foldedFamily
            return !skipped.contains(name) || folded.contains(name)
        }
        let pool = fresh.isEmpty ? ordered : fresh

        if pairing {
            return balanced(pool.map(\.bucket), limit: limit)
        }
        if let best = pool.first, best.score > 0 {
            return pool.prefix(limit).map { card($0.bucket) }
        }
        return balanced(pool.map(\.bucket), limit: min(limit, 12))
    }

    private static func families(from faces: [FontFace], query: String) -> [FamilyBucket] {
        let grouped = Dictionary(grouping: faces) { SearchIndex.shared.text(for: $0).family }
        let foldedQuery = fold(query)
        let terms = foldedQuery.split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
        return grouped.map { key, faces in
            let first = faces[0]
            let lead = faces.min { lhs, rhs in
                if lhs.isItalic != rhs.isItalic { return !lhs.isItalic }
                return abs(lhs.weightClass - 400) < abs(rhs.weightClass - 400)
            } ?? first
            let styles = uniqueStyles(faces, terms: terms)
            let foundry = faces.map(\.manufacturer).first { !$0.cleanedFontName.isEmpty } ?? ""
            let designer = faces.map(\.designer).first { !$0.cleanedFontName.isEmpty } ?? ""
            var tally: [FontCategory: Int] = [:]
            for face in faces { tally[face.category, default: 0] += 1 }
            let category = tally.max { $0.value < $1.value }?.key ?? first.category
            return FamilyBucket(
                family: first.family,
                foldedFamily: key,
                category: category,
                foundry: foundry,
                foldedFoundry: fold(foundry),
                designer: designer,
                foldedDesigner: fold(designer),
                styles: styles,
                styleText: faces.map { SearchIndex.shared.text(for: $0).style }.joined(separator: " "),
                isVariable: faces.contains(where: \.isVariable),
                isAvailable: faces.contains(where: \.activation.isAvailableToApps),
                isTrial: faces.allSatisfy(\.isTrial),
                contrast: lead.contrast,
                xHeight: lead.xHeight,
                widthClass: lead.widthClass,
                averageWidth: lead.averageWidth,
                coversCyrillic: faces.contains(where: \.coversCyrillic),
                coversGreek: faces.contains(where: \.coversGreek),
                form: FontPassport.form(of: lead, familyFaces: faces)
            )
        }
    }

    private static func uniqueStyles(_ faces: [FontFace], terms: [String]) -> [String] {
        var seen = Set<String>()
        let keyed = faces.map { face -> (face: FontFace, folded: String, hits: Int) in
            let folded = SearchIndex.shared.text(for: face).style
            let hits = terms.isEmpty ? 0 : terms.filter { folded.contains($0) }.count
            return (face, folded, hits)
        }
        let ordered = keyed.sorted { lhs, rhs in
            if lhs.hits != rhs.hits { return lhs.hits > rhs.hits }
            if lhs.face.isItalic != rhs.face.isItalic { return !lhs.face.isItalic }
            if lhs.face.weightClass != rhs.face.weightClass { return lhs.face.weightClass < rhs.face.weightClass }
            return lhs.face.style.localizedStandardCompare(rhs.face.style) == .orderedAscending
        }
        var styles: [String] = []
        for entry in ordered {
            if seen.insert(entry.folded).inserted {
                styles.append(entry.face.style)
            }
            if styles.count == 12 { break }
        }
        return styles
    }

    private static func balanced(_ ranked: [FamilyBucket], limit: Int) -> [FamilyCandidate] {
        let order: [FontCategory] = [.serif, .sans, .display, .script, .slab, .mono, .symbol, .unclassified]
        var picked: [FamilyBucket] = []
        var used = Set<String>()
        for category in order {
            let matches = ranked.filter { $0.category == category }
            let take = category == .serif || category == .sans ? 4 : 2
            for bucket in matches.prefix(take) where picked.count < limit {
                picked.append(bucket)
                used.insert(bucket.foldedFamily)
            }
        }
        if picked.count < limit {
            for bucket in ranked where picked.count < limit {
                if used.insert(bucket.foldedFamily).inserted {
                    picked.append(bucket)
                }
            }
        }
        return picked.map(card)
    }

    private static func score(
        _ bucket: FamilyBucket,
        query: String,
        wanted: Set<FontCategory>,
        form: FormWanted,
        skipped: Set<String>
    ) -> Int {
        var total = 0
        let family = bucket.foldedFamily
        let foundry = bucket.foldedFoundry
        let designer = bucket.foldedDesigner
        for term in query.split(whereSeparator: \.isWhitespace).map(String.init) where term.count >= 3 {
            if family.contains(term) { total += 14 }
            if foundry.contains(term) { total += 8 }
            if designer.contains(term) { total += 6 }
            if bucket.styleText.contains(term) { total += 4 }
        }
        if wanted.contains(bucket.category) { total += 10 }
        total += formScore(bucket, form)
        if (query.contains("variable") || query.contains("achse")) && bucket.isVariable { total += 6 }
        if bucket.isAvailable { total += 1 }
        if bucket.isTrial { total -= 16 }
        if (query.contains("serif") || query.contains("fliesstext") || query.contains("fliestext") || query.contains("body")),
           ["initial", "fraktur", "blackletter", "uncial"].contains(where: { family.contains($0) }) {
            total -= 24
        }
        if skipped.contains(family) && !query.contains(family) { total -= 40 }
        return total
    }

    private static func formScore(_ bucket: FamilyBucket, _ wanted: FormWanted) -> Int {
        var total = 0
        if let band = wanted.contrast {
            if FontPassport.contrastBand(bucket.contrast) == band {
                total += 10
            } else if bucket.contrast > 0 {
                total -= 8
            }
        }
        if let band = wanted.xHeight {
            if FontPassport.xHeightBand(bucket.xHeight) == band {
                total += 10
            } else if bucket.xHeight > 0 {
                total -= 8
            }
        }
        let namedNarrow = bucket.styleText.contains("condens") || familyMentionsNarrow(bucket)
        let namedWide = bucket.styleText.contains("expand") || bucket.foldedFamily.contains("expand")
        if wanted.narrow {
            if FontPassport.isNarrow(widthClass: bucket.widthClass, averageWidth: bucket.averageWidth) || namedNarrow {
                total += 10
            } else if FontPassport.isWide(widthClass: bucket.widthClass, averageWidth: bucket.averageWidth) {
                total -= 8
            }
        }
        if wanted.wide {
            if FontPassport.isWide(widthClass: bucket.widthClass, averageWidth: bucket.averageWidth) || namedWide {
                total += 10
            } else if FontPassport.isNarrow(widthClass: bucket.widthClass, averageWidth: bucket.averageWidth) {
                total -= 8
            }
        }
        if wanted.cyrillic, bucket.coversCyrillic { total += 8 }
        if wanted.greek, bucket.coversGreek { total += 8 }
        if wanted.fullWeight, bucket.form.contains("light to black") { total += 6 }
        return total
    }

    private static func familyMentionsNarrow(_ bucket: FamilyBucket) -> Bool {
        bucket.foldedFamily.contains("condens")
            || bucket.foldedFamily.contains("schmal")
            || bucket.foldedFamily.contains("compact")
    }

    private static func wantedCategories(in query: String) -> Set<FontCategory> {
        var wanted = Set<FontCategory>()
        for (category, words) in categoryWords where words.contains(where: { query.contains($0) }) {
            wanted.insert(category)
        }
        return wanted
    }

    private static func card(_ bucket: FamilyBucket) -> FamilyCandidate {
        FamilyCandidate(
            family: bucket.family,
            category: bucket.category.rawValue,
            form: bucket.form,
            foundry: bucket.foundry,
            styles: bucket.styles.joined(separator: ", "),
            isVariable: bucket.isVariable,
            isAvailable: bucket.isAvailable,
            isTrial: bucket.isTrial
        )
    }

    private static func wantedForm(in query: String) -> FormWanted {
        var wanted = FormWanted()
        if holds(highContrastWords, in: query) { wanted.contrast = .high }
        else if holds(lowContrastWords, in: query) { wanted.contrast = .low }
        else if holds(moderateContrastWords, in: query) { wanted.contrast = .moderate }

        if holds(highXHeightWords, in: query) { wanted.xHeight = .high }
        else if holds(lowXHeightWords, in: query) { wanted.xHeight = .low }
        else if holds(moderateXHeightWords, in: query) { wanted.xHeight = .moderate }

        wanted.narrow = holds(narrowWords, in: query)
        wanted.wide = holds(wideWords, in: query)
        if wanted.narrow && wanted.wide {
            wanted.narrow = false
            wanted.wide = false
        }
        wanted.cyrillic = holds(["cyrillic", "kyrillisch"], in: query)
        wanted.greek = holds(["griechisch"], in: query) || containsWord("greek", in: query)
        wanted.fullWeight = holds(["light to black", "thin to black", "full range"], in: query)
        return wanted
    }

    private static func holds(_ words: [String], in query: String) -> Bool {
        words.contains { word in
            if word.contains(" ") || word.count >= 5 { return query.contains(word) }
            return containsWord(word, in: query)
        }
    }

    private static func containsWord(_ needle: String, in text: String) -> Bool {
        var search = text.startIndex
        while let range = text.range(of: needle, range: search..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let beforeOK = before.map { !$0.isLetter && !$0.isNumber } ?? true
            let afterOK = after.map { !$0.isLetter && !$0.isNumber } ?? true
            if beforeOK && afterOK { return true }
            search = range.upperBound
        }
        return false
    }

    private static func fold(_ value: String) -> String {
        TextFold.fold(value)
    }

    private static func mix(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static let pairingWords = [
        "pair", "pairing", "combination", "combine", "alongside", "together",
        "kombination", "kombinier", "paarung", "zusammen", "gegensatz"
    ]

    private static let highContrastWords = [
        "high contrast", "didone", "modern face", "hochkontrast", "hoher kontrast",
        "hohen kontrast", "hohem kontrast", "starker strich", "starkem strich"
    ]
    private static let lowContrastWords = [
        "low contrast", "wenig kontrast", "monoline", "even stroke", "gleichmassig"
    ]
    private static let moderateContrastWords = [
        "moderate contrast", "medium contrast", "mittlerer kontrast", "mittleren kontrast"
    ]
    private static let highXHeightWords = [
        "high x-height", "large x-height", "hohe x-hohe", "hohen x-hohe", "hoher x-hohe",
        "hohe x hohe", "grosse minuskel"
    ]
    private static let lowXHeightWords = [
        "low x-height", "small x-height", "kleine x-hohe", "kleine minuskel", "niedrige x-hohe"
    ]
    private static let moderateXHeightWords = [
        "moderate x-height", "mittlere x-hohe"
    ]
    private static let narrowWords = [
        "condensed", "narrow", "compact", "schmal", "kompress", "enge", "enger", "enges", "eng"
    ]
    private static let wideWords = [
        "expanded", "extended", "extra expanded", "ultra expanded", "breit", "breite", "breiter"
    ]

    private static let categoryWords: [(FontCategory, [String])] = [
        (.serif, ["serif", "serifen", "antiqua", "garamond", "editorial", "wine", "wein", "luxury", "luxus", "classic", "klassisch", "elegant", "literary", "book", "buch"]),
        (.sans, ["sans", "serifenlos", "grotesk", "gothic", "modern", "interface", "clean", "klar", "swiss", "neutral"]),
        (.script, ["script", "schreibschrift", "handschrift", "handwriting", "calligraph", "kalligraph", "wedding", "hochzeit", "signature", "signatur"]),
        (.display, ["display", "poster", "plakat", "logo", "headline", "schlagzeile", "loud"]),
        (.mono, ["mono", "monospace", "code", "coding", "terminal", "technical", "technisch"]),
        (.slab, ["slab", "egyptienne"]),
        (.symbol, ["symbol", "dingbat", "icon", "piktogramm"])
    ]
}

private struct FamilyBucket {
    var family: String
    var foldedFamily: String
    var category: FontCategory
    var foundry: String
    var foldedFoundry: String
    var designer: String
    var foldedDesigner: String
    var styles: [String]
    var styleText: String
    var isVariable: Bool
    var isAvailable: Bool
    var isTrial: Bool
    var contrast: Int
    var xHeight: Int
    var widthClass: Int
    var averageWidth: Int
    var coversCyrillic: Bool
    var coversGreek: Bool
    var form: String
}

private struct FormWanted {
    var contrast: FontPassport.ContrastBand?
    var xHeight: FontPassport.XHeightBand?
    var narrow = false
    var wide = false
    var cyrillic = false
    var greek = false
    var fullWeight = false
}
