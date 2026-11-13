import AppKit
import FontsoCore
import SwiftUI

struct FoundriesView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var addedName = ""
    @State private var addedSite = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Foundries")
                    .font(.uiTitle2.weight(.semibold))
                Spacer()
                Button("Update index") { store.indexFoundries() }
                    .disabled(store.isIndexingFoundries)
                    .help("Fetch the foundry lists again")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .help("Close the foundries")
            }
            Text("The index is the full list from typefoundries.info and the Type Foundry Directory. Star a foundry to follow it, or add one of your own. New names from followed foundries show up in News.")
                .font(.uiCallout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.isIndexingFoundries {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.foundryIndexNote.isEmpty ? "Reading the directories…" : store.foundryIndexNote)
                        .foregroundStyle(.secondary)
                }
            } else if !store.foundryIndexNote.isEmpty {
                Text(store.foundryIndexNote)
                    .font(.uiCaption)
                    .foregroundStyle(.secondary)
            }
            TextField("Find a foundry", text: $query)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                TextField("Name", text: $addedName)
                    .textFieldStyle(.roundedBorder)
                TextField("Website", text: $addedSite)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    store.addFoundry(name: addedName, website: addedSite)
                    addedName = ""
                    addedSite = ""
                }
                .disabled(
                    addedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || addedSite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .help("Add this foundry and follow it")
            }
            List(shown) { foundry in
                HStack(spacing: 8) {
                    Button {
                        store.setFoundryWatched(foundry, watched: !foundry.watched)
                    } label: {
                        Image(systemName: foundry.watched ? "star.fill" : "star")
                            .foregroundStyle(foundry.watched ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(foundry.watched ? "Stop watching" : "Watch this foundry")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(foundry.name)
                            .lineLimit(1)
                        Text(foundryCaption(foundry))
                            .font(.uiCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Open") { NSWorkspace.shared.open(foundry.url) }
                        .buttonStyle(.paper)
                        .help("Open the foundry’s website")
                }
            }
            .frame(minHeight: 280)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 560)
        .onAppear { store.indexFoundriesIfNeeded() }
    }

    private var shown: [FoundryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return store.foundries }
        let folded = needle.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
        return store.foundries.filter {
            $0.name.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased().contains(folded)
                || $0.host.contains(folded)
        }
    }

    private func foundryCaption(_ foundry: FoundryEntry) -> String {
        let count = store.foundryFaces[foundry.id]?.count ?? 0
        if count > 0 {
            return "\(foundry.sources) · \(count) fonts read"
        }
        return foundry.sources
    }
}

enum FoundryFetch {
    static func infoHTML() async -> String? {
        await text(URL(string: "https://typefoundries.info/"), timeout: 25)
    }

    static func directoryHTML() async -> String? {
        if let cached = cachedDirectory() { return cached }
        guard let html = await text(FoundryLookup.directoryPage, timeout: 40),
              html.contains("data-sort-name") else { return nil }
        let file = cacheURL
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? html.write(to: file, atomically: true, encoding: .utf8)
        return html
    }

    /// Whether a page is there: the site answers with the page itself, not with an error or its front page.
    static func exists(_ url: URL, timeout: TimeInterval = 8) async -> Bool {
        var request = URLRequest(url: FoundryLookup.secure(url), timeoutInterval: timeout)
        request.setValue("AllFontsO", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return (http.url?.path.count ?? 0) > 1
    }

    /// Reads a page over https; macOS refuses plain http, and nearly every foundry answers on https.
    static func text(_ url: URL?, timeout: TimeInterval = 20) async -> String? {
        guard let url else { return nil }
        var request = URLRequest(url: FoundryLookup.secure(url), timeoutInterval: timeout)
        request.setValue("AllFontsO", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fontso/typefoundry-directory.html", isDirectory: false)
    }

    private static func cachedDirectory() -> String? {
        let file = cacheURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 60 * 60 * 24 * 3,
              let text = try? String(contentsOf: file, encoding: .utf8),
              text.contains("data-sort-name") else { return nil }
        return text
    }
}
