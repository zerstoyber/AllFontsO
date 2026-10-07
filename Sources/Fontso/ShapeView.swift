import AppKit
import FontsoCore
import SwiftUI

struct ShapeView: View {
    @EnvironmentObject private var store: LibraryStore
    @AppStorage("fontso.sampleText") private var sample = SpecimenText.standard
    @AppStorage("fontso.listSampleSize") private var sampleSize = 16.0
    @AppStorage("fontso.shapeSampleOpen") private var sampleOpen = true
    @State private var sampleDockHeight: CGFloat = 72
    @State private var referenceID: Int64?
    @State private var selectionAnchor: Int64?
    @State private var neighbors: [FormNeighbor] = []
    @State private var refining = false
    @AppStorage("fontso.shape.tuningOpen") private var tuningOpen = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { scroller in
                ColumnScroll(bottomInset: sampleDockHeight + 16) {
                    VStack(alignment: .leading, spacing: 22) {
                        referenceBlock
                        if face(referenceID) != nil {
                            tuningBlock
                        }
                        libraryBlock
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(ArrowKeyCatcher { direction, flags in
                    step(direction, flags: flags, scroller: scroller)
                })
            }
            SampleDock(
                isOpen: $sampleOpen,
                placeholder: "Sample text for the matches…",
                faceForCharacters: face(referenceID) ?? store.previewFace
            )
            .reportOverlayHeight()
        }
        .onPreferenceChange(OverlayHeightKey.self) { sampleDockHeight = $0 }
        .onChange(of: searchID) { _, _ in
            loadSearch(applySelection: true)
        }
        .onChange(of: currentSearch?.referenceIdentity) { old, new in
            if old != new { loadSearch(applySelection: true) }
        }
        .onChange(of: store.fonts.count) { _, _ in
            if referenceID == nil { loadSearch(applySelection: true) }
        }
        .task(id: rankKey) {
            await rank()
        }
        .task(id: searchID) {
            loadSearch(applySelection: true)
        }
    }

    private var searchID: Int64? {
        if case .shape(let id) = store.filter { return id }
        return nil
    }

    private var currentSearch: ShapeSearch? {
        guard let searchID else { return nil }
        return store.shapeSearches.first { $0.id == searchID }
    }

    /// Everything the ranking depends on. Compared as values, so the task only restarts when one of them changes.
    private struct RankKey: Hashable {
        var reference: Int64
        var fontCount: Int
        var tuning: MatchTuning
    }

    private var rankKey: RankKey {
        RankKey(reference: referenceID ?? -1, fontCount: store.fonts.count, tuning: tuning)
    }

    private var tuning: MatchTuning {
        currentSearch?.tuning ?? .standard
    }

    private func setTuning(_ change: (inout MatchTuning) -> Void) {
        guard let searchID else { return }
        var updated = tuning
        change(&updated)
        store.updateShapeTuning(searchID, tuning: updated)
    }

    private func factor(_ keyPath: WritableKeyPath<MatchTuning, Bool>) -> Binding<Bool> {
        Binding(
            get: { tuning[keyPath: keyPath] },
            set: { value in setTuning { $0[keyPath: keyPath] = value } }
        )
    }

    /// The letters whose drawn shapes are compared, written the way the user typed them.
    private var lettersBinding: Binding<String> {
        Binding(
            get: { tuning.letters },
            set: { value in
                let trimmed = String(value.filter { !$0.isWhitespace }.prefix(MatchTuning.letterLimit * 2))
                setTuning { $0.letters = trimmed }
            }
        )
    }

    private struct Factor: Identifiable {
        var title: String
        var help: String
        var keyPath: WritableKeyPath<MatchTuning, Bool>
        var id: String { title }
    }

    private static let factors: [Factor] = [
        Factor(title: "x-height", help: "Height of the lowercase letters, as recorded in the font.", keyPath: \.xHeight),
        Factor(title: "Cap height", help: "Height of the capitals, as recorded in the font.", keyPath: \.capHeight),
        Factor(title: "Width", help: "Average letter width and the width class, condensed through extended.", keyPath: \.width),
        Factor(title: "Weight", help: "Weight class, thin through black.", keyPath: \.weight),
        Factor(title: "Contrast", help: "Difference between thick and thin strokes.", keyPath: \.contrast),
        Factor(title: "Slant", help: "Upright against italic.", keyPath: \.slant),
        Factor(title: "Category", help: "Sans, serif, slab, script, mono.", keyPath: \.category),
    ]

    private static let letterPresets = ["no", "ag", "RG", "ea", "Mk"]

