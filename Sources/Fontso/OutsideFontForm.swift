import FontsoCore
import SwiftUI

/// Small form for keeping a font that is not in the library: a name, where it comes from, and its page.
/// Given an existing item it edits that item instead, for example to correct a link that points to the wrong page.
struct OutsideFontForm: View {
    var editing: OutsideFont?
    var add: (String, String, URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var source = ""
    @State private var address = ""

    init(editing: OutsideFont? = nil, add: @escaping (String, String, URL) -> Void) {
        self.editing = editing
        self.add = add
        _name = State(initialValue: editing?.name ?? "")
        _source = State(initialValue: editing?.source ?? "")
        _address = State(initialValue: editing?.url.absoluteString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing == nil ? "Font from outside the library" : "Edit this item")
                .font(.uiHeadline)
            Text(editing == nil
                ? "Only the name and link are kept. Nothing is downloaded."
                : "Correct the name, the source, or the page it points to. The change applies wherever this item is saved.")
                .font(.uiCaption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name, prompt: Text("Name of the font"))
                .textFieldStyle(.roundedBorder)
            TextField("Foundry", text: $source, prompt: Text("Foundry or source"))
                .textFieldStyle(.roundedBorder)
            TextField("URL", text: $address, prompt: Text("URL of the font's page"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .help("Close without saving")
                Button(editing == nil ? "Add" : "Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                    .help("Save the name, source, and link")
            }
        }
        .padding(16)
        .frame(width: 360)
        .modifier(ChromeSheet())
    }

    private var url: URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host(), host.contains(".") else { return nil }
        return url
    }

    private func commit() {
        guard let url else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.count >= 2 else { return }
        var trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSource.isEmpty {
            trimmedSource = url.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        }
        add(trimmedName, trimmedSource, url)
        dismiss()
    }
}
