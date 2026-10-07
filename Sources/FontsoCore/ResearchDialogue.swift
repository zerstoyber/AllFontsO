import Foundation

public struct ResearchList: Sendable, Equatable {
    public var name: String
    public var identities: [String]

    public init(name: String, identities: [String]) {
        self.name = name
        self.identities = identities
    }
}

public struct ResearchTurn: Sendable {
    public var text: String
    public var suggestions: [ResearchSuggestion]

    public var listName: String?
    public var listFamilies: [String]
    public var listStyles: [String]
    public var listReplaces: Bool

    public init(
        text: String,
        suggestions: [ResearchSuggestion],
        listName: String? = nil,
        listFamilies: [String] = [],
        listStyles: [String] = [],
        listReplaces: Bool = false
    ) {
        self.text = text
        self.suggestions = suggestions
        self.listName = listName
        self.listFamilies = listFamilies
        self.listStyles = listStyles
        self.listReplaces = listReplaces
    }
}

public enum ResearchDialogue {
    public static func followUp(
        history: [ResearchMessage],
        faces: [FontFace],
        lists: [ResearchList] = []
    ) -> ResearchTurn? {
        if let earlier = historyForRetry(history) {
            return followUp(history: earlier, faces: faces, lists: lists)
        }
        guard let latest = history.last(where: { $0.role == "user" })?.text else { return nil }
        if aboutTheAssistant(latest) {
            return ResearchTurn(text: assistantReply(latest), suggestions: [])
        }
        if asksAboutShownFiles(latest) {
            return filesOfShown(history, faces: faces)
        }
        let tokens = tokenSet(latest)
        let shown = shownFamilies(history)

        if wantsPreview(latest) {
            let list = previewFamilies(history)
            if list.isEmpty {
                return ResearchTurn(text: "Noch keine Schriften zum Nebeneinanderlegen.", suggestions: [])
            }
            return ResearchTurn(
                text: "Hier nebeneinander, gleicher Schriftgrad.",
                suggestions: list.map { ResearchSuggestion(family: $0, role: "preview", reason: "") }
            )
        }

        if tokens.contains(where: showWords.contains), let family = namedFamily(in: latest, faces: faces) {
            return ResearchTurn(
                text: "\(family) liegt in der Bibliothek.",
                suggestions: [ResearchSuggestion(family: family, role: "show", reason: "")]
            )
        }

        if wantsLikeness(latest) {
            return likeness(for: latest, history: history, faces: likenessFaces(latest, history: history, faces: faces))
        }

        if wantsToKeep(latest) {
            return keepShown(latest, history: history)
        }

        if wantsOnlyMatchingCuts(latest) {
            return keepMatchingCuts(latest, history: history, faces: faces, lists: lists)
        }

        if let cut = namedCut(in: latest, history: history, faces: faces) {
            return cut
        }

        if wantsAddition(latest) {
            guard let family = namedFamily(in: latest, faces: faces) else {
                return ResearchTurn(text: "Diese Schrift liegt nicht in der Bibliothek.", suggestions: [])
            }
            let name = previousListName(history) ?? "Research"
            return ResearchTurn(
                text: "\(family) ist in der Liste \(name).",
                suggestions: [ResearchSuggestion(family: family, role: "", reason: "")],
                listName: name,
                listFamilies: [family]
            )
        }

        if folded(latest).contains("sichtbar") || folded(latest).contains("\"lists\"") || folded(latest).contains("unter lists") {
            return ResearchTurn(
                text: "Die Liste steht links unter Lists, sobald sie angelegt ist. Ein Neustart ändert daran nichts. Wenn dort kein neuer Name steht, ist die Liste noch nicht angelegt.",
                suggestions: []
            )
        }

        let asksForMore = !folded(latest).contains("nur noch")
            && !folded(latest).contains("noch nicht")
            && (tokens.contains(where: moreWords.contains) || folded(latest).contains("slebe"))
        if asksForMore && !shown.isEmpty {
            let list = otherFamilies(faces: faces, query: brief(history), avoiding: shown)
            if list.isEmpty {
                return ResearchTurn(text: "Weitere Schriften in dieser Richtung habe ich nicht gefunden.", suggestions: [])
            }
            let same = tokens.contains(where: sameWords.contains) || folded(latest).contains("slebe")
            let text = same
                ? "Stimmt, das war noch einmal dieselbe. Andere: \(sentence(list))."
                : "Andere aus der Bibliothek: \(sentence(list))."
            return ResearchTurn(text: text, suggestions: chips(list))
        }

        return nil
    }

    /// Answers foundry, family, and pairing questions from the library. Apple's on-device model often refuses these.
    public static func libraryAnswer(history: [ResearchMessage], faces: [FontFace]) -> ResearchTurn? {
        guard let latest = history.last(where: { $0.role == "user" })?.text else { return nil }
        if let cuts = cutAnswer(for: latest, history: history, faces: faces) {
            return cuts
        }
        if let paired = pairing(for: latest, faces: faces, avoiding: []) {
            return paired
        }
        if let collected = collection(for: latest, faces: faces) {
            return collected
        }
        if let picked = widthPick(for: latest, faces: faces) {
            return picked
        }
        return foundryAnswer(latest, faces: faces)
    }

    public static func repair(
        _ reply: String,
        history: [ResearchMessage],
        faces: [FontFace],
        lists: [ResearchList] = []
    ) -> ResearchTurn {
        if let earlier = historyForRetry(history) {
            return repair(reply, history: earlier, faces: faces, lists: lists)
        }
        let latest = history.last(where: { $0.role == "user" })?.text ?? ""
        if aboutTheAssistant(latest) {
            return ResearchTurn(text: assistantReply(latest), suggestions: [])
        }
        if asksAboutShownFiles(latest) {
            return filesOfShown(history, faces: faces)
        }
        if wantsOnlyMatchingCuts(latest) {
            return keepMatchingCuts(latest, history: history, faces: faces, lists: lists)
        }
        let previous = history.last(where: { $0.role == "assistant" })?.text ?? ""
        let mentions = FontResearch.mentions(in: reply, faces: faces)
        let missedLibrary = ResearchLanguage.isFontRequest(latest) && mentions.isEmpty
        let useless = isCanned(reply) || isRefusal(reply) || isInstructionLeak(reply) || sameText(reply, previous) || missedLibrary
        guard useless else {
            return ResearchTurn(text: withoutMarkup(reply), suggestions: mentions)
        }
        if let cuts = cutAnswer(for: latest, history: history, faces: faces) {
            return cuts
        }
        if let picked = widthPick(for: latest, faces: faces) {
            return picked
        }
        if let collected = collection(for: latest, faces: faces) {
            return collected
        }
        if let paired = pairing(for: latest, faces: faces, avoiding: shownFamilies(history)) {
            return paired
        }
        let shown = shownFamilies(history)
        let list = otherFamilies(faces: faces, query: latest, avoiding: shown)
        if list.isEmpty {
            return ResearchTurn(text: "Dazu habe ich in der Bibliothek nichts Weiteres gefunden.", suggestions: [])
        }
        return ResearchTurn(
            text: "Aus der Bibliothek: \(sentence(list)).",
            suggestions: chips(list)
        )
    }

