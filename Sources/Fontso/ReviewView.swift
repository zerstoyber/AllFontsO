import AppKit
import FontsoCore
import SwiftUI

/// Walks through the library one family at a time to check how AllFontsO filed it.
/// Least certain guesses come first; confirmed families go to the back, so another round is always possible.
struct ReviewView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fontso.sampleText") private var sampleText = SpecimenText.standard

    @State private var queue: [LibraryStore.ReviewFamily] = []
    @State private var position = 0
    @State private var confirmedFlash = false
    @State private var confirmReset = false
    @State private var roundDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let family = current {
                card(family)
                    .id(family.name)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            } else if queue.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal", description: Text("Add a folder of fonts first."))
            } else {
                finished
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 760, minHeight: 600, idealHeight: 640)
        .animation(.easeInOut(duration: 0.18), value: position)
        .onAppear(perform: start)
        .onChange(of: store.fonts.count) { _, _ in rebuildKeepingPlace() }
        .onChange(of: store.reviewSourcesVersion) { _, _ in rebuildKeepingPlace() }
        .alert("Start over?", isPresented: $confirmReset) {
            Button("Start over", role: .destructive) {
                store.resetReview()
                start()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every family comes up again, least certain first. Categories and lists stay as they are.")
        }
    }

    // MARK: Pieces

    private var current: LibraryStore.ReviewFamily? {
        guard queue.indices.contains(position), !roundDone else { return nil }
        // Live faces, so a category changed a moment ago shows at once.
        let name = queue[position].name
        let faces = store.cuts(in: name).filter { $0.family == name }
        guard !faces.isEmpty else { return nil }
        return LibraryStore.ReviewFamily(name: name, faces: faces, reviewedAt: reviewedAt(faces))
    }

    private func reviewedAt(_ faces: [FontFace]) -> Date? {
        let marks = faces.map { store.reviewMarks[$0.identity] }
        return marks.allSatisfy { $0 != nil } ? marks.compactMap { $0 }.min() : nil
    }

    private var reviewedCount: Int {
        queue.filter { family in reviewedAt(store.cuts(in: family.name).filter { $0.family == family.name }) != nil }.count
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Review")
                    .font(.title2.weight(.semibold))
                Text("Does each family sit in the right place?")
                    .foregroundStyle(.secondary)
                Spacer()
                if !queue.isEmpty {
                    Text("\(position + 1) of \(queue.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Menu {
                    Button("Start over…") { confirmReset = true }
                        .disabled(store.reviewMarks.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Forget which families were confirmed")
            }
            if !queue.isEmpty {
                let done = reviewedCount
                ProgressView(value: Double(done), total: Double(max(queue.count, 1)))
                    .progressViewStyle(.linear)
                    .tint(done == queue.count ? .green : .accentColor)
                Text("\(done) of \(queue.count) families confirmed. Least certain guesses come first; confirmed families wait at the back.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func card(_ family: LibraryStore.ReviewFamily) -> some View {
        let lead = family.lead
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(family.name)
                        .font(.title3.weight(.semibold))
                    Text(subtitle(lead, count: family.faces.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let date = family.reviewedAt {
                    Label("Confirmed \(date.formatted(.relative(presentation: .named)))", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Button {
                    showInLibrary(family)
                } label: {
                    Label("Show in library", systemImage: "sidebar.left")
                }
                .controlSize(.small)
                .help("Select this family in the main window")
            }

            FamilySample(face: lead, text: sampleText, size: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            cuts(family.faces)

            verdict(family, lead: lead)

            categoryChips(lead)

            HStack(spacing: 10) {
                listMenu(family)
                Toggle(isOn: Binding(
                    get: { store.isInStandardList(.trial, lead) },
                    set: { _ in store.toggleStandardList(.trial, for: lead, familyWide: true) }
                )) {
                    Text("Trial")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Mark the whole family as a trial version")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func subtitle(_ lead: FontFace, count: Int) -> String {
        var parts: [String] = []
        parts.append(count == 1 ? "1 cut" : "\(count) cuts")
        if !lead.manufacturer.cleanedFontName.isEmpty { parts.append(lead.manufacturer.cleanedFontName) }
        if !lead.designer.cleanedFontName.isEmpty { parts.append(lead.designer.cleanedFontName) }
        return parts.joined(separator: " · ")
    }

    private func cuts(_ faces: [FontFace]) -> some View {
        let ordered = faces.sorted { lhs, rhs in
            if lhs.isItalic != rhs.isItalic { return !lhs.isItalic }
            if lhs.weightClass != rhs.weightClass { return lhs.weightClass < rhs.weightClass }
            return lhs.style.localizedStandardCompare(rhs.style) == .orderedAscending
        }
        let shown = Array(ordered.prefix(18))
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(shown) { face in
                    FamilySample(face: face, text: face.style, size: 15)
                        .frame(width: max(60, CGFloat(face.style.count) * 9), alignment: .leading)
                        .help("\(face.family) \(face.style) · \(face.category.rawValue)")
                }
                if ordered.count > shown.count {
                    Text("+\(ordered.count - shown.count) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 30)
    }

    private func verdict(_ family: LibraryStore.ReviewFamily, lead: FontFace) -> some View {
        let categories = Set(family.faces.map(\.category))
        let source = family.source
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: confidenceSymbol(family.confidence))
                .foregroundStyle(confidenceColor(family.confidence))
            Group {
                if lead.category == .unclassified {
                    Text("Not filed yet: the file gives no hint and the letters could not be measured. Pick a category below.")
                } else if categories.count > 1 {
                    Text("The cuts are filed differently: ") + Text(categories.map(\.rawValue).sorted().joined(separator: ", ")).bold() + Text(". Pick one category below for all of them, or confirm as is.")
                } else {
                    Text("Filed under ") + Text(lead.category.rawValue).bold() + Text(" \(source.reason). ") + Text(confidenceWords(family.confidence)).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confidenceSymbol(_ confidence: Int) -> String {
        switch confidence {
        case ..<0: return "questionmark.circle.fill"
        case 0...1: return "exclamationmark.circle.fill"
        case 2: return "circle.lefthalf.filled"
        default: return "checkmark.circle.fill"
        }
    }

    private func confidenceColor(_ confidence: Int) -> Color {
        switch confidence {
        case ..<0: return .red
        case 0...1: return .orange
        case 2: return .yellow
        default: return .green
        }
    }

    private func confidenceWords(_ confidence: Int) -> String {
        switch confidence {
        case ..<0: return ""
        case 0...1: return "A guess worth a look."
        case 2: return "Usually right."
        case 4: return ""
        default: return "The designer's own word; rarely wrong."
        }
    }

    private func categoryChips(_ lead: FontFace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Category")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Array(FontCategory.typographic.enumerated()), id: \.element) { index, category in
                    let on = store.isInStandardList(category, lead)
                    Button {
                        store.toggleStandardList(category, for: lead, familyWide: true)
                    } label: {
                        HStack(spacing: 4) {
                            Text(category.rawValue)
                            Text("\(index + 1)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(on ? Color.white.opacity(0.8) : Color.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(on ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
                        .foregroundStyle(on ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                    .help(on ? "In \(category.rawValue). Click or press \(index + 1) to take it out." : "File the family under \(category.rawValue). Press \(index + 1).")
                }
            }
            Text("A family can sit in more than one category. Numbers on the keyboard switch them.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func listMenu(_ family: LibraryStore.ReviewFamily) -> some View {
        let identities = family.faces.map(\.identity)
        return Menu {
            if store.groups.isEmpty {
                Text("No lists yet")
            }
            ForEach(store.menuGroups) { group in
                let inside = identities.allSatisfy { store.membership[group.id, default: []].contains($0) }
                Button {
                    if inside {
                        store.removeFromGroup(group.id, identities: identities)
                    } else {
                        store.addToGroup(group.id, identities: identities)
                    }
                } label: {
                    if inside {
                        Label(store.menuTitle(group), systemImage: "checkmark")
                    } else {
                        Text(store.menuTitle(group))
                    }
                }
            }
            Divider()
            Button("New list…") {
                store.showNewGroup = true
                raiseMainWindow()
            }
        } label: {
            Label("Add to list", systemImage: "text.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help("Put this family into one of your lists on the way")
    }

    private var finished: some View {
        ContentUnavailableView {
            Label("Round done", systemImage: "checkmark.seal.fill")
        } description: {
            Text("You went through all \(queue.count) families. Confirmed ones wait at the back; another round starts with the least certain again.")
        } actions: {
            Button("Go round again") { start() }
                .keyboardShortcut(.defaultAction)
                .help("Start another round with the least certain families")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                back()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(position == 0 || roundDone)
            .help("Back to the previous family (←)")
            Spacer()
            if confirmedFlash {
                Label("Confirmed", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .help("Close Review")
            Button {
                skip()
            } label: {
                Label("Skip", systemImage: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(current == nil)
            .help("Leave this family open and look at the next one")
            Button("Looks right") { confirm() }
                .keyboardShortcut(.defaultAction)
                .disabled(current == nil)
                .help("Confirm the category and lists as they are now. Return.")
        }
    }

    // MARK: Logic

    private func start() {
        store.fillCategorySourcesIfNeeded()
        queue = store.reviewQueue()
        position = 0
        roundDone = false
    }

    /// After a rescan, keep the current family in view when it still exists.
    private func rebuildKeepingPlace() {
        let name = current?.name
        queue = store.reviewQueue()
        if let name, let index = queue.firstIndex(where: { $0.name == name }) {
            position = index
        } else {
            position = min(position, max(queue.count - 1, 0))
        }
    }

    private func confirm() {
        guard let family = current else { return }
        store.confirmReviewed(family)
        withAnimation { confirmedFlash = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation { confirmedFlash = false }
        }
        skip()
    }

    private func skip() {
        guard !queue.isEmpty else { return }
        if position + 1 < queue.count {
            position += 1
        } else {
            roundDone = true
        }
    }

    private func back() {
        guard position > 0 else { return }
        position -= 1
    }

    private func showInLibrary(_ family: LibraryStore.ReviewFamily) {
        store.filter = .all
        store.query = ""
        store.selection = Set(family.faces.map(\.id))
        store.outsideSelection = []
        raiseMainWindow()
    }

    /// The library window: the one that is not this review window.
    private func raiseMainWindow() {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.title != "Review" }?.makeKeyAndOrderFront(nil)
    }
}
