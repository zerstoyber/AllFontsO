import Foundation

public enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case family
    case style
    case foundry
    case designer
    case postscript

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .family: return "Family"
        case .style: return "Style"
        case .foundry: return "Foundry"
        case .designer: return "Designer"
        case .postscript: return "PostScript"
        }
    }

    public func matches(_ face: FontFace, query: String) -> Bool {
        SearchScope.matches(face, query: query, fields: [self])
    }

    public static func matches(_ face: FontFace, query: String, fields: Set<SearchScope>) -> Bool {
        let terms = SearchScope.terms(in: query)
        guard !terms.isEmpty else { return true }
        return matches(face, terms: terms, fields: fields)
    }

    /// Split and fold the query once, then test many faces with `matches(_:terms:fields:)`.
    public static func terms(in query: String) -> [[UInt8]] {
        query
            .split(whereSeparator: \.isWhitespace)
            .map { Array(TextFold.fold(String($0)).utf8) }
            .filter { !$0.isEmpty }
    }

    public static func matches(_ face: FontFace, terms: [[UInt8]], fields: Set<SearchScope>) -> Bool {
        guard !terms.isEmpty else { return true }
        let text = SearchIndex.shared.text(for: face)
        if fields.isEmpty || fields.contains(.all) {
            return terms.allSatisfy { TextFold.bytes(text.allBytes, contain: $0) }
        }
        return terms.allSatisfy { term in
            fields.contains { $0.haystack(in: text).contains { TextFold.bytes($0, contain: term) } }
        }
    }

    private func haystack(in text: FaceSearchText) -> [[UInt8]] {
        switch self {
        case .all:
            return [text.allBytes]
        case .family:
            return [text.familyBytes]
        case .style:
            return [text.styleBytes]
        case .foundry:
            return [text.manufacturerBytes]
        case .designer:
            return [text.designerBytes]
        case .postscript:
            return [text.postscriptBytes]
        }
    }
}