    private static func pairing(for query: String, faces: [FontFace], avoiding: [String]) -> ResearchTurn? {
        let parts = clauses(in: query).filter { clauseHasAsk($0) }
        guard parts.count >= 2 else { return nil }
        let german = ResearchLanguage.detect(query) == .german
        var used: [String] = avoiding
        var suggestions: [ResearchSuggestion] = []
        var lines: [String] = []
        for part in parts.prefix(3) {
            let hint = hintToken(in: part)
            let role = roleTitle(in: part, german: german)
            let ranked = FontResearch.candidates(in: faces, query: part, avoiding: used, limit: 40)
            let hinted = hint.isEmpty ? ranked : ranked.filter { card in
                folded(card.family).contains(hint) || folded(card.foundry).contains(hint)
            }
            let pool = hinted.isEmpty ? ranked : hinted
            let match = pool.first { !$0.isTrial } ?? pool.first
            guard let match else { continue }
            used.append(match.family)
            let foundryHit = !hint.isEmpty && (folded(match.family).contains(hint) || folded(match.foundry).contains(hint))
            let maker = match.foundry.isEmpty ? "" : " (\(match.foundry))"
            if !hint.isEmpty && !foundryHit {
                lines.append(german
                    ? "\(role): \(hint) liegt nicht in der Bibliothek. Stattdessen \(match.family)."
                    : "\(role): \(hint) is not in the library. Using \(match.family) instead.")
            } else {
                lines.append(german
                    ? "\(role): \(match.family)\(maker)."
                    : "\(role): \(match.family)\(maker).")
            }
            suggestions.append(ResearchSuggestion(family: match.family, role: role, reason: ""))
        }
        guard suggestions.count >= 2 else { return nil }
        return ResearchTurn(text: lines.joined(separator: " "), suggestions: suggestions)
    }

    private static func foundryAnswer(_ text: String, faces: [FontFace]) -> ResearchTurn? {
        let hints = nameHints(in: text)
        guard !hints.isEmpty else { return nil }
        let cards = FontResearch.candidates(in: faces, query: hints.joined(separator: " "), limit: 80)
        let matched = cards.filter { card in
            let haystack = "\(folded(card.family)) \(folded(card.foundry))"
            return hints.allSatisfy { haystack.contains($0) }
        }
        guard !matched.isEmpty else { return nil }
        var seen = Set<String>()
        var picked: [FamilyCandidate] = []
        let ordered = matched.sorted { lhs, rhs in
            if lhs.isTrial != rhs.isTrial { return !lhs.isTrial }
            return lhs.family.localizedStandardCompare(rhs.family) == .orderedAscending
        }
        for card in ordered {
            let key = stem(card.family)
            guard seen.insert(key).inserted else { continue }
            picked.append(card)
            if picked.count == 4 { break }
        }
        let german = ResearchLanguage.detect(text) == .german
        let maker = picked.first?.foundry.isEmpty == false ? picked[0].foundry : hints[0]
        let line = german
            ? "Von \(maker): \(sentence(picked.map(\.family)))."
            : "From \(maker): \(sentence(picked.map(\.family)))."
        return ResearchTurn(
            text: line,
            suggestions: picked.map { ResearchSuggestion(family: $0.family, role: "", reason: $0.foundry) }
        )
    }

    private static func nameHints(in text: String) -> [String] {
        let skip: Set<String> = [
            "kannst", "mochte", "möchte", "aber", "einen", "eine", "ein", "haben", "habe", "des", "dem", "den",
            "der", "die", "das", "von", "vom", "und", "mit", "als", "bitte", "mir", "dir", "du", "ich",
            "foundry", "foundrys", "foundries", "schrift", "schriften", "schift", "font", "fonts",
            "serif", "sans", "mono", "headline", "text", "trial", "neue", "regular"
        ]
        var seen = Set<String>()
        return folded(text).split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { token in
            token.count >= 3 && !skip.contains(token) && seen.insert(token).inserted
        }
    }

    private static func stem(_ family: String) -> String {
        folded(family)
            .replacingOccurrences(of: "unlicensed", with: " ")
            .replacingOccurrences(of: "variable", with: " ")
            .replacingOccurrences(of: "trial", with: " ")
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    private static func clauses(in query: String) -> [String] {
        let value = folded(query)
        if value.contains(" und dann ") {
            return value.components(separatedBy: " und dann ")
        }
        if value.contains(" and then ") {
            return value.components(separatedBy: " and then ")
        }
        let parts = value.components(separatedBy: " und ")
        if parts.filter(clauseHasAsk).count >= 2 { return parts }
        let english = value.components(separatedBy: " and ")
        if english.filter(clauseHasAsk).count >= 2 { return english }
        return [value]
    }

    private static func clauseHasAsk(_ clause: String) -> Bool {
        roleTitle(in: clause, german: true) != "Schrift" || categoryMentioned(clause)
    }

    private static func categoryMentioned(_ clause: String) -> Bool {
        ["serif", "serifen", "sans", "mono", "grotesk", "slab", "script", "display"].contains { clause.contains($0) }
    }

    private static func roleTitle(in clause: String, german: Bool) -> String {
        if ["headline", "schlagzeile", "uberschrift", "titel"].contains(where: { clause.contains($0) }) {
            return german ? "Headline" : "Headline"
        }
        if ["fliesstext", "fliestext", "fließtext", "lesetext", "lauftext", "body"].contains(where: { clause.contains($0) }) {
            return german ? "Fließtext" : "Body"
        }
        return german ? "Schrift" : "Font"
    }

    private static func hintToken(in clause: String) -> String {
        let skip: Set<String> = [
            "kannst", "du", "mir", "dir", "lieber", "eine", "ein", "font", "fonts", "schrift", "schriften",
            "schriftart", "mit", "als", "geben", "dann", "und", "bitte", "fuer", "fur", "die", "der", "das",
            "mal", "noch", "gerne", "text", "headline", "body", "serif", "serifenschrift", "mono", "monospace",
            "sans", "display", "fliesstext", "fliestext", "lesetext", "lauftext"
        ]
        return folded(clause).split { !$0.isLetter }.map(String.init).first { token in
            token.count >= 4 && !skip.contains(token) && !categoryMentioned(token)
        } ?? ""
    }

    private static func wantsPreview(_ text: String) -> Bool {
        let value = folded(text)
        return ["visualis", "vorschau", "preview", "nebeneinander", "gegenuber"].contains { value.contains($0) }
    }

    private static func previewFamilies(_ history: [ResearchMessage]) -> [String] {
        let useful = history.filter { message in
            message.role == "assistant" && !message.suggestions.isEmpty && !isDump(message.text)
        }
        let chosen = useful.last?.suggestions.map(\.family) ?? []
        if !chosen.isEmpty { return Array(chosen.prefix(4)) }
        return Array(shownFamilies(history).suffix(3))
    }

    private static func isDump(_ text: String) -> Bool {
        folded(text).hasPrefix("aus der bibliothek")
    }

    public static func isInstructionLeak(_ text: String) -> Bool {
        let value = folded(text)
        return value.contains("antworte ausschliesslich")
            || value.contains("wechsle nicht das thema")
            || value.contains("reply in the same language")
    }

    public static func isCanned(_ text: String) -> Bool {
        let value = folded(text)
        return value.contains("am besten zusagt") || value.contains("schriftfamilie, die dir")
    }

    public static func isRefusal(_ text: String) -> Bool {
        let value = folded(text)
        let markers = [
            "legale handlung", "unschad", "kann dir keine", "kann dir leider nicht",
            "nicht helfen", "richtlinien", "urheberrecht", "geistiges eigentum",
            "verstoss", "verstosst", "designvorlage", "ethisch", "unsafe", "nicht sicher",
            "nicht loschen", "nicht entfernen", "selbst in deinem", "nicht in deinen dateien"
        ]
        return markers.contains { value.contains($0) }
    }

    private static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        let left = folded(lhs)
        let right = folded(rhs)
        return !left.isEmpty && left == right
    }

