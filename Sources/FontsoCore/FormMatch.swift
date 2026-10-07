import Foundation

public struct FormNeighbor: Sendable, Identifiable, Equatable {
    public let face: FontFace
    public let score: Int

    public var id: Int64 { face.id }
}

/// Which measurements a shape search compares, and which letters it draws for the outline pass.
public struct MatchTuning: Sendable, Hashable, Codable {
    public var xHeight = true
    public var capHeight = true
    public var width = true
    public var weight = true
    public var contrast = true
    public var slant = true
    public var category = true
    public var compareLetters = true
    /// Letters whose drawn shapes are compared, up to eight.
    public var letters = "no"

    public static let standard = MatchTuning()
    public static let letterLimit = 8

    public init() {}

    public var isStandard: Bool { self == .standard }

    /// True when at least one stored measurement takes part. Without one, only the drawn letters rank the library.
    public var comparesProportions: Bool {
        xHeight || capHeight || width || weight || contrast || slant || category
    }

    public var comparesAnything: Bool { comparesProportions || !letterList.isEmpty }

    /// The letters that are actually drawn: unique, no spaces, from the Basic Multilingual Plane.
    public var letterList: [Character] {
        guard compareLetters else { return [] }
        var seen = Set<Character>()
        var list: [Character] = []
        for character in letters where !character.isWhitespace && character.utf16.count == 1 {
            if seen.insert(character).inserted { list.append(character) }
            if list.count == MatchTuning.letterLimit { break }
        }
        return list
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String) -> MatchTuning {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MatchTuning.self, from: data) else { return .standard }
        return decoded
    }

    private enum CodingKeys: String, CodingKey {
        case xHeight, capHeight, width, weight, contrast, slant, category, compareLetters, letters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        xHeight = try container.decodeIfPresent(Bool.self, forKey: .xHeight) ?? true
        capHeight = try container.decodeIfPresent(Bool.self, forKey: .capHeight) ?? true
        width = try container.decodeIfPresent(Bool.self, forKey: .width) ?? true
        weight = try container.decodeIfPresent(Bool.self, forKey: .weight) ?? true
        contrast = try container.decodeIfPresent(Bool.self, forKey: .contrast) ?? true
        slant = try container.decodeIfPresent(Bool.self, forKey: .slant) ?? true
        category = try container.decodeIfPresent(Bool.self, forKey: .category) ?? true
        compareLetters = try container.decodeIfPresent(Bool.self, forKey: .compareLetters) ?? true
        letters = try container.decodeIfPresent(String.self, forKey: .letters) ?? "no"
    }
}

/// Ranks other families by the proportions stored on each face, then by the drawn shapes of chosen letters.
public enum FormMatch {
    public static func neighbors(
        of reference: FontFace,
        in library: [FontFace],
        tuning: MatchTuning = .standard,
        limit: Int = 36
    ) -> [FormNeighbor] {
        guard tuning.comparesAnything else { return [] }
        let own = folded(reference.family)
        var byFamily: [String: [FontFace]] = [:]
        for face in library {
            let key = folded(face.family)
            if key.isEmpty || key == own { continue }
            if face.category == .symbol, reference.category != .symbol { continue }
            byFamily[key, default: []].append(face)
        }

        // Only the drawn letters count: hand every family on, the outline pass does the ranking.
        guard tuning.comparesProportions else {
            var all: [FormNeighbor] = []
            all.reserveCapacity(byFamily.count)
            for faces in byFamily.values {
                guard let face = representative(faces, like: reference) else { continue }
                all.append(FormNeighbor(face: face, score: 100))
            }
            all.sort(by: closer)
            return all
        }

        let wantsProportions = tuning.xHeight || tuning.capHeight || tuning.width
        let hasProportions = reference.xHeight > 0 && reference.averageWidth > 0
        let precise = wantsProportions && hasProportions
        var ranked: [FormNeighbor] = []
        ranked.reserveCapacity(min(byFamily.count, limit))
        for faces in byFamily.values {
            guard let face = representative(faces, like: reference) else { continue }
            var score = Int((100 - distance(face, reference, precise: precise, tuning: tuning)).rounded())
            score = min(100, max(0, score))
            if wantsProportions, !hasProportions { score = min(score, 70) }
            if score < 42 { continue }
            ranked.append(FormNeighbor(face: face, score: score))
        }
        ranked.sort(by: closer)
        if ranked.count > limit {
            ranked.removeLast(ranked.count - limit)
        }
        return ranked
    }

