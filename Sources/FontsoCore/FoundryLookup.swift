import Foundation

/// A font or foundry named on a public directory. The URL opens that page. No font file is fetched.
public struct FoundryDraft: Sendable, Equatable {
    public var name: String
    public var host: String
    public var url: URL
    public var sources: [String]

    public var sourceLabel: String { sources.joined(separator: ", ") }
}

public struct FoundryEntry: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var host: String
    public var url: URL
    public var sources: String
    public var watched: Bool

    public init(id: Int64, name: String, host: String, url: URL, sources: String, watched: Bool) {
        self.id = id
        self.name = name
        self.host = host
        self.url = url
        self.sources = sources
        self.watched = watched
    }
}

public struct FoundryNoticeDraft: Sendable, Equatable {
    public var name: String
    public var url: URL
    public var publishedAt: Date?

    public init(name: String, url: URL, publishedAt: Date?) {
        self.name = name
        self.url = url
        self.publishedAt = publishedAt
    }
}

public struct FoundryFeedItem: Sendable, Equatable {
    public var title: String
    public var url: URL
    public var published: Date?

    public init(title: String, url: URL, published: Date?) {
        self.title = title
        self.url = url
        self.published = published
    }
}

public struct FoundryReleaseNote: Sendable, Equatable {
    public var date: Date
    public var text: String

    public init(date: Date, text: String) {
        self.date = date
        self.text = text
    }
}

public struct FoundryNotice: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var foundryHost: String
    public var foundryName: String
    public var name: String
    public var url: URL
    public var publishedAt: Date?
    public var seen: Bool
    public var discoveredAt: Date

    public init(
        id: Int64,
        foundryHost: String,
        foundryName: String,
        name: String,
        url: URL,
        publishedAt: Date?,
        seen: Bool,
        discoveredAt: Date
    ) {
        self.id = id
        self.foundryHost = foundryHost
        self.foundryName = foundryName
        self.name = name
        self.url = url
        self.publishedAt = publishedAt
        self.seen = seen
        self.discoveredAt = discoveredAt
    }
}

public struct OutsideFont: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let source: String
    public let detail: String
    public let url: URL
    /// A picture of the lettering published by Typecache. Nil when the directory has no specimen.
    public let imageURL: URL?

    public init(name: String, source: String, detail: String, url: URL, imageURL: URL? = nil) {
        self.name = name
        self.source = source
        self.detail = detail
        self.url = url
        self.imageURL = imageURL
        self.id = source + "\n" + name + "\n" + url.absoluteString
    }
}

public enum FoundryLookup {
    public static let directoryPage = URL(string: "https://typefoundry.directory/")!