    private static func wantsNewList(_ text: String) -> Bool {
        let value = folded(text)
        return value.contains("liste") || value.contains("erstelle") || value.contains("zusammenstell")
    }

    /// Tests supply measurements without opening font files. The app leaves this empty and reads Core Text.
    public static var metricsOverride: ((String, Int) -> (xHeight: Double, capHeight: Double, width: Double)?)?

    private static func wantsLikeness(_ text: String) -> Bool {
        let value = folded(text)
        if tokenSet(text).contains(where: { similarWords.contains($0) || $0.hasPrefix("ahnlich") }) { return true }
        return value.contains("x-hohe") || value.contains("xhohe") || value.contains("aussehen") || value.contains("eigenschaft")
    }

    private static func refersToShown(_ text: String) -> Bool {
        let folded = folded(text)
        return folded.contains("von welche")
            || folded.contains("von denen")
            || folded.contains("von diese")
            || folded.contains("davon")
            || folded.contains("aus diesen")
            || folded.contains("aus denen")
            || folded.contains("mitte von")
    }

    /// Keeps a comparison inside the fonts already on screen when the question points at them.
    private static func likenessFaces(_ query: String, history: [ResearchMessage], faces: [FontFace]) -> [FontFace] {
        guard refersToShown(query) else { return faces }
        let names = Set(subjectFamilies(history).map(folded))
        guard !names.isEmpty else { return faces }
        let limited = faces.filter { face in
            names.contains(folded(face.family)) || folded(query).contains(folded(face.family))
        }
        return limited.isEmpty ? faces : limited
    }

    private static func likeness(for query: String, history: [ResearchMessage], faces: [FontFace]) -> ResearchTurn {
        guard let reference = referenceFace(in: query, faces: faces) else {
            let german = ResearchLanguage.detect(query) == .german
            let text = german
                ? "Dazu finde ich keine Vergleichsschrift in der Bibliothek."
                : "I cannot find that font in the library."
            return ResearchTurn(text: text, suggestions: [])
        }
        let limit = min(requestedCount(query) ?? 8, 20)
        let topic = listTopic(query) ?? previousListName(history)
        let stored = reference.xHeight > 0 && metricsOverride == nil
        let pool = candidateFaces(like: reference, topic: topic, in: faces, useStoredMetrics: stored)
        let referenceMetrics = readMetrics(reference)
        let ranked = pool.map { face in
            (face, likenessDistance(reference, face, referenceMetrics, readMetrics(face)))
        }.sorted { $0.1 < $1.1 }
        let picked = ranked.prefix(limit).map(\.0)
        guard !picked.isEmpty else {
            let german = ResearchLanguage.detect(query) == .german
            let text = german
                ? "In dieser Richtung ist nichts Weiteres übrig."
                : "Nothing else is close to that."
            return ResearchTurn(text: text, suggestions: [])
        }
        let german = ResearchLanguage.detect(query) == .german
        let title = "\(reference.family) \(reference.style)".trimmingCharacters(in: .whitespaces)
        let wantsCloseXHeight = folded(query).contains("x-hohe") || folded(query).contains("xhohe")
        let close = wantsCloseXHeight ? picked.filter { face in
            guard let referenceMetrics, let metrics = readMetrics(face) else { return true }
            return abs(referenceMetrics.xHeight - metrics.xHeight) <= 0.045
        } : picked
        let chosen = close.isEmpty ? picked : close
        let measured = referenceMetrics.map { metrics in
            german
                ? "\(title) ist der Ausgangspunkt, mit X-Höhe \(mille(metrics.xHeight))/1000 und Versalhöhe \(mille(metrics.capHeight))/1000. Diese \(chosen.count) Schnitte liegen am nächsten."
                : "\(title) is the starting point, with x-height \(mille(metrics.xHeight))/1000 and cap height \(mille(metrics.capHeight))/1000. These \(chosen.count) cuts are the closest."
        }
        let text = measured ?? (german
            ? "Diese \(chosen.count) Schnitte liegen \(title) am nächsten."
            : "These \(chosen.count) cuts are the closest to \(title).")
        let replaces = folded(query).contains("beschrank") || folded(query).contains("liste") || folded(query).contains("auswahl")
        let cuts = folded(query).contains("schnitt")
        let listName = topic ?? listTopic(reference.style)
        return ResearchTurn(
            text: text,
            suggestions: chosen.map { face in
                ResearchSuggestion(family: face.family, role: "", reason: likenessReason(face, german: german))
            },
            listName: replaces ? listName : nil,
            listFamilies: replaces ? chosen.map(\.family) : [],
            listStyles: replaces && cuts ? chosen.map(\.style) : [],
            listReplaces: replaces && listName != nil
        )
    }

    private static func referenceFace(in text: String, faces: [FontFace]) -> FontFace? {
        guard let family = closestFamily(in: text, faces: faces)?.family else { return nil }
        let members = faces.filter { folded($0.family) == folded(family) }
        return members.min { lhs, rhs in
            styleRank(lhs, in: text) < styleRank(rhs, in: text)
        }
    }

    private static func styleRank(_ face: FontFace, in text: String) -> Int {
        let style = tokenSet(face.style)
        var score = 0
        for token in tokenSet(text) where token.count >= 4 {
            if style.contains(token) {
                score += 3
            } else if style.contains(where: { $0.count >= 5 && editDistance($0, token) <= 1 }) {
                score += 2
            }
        }
        if face.isItalic { score -= 2 }
        return -score
    }

