import AppKit
import FontsoCore
import SwiftUI

/// Shape: the pinned fonts in a row at the top, one of them the reference, and under it the library ranked by how
/// close each family comes to that reference in its measurements and drawn letters.
struct ShapeView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.surface) private var surface
    @AppStorage("fontso.sampleText") private var sample = SpecimenText.standard
    /// Size, spacing, and line height are the ones Preview uses, so a match looks here as it does there.
    @AppStorage("fontso.specimenSize") private var specimenSize = 48.0
    @AppStorage("fontso.specimen.tracking") private var tracking = 0.0
    @AppStorage("fontso.specimen.leading") private var leading = 1.2
    @ObservedObject private var theme = PaperSettings.shared
    @State private var editorHeights: [Int64: CGFloat] = [:]
    @AppStorage("fontso.shapeSampleOpen") private var dockOpen = true
    /// The pinned font the matches are measured against.
    @AppStorage("fontso.shape.reference") private var referenceIdentity = ""
    /// The chosen measurements and letters, as JSON.
    @AppStorage("fontso.shape.tuning") private var tuningJSON = ""
    @State private var dockHeight: CGFloat = 72
    @State private var selectionAnchor: Int64?
    @State private var neighbors: [FormNeighbor] = []
    @State private var refining = false
    @State private var dropTargeted = false

    var body: some View {
        let reference = reference
        VStack(spacing: 0) {
            pinnedBar(reference)
            Rectangle()
                .fill(surface.hairline)
                .frame(height: 0.5)
            // Only what is under the pinned fonts changes: the matches of the reference, or the mix of the cuts.
            // Each mode brings its settings in a row of its own, then its content.
            SubNavigation(
                items: ShapeMode.allCases.map { .init(title: $0.title, value: $0, help: $0.help) },
                selection: Bindable(store).shapeMode
            )
            if store.shapeMode == .mix {
                LetterMixView()
            } else {
                matchBoard(reference)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(surface.ink, lineWidth: 1)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        // A font dropped anywhere on Shape is pinned and becomes the reference.
        .dropDestination(for: FontDragItem.self) { items, _ in
            adopt(items.flatMap(\.identities))
        } isTargeted: { dropTargeted = $0 }
        .task(id: rankKey) {
            await rank()
        }
    }

    /// Match: the reference and the library ranked against it, with Text and Adjust floating at the bottom.
    private func matchBoard(_ reference: FontFace?) -> some View {
        VStack(spacing: 0) {
            tuningRow
                .settingsBar()
            matchContent(reference)
        }
    }

    private func matchContent(_ reference: FontFace?) -> some View {
        ZStack(alignment: .bottom) {
                ScrollViewReader { scroller in
                    ColumnScroll(bottomInset: dockHeight + 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            if let reference {
                                Text(matchNote(reference))
                                    .font(AppChrome.small)
                                    .foregroundStyle(surface.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                specimenCard(reference, score: nil)
                            }
                            libraryBlock(reference)
                        }
                        .padding(.leading, 16)
                        .padding(.trailing, 9)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(ArrowKeyCatcher { direction, flags in
                        step(direction, flags: flags, scroller: scroller)
                    })
                }
            Group {
                if dockOpen {
                    ChromeDock(hideHelp: "Hide Text and Adjust", onHide: { dockOpen = false }) {
                        DockSection("Text", key: "shape.text") {
                            SampleChips(text: $sample, face: reference)
                        } content: {
                            TextField("Sample text for the matches", text: $sample, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(AppChrome.type())
                                .foregroundStyle(surface.ink)
                                .lineLimit(1...3)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .help("The sample text of the reference and of every match")
                        }
                        DockSection("Adjust", key: "shape.adjust") {
                            UnitSegments()
                        } content: {
                            SampleAdjustRows()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help("Size, spacing, and line height of the samples, as in Preview")
                        }
                    }
                } else {
                    DockPill(title: "Text · Adjust", help: "Show the sample text and its size") {
                        dockOpen = true
                    }
                }
            }
            .padding(.horizontal, AppChrome.dockInset)
            .padding(.bottom, 12)
            .reportOverlayHeight()
        }
        .onPreferenceChange(OverlayHeightKey.self) { dockHeight = $0 }
    }

    // MARK: Reference

    /// The chosen pinned font, or the first one while nothing is chosen.
    private var reference: FontFace? {
        let pinned = store.pinnedFaces
        return pinned.first { $0.identity == referenceIdentity } ?? pinned.first
    }

    /// Pins the fonts and makes the first of them the reference.
    @discardableResult
    private func adopt(_ identities: [String]) -> Bool {
        let valid = identities.filter { store.hasFace(identity: $0) }
        guard let first = valid.first else { return false }
        store.addToPreview(valid)
        referenceIdentity = first
        return true
    }

    private func pinnedBar(_ reference: FontFace?) -> some View {
        PinnedBar(
            reference: reference,
            pickHelp: "Search the library and pin a font as the reference",
            emptyNote: "Pin a font in Preview, or drag one here from the navigation. The pinned font you click is the reference; Match lists the families closest to it, Mix sets every letter in another pinned cut.",
            onChoose: { face in referenceIdentity = face.identity },
            onPick: { face in adopt([face.identity]) },
            menuExtra: store.shapeMode == .mix
                ? [.init(title: "Send this mix to Playground") { NotificationCenter.default.post(name: .fontsoMixToPlayground, object: nil) }]
                : []
        )
    }

    /// A cut as Preview shows it: name and buttons in the header, the editable sample under it, grey when selected.
    /// The reference carries its mark, a match how close it comes.
    private func specimenCard(_ face: FontFace, score: Int?) -> some View {
        let selected = store.selection.contains(face.id)
        let pinned = store.isPinned(face)
        let active = face.activation.isAvailableToApps
        let ground = selected ? selectedPaper : theme.paper
        let shape = RoundedRectangle(cornerRadius: AppChrome.cardRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(face.family)
                    .font(AppChrome.type(AppChrome.smallSize + 1, weight: .medium))
                    .foregroundStyle(surface.ink)
                    .lineLimit(1)
                Text("\(face.style), \(face.format.uppercased())")
                    .font(AppChrome.small)
                    .foregroundStyle(surface.half)
                    .lineLimit(1)
                if face.isVariable, !face.axes.isEmpty {
                    VariableAxesButton(face: face)
                }
                Spacer(minLength: 8)
                if let score {
                    Text("\(score) %")
                        .font(AppChrome.small.monospacedDigit())
                        .foregroundStyle(surface.ink)
                        .help("\(score) percent alike")
                } else {
                    Text("Reference")
                        .font(AppChrome.small)
                        .foregroundStyle(surface.half)
                        .help("The matches below are measured against this font")
                }
                Button("Info") { select(face) }
                    .buttonStyle(.chip(on: selected))
                    .help(selected ? "Selected: its Info shows under the navigation" : "Select this cut and show its Info under the navigation")
                Button(active ? (face.canDeactivate ? "Active" : face.activation.label) : "Activate") {
                    store.toggle(face)
                }
                .buttonStyle(.chip(on: active))
                .disabled(!face.canActivate && !face.canDeactivate)
                .help(active ? "Available to other apps. Click to deactivate it." : "Activate this file so other apps can use it.")
                IconChip(symbol: "plus.rectangle.on.rectangle", help: "To Playground: add this font as a new text block") {
                    store.addToPlayground([face.identity])
                }
                IconChip(
                    symbol: pinned ? "pin.fill" : "pin",
                    on: pinned,
                    help: pinned ? "Pinned. Click to unpin." : "Pin this font, so it joins the row at the top"
                ) {
                    store.togglePin(face)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .onTapGesture { select(face) }
            .draggable(FontDragItem(identities: store.identitiesForDrag(face)))
            SpecimenEditor(
                text: $sample,
                face: face,
                pointSize: specimenSize,
                tracking: tracking * specimenSize,
                leading: leading,
                textColor: theme.ink,
                background: ground,
                variations: store.axisValues[face.id] ?? [:],
                measuredHeight: Binding(
                    get: { editorHeights[face.id] ?? 120 },
                    set: { editorHeights[face.id] = $0 }
                ),
                onFocus: { select(face) }
            )
            .frame(
                maxWidth: .infinity,
                minHeight: max(editorHeights[face.id] ?? 120, specimenSize * max(leading, 1.2) + 48),
                alignment: .topLeading
            )
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: ground))
        .clipShape(shape)
        .overlay(shape.stroke(surface.stroke, lineWidth: 0.5))
        .contextMenu { listMenu(face) }
        .id(face.id)
    }

    /// The grey a selected cut sits on: the paper, a step towards the ink.
    private var selectedPaper: NSColor {
        let base = theme.paper.usingColorSpace(.sRGB) ?? theme.paper
        let top = theme.ink.usingColorSpace(.sRGB) ?? theme.ink
        return base.blended(withFraction: 0.15, of: top) ?? base
    }

    // MARK: Tuning

    private var tuning: MatchTuning {
        guard let data = tuningJSON.data(using: .utf8),
              let stored = try? JSONDecoder().decode(MatchTuning.self, from: data) else { return .standard }
        return stored
    }

    private func setTuning(_ change: (inout MatchTuning) -> Void) {
        var updated = tuning
        change(&updated)
        guard let data = try? JSONEncoder().encode(updated), let json = String(data: data, encoding: .utf8) else { return }
        tuningJSON = json
    }

    private struct Factor: Identifiable {
        var title: String
        var help: String
        var keyPath: WritableKeyPath<MatchTuning, Bool>
        var id: String { title }
    }

    private static let factors: [Factor] = [
        Factor(title: "x-height", help: "Height of the lowercase letters, as recorded in the font.", keyPath: \.xHeight),
        Factor(title: "cap-height", help: "Height of the capitals, as recorded in the font.", keyPath: \.capHeight),
        Factor(title: "Width", help: "Average letter width and the width class, condensed through extended.", keyPath: \.width),
        Factor(title: "Weight", help: "Weight class, thin through black.", keyPath: \.weight),
        Factor(title: "Contrast", help: "Difference between thick and thin strokes.", keyPath: \.contrast),
        Factor(title: "Slant", help: "Upright against italic.", keyPath: \.slant),
        Factor(title: "Category", help: "Sans, serif, slab, script, mono.", keyPath: \.category),
    ]

    private static let letterPresets = ["no", "ag", "RG", "ea", "Mk"]

    /// The settings of Match, in one row like those of Mix: the measurements that count, the drawn letters, and
    /// the way back to the standard. Filled chips count. A narrow window breaks the row in two.
    private var tuningRow: some View {
        let tuning = tuning
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                factorChips(tuning)
                letterChips(tuning)
                Spacer(minLength: 0)
                standardChip(tuning)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    factorChips(tuning)
                    Spacer(minLength: 0)
                    standardChip(tuning)
                }
                letterChips(tuning)
            }
        }
    }

    private func factorChips(_ tuning: MatchTuning) -> some View {
        HStack(spacing: 4) {
            ForEach(Self.factors) { factor in
                Button(factor.title) {
                    setTuning { $0[keyPath: factor.keyPath].toggle() }
                }
                .buttonStyle(.chip(on: tuning[keyPath: factor.keyPath]))
                .help(factor.help)
            }
        }
        .fixedSize()
    }

    private func letterChips(_ tuning: MatchTuning) -> some View {
        HStack(spacing: 4) {
            Button("Letters") {
                setTuning { $0.compareLetters.toggle() }
            }
            .buttonStyle(.chip(on: tuning.compareLetters))
            .help("Draws these letters in the reference and in each candidate, then compares the drawings.")
            TextField("Letters", text: lettersBinding)
                .textFieldStyle(.plain)
                .font(AppChrome.small)
                .foregroundStyle(surface.ink)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .frame(width: 56)
                .background(surface.control, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .disabled(!tuning.compareLetters)
                .opacity(tuning.compareLetters ? 1 : 0.5)
                .help("Up to \(MatchTuning.letterLimit) letters. Pick the ones that show the character of the typeface.")
            ForEach(Self.letterPresets, id: \.self) { preset in
                Button(preset) {
                    setTuning {
                        $0.letters = preset
                        $0.compareLetters = true
                    }
                }
                .buttonStyle(.chip(on: tuning.compareLetters && tuning.letters == preset))
                .help("Compare the letters \(preset)")
            }
        }
        .fixedSize()
    }

    private func standardChip(_ tuning: MatchTuning) -> some View {
        IconChip(symbol: "arrow.counterclockwise", help: "Reset: compare all measurements again, without drawn letters") {
            setTuning { $0 = .standard }
        }
        .disabled(tuning.isStandard)
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

    private func letterSentence(_ letters: [Character]) -> String {
        let names = letters.map(String.init)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
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
        case 0: note = "Nothing is compared yet. Switch on a measurement or the letters."
        case 1: note = "Matched on \(parts[0])."
        case 2: note = "Matched on \(parts[0]) and \(parts[1])."
        default: note = "Matched on " + parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1] + "."
        }
        if (tuning.xHeight || tuning.width), face.xHeight == 0 || face.averageWidth == 0 {
            note += " This font has no recorded proportions, so those measurements are skipped."
        }
        if !tuning.comparesProportions, !letters.isEmpty {
            note += " Only the drawn letters count, so every family is drawn once; the first pass takes a moment."
        }
        return note
    }

    // MARK: Matches

    private func libraryBlock(_ reference: FontFace?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("In your library")
                    .font(AppChrome.type(12, weight: .medium))
                    .foregroundStyle(surface.ink)
                if !neighbors.isEmpty {
                    Text("\(neighbors.count)")
                        .font(AppChrome.type().monospacedDigit())
                        .foregroundStyle(surface.half)
                }
                if refining {
                    ProgressView()
                        .controlSize(.small)
                    Text("Drawing \(letterSentence(tuning.letterList))")
                        .font(AppChrome.small)
                        .foregroundStyle(surface.half)
                }
            }
            if neighbors.isEmpty {
                Text(emptyText(reference))
                    .font(AppChrome.type())
                    .foregroundStyle(surface.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(neighbors) { neighbor in
                        specimenCard(neighbor.face, score: neighbor.score)
                    }
                }
            }
        }
    }

    private func emptyText(_ reference: FontFace?) -> String {
        if reference == nil { return "No reference yet. Pin a font to start." }
        if refining { return "Drawing the letters of every family…" }
        if !tuning.comparesAnything { return "Switch on a measurement or the letters above." }
        return "No other family is close enough."
    }

    /// Everything the ranking depends on. Compared as values, so the task only restarts when one of them changes.
    private struct RankKey: Hashable {
        var reference: Int64
        var fontCount: Int
        var tuning: MatchTuning
    }

    private var rankKey: RankKey {
        RankKey(reference: reference?.id ?? -1, fontCount: store.fonts.count, tuning: tuning)
    }

    private func rank() async {
        guard let reference else {
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

    // MARK: Selection

    private var selectableFaces: [FontFace] {
        var faces: [FontFace] = []
        let reference = reference
        if let reference { faces.append(reference) }
        for neighbor in neighbors where neighbor.face.id != reference?.id {
            faces.append(neighbor.face)
        }
        return faces
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

    private func select(_ face: FontFace) {
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
            store.infoPanelOpen = true
            selectionAnchor = face.id
        }
    }

    /// Puts this cut, or the whole selection when it is part of it, into one of the user's lists.
    @ViewBuilder
    private func listMenu(_ face: FontFace) -> some View {
        let identities = store.identitiesForDrag(face)
        Button("Use as reference") { adopt([face.identity]) }
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
}