    public static func isDirectoryHost(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return ["typecache.com", "typefoundries.info", "typefoundry.directory"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    public static func typecacheSearchURL(_ query: String) -> URL? {
        searchURL("https://typecache.com/search/", query: query, name: "q")
    }

    public static func foundriesSearchURL(_ query: String) -> URL? {
        searchURL("https://typefoundries.info/", query: query, name: "s")
    }

    public static func typecache(_ html: String, query: String, limit: Int = 12) -> [OutsideFont] {
        let tokens = queryTokens(query)
        guard !tokens.isEmpty else { return [] }
        var results: [OutsideFont] = []
        var rest = html[...]
        while results.count < limit, let article = rest.range(of: "<article") {
            let end = rest.range(of: "</article>", range: article.upperBound..<rest.endIndex)?.upperBound ?? rest.endIndex
            let block = rest[article.lowerBound..<end]
            rest = rest[end...]
            if let image = specimenImage(in: block), let page = articleLink(block) {
                let title = plain(element("dt", in: block) ?? "")
                if containsAll(tokens, in: title), results.count < limit {
                    results.append(OutsideFont(
                        name: title,
                        source: "Typecache",
                        detail: "Specimen from Typecache. Not in your library.",
                        url: page,
                        imageURL: image
                    ))
                }
                continue
            }
            guard let page = articleLink(block), page.host?.contains("typecache.com") == true else { continue }
            let foundry = plain(element("dt", in: block) ?? "")
            let listed = typefaces(in: block)
            let hits = listed.filter { containsAll(tokens, in: $0) }
            if hits.isEmpty {
                if !foundry.isEmpty, containsAll(tokens, in: foundry), results.count < limit {
                    results.append(OutsideFont(
                        name: foundry,
                        source: "Typecache",
                        detail: "Foundry page. Not in your library.",
                        url: page
                    ))
                }
                continue
            }
            let label = foundry.isEmpty ? "Not in your library." : "\(foundry). Not in your library."
            for name in hits.prefix(3) where results.count < limit {
                results.append(OutsideFont(name: name, source: "Typecache", detail: label, url: page))
            }
        }
        return results
    }

    public static func foundriesInfo(_ html: String, query: String, limit: Int = 8) -> [OutsideFont] {
        let tokens = queryTokens(query)
        guard !tokens.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(
            pattern: "<a\\s[^>]*href=\"(https?://[^\"]+)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [OutsideFont] = []
        regex.enumerateMatches(in: html, range: range) { match, _, stop in
            guard let match, results.count < limit,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html),
                  let url = URL(string: String(html[hrefRange])) else { return }
            let host = url.host?.lowercased() ?? ""
            if blockedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return }
            let name = plain(String(html[textRange]))
            guard name.count >= 2, name.count <= 80, name.contains(where: \.isLetter), containsAll(tokens, in: name) else { return }
            results.append(OutsideFont(
                name: name,
                source: "typefoundries.info",
                detail: "Foundry website. Not in your library.",
                url: url
            ))
            if results.count >= limit { stop.pointee = true }
        }
        return results
    }

    public static func directory(_ html: String, query: String, limit: Int = 8) -> [OutsideFont] {
        let tokens = queryTokens(query)
        guard !tokens.isEmpty else { return [] }
        var results: [OutsideFont] = []
        var search = html.startIndex
        let marker = "data-sort-name=\""
        while results.count < limit, let start = html.range(of: marker, range: search..<html.endIndex) {
            let nameStart = start.upperBound
            guard let nameEnd = html.range(of: "\"", range: nameStart..<html.endIndex) else { break }
            let sortName = String(html[nameStart..<nameEnd.lowerBound])
            let next = html.range(of: marker, range: nameEnd.upperBound..<html.endIndex)?.lowerBound ?? html.endIndex
            let window = html[nameEnd.upperBound..<next]
            let display = directoryName(in: window) ?? sortName
            if containsAll(tokens, in: sortName + " " + display), let url = directoryLink(in: window) {
                results.append(OutsideFont(
                    name: display,
                    source: "Type Foundry Directory",
                    detail: "Foundry website. Not in your library.",
                    url: url
                ))
            }
            search = nameEnd.upperBound
        }
        return results
    }

    /// Every foundry named on the two directory pages, one row per website.
    public static func catalog(directoryHTML: String?, infoHTML: String?) -> [FoundryDraft] {
        var byHost: [String: FoundryDraft] = [:]
        if let directoryHTML {
            for item in directoryEntries(directoryHTML) {
                merge(&byHost, name: item.name, url: item.url, source: "Type Foundry Directory")
            }
        }
        if let infoHTML {
            for item in infoEntries(infoHTML) {
                merge(&byHost, name: item.name, url: item.url, source: "typefoundries.info")
            }
        }
        return byHost.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The published specimen picture for a typeface, when Typecache has one.
    public static func specimen(in html: String, name: String) -> URL? {
        matchingSpecimen(in: html, name: name)?.image
    }

    /// The foundry page linked next to that specimen.
    public static func specimenPage(in html: String, name: String) -> URL? {
        matchingSpecimen(in: html, name: name)?.page
    }

    /// A link on the foundry's own site whose path names this typeface, such as /typeface/avantt.
    public static func typefacePage(on site: URL, name: String, html: String) -> URL? {
        let wanted = slugVariants(name)
        guard let exact = wanted.first, exact.count >= 3 else { return nil }
        guard let home = URL(string: "/", relativeTo: site)?.absoluteURL else { return nil }
        var best: (url: URL, score: Int)?
        for raw in linkHrefs(in: html) {
            guard let url = resolveLink(raw, base: home), sameSite(url, site) else { continue }
            let path = url.path.lowercased()
            if path.count <= 1 || path.contains("/assets/") || path.hasSuffix(".js") || path.hasSuffix(".css") {
                continue
            }
            let segments = path.split(separator: "/").map { slug(String($0)) }
            var score = 0
            for (index, variant) in wanted.enumerated() where variant.count >= 3 {
                if segments.contains(variant) {
                    score = max(score, 30 - index * 5)
                }
            }
            guard score > 0 else { continue }
            if segments.last == exact { score += 8 }
            if path.contains("typeface") || path.contains("font") { score += 4 }
            if best == nil || score > best?.score ?? 0 {
                best = (url, score)
            }
        }
        return best?.url
    }

    /// Typeface names linked on a foundry's own site, such as /typeface/avantt.
    public static func linkedTypefaces(on site: URL, html: String, limit: Int = 40) -> [String] {
        guard let home = URL(string: "/", relativeTo: site)?.absoluteURL else { return [] }
        guard let regex = try? NSRegularExpression(
            pattern: "<a\\s[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var names: [String] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: range) {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let labelRange = Range(match.range(at: 2), in: html),
                  let url = resolveLink(String(html[hrefRange]), base: home),
                  sameSite(url, site) else { continue }
            let path = url.path.lowercased()
            guard path.contains("typeface") || path.contains("font") else { continue }
            if path.contains("/assets/") || path.hasSuffix(".js") || path.hasSuffix(".css") { continue }
            let last = url.path.split(separator: "/").last.map(String.init) ?? ""
            let key = slug(last)
            guard key.count >= 3, !genericTypefaceKeys.contains(key), seen.insert(key).inserted else { continue }
            let label = plain(String(html[labelRange])).trimmingCharacters(in: .whitespacesAndNewlines)
            let display = (label.count >= 2 && label.count <= 48) ? label : titledSlug(last)
            names.append(display)
            if names.count >= limit { break }
        }
        return names
    }

    /// Release dates written on a Typecache page, next to the sentence that names the fonts.
    public static func releaseNotes(in html: String) -> [FoundryReleaseNote] {
        guard let regex = try? NSRegularExpression(
            pattern: "Date:\\s*(?:</span>\\s*)?([A-Z][a-z]+ \\d{1,2}, \\d{4})"
        ) else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var notes: [FoundryReleaseNote] = []
        for match in regex.matches(in: html, range: range) {
            guard let dateRange = Range(match.range(at: 1), in: html),
                  let date = formatter.date(from: String(html[dateRange])) else { continue }
            let tailEnd = html.index(dateRange.upperBound, offsetBy: 500, limitedBy: html.endIndex) ?? html.endIndex
            var chunk = String(html[dateRange.upperBound..<tailEnd])
            if let cut = chunk.range(of: "<dt") {
                chunk = String(chunk[..<cut.lowerBound])
            }
            let text = plain(chunk).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 3 else { continue }
            notes.append(FoundryReleaseNote(date: date, text: text))
        }
        return notes
    }

    /// The RSS or Atom address advertised on a foundry page.
    public static func feedURL(in html: String, base: URL) -> URL? {
        guard let home = URL(string: "/", relativeTo: base)?.absoluteURL else { return nil }
        guard let regex = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let rel = attribute("rel", in: tag)?.lowercased() ?? ""
            let type = attribute("type", in: tag)?.lowercased() ?? ""
            guard rel.contains("alternate") else { continue }
            guard type.contains("rss") || type.contains("atom") else { continue }
            guard let href = attribute("href", in: tag), let url = resolveLink(href, base: home) else { continue }
            return url
        }
        return nil
    }

    public static func commonFeedURLs(_ site: URL) -> [URL] {
        ["/feed", "/rss", "/atom.xml"].compactMap { URL(string: $0, relativeTo: site)?.absoluteURL }
    }

    /// Posts from an RSS or Atom document published by that foundry.
    public static func feedItems(in xml: String, base: URL, limit: Int = 16) -> [FoundryFeedItem] {
        var items: [FoundryFeedItem] = []
        for block in xmlBlocks(xml, tags: ["item", "entry"]) {
            guard let title = xmlValue("title", in: block), title.count >= 2, title.count <= 140 else { continue }
            guard let link = feedLink(in: block, base: base) else { continue }
            items.append(FoundryFeedItem(title: title, url: link, published: feedDate(in: block)))
            if items.count >= limit { break }
        }
        return items
    }

    private static let genericTypefaceKeys: Set<String> = [
        "font", "fonts", "typeface", "typefaces", "shop", "store", "retail", "blog", "news",
        "about", "home", "contact", "work", "index", "specimen", "specimens", "custom",
        "account", "cart", "search", "login"
    ]

    private static func titledSlug(_ text: String) -> String {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.map { word in
            guard let first = word.first else { return "" }
            return first.uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    private static func matchingSpecimen(in html: String, name: String) -> (image: URL, page: URL)? {
        let tokens = queryTokens(name)
        guard !tokens.isEmpty else { return nil }
        var rest = html[...]
        while let article = rest.range(of: "<article") {
            let end = rest.range(of: "</article>", range: article.upperBound..<rest.endIndex)?.upperBound ?? rest.endIndex
            let block = rest[article.lowerBound..<end]
            rest = rest[end...]
            guard let image = specimenImage(in: block), let page = articleLink(block) else { continue }
            let title = plain(element("dt", in: block) ?? "")
            if containsAll(tokens, in: title) { return (image, page) }
        }
        return nil
    }

    /// Typeface names listed under this foundry on a Typecache page. The foundry name has to match, so a nearby foundry on the same search page is left out.
    public static func typefaces(ofFoundry name: String, in html: String, limit: Int = 40) -> [String] {
        let wanted = foundryKey(name)
        guard wanted.count >= 3 else { return [] }
        var rest = html[...]
        while let article = rest.range(of: "<article") {
            let end = rest.range(of: "</article>", range: article.upperBound..<rest.endIndex)?.upperBound ?? rest.endIndex
            let block = rest[article.lowerBound..<end]
            rest = rest[end...]
            let foundry = foundryKey(plain(element("dt", in: block) ?? ""))
            guard foundry == wanted else { continue }
            let names = typefaces(in: block)
            guard !names.isEmpty else { continue }
            return Array(names.prefix(limit))
        }
        return []
    }

    public static func siteHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.isEmpty || blockedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return nil }
        return host
    }

    private static func merge(_ byHost: inout [String: FoundryDraft], name: String, url: URL, source: String) {
        guard let host = siteHost(url) else { return }
        let cleaned = plain(name)
        guard cleaned.count >= 2 else { return }
        if var existing = byHost[host] {
            if !existing.sources.contains(source) { existing.sources.append(source) }
            if cleaned.count > existing.name.count { existing.name = cleaned }
            byHost[host] = existing
        } else {
            byHost[host] = FoundryDraft(name: cleaned, host: host, url: url, sources: [source])
        }
    }

    private static func directoryEntries(_ html: String) -> [(name: String, url: URL)] {
        var results: [(name: String, url: URL)] = []
        var search = html.startIndex
        let marker = "data-sort-name=\""
        while let start = html.range(of: marker, range: search..<html.endIndex) {
            let nameStart = start.upperBound
            guard let nameEnd = html.range(of: "\"", range: nameStart..<html.endIndex) else { break }
            let sortName = String(html[nameStart..<nameEnd.lowerBound])
            let next = html.range(of: marker, range: nameEnd.upperBound..<html.endIndex)?.lowerBound ?? html.endIndex
            let window = html[nameEnd.upperBound..<next]
            let display = directoryName(in: window) ?? sortName
            if let url = directoryLink(in: window) {
                results.append((display, url))
            }
            search = nameEnd.upperBound
        }
        return results
    }

    private static func infoEntries(_ html: String) -> [(name: String, url: URL)] {
        guard let regex = try? NSRegularExpression(
            pattern: "<a\\s[^>]*href=\"(https?://[^\"]+)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [(name: String, url: URL)] = []
        let skipped = ["add", "home", "form", "changelog", "imprint", "data protection", "type foundry", "typefoundries.info"]
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html),
                  let url = URL(string: String(html[hrefRange])) else { return }
            let name = plain(String(html[textRange]))
            guard name.count >= 2, name.count <= 80, name.contains(where: \.isLetter) else { return }
            if skipped.contains(folded(name)) { return }
            results.append((name, url))
        }
        return results
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*([\"'])(.*?)\\1"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, range: range),
              let value = Range(match.range(at: 2), in: tag) else { return nil }
        return String(tag[value])
    }

    private static func xmlBlocks(_ xml: String, tags: [String]) -> [String] {
        var blocks: [String] = []
        for tag in tags {
            var rest = xml[...]
            let open = "<\(tag)"
            let close = "</\(tag)>"
            while let start = rest.range(of: open) {
                guard let end = rest.range(of: close, range: start.upperBound..<rest.endIndex) else { break }
                blocks.append(String(rest[start.lowerBound..<end.upperBound]))
                rest = rest[end.upperBound...]
            }
        }
        return blocks
    }

    private static func xmlValue(_ tag: String, in block: String) -> String? {
        let pattern = "<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(block.startIndex..<block.endIndex, in: block)
        guard let match = regex.firstMatch(in: block, range: range),
              let value = Range(match.range(at: 1), in: block) else { return nil }
        var text = String(block[value])
        if let start = text.range(of: "<![CDATA["), let end = text.range(of: "]]>", range: start.upperBound..<text.endIndex) {
            text = String(text[start.upperBound..<end.lowerBound])
        }
        let cleaned = plain(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func feedLink(in block: String, base: URL) -> URL? {
        if let href = attribute("href", in: block.components(separatedBy: ">").first.map { $0 + ">" } ?? block),
           let url = resolveLink(href, base: base), url.scheme?.hasPrefix("http") == true {
            return url
        }
        guard let regex = try? NSRegularExpression(
            pattern: "<link\\b([^>]*)>([\\s\\S]*?)</link>|<link\\b([^>]*)/?>",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(block.startIndex..<block.endIndex, in: block)
        var fallback: URL?
        for match in regex.matches(in: block, range: range) {
            let attrs: String
            if let attrRange = Range(match.range(at: 1), in: block), !attrRange.isEmpty {
                attrs = String(block[attrRange])
            } else if let attrRange = Range(match.range(at: 3), in: block) {
                attrs = String(block[attrRange])
            } else {
                attrs = ""
            }
            let raw = attribute("href", in: "<link " + attrs + ">")
                ?? Range(match.range(at: 2), in: block).map { plain(String(block[$0])) }
            guard let raw, let url = resolveLink(raw.trimmingCharacters(in: .whitespacesAndNewlines), base: base),
                  url.scheme?.hasPrefix("http") == true else { continue }
            let rel = attribute("rel", in: "<link " + attrs + ">")?.lowercased() ?? ""
            if rel.isEmpty || rel.contains("alternate") { return url }
            fallback = fallback ?? url
        }
        return fallback
    }

    private static func feedDate(in block: String) -> Date? {
        for tag in ["pubDate", "published", "updated", "dc:date"] {
            guard let text = xmlValue(tag, in: block) else { continue }
            if let date = parseFeedDate(text) { return date }
        }
        return nil
    }

    private static func parseFeedDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    private static func foundryKey(_ name: String) -> String {
        var text = folded(name)
        for suffix in [" type foundry", " foundry", " type"] where text.hasSuffix(suffix) && text.count - suffix.count >= 3 {
            text.removeLast(suffix.count)
            break
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static let blockedHosts = [
        "typefoundries.info",
        "typefoundry.directory",
        "type-atlas.xyz",
        "type.lol",
        "typetofu.com",
        "wordpress.org",
        "facebook.com",
        "twitter.com",
        "instagram.com"
    ]

    private static func searchURL(_ base: String, query: String, name: String) -> URL? {
        var parts = URLComponents(string: base)
        parts?.queryItems = [URLQueryItem(name: name, value: query)]
        return parts?.url
    }

    private static func queryTokens(_ query: String) -> [String] {
        folded(query)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    private static func containsAll(_ tokens: [String], in text: String) -> Bool {
        let haystack = folded(text)
        return tokens.allSatisfy { haystack.contains($0) }
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    private static func typefaces(in block: Substring) -> [String] {
        guard let label = block.range(of: "Typefaces:") else { return [] }
        let after = block[label.upperBound...]
        let end = after.range(of: "</dd>")?.lowerBound ?? after.endIndex
        return plain(String(after[..<end]))
            .replacingOccurrences(of: "‚", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    private static func element(_ tag: String, in block: Substring) -> String? {
        guard let open = block.range(of: "<" + tag) else { return nil }
        guard let start = block.range(of: ">", range: open.upperBound..<block.endIndex)?.upperBound else { return nil }
        guard let close = block.range(of: "</" + tag, range: start..<block.endIndex) else { return nil }
        return String(block[start..<close.lowerBound])
    }

    private static func slug(_ text: String) -> String {
        let folded = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private static func slugVariants(_ name: String) -> [String] {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        var variants = [slug(words.joined())]
        let styles = ["regular", "italic", "bold", "light", "condensed", "compressed", "extended", "display", "text", "mono", "headline", "narrow", "wide", "variable"]
        var trimmed = words
        while trimmed.count > 1, styles.contains(trimmed[trimmed.count - 1].lowercased()) {
            trimmed.removeLast()
            let next = slug(trimmed.joined())
            if !variants.contains(next) { variants.append(next) }
        }
        return variants
    }

    private static func linkHrefs(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "href\\s*=\\s*[\"']([^\"']+)[\"']", options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var found: [String] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let span = Range(match.range(at: 1), in: html) else { return }
            found.append(String(html[span]))
        }
        return found
    }

    private static func resolveLink(_ raw: String, base: URL) -> URL? {
        if raw.hasPrefix("#") || raw.hasPrefix("mailto:") || raw.hasPrefix("javascript:") { return nil }
        if raw.hasPrefix("http") { return URL(string: raw) }
        if raw.hasPrefix("//") { return URL(string: "https:" + raw) }
        if raw.hasPrefix("/") { return URL(string: raw, relativeTo: base)?.absoluteURL }
        return nil
    }

    private static func sameSite(_ url: URL, _ site: URL) -> Bool {
        func host(_ url: URL) -> String {
            var host = url.host?.lowercased() ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        }
        return host(url) == host(site) && !host(url).isEmpty
    }

    private static func articleLink(_ block: Substring) -> URL? {
        let found = links(in: block)
        if let external = found.first(where: { !isDirectoryHost($0) }) {
            return external
        }
        return found.first
    }

    private static func links(in block: Substring) -> [URL] {
        var found: [URL] = []
        var rest = block
        while let key = rest.range(of: "href=\"") {
            guard let end = rest.range(of: "\"", range: key.upperBound..<rest.endIndex) else { break }
            let raw = String(rest[key.upperBound..<end.lowerBound])
            if raw.hasPrefix("http"), let url = URL(string: raw) {
                found.append(url)
            } else if raw.hasPrefix("/"), let url = URL(string: "https://typecache.com" + raw) {
                found.append(url)
            }
            rest = rest[end.upperBound...]
        }
        return found
    }

    private static func specimenImage(in block: Substring) -> URL? {
        guard let src = attribute("src", in: block), src.contains("font-clusters") else { return nil }
        var path = src
        path = path.replacingOccurrences(of: "/font-clusters/font_cluster_s/", with: "/font-clusters/font_cluster/")
        if path.hasSuffix("_s.jpg") {
            path = String(path.dropLast("_s.jpg".count)) + ".jpg"
        }
        if path.hasPrefix("/") { path = "https://typecache.com" + path }
        return URL(string: path)
    }

    private static func attribute(_ name: String, in block: Substring) -> String? {
        guard let key = block.range(of: name + "=\"") else { return nil }
        guard let end = block.range(of: "\"", range: key.upperBound..<block.endIndex) else { return nil }
        return String(block[key.upperBound..<end.lowerBound])
    }

    private static func directoryName(in window: Substring) -> String? {
        guard let marker = window.range(of: "foundry--name") else { return nil }
        guard let href = window.range(of: "href=\"", range: marker.upperBound..<window.endIndex),
              let close = window.range(of: ">", range: href.upperBound..<window.endIndex),
              let end = window.range(of: "<", range: close.upperBound..<window.endIndex) else { return nil }
        let name = plain(String(window[close.upperBound..<end.lowerBound]))
        return name.isEmpty ? nil : name
    }

    private static func directoryLink(in window: Substring) -> URL? {
        guard let href = window.range(of: "href=\""),
              let end = window.range(of: "\"", range: href.upperBound..<window.endIndex) else { return nil }
        let raw = String(window[href.upperBound..<end.lowerBound])
        guard raw.hasPrefix("http") else { return nil }
        return URL(string: raw)
    }

    private static func plain(_ html: String) -> String {
        var text = html
        let swaps = [
            "&sbquo;": ",",
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&nbsp;": " ",
            "&raquo;": ""
        ]
        for (entity, value) in swaps {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