    private static func candidateFaces(like reference: FontFace, topic: String?, in faces: [FontFace], useStoredMetrics: Bool) -> [FontFace] {
        var allowed: Set<String>?
        if let topic, let band = widthBand(topic) {
            allowed = Set(widthFamilies(band, in: faces).map(folded))
        }
        let grouped = Dictionary(grouping: faces) { folded($0.family) }
        var representatives: [FontFace] = []
        for (_, members) in grouped {
            guard folded(members[0].family) != folded(reference.family) else { continue }
            if let allowed, !allowed.contains(folded(members[0].family)) { continue }
            guard let face = members.min(by: { metaDistance($0, reference) < metaDistance($1, reference) }) else { continue }
            representatives.append(face)
        }
        if useStoredMetrics {
            return representatives.sorted { lhs, rhs in
                let left = abs(lhs.xHeight - reference.xHeight)
                let right = abs(rhs.xHeight - reference.xHeight)
                if left != right { return left < right }
                return metaDistance(lhs, reference) < metaDistance(rhs, reference)
            }
        }
        return representatives
            .sorted { metaDistance($0, reference) < metaDistance($1, reference) }
            .prefix(80)
            .map { $0 }
    }

    private static func metaDistance(_ face: FontFace, _ reference: FontFace) -> Double {
        var score = Double(abs(face.widthClass - reference.widthClass)) * 0.2
        score += Double(abs(face.weightClass - reference.weightClass)) / 2000
        if face.category != reference.category { score += 0.25 }
        if face.isItalic != reference.isItalic { score += 0.2 }
        if face.isTrial { score += 0.08 }
        return score
    }

    private static func likenessDistance(
        _ reference: FontFace,
        _ face: FontFace,
        _ referenceMetrics: (xHeight: Double, capHeight: Double, width: Double)?,
        _ metrics: (xHeight: Double, capHeight: Double, width: Double)?
    ) -> Double {
        var score = metaDistance(face, reference)
        if let referenceMetrics, let metrics {
            score += abs(referenceMetrics.xHeight - metrics.xHeight) * 3
            score += abs(referenceMetrics.capHeight - metrics.capHeight) * 2
            let widthScale = (referenceMetrics.width < 3 && metrics.width < 3) ? 1.5 : 0.2
            score += abs(referenceMetrics.width - metrics.width) * widthScale
        }
        if reference.contrast > 0, face.contrast > 0 {
            score += Double(abs(reference.contrast - face.contrast)) * 0.05
        }
        return score
    }

    private static func readMetrics(_ face: FontFace) -> (xHeight: Double, capHeight: Double, width: Double)? {
        if let metricsOverride {
            return metricsOverride(face.filePath, face.faceIndex)
        }
        if face.xHeight > 0 || face.capHeight > 0 {
            return (
                xHeight: Double(face.xHeight) / 1000,
                capHeight: Double(face.capHeight) / 1000,
                width: Double(face.averageWidth) / 1000
            )
        }
        return FontMeasurer.proportions(filePath: face.filePath, faceIndex: face.faceIndex)
    }

    private static func mille(_ value: Double) -> Int {
        Int((value * 1000).rounded())
    }

    private static func likenessReason(_ face: FontFace, german: Bool) -> String {
        guard let metrics = readMetrics(face) else { return face.style }
        let x = mille(metrics.xHeight)
        let cap = mille(metrics.capHeight)
        return german
            ? "\(face.style) · X-Höhe \(x)/1000 · Versalhöhe \(cap)/1000"
            : "\(face.style) · x-height \(x)/1000 · cap height \(cap)/1000"
    }

    private static let styleWords: Set<String> = [
        "condensed", "cond", "compressed", "narrow", "super", "supr", "bold", "light", "thin",
        "black", "italic", "regular", "medium", "semibold", "extra", "wide", "extended", "heavy"
    ]

    private static func namedCut(in text: String, history: [ResearchMessage], faces: [FontFace]) -> ResearchTurn? {
        let tokens = tokenSet(text).filter { $0.count >= 3 && !noise.contains($0) && !actionWords.contains($0) && !nameSkip.contains($0) }
        let askedStyle = tokens.contains { token in
            if styleWords.contains(token) { return true }
            if token.count >= 3 && styleWords.contains(where: { $0.hasPrefix(token) }) { return true }
            return token.count >= 4 && styleWords.contains { editDistance($0, token) <= 2 }
        }
        guard askedStyle else { return nil }
        let familyName = closestFamily(in: text, faces: faces, skipping: styleWords)?.family
            ?? shownFamilies(history).last
        guard let familyName else { return nil }
        let members = faces.filter { folded($0.family) == folded(familyName) }
        guard let face = members.max(by: { styleMatch($0, tokens: tokens) < styleMatch($1, tokens: tokens) }),
              styleMatch(face, tokens: tokens) >= 4 else { return nil }
        let german = ResearchLanguage.detect(text) == .german
        let adding = wantsAddition(text) || folded(text).contains("liste")
        let title = "\(face.family) \(face.style)"
        let reply = german
            ? (adding
                ? "Ich lege nur den Schnitt \(title) in die Liste."
                : "\(title) ist der Schnitt.")
            : (adding
                ? "I'll add only the \(title) cut."
                : "\(title) is the cut.")
        let list = adding ? (previousListName(history) ?? listTopic(text) ?? "Research") : nil
        return ResearchTurn(
            text: reply,
            suggestions: [ResearchSuggestion(family: face.family, role: "", reason: face.style)],
            listName: list,
            listFamilies: adding ? [face.family] : [],
            listStyles: adding ? [face.style] : [],
            listReplaces: false
        )
    }

    private static func styleMatch(_ face: FontFace, tokens: Set<String>) -> Int {
        let words = tokenSet(face.style)
        var score = 0
        for token in tokens {
            for word in words {
                if word == token { score += 4 }
                else if word.hasPrefix(token) && token.count >= 3 { score += 3 }
                else if word.count >= 4 && token.count >= 4 && editDistance(word, token) <= 2 { score += 3 }
            }
        }
        if !tokens.contains("italic") && face.isItalic { score -= 3 }
        return score
    }

    private static func wantsToKeep(_ text: String) -> Bool {
        let value = folded(text)
        if value.contains("nur noch")
            || value.contains("ausmist")
            || value.contains("drin lassen")
            || value.contains("drinlass")
            || value.contains("ubrig lassen")
            || value.contains("behalten") {
            return true
        }
        let editsList = value.contains("liste")
        let pointsAtShown = value.contains("nur diese") || value.contains("diese")
        let packing = value.contains("packen") || value.contains("hinein")
        return editsList && (pointsAtShown || packing)
    }