    /// Re-scores the families after drawing the chosen letters. Families whose font cannot draw a letter lose a little.
    public static func refine(
        _ neighbors: [FormNeighbor],
        reference: FontFace,
        tuning: MatchTuning = .standard,
        limit: Int = 36
    ) -> [FormNeighbor] {
        let letters = tuning.letterList.compactMap { $0.utf16.first }
        guard !letters.isEmpty else { return Array(neighbors.prefix(limit)) }
        let origin = FontShape.letterShapes(filePath: reference.filePath, faceIndex: reference.faceIndex, letters: letters)
        guard !origin.isEmpty else { return Array(neighbors.prefix(limit)) }

        var updated = neighbors
        for index in updated.indices {
            let face = updated[index].face
            let shapes = FontShape.letterShapes(filePath: face.filePath, faceIndex: face.faceIndex, letters: Array(origin.keys))
            var penalty = 0.0
            for (letter, reference) in origin {
                if let shape = shapes[letter] {
                    penalty += FontShape.difference(reference, shape)
                } else {
                    penalty += 14
                }
            }
            penalty /= Double(origin.count)
            let score = min(100, max(0, updated[index].score - Int(penalty.rounded())))
            updated[index] = FormNeighbor(face: face, score: score)
        }
        updated.sort(by: closer)
        if updated.count > limit {
            updated.removeLast(updated.count - limit)
        }
        return updated
    }

    private static func closer(_ lhs: FormNeighbor, _ rhs: FormNeighbor) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.face.family.localizedStandardCompare(rhs.face.family) == .orderedAscending
    }

    private static func representative(_ faces: [FontFace], like reference: FontFace) -> FontFace? {
        faces.min { lhs, rhs in
            styleDistance(lhs, reference) < styleDistance(rhs, reference)
        }
    }

    private static func styleDistance(_ face: FontFace, _ reference: FontFace) -> Int {
        let italic = face.isItalic == reference.isItalic ? 0 : 1_000
        return italic + abs(face.weightClass - reference.weightClass) / 10 + abs(face.widthClass - reference.widthClass) * 20
    }

    private static func distance(_ face: FontFace, _ reference: FontFace, precise: Bool, tuning: MatchTuning) -> Double {
        var distance = 0.0
        if tuning.xHeight {
            if reference.xHeight > 0, face.xHeight > 0 {
                distance += Double(abs(face.xHeight - reference.xHeight)) / 8
            } else if precise {
                distance += 10
            }
        }
        if tuning.capHeight, reference.capHeight > 0, face.capHeight > 0 {
            distance += Double(abs(face.capHeight - reference.capHeight)) / 12
        }
        if tuning.width {
            if reference.averageWidth > 0, face.averageWidth > 0 {
                distance += Double(abs(face.averageWidth - reference.averageWidth)) / 6
            } else if precise {
                distance += 8
            }
            distance += Double(abs(face.widthClass - reference.widthClass)) * 8
        }
        if tuning.contrast, reference.contrast > 0, face.contrast > 0 {
            distance += Double(abs(face.contrast - reference.contrast)) * 6
        }
        if tuning.weight {
            distance += Double(abs(face.weightClass - reference.weightClass)) / 100 * 3
        }
        if tuning.slant, face.isItalic != reference.isItalic { distance += 12 }
        if tuning.category,
           face.category != reference.category,
           face.category != .unclassified, reference.category != .unclassified,
           face.category != .trial, reference.category != .trial {
            distance += 18
        }
        return distance
    }

    private static func folded(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 128 }) { return text.lowercased() }
        return text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }
}