    /// Switches under the reference for choosing what the match looks at.
    private var tuningBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { tuningOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tuningOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 10)
                    Image(systemName: "slider.horizontal.3")
                    Text("Tune the matches")
                        .font(.headline)
                    if !tuning.isStandard {
                        Text("· adjusted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tuningOpen ? "Hide the match settings" : "Choose which measurements and letters the match compares")

            if tuningOpen {
                Text("Measurements")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(Self.factors) { factor in
                        Toggle(factor.title, isOn: self.factor(factor.keyPath))
                            .toggleStyle(.button)
                            .controlSize(.small)
                            .help(factor.help)
                    }
                }
                Text("Letter shapes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                HStack(spacing: 8) {
                    Toggle("Draw and compare", isOn: factor(\.compareLetters))
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Draws these letters in the reference and in each candidate, then compares the drawings.")
                    TextField("Letters", text: lettersBinding)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 96)
                        .disabled(!tuning.compareLetters)
                        .help("Up to \(MatchTuning.letterLimit) letters. Pick the ones that show the character of the typeface.")
                    ForEach(Self.letterPresets, id: \.self) { preset in
                        Button(preset) {
                            setTuning {
                                $0.letters = preset
                                $0.compareLetters = true
                            }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .font(.caption.monospaced())
                        .disabled(tuning.compareLetters && tuning.letters == preset)
                    }
                }
                Text(tuningNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !tuning.isStandard {
                    Button("Back to the standard match") {
                        setTuning { $0 = .standard }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var tuningNote: String {
        let letters = tuning.letterList
        if !tuning.comparesProportions, letters.isEmpty {
            return "Nothing is compared right now. Switch on a measurement or the letter shapes."
        }
        if !tuning.comparesProportions {
            return "Only the drawn letters count, so every family in the library is drawn once. The first pass takes a moment."
        }
        if letters.isEmpty {
            return "The measurements rank the families. Switch on the letter shapes to check the drawings as well."
        }
        return "The measurements pick the closest 36 families, then the drawings of \(letterSentence(letters)) sort them."
    }

    private func letterSentence(_ letters: [Character]) -> String {
        let names = letters.map(String.init)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }

    private var referenceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let face = face(referenceID) {
                Button {
                    selectFace(face)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("Reference")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.16), in: Capsule())
                            Text(face.style)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(face.family)
                            .font(.title3.weight(.semibold))
                        if !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            FamilySample(face: face, text: sample, size: 28)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        store.selection.contains(face.id) ? Color.accentColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
                .id(face.id)
                .help("Select this reference in the preview. Hold Command to add it to the selection.")
                Text(matchNote(face))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Drop a font here, or select one. It stays with this shape search.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            }
            if let selected = store.previewFaces.first, selected.id != referenceID {
                Button("Use \(selected.family) as reference") { adopt(selected) }
                    .buttonStyle(.borderless)
            }
        }
        .dropDestination(for: FontDragItem.self) { items, _ in
            guard let searchID else { return false }
            return store.keepShapeReference(searchID, identities: items.flatMap(\.identities))
        }
    }

    private var libraryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("In your library")
                    .font(.headline)
                if refining {
                    ProgressView()
                        .controlSize(.small)
                    Text("Drawing \(letterSentence(tuning.letterList))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if neighbors.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(neighbors) { neighbor in
                        neighborRow(neighbor)
                    }
                }
            }
        }
    }

    private func neighborRow(_ neighbor: FormNeighbor) -> some View {
        let face = neighbor.face
        let selected = store.selection.contains(face.id)
        return HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(face.activation.isAvailableToApps ? Color.green : Color.clear)
                    .overlay(Circle().stroke(Color.secondary.opacity(0.7), lineWidth: 1))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(face.family)
                            .lineLimit(1)
                        Text("\(face.style) · \(face.category.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        FamilySample(face: face, text: sample, size: sampleSize)
                    }
                }
                Spacer(minLength: 8)
                Text("\(neighbor.score)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(face.format.uppercased())
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { selectFace(face) }
            .draggable(FontDragItem(identities: store.identitiesForDrag(face)))
            .contextMenu { listMenu(face) }
            .id(face.id)
            .help("Select this cut in the preview. Command adds it, Shift extends the selection. Drag it onto a list. \(neighbor.score) percent alike.")
    }

    private var emptyText: String {
        if face(referenceID) == nil { return "No reference yet." }
        if refining { return "Drawing the letters of every family…" }
        if !tuning.comparesAnything { return "Switch on a measurement or the letter shapes above." }
        return "No other family is close enough."
    }

    /// Up and down walk the reference and the matches; Shift keeps what is selected.
    private func step(_ direction: ArrowDirection, flags: NSEvent.ModifierFlags, scroller: ScrollViewProxy) -> Bool {
        guard direction.isVertical else { return false }
        let order = selectableFaces
        guard !order.isEmpty else { return false }
        let target: Int
        if direction == .down {
            target = order.lastIndex(where: { store.selection.contains($0.id) }).map { $0 + 1 } ?? 0
        } else {
            target = order.firstIndex(where: { store.selection.contains($0.id) }).map { $0 - 1 } ?? order.count - 1
        }
        guard order.indices.contains(target) else { return true }
        let face = order[target]
        if flags.contains(.shift) {
            store.selection.insert(face.id)
        } else {
            store.selection = [face.id]
        }
        store.outsideSelection = []
        selectionAnchor = face.id
        withAnimation(.easeOut(duration: 0.12)) {
            scroller.scrollTo(face.id, anchor: .center)
        }
        return true
    }

    /// Puts this cut, or the whole selection when it is part of it, into one of the user's lists.
    @ViewBuilder
    private func listMenu(_ face: FontFace) -> some View {
        let identities = store.identitiesForDrag(face)
        Menu(identities.count > 1 ? "Add \(identities.count) fonts to list" : "Add to list") {
            if store.groups.isEmpty {
                Button("New list…") { store.showNewGroup = true }
            }
            ForEach(store.menuGroups) { group in
                Button(store.menuTitle(group)) { store.addToGroup(group.id, identities: identities) }
            }
        }
        Button(store.isFavorite(face) ? "Remove favorite" : "Add to favorites") {
            store.toggleFavorite(face)
        }
    }

    private func face(_ id: Int64?) -> FontFace? {
        guard let id else { return nil }
        return store.fonts.first { $0.id == id }
    }

    /// Says what the current settings compare for this reference, skipping measurements the file does not carry.
    private func matchNote(_ face: FontFace) -> String {
        let tuning = tuning
        var parts: [String] = []
        if tuning.xHeight, face.xHeight > 0 { parts.append("x-height") }
        if tuning.capHeight, face.capHeight > 0 { parts.append("cap height") }
        if tuning.width { parts.append("width") }
        if tuning.weight { parts.append("weight") }
        if tuning.contrast, face.contrast > 0 { parts.append("contrast") }
        if tuning.slant { parts.append("slant") }
        if tuning.category { parts.append("category") }
        let letters = tuning.letterList
        if !letters.isEmpty {
            parts.append("the drawn \(letters.count == 1 ? "shape" : "shapes") of \(letterSentence(letters))")
        }
        var note: String
        switch parts.count {
        case 0: note = "Nothing is compared yet."
        case 1: note = "Matched on \(parts[0])."
        case 2: note = "Matched on \(parts[0]) and \(parts[1])."
        default: note = "Matched on " + parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1] + "."
        }
        if (tuning.xHeight || tuning.width), face.xHeight == 0 || face.averageWidth == 0 {
            note += " This font has no recorded proportions, so those measurements are skipped."
        }
        return note
    }

    private func rank() async {
        guard let reference = face(referenceID) else {
            neighbors = []
            refining = false
            return
        }
        let library = store.fonts
        let tuning = tuning
        let coarse = FormMatch.neighbors(of: reference, in: library, tuning: tuning)
        let drawsLetters = !tuning.letterList.isEmpty
        // With no measurements switched on, the coarse list is the whole library; showing it would mean nothing yet.
        neighbors = tuning.comparesProportions ? coarse : []
        refining = drawsLetters && !coarse.isEmpty
        guard refining else { return }
        let refined = await Task.detached(priority: .userInitiated) {
            FormMatch.refine(coarse, reference: reference, tuning: tuning)
        }.value
        if Task.isCancelled { return }
        neighbors = refined
        refining = false
    }

    private var selectableFaces: [FontFace] {
        var faces: [FontFace] = []
        if let face = face(referenceID) { faces.append(face) }
        for neighbor in neighbors where neighbor.face.id != face(referenceID)?.id {
            faces.append(neighbor.face)
        }
        return faces
    }

    private func selectFace(_ face: FontFace) {
        let flags = NSEvent.modifierFlags
        let order = selectableFaces
        if flags.contains(.shift),
           let anchor = selectionAnchor,
           let from = order.firstIndex(where: { $0.id == anchor }),
           let to = order.firstIndex(where: { $0.id == face.id }) {
            let ids = Set(order[min(from, to)...max(from, to)].map(\.id))
            store.selection = flags.contains(.command) ? store.selection.union(ids) : ids
            if !flags.contains(.command) { store.outsideSelection = [] }
        } else if flags.contains(.command) {
            if store.selection.contains(face.id) {
                store.selection.remove(face.id)
            } else {
                store.selection.insert(face.id)
            }
            selectionAnchor = face.id
        } else {
            store.selection = [face.id]
            store.outsideSelection = []
            selectionAnchor = face.id
        }
    }

    private func loadSearch(applySelection: Bool) {
        guard let search = currentSearch else { return }
        guard let face = store.fonts.first(where: { $0.identity == search.referenceIdentity }) else { return }
        let changed = referenceID != face.id
        referenceID = face.id
        if applySelection, changed || !store.selection.contains(face.id) {
            store.selection = [face.id]
            store.outsideSelection = []
        }
    }

    private func adopt(_ face: FontFace) {
        referenceID = face.id
        guard let searchID, let search = currentSearch else { return }
        let previousTitle = search.title
        let previousQuery = search.query
        store.updateShapeSearch(searchID, referenceIdentity: face.identity, query: face.family)
        if previousTitle == "New shape" || previousTitle == previousQuery {
            store.renameTitle = face.family
            store.titlePending = TitlePending(kind: .shape, itemID: searchID)
            store.commitRenameTitle()
        }
    }
}