    private static func keepShown(_ query: String, history: [ResearchMessage]) -> ResearchTurn {
        let german = ResearchLanguage.detect(query) == .german
        let last = history.last { message in
            message.role == "assistant"
                && !message.suggestions.isEmpty
                && !folded(message.text).contains("darunter")
        }
        var suggestions = last?.suggestions ?? []
        var seen = Set<String>()
        suggestions = suggestions.filter { seen.insert(folded($0.family)).inserted }
        if let limit = requestedCount(query) {
            suggestions = Array(suggestions.prefix(limit))
        }
        guard !suggestions.isEmpty else {
            let text = german
                ? "Ich sehe keine Schriften, die ich in der Liste lassen kann."
                : "I don't see fonts to keep in the list."
            return ResearchTurn(text: text, suggestions: [])
        }
        let topic = listTopic(query) ?? previousListName(history) ?? "Research"
        let filed = filedCuts(from: suggestions)
        let noun = filed.styles.isEmpty ? (german ? "Schriften" : "fonts") : (german ? "Schnitte" : "cuts")
        let count = filed.styles.isEmpty ? suggestions.count : filed.styles.count
        let text = german
            ? "Ja. Die Liste \(topic) habe ich geleert und diese \(count) \(noun) hineingelegt."
            : "Done. I cleared \(topic) and put these \(count) \(noun) in it."
        return ResearchTurn(
            text: text,
            suggestions: filed.suggestions,
            listName: topic,
            listFamilies: filed.families,
            listStyles: filed.styles,
            listReplaces: true
        )
    }

    /// A list can hold one cut. Each named style becomes its own entry.
    private static func filedCuts(from suggestions: [ResearchSuggestion]) -> (suggestions: [ResearchSuggestion], families: [String], styles: [String]) {
        var filed: [ResearchSuggestion] = []
        var families: [String] = []
        var styles: [String] = []
        for suggestion in suggestions {
            let names = styleNames(suggestion)
            if names.isEmpty {
                filed.append(suggestion)
                families.append(suggestion.family)
                continue
            }
            for name in names {
                filed.append(ResearchSuggestion(family: suggestion.family, role: suggestion.role, reason: name))
                families.append(suggestion.family)
                styles.append(name)
            }
        }
        return (filed, families, styles)
    }

