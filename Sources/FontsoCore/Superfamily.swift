import Foundation

/// Families that share a design and differ by a branch: Mono beside Sans, Condensed beside the regular width.
public struct SuperfamilyIndex: Sendable, Equatable {
    private var displayNames: [String: [String]]
    private var stemOfFamily: [String: String]
    private var designOfFamily: [String: String]

    public init(families: [String]) {
        var bestName: [String: String] = [:]
        var stems: [String: String] = [:]
        var designs: [String: String] = [:]
        stems.reserveCapacity(families.count)
        designs.reserveCapacity(families.count)
        for name in families {
            let design = SuperfamilyIndex.designKey(name)
            guard !design.isEmpty else { continue }
            let folded = name.lowercased()
            designs[folded] = design
            stems[folded] = SuperfamilyIndex.stem(of: design)
            if let current = bestName[design] {
                if SuperfamilyIndex.prefer(name, over: current, design: design) {
                    bestName[design] = name
                }
            } else {
                bestName[design] = name
            }
        }
        var grouped: [String: [String]] = [:]
        for (design, display) in bestName {
            grouped[SuperfamilyIndex.stem(of: design), default: []].append(display)
        }
        for key in grouped.keys where (grouped[key]?.count ?? 0) < 2 {
            grouped[key] = nil
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        displayNames = grouped
        stemOfFamily = stems
        designOfFamily = designs
    }

    /// The other branches. A trial or a variable file of the same branch is not listed again.
    public func relatives(of family: String) -> [String] {
        let folded = family.lowercased()
        guard let stem = stemOfFamily[folded], let names = displayNames[stem] else { return [] }
        let own = designOfFamily[folded] ?? SuperfamilyIndex.designKey(family)
        return names.filter { SuperfamilyIndex.designKey($0) != own }
    }

    /// The branch, with trial, variable, and web copies folded into the retail name.
    static func designKey(_ name: String) -> String {
        var tokens = tokenize(name)
        while let last = tokens.last, noise.contains(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    /// The shared name, with Mono, Sans, Condensed, and the other branch words taken off the end.
    static func stem(of design: String) -> String {
        var tokens = design.split(separator: " ").map(String.init)
        var changed = true
        while changed {
            changed = false
            if tokens.count >= 2, tokens[tokens.count - 2] == "semi", tokens[tokens.count - 1] == "mono" {
                tokens.removeLast(2)
                changed = true
                continue
            }
            guard let last = tokens.last else { break }
            if tokens.count > 1, branches.contains(last) {
                tokens.removeLast()
                changed = true
                continue
            }
            if let peeled = peel(last) {
                tokens[tokens.count - 1] = peeled
                changed = true
            }
        }
        let stem = tokens.joined(separator: " ")
        return stem.isEmpty ? design : stem
    }

    private static func prefer(_ candidate: String, over current: String, design: String) -> Bool {
        let candidateExact = tokenize(candidate).joined(separator: " ") == design
        let currentExact = tokenize(current).joined(separator: " ") == design
        if candidateExact != currentExact { return candidateExact }
        if candidate.count != current.count { return candidate.count < current.count }
        return candidate.localizedStandardCompare(current) == .orderedAscending
    }

    private static func tokenize(_ name: String) -> [String] {
        name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// A branch glued onto the family, as in TheSans or AmplitudeCond. The piece that remains has to be a real name.
    private static func peel(_ token: String) -> String? {
        for suffix in glued where token.hasSuffix(suffix) {
            let rest = token.dropLast(suffix.count)
            guard rest.count >= 3, rest.allSatisfy(\.isLetter) else { continue }
            return String(rest)
        }
        return nil
    }

    private static let noise: Set<String> = [
        "trial", "unlicensed", "variable", "web", "demo", "test", "vf", "woff", "woff2", "italic", "upright"
    ]

    private static let branches: Set<String> = [
        "mono", "monospace", "semimono", "sans", "serif", "slab",
        "display", "text", "headline", "caption", "deck", "micro", "poster",
        "condensed", "compressed", "compact", "extended", "expanded", "narrow", "wide", "rounded",
        "plus", "cyrillic", "cyr", "greek", "latin", "arabic", "hebrew"
    ]

    /// Longest first, so "monospace" is taken off before "mono".
    private static let glued: [String] = [
        "monospace", "semimono", "condensed", "compressed", "extended", "expanded",
        "cyrillic", "headline", "caption", "display", "narrow", "rounded", "compact",
        "mono", "sans", "serif", "slab", "wide", "cond", "comp", "plus"
    ]
}