    /// "Kannst du das jetzt?" repeats the last real request instead of asking the model again.
    private static func asksToRetry(_ text: String) -> Bool {
        let value = folded(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 48 else { return false }
        return value.contains("das jetzt")
            || value.contains("jetzt nochmal")
            || value.contains("kannst du das")
            || value.contains("mach das")
            || value.contains("tu das")
            || value.contains("geht das")
            || value == "und jetzt"
            || value == "und jetzt?"
            || value == "nochmal"
            || value == "nochmal?"
    }

    private static func historyForRetry(_ history: [ResearchMessage]) -> [ResearchMessage]? {
        let users = history.enumerated().filter { $0.element.role == "user" }
        guard let latest = users.last, asksToRetry(latest.element.text) else { return nil }
        guard let prior = users.dropLast().last(where: { !asksToRetry($0.element.text) }) else { return nil }
        return Array(history[...prior.offset])
    }

    private static func wantsOnlyMatchingCuts(_ text: String) -> Bool {
        let value = folded(text)
        guard value.contains("schnitt"), listTopic(text) != nil else { return false }
        return value.contains("entfernen") || value.contains("nicht brauche") || value.contains("nur ")
            || value.contains("aufraum") || value.contains("leeren") || value.contains("sauber")
    }

    private static func namedList(in text: String, lists: [ResearchList]) -> ResearchList? {
        let haystack = folded(text)
        let ranked = lists.sorted { $0.name.count > $1.name.count }
        if let contained = ranked.first(where: { haystack.contains(folded($0.name)) && $0.name.count >= 3 }) {
            return contained
        }
        let tokens = tokenSet(text).filter { $0.count >= 5 }
        var best: (ResearchList, Int)?
        for list in lists {
            let name = folded(list.name)
            guard name.count >= 5 else { continue }
            for token in tokens {
                let distance = editDistance(token, name)
                guard distance <= 1 else { continue }
                if best == nil || distance < best!.1 {
                    best = (list, distance)
                }
            }
        }
        return best?.0
    }

    /// Replaces a named list, or the families already in the chat, with the matching cuts.
    private static func keepMatchingCuts(
        _ query: String,
        history: [ResearchMessage],
        faces: [FontFace],
        lists: [ResearchList]
    ) -> ResearchTurn {
        let german = ResearchLanguage.detect(query) == .german
        let topic = listTopic(query) ?? previousListName(history) ?? "Condensed"
        let list = namedList(in: query, lists: lists)
        var pairs: [(String, String)] = []
        var seen = Set<String>()
        let pool: [FontFace]
        if let list {
            let known = Dictionary(faces.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
            pool = list.identities.compactMap { known[$0] }.filter { faceMatches(topic, $0) }
        } else {
            let names = Set(subjectFamilies(history).map(folded))
            let matches = faces.filter { names.contains(folded($0.family)) && faceMatches(topic, $0) }
            let romans = matches.filter { !$0.isItalic }
            pool = (romans.isEmpty ? matches : romans).sorted { $0.weightClass < $1.weightClass }
        }
        for face in pool {
            let key = folded(face.family) + "\n" + folded(face.style)
            guard seen.insert(key).inserted else { continue }
            pairs.append((face.family, face.style))
        }
        guard !pairs.isEmpty else {
            let text: String
            if let list {
                text = german
                    ? "In der Liste \(list.name) ist kein \(topic)-Schnitt."
                    : "The list \(list.name) has no \(topic) cut."
            } else {
                text = german
                    ? "In der letzten Auswahl finde ich keine \(topic)-Schnitte."
                    : "The last selection has no \(topic) cuts."
            }
            return ResearchTurn(text: text, suggestions: [])
        }
        let listTitle = list?.name ?? topic
        var order: [String] = []
        var stylesByFamily: [String: [String]] = [:]
        for pair in pairs {
            if stylesByFamily[pair.0] == nil { order.append(pair.0) }
            stylesByFamily[pair.0, default: []].append(pair.1)
        }
        let text = german
            ? "Die Liste \(listTitle) enthält jetzt nur diese \(pairs.count) \(topic)-Schnitte."
            : "The list \(listTitle) now has only these \(pairs.count) \(topic) cuts."
        return ResearchTurn(
            text: text,
            suggestions: order.prefix(12).map { name in
                let styles = (stylesByFamily[name] ?? []).prefix(6).joined(separator: ", ")
                return ResearchSuggestion(family: name, role: "", reason: styles)
            },
            listName: listTitle,
            listFamilies: pairs.map(\.0),
            listStyles: pairs.map(\.1),
            listReplaces: true
        )
    }

    private static func cutName(_ suggestion: ResearchSuggestion) -> String {
        let head = suggestion.reason.split(separator: "·", maxSplits: 1).first.map(String.init) ?? ""
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func styleNames(_ suggestion: ResearchSuggestion) -> [String] {
        cutName(suggestion)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func wantsAddition(_ text: String) -> Bool {
        let value = folded(text)
        return value.contains("hinzu") || value.contains("hinzuf") || value.contains(" dazu") || value.contains(" add ")
    }

    private static func listTopic(_ text: String) -> String? {
        let value = folded(text)
        let styles = [
            ("fraktur", "Fraktur"), ("blackletter", "Blackletter"), ("textura", "Textura"),
            ("schwabacher", "Schwabacher"), ("gotisch", "Gotisch"),
            ("condensed", "Condensed"), ("kondens", "Condensed"), ("compressed", "Condensed"),
            ("narrow", "Condensed"), ("schmal", "Condensed"),
            ("extended", "Extended"), ("expanded", "Extended"), ("breit", "Extended"),
            ("serif", "Serif"), ("mono", "Mono"), ("sans", "Sans")
        ]
        if let exact = styles.first(where: { value.contains($0.0) })?.1 {
            return exact
        }
        for token in tokenSet(text) where token.count >= 6 {
            if editDistance(token, "condensed") <= 1 || editDistance(token, "compressed") <= 1 {
                return "Condensed"
            }
            if editDistance(token, "extended") <= 1 || editDistance(token, "expanded") <= 1 {
                return "Extended"
            }
        }
        return nil
    }

    private static func previousListName(_ history: [ResearchMessage]) -> String? {
        let earlier = history.filter { $0.role == "user" }.dropLast()
        for message in earlier.reversed() {
            if let topic = listTopic(message.text) { return topic }
        }
        return nil
    }

    private static func collection(for query: String, faces: [FontFace]) -> ResearchTurn? {
        guard wantsNewList(query), let topic = listTopic(query) else { return nil }
        let blackletter = ["Fraktur", "Blackletter", "Textura", "Schwabacher", "Gotisch"].contains(topic)
        var families = blackletter ? blackletterFamilies(in: faces) : categoryFamilies(topic, in: faces)
        if let band = widthBand(topic) {
            families = widthFamilies(band, in: faces)
        }
        guard !families.isEmpty else {
            return ResearchTurn(text: "Dazu habe ich in der Bibliothek keine Schriften gefunden.", suggestions: [])
        }
        let example = closestFamily(in: query, faces: faces)
        families = ordered(families, example: example?.family, faces: faces)
        let german = ResearchLanguage.detect(query) == .german
        let shown = Array(families.prefix(8))
        let body = families.count <= shown.count
            ? (german
                ? "Die Liste \(topic) enthält \(families.count) Schriften: \(sentence(shown))."
                : "The list \(topic) has \(families.count) fonts: \(sentence(shown)).")
            : (german
                ? "Die Liste \(topic) enthält \(families.count) Schriften. Darunter \(sentence(shown))."
                : "The list \(topic) has \(families.count) fonts, including \(sentence(shown)).")
        let text = correction(example, german: german) + body
        return ResearchTurn(
            text: text,
            suggestions: shown.map { name in
                ResearchSuggestion(family: name, role: "", reason: cutSummary(name, topic: topic, faces: faces))
            },
            listName: topic,
            listFamilies: families
        )
    }

    private static func widthPick(for query: String, faces: [FontFace]) -> ResearchTurn? {
        guard let topic = listTopic(query), widthBand(topic) != nil else { return nil }
        guard ResearchLanguage.isFontRequest(query) else { return nil }
        let families = pickedFamilies(topic, query: query, faces: faces, fallback: requestedCount(query) ?? 8)
        guard !families.isEmpty else { return nil }
        return presentCuts(families, topic: topic, query: query, faces: faces, fileList: true)
    }

    private static func cutAnswer(for query: String, history: [ResearchMessage], faces: [FontFace]) -> ResearchTurn? {
        guard asksForCuts(query) else { return nil }
        let topic = listTopic(query) ?? listTopic(brief(history)) ?? "Condensed"
        guard widthBand(topic) != nil || ["Fraktur", "Blackletter", "Textura", "Schwabacher", "Gotisch"].contains(topic) else {
            return nil
        }
        let shown = shownFamilies(history)
        let families = shown.isEmpty
            ? pickedFamilies(topic, query: query, faces: faces, fallback: requestedCount(query) ?? 8)
            : shown
        let usable = families.filter { !cutLabels($0, topic: topic, faces: faces).isEmpty }
        guard !usable.isEmpty else { return nil }
        return presentCuts(usable, topic: topic, query: query, faces: faces, fileList: false)
    }

    private static func presentCuts(
        _ families: [String],
        topic: String,
        query: String,
        faces: [FontFace],
        fileList: Bool
    ) -> ResearchTurn {
        let german = ResearchLanguage.detect(query) == .german
        let text = german
            ? "\(families.count) \(topic)-Schnitte aus der Bibliothek."
            : "\(families.count) \(topic) cuts from the library."
        return ResearchTurn(
            text: text,
            suggestions: families.map { name in
                ResearchSuggestion(family: name, role: "", reason: cutSummary(name, topic: topic, faces: faces))
            },
            listName: fileList ? topic : nil,
            listFamilies: fileList ? families : []
        )
    }

    private static func pickedFamilies(_ topic: String, query: String, faces: [FontFace], fallback: Int) -> [String] {
        let names: [String]
        if let band = widthBand(topic) {
            names = widthFamilies(band, in: faces)
        } else if ["Fraktur", "Blackletter", "Textura", "Schwabacher", "Gotisch"].contains(topic) {
            names = blackletterFamilies(in: faces)
        } else {
            names = categoryFamilies(topic, in: faces)
        }
        let limit = min(max(requestedCount(query) ?? fallback, 1), 12)
        return diverse(names, faces: faces, limit: limit)
    }

    private static func asksForCuts(_ text: String) -> Bool {
        let value = folded(text)
        return value.contains("schnitt") || value.contains(" cut") || value.contains("cuts")
    }

    private static func requestedCount(_ text: String) -> Int? {
        for token in folded(text).split(whereSeparator: { !$0.isNumber }) {
            if let value = Int(token), (1...24).contains(value) { return value }
        }
        return nil
    }

    private static func cutSummary(_ family: String, topic: String, faces: [FontFace]) -> String {
        cutLabels(family, topic: topic, faces: faces).joined(separator: ", ")
    }

    private static func cutLabels(_ family: String, topic: String, faces: [FontFace]) -> [String] {
        let key = folded(family)
        let matches = faces.filter { face in
            folded(face.family) == key && faceMatches(topic, face)
        }
        let romans = matches.filter { !$0.isItalic }
        let pool = romans.isEmpty ? matches : romans
        var seen = Set<String>()
        let labels = pool.sorted { lhs, rhs in
            if lhs.weightClass != rhs.weightClass { return lhs.weightClass < rhs.weightClass }
            return lhs.style.localizedStandardCompare(rhs.style) == .orderedAscending
        }.compactMap { face -> String? in
            let label = face.style.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seen.insert(folded(label)).inserted else { return nil }
            return label
        }
        return Array(labels.prefix(4))
    }

    private static func faceMatches(_ topic: String, _ face: FontFace) -> Bool {
        if let band = widthBand(topic) { return matchesWidth(band, face) }
        if ["Fraktur", "Blackletter", "Textura", "Schwabacher", "Gotisch"].contains(topic) {
            let stems = ["fraktur", "textura", "schwabacher", "blackletter", "gotisch", "rotunda", "bastarda"]
            let haystack = folded("\(face.family) \(face.style) \(face.fullName) \(face.postscriptName)")
            return stems.contains { haystack.contains($0) }
        }
        return true
    }

    private static func diverse(_ names: [String], faces: [FontFace], limit: Int) -> [String] {
        let ranked = ordered(names, example: nil, faces: faces)
        let categoryOf = Dictionary(grouping: faces, by: { folded($0.family) }).compactMapValues { group in
            group.first?.category
        }
        var buckets: [FontCategory: [String]] = [:]
        for name in ranked {
            let category = categoryOf[folded(name)] ?? .unclassified
            buckets[category, default: []].append(name)
        }
        var result: [String] = []
        var index = 0
        while result.count < limit {
            var added = false
            for category in FontCategory.allCases {
                guard let list = buckets[category], index < list.count else { continue }
                result.append(list[index])
                added = true
                if result.count == limit { break }
            }
            if !added { break }
            index += 1
        }
        return result
    }

    private static func blackletterFamilies(in faces: [FontFace]) -> [String] {
        let stems = ["fraktur", "textura", "schwabacher", "blackletter", "gotisch", "rotunda", "bastarda"]
        return families(matchingAny: stems, in: faces)
    }

    private static func categoryFamilies(_ topic: String, in faces: [FontFace]) -> [String] {
        let wanted = FontCategory.allCases.first { folded($0.rawValue).contains(folded(topic)) }
        guard let wanted else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for face in faces where face.category == wanted {
            guard seen.insert(folded(face.family)).inserted else { continue }
            names.append(face.family)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func families(matchingAny stems: [String], in faces: [FontFace]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for face in faces {
            let haystack = folded("\(face.family) \(face.style) \(face.fullName) \(face.postscriptName)")
            guard stems.contains(where: { haystack.contains($0) }) else { continue }
            guard seen.insert(folded(face.family)).inserted else { continue }
            names.append(face.family)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func widthBand(_ topic: String) -> WidthBand? {
        switch topic {
        case "Condensed": return .condensed
        case "Extended": return .extended
        default: return nil
        }
    }

    private static func widthFamilies(_ band: WidthBand, in faces: [FontFace]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for face in faces where matchesWidth(band, face) {
            guard seen.insert(folded(face.family)).inserted else { continue }
            names.append(face.family)
        }
        return names
    }

    private static func matchesWidth(_ band: WidthBand, _ face: FontFace) -> Bool {
        let tokens = tokenSet("\(face.family) \(face.style) \(face.fullName) \(face.postscriptName)")
        switch band {
        case .condensed:
            if (1...4).contains(face.widthClass) { return true }
            return ["condensed", "compressed", "narrow", "cond", "cn"].contains { tokens.contains($0) }
        case .extended:
            if (6...9).contains(face.widthClass) { return true }
            return ["extended", "expanded", "wide"].contains { tokens.contains($0) }
        }
    }

    private static func closestFamily(in text: String, faces: [FontFace], skipping extra: Set<String> = []) -> (family: String, typed: String)? {
        let tokens = tokenSet(text).filter { $0.count >= 5 && !nameSkip.contains($0) && !actionWords.contains($0) && !extra.contains($0) }
        let families = Array(Set(faces.map(\.family)))
        var best: (family: String, typed: String, distance: Int)?
        for token in tokens {
            for family in families {
                let head = folded(family).split { !$0.isLetter }.first.map(String.init) ?? ""
                guard head.count >= 5 else { continue }
                let distance = editDistance(token, head)
                guard distance <= 2 else { continue }
                if best == nil || distance < best!.distance || (distance == best!.distance && family.count > best!.family.count) {
                    best = (family, token, distance)
                }
            }
        }
        return best.map { ($0.family, $0.typed) }
    }

    private static func correction(_ example: (family: String, typed: String)?, german: Bool) -> String {
        guard let example else { return "" }
        let head = folded(example.family).split { !$0.isLetter }.first.map(String.init) ?? ""
        guard example.typed != head else { return "" }
        let typed = example.typed.prefix(1).uppercased() + example.typed.dropFirst()
        return german ? "\(typed) ist \(example.family). " : "\(typed) is \(example.family). "
    }

    private static func ordered(_ names: [String], example: String?, faces: [FontFace]) -> [String] {
        let trials = trialFamilyKeys(in: faces)
        return names.sorted { lhs, rhs in
            let leftExample = example == lhs
            let rightExample = example == rhs
            if leftExample != rightExample { return leftExample }
            let leftTrial = trials.contains(folded(lhs))
            let rightTrial = trials.contains(folded(rhs))
            if leftTrial != rightTrial { return !leftTrial }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private static func trialFamilyKeys(in faces: [FontFace]) -> Set<String> {
        let grouped = Dictionary(grouping: faces) { folded($0.family) }
        return Set(grouped.compactMap { key, group in group.allSatisfy(\.isTrial) ? key : nil })
    }

    private static func otherFamilies(faces: [FontFace], query: String, avoiding: [String]) -> [String] {
        let skip = Set(avoiding.map(folded))
        if folded(query).contains("fraktur") || folded(query).contains("blackletter") || folded(query).contains("textura") || folded(query).contains("gotisch") {
            return blackletterFamilies(in: faces).filter { !skip.contains(folded($0)) }
        }
        if let topic = listTopic(query), let band = widthBand(topic) {
            return Array(widthFamilies(band, in: faces).filter { !skip.contains(folded($0)) }.prefix(8))
        }
        var seen = Set<String>()
        return FontResearch.candidates(in: faces, query: query, avoiding: avoiding, limit: 8).compactMap { card in
            let key = folded(card.family)
            guard seen.insert(key).inserted else { return nil }
            return card.family
        }.prefix(3).map { $0 }
    }

    private static func shownFamilies(_ history: [ResearchMessage]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for message in history {
            for suggestion in message.suggestions where seen.insert(folded(suggestion.family)).inserted {
                names.append(suggestion.family)
            }
        }
        return names
    }

    private static func brief(_ history: [ResearchMessage]) -> String {
        let requests = history.filter { $0.role == "user" && ResearchLanguage.isFontRequest($0.text) }.map(\.text)
        if let last = requests.last { return last }
        return history.filter { $0.role == "user" }.map(\.text).joined(separator: " ")
    }

    private static func namedFamily(in message: String, faces: [FontFace]) -> String? {
        let families = Array(Set(faces.map(\.family))).sorted { $0.count > $1.count }
        let haystack = folded(message)
        if let contained = families.first(where: { folded($0).count >= 4 && haystack.contains(folded($0)) }) {
            return contained
        }
        let tail = tokenSet(message).subtracting(noise).sorted().joined()
        guard tail.count >= 4 else { return nil }
        var best: (String, Int)?
        for family in families {
            let compact = folded(family).filter(\.isLetter)
            guard compact.count >= 4, abs(compact.count - tail.count) <= 3 else { continue }
            let distance = editDistance(tail, compact)
            guard distance <= 2 else { continue }
            if best == nil || distance < best!.1 {
                best = (family, distance)
            }
        }
        return best?.0
    }

    private static func chips(_ families: [String]) -> [ResearchSuggestion] {
        families.map { ResearchSuggestion(family: $0, role: "", reason: "") }
    }

    private static func sentence(_ families: [String]) -> String {
        switch families.count {
        case 0: return ""
        case 1: return families[0]
        case 2: return "\(families[0]) und \(families[1])"
        default:
            let head = families.dropLast().joined(separator: ", ")
            return "\(head) und \(families[families.count - 1])"
        }
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        Set(folded(text).split { !$0.isLetter }.map(String.init))
    }

    private static func asksAboutShownFiles(_ text: String) -> Bool {
        let folded = folded(text)
        let pointsBack = folded.contains("sind das")
            || folded.contains("sind die")
            || folded.contains("waren das")
            || folded.contains("waren die")
            || folded.contains("meinst du")
            || folded.contains("auch als")
            || folded.contains("gibt es die")
            || folded.contains("gibt es sie")
            || folded.contains("habe nach")
            || folded.contains("danach gefragt")
        let aboutFile = folded.contains("webfont")
            || folded.contains("woff")
            || folded.contains("otf")
            || folded.contains("ttf")
            || folded.contains("datei")
        return pointsBack && aboutFile
    }

    private static func asksAboutTheLastCards(_ text: String) -> Bool {
        let folded = folded(text)
        return folded.contains("sind das")
            || folded.contains("sind die")
            || folded.contains("waren das")
            || folded.contains("waren die")
    }

    private static func isFormatReply(_ text: String) -> Bool {
        let folded = folded(text)
        return folded.hasPrefix("nein")
            || folded.hasPrefix("ja. das sind")
            || folded.hasPrefix("aus der bibliothek")
            || folded.hasPrefix("nur ein teil")
            || folded.hasPrefix("no.")
            || folded.hasPrefix("yes.")
    }

    /// Fonts the conversation is actually about. A format check or a stray library list does not replace them.
    private static func subjectFamilies(_ history: [ResearchMessage]) -> [String] {
        let assistants = history.filter { $0.role == "assistant" && !$0.suggestions.isEmpty }
        let substantive = assistants.filter { !isFormatReply($0.text) }
        let source = substantive.last ?? assistants.last
        var names: [String] = []
        var seen = Set<String>()
        for suggestion in source?.suggestions ?? [] where seen.insert(folded(suggestion.family)).inserted {
            names.append(suggestion.family)
        }
        return names
    }

    private static func withoutMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
    }

    private static func filesOfShown(_ history: [ResearchMessage], faces: [FontFace]) -> ResearchTurn {
        let latest = history.last { $0.role == "user" }?.text ?? ""
        let names = asksAboutTheLastCards(latest)
            ? lastCardFamilies(history)
            : subjectFamilies(history)
        let german = ResearchLanguage.detect(latest) == .german
        guard !names.isEmpty else {
            let text = german
                ? "In der letzten Antwort sind keine Schriften zum Prüfen."
                : "The last answer has no fonts to check."
            return ResearchTurn(text: text, suggestions: [])
        }
        var lines: [String] = []
        var web = 0
        for name in names {
            let formats = Set(
                faces.filter { $0.family.caseInsensitiveCompare(name) == .orderedSame }.map { $0.format.lowercased() }
            ).sorted()
            if formats.contains("woff") || formats.contains("woff2") { web += 1 }
            let label: String
            if formats.isEmpty {
                label = german ? "nicht in der Bibliothek" : "not in the library"
            } else {
                label = formats.map { $0.uppercased() }.joined(separator: ", ")
            }
            lines.append("\(name): \(label)")
        }
        let intro: String
        if web == 0 {
            intro = german ? "Nein. Das sind keine WOFF-Dateien." : "No. Those are not WOFF files."
        } else if web == names.count {
            intro = german ? "Ja. Das sind Webfonts." : "Yes. Those are webfonts."
        } else {
            intro = german ? "Nur ein Teil davon sind Webfonts." : "Only some of those are webfonts."
        }
        let cards = names.map { ResearchSuggestion(family: $0, role: "", reason: "") }
        return ResearchTurn(
            text: intro + " " + lines.joined(separator: ". ") + ".",
            suggestions: cards
        )
    }

    private static func lastCardFamilies(_ history: [ResearchMessage]) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for suggestion in history.last(where: { $0.role == "assistant" })?.suggestions ?? [] where seen.insert(folded(suggestion.family)).inserted {
            names.append(suggestion.family)
        }
        return names
    }

    private static func aboutTheAssistant(_ text: String) -> Bool {
        let folded = folded(text)
        let asksHowItWorks = folded.contains("wie kann ich dich")
            || folded.contains("vorbereit")
            || folded.contains("welche daten")
            || folded.contains("andere ideen")
            || folded.contains("was kannst du")
            || folded.contains("wie funktionierst")
        return asksHowItWorks
    }

    private static func assistantReply(_ text: String) -> String {
        if ResearchLanguage.detect(text) == .german {
            return "Ich suche in deiner Bibliothek, sobald du eine Schrift, einen Schnitt, eine Breite oder eine Liste nennst. Gewicht, Breite, Kategorie und Foundry liegen schon am Schnitt. X-Höhe und Versalhöhe messe ich, wenn du Schriften vergleichen willst. Eine Frage an mich lege ich nicht als Schriften ab."
        }
        return "I search your library when you name a font, a cut, a width, or a list. Weight, width, category, and foundry are already on each cut. I measure x-height and cap height when you want fonts compared. A question about me does not add font cards."
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        var row = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var next = [i + 1]
            for (j, right) in b.enumerated() {
                let cost = left == right ? 0 : 1
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + cost))
            }
            row = next
        }
        return row[b.count]
    }

    private enum WidthBand {
        case condensed
        case extended
    }

    private static let actionWords: Set<String> = [
        "packen", "legen", "nehmen", "lassen", "bitte", "kannst", "diese", "diesen", "hinein"
    ]

    private static let nameSkip: Set<String> = [
        "kannst", "suche", "schriften", "schrift", "liste", "machen", "beispiel", "etwas", "anderes",
        "dafur", "bitte", "eine", "einen", "condensed", "compressed", "narrow", "extended", "expanded",
        "kondens", "schmal", "black", "bold", "light", "regular", "medium", "italic", "fonts", "font",
        "typeface", "familie", "family", "haben", "diese", "dieser"
    ]

    private static let showWords: Set<String> = ["zeig", "zeige", "zeigen", "anzeigen", "anzeige"]
    private static let similarWords: Set<String> = ["ahnlich", "ahnliche", "ahnlichen", "xhohe"]
    private static let moreWords: Set<String> = ["andere", "weitere", "selbe", "gleiche", "dieselbe", "zuerst"]
    private static let sameWords: Set<String> = ["selbe", "gleiche", "dieselbe", "zuerst"]
    private static let noise: Set<String> = [
        "kannst", "du", "mir", "bitte", "die", "der", "das", "ein", "eine", "schrift", "schriften",
        "anzeigen", "anzeige", "zeig", "zeige", "zeigen", "mal", "noch", "und", "ok", "ja", "ist"
    ]
}
