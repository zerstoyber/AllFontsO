import AppKit
import FontsoCore
import SwiftUI

/// Mix, under the pinned fonts of Shape: every letter of the sample text set in its own cut. The cuts are the
/// pinned ones, or come from the whole view at random, or from families close to the selected font in x-height and
/// letter width. Letters take a cut at random or in turn,
/// and any letter can be given a cut by hand. Size, spacing, and line height are the preview's own.
struct LetterMixView: View {
    @Environment(LibraryStore.self) private var store
    /// The sample text of Preview, Compare, and Shape: what is typed in one shows in all.
    @AppStorage("fontso.sampleText") private var text = SpecimenText.standard
    @AppStorage("fontso.specimenSize") private var size = 48.0
    @AppStorage("fontso.specimen.unit") private var unitRaw = SpecimenUnit.point.rawValue
    @AppStorage("fontso.specimen.tracking") private var tracking = 0.0
    @AppStorage("fontso.specimen.leading") private var leading = 1.2
    /// A mix starts from the pinned cuts.
    @AppStorage("fontso.mix.cuts") private var sourceRaw = MixSource.chosen.rawValue
    @AppStorage("fontso.mix.count") private var count = 6
    @AppStorage("fontso.mix.order") private var orderRaw = MixOrder.random.rawValue
    @AppStorage("fontso.mix.sameLetter") private var sameLetter = false
    @ObservedObject private var theme = PaperSettings.shared
    @AppStorage("fontso.mix.adjustOpen") private var adjustOpen = true
    @Environment(\.undoManager) private var undoManager
    @StateObject private var model = MixModel()
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editorHeight: CGFloat = 160
    @State private var adjustHeight: CGFloat = 120
    @State private var finding = false

    private var pool: [String] { model.pool }
    private var seed: UInt64 { model.seed }
    private var dealt: [Int: UInt64] { model.dealt }
    private var byPosition: [Int: String] { model.byPosition }
    private var byLetter: [String: String] { model.byLetter }

    private var source: MixSource { MixSource(rawValue: sourceRaw) ?? .chosen }
    private var order: MixOrder { MixOrder(rawValue: orderRaw) ?? .random }
    private var unit: SpecimenUnit { SpecimenUnit(rawValue: unitRaw) ?? .point }

    var body: some View {
        let known = store.facesKeyedByIdentity
        let cuts = poolFaces(known)
        let letters = MixText.letters(in: text)
        let assigned = assignment(letters, cuts: cuts, known: known)
        VStack(spacing: 0) {
            controls(cuts)
                .settingsBar()
            ZStack(alignment: .bottom) {
                ColumnScroll(bottomInset: adjustHeight + 28) {
                    VStack(alignment: .leading, spacing: 16) {
                        board(letters, assigned: assigned, cuts: cuts)
                        let picked = selectedLetters(letters)
                        if !picked.isEmpty, !cuts.isEmpty {
                            letterBar(picked, letters: letters, cuts: cuts)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                adjustDock(cuts)
                    .padding(.horizontal, AppChrome.dockInset)
                    .padding(.bottom, 12)
                    .reportOverlayHeight()
            }
            .onPreferenceChange(OverlayHeightKey.self) { adjustHeight = $0 }
        }
        .dropDestination(for: FontDragItem.self) { items, _ in
            addToPool(items.flatMap(\.identities))
        }
        // From the three dots beside the pinned fonts: the mix as a block, with its letters, size, spacing, and line height.
        .onReceive(NotificationCenter.default.publisher(for: .fontsoMixToPlayground)) { _ in
            guard !cuts.isEmpty, !text.isEmpty else { return }
            sendToPlayground(cuts)
        }
        .task(id: refillKey) {
            // After an undo the pool already belongs to this key; keep it.
            guard model.poolKey != refillKey || model.pool.isEmpty else { return }
            await refill()
        }
        .onAppear { deal(keepingDealt: true) }
        .onChange(of: text) { _, _ in deal(keepingDealt: true) }
    }

    // MARK: Controls

    private func controls(_ cuts: [FontFace]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ChromeSegments(
                    items: MixSource.allCases.map { .init(title: $0.title, value: $0.rawValue, help: $0.help) },
                    selection: undoable($sourceRaw, "Change Cuts"),
                    compact: true
                )
                if source != .chosen {
                    Stepper("\(count) cuts", value: undoable($count, "Change Number of Cuts"), in: 2...16)
                        .font(AppChrome.small)
                        .controlSize(.mini)
                        .fixedSize()
                        .help("How many cuts take part")
                    Button("New cuts") {
                        let before = model.snapshot
                        Task {
                            await refill()
                            model.registerUndo(from: before, undoManager, "New Cuts")
                        }
                    }
                    .disabled(finding)
                    .help(source == .random ? "Pick other cuts at random" : "Pick other cuts close to the reference")
                    if finding {
                        ProgressView().controlSize(.small)
                    }
                }
                ChromeSegments(
                    items: MixOrder.allCases.map { .init(title: $0.title, value: $0.rawValue, help: $0.help) },
                    selection: undoable($orderRaw, "Change Letter Order"),
                    compact: true
                )
                Button("Shuffle") {
                    model.change(undoManager, "Shuffle Letters") {
                        model.seed = UInt64.random(in: 1...UInt64.max)
                        deal(keepingDealt: false)
                    }
                }
                .disabled(order != .random || cuts.count < 2)
                .help("Deal the cuts to the letters again. Letters given a cut by hand keep it.")
                Button("Same letter, same cut") {
                    undoable($sameLetter, "Same Letter, Same Cut").wrappedValue.toggle()
                }
                .buttonStyle(.chip(on: sameLetter))
                .help("Every “a” in the text shares one cut")
                if !byPosition.isEmpty || !byLetter.isEmpty {
                    Button {
                        model.change(undoManager, "Clear Hand-Picked") {
                            model.byPosition = [:]
                            model.byLetter = [:]
                        }
                    } label: {
                        Label("Hand-picked", systemImage: "arrow.counterclockwise")
                    }
                    .help("Reset the hand-picked letters: they go back to the shuffle")
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.chip())
        .foregroundStyle(ink)
    }

    /// Adjust and the cuts of the mix float at the bottom of the column, as in Preview, and fold into a chip.
    @ViewBuilder
    private func adjustDock(_ cuts: [FontFace]) -> some View {
        if adjustOpen {
            ChromeDock(hideHelp: "Hide Text, Adjust, and the cuts", onHide: { adjustOpen = false }) {
                DockSection("Text", key: "mix.text") {
                    SampleChips(text: $text, face: cuts.first)
                } content: {
                    TextField("Type here", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(AppChrome.type())
                        .foregroundStyle(ink)
                        .lineLimit(1...3)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .help("The sample text: the same one Preview, Compare, and Match show. The mix sets its letters.")
                }
                DockSection("Adjust", key: "mix.adjust") {
                    UnitSegments()
                } content: {
                    SampleAdjustRows()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The pinned cuts stand in the row at the top. Random and similar cuts are listed here.
                if source != .chosen {
                    DockSection(poolTitle, key: "mix.cuts", detail: "\(cuts.count)", minWidth: 220, onFonts: { addToPool($0) }) {
                        AddFontButton(
                            title: "Add cut",
                            help: "Add a cut to the mix",
                            onPick: { face in _ = addToPool([face.identity]) },
                            isChosen: { face in cuts.contains { $0.id == face.id } },
                            compact: true
                        )
                    } content: {
                        CutStrip(
                            faces: cuts,
                            emptyNote: poolNote,
                            onRemove: { remove($0) },
                            onDrop: { addToPool($0) }
                        )
                        .help(poolNote)
                    }
                }
            }
        } else {
            DockPill(title: source == .chosen ? "Text · Adjust" : "Text · Adjust · Cuts", help: "Show the sample text, Adjust, and the cuts of the mix") {
                adjustOpen = true
            }
        }
    }

    // MARK: The mixed text

    @ViewBuilder
    private func board(_ letters: [NSRange], assigned: [Int: FontFace], cuts: [FontFace]) -> some View {
        if cuts.isEmpty {
            Text(emptyText)
                .font(.uiCallout)
                .foregroundStyle(ink.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        } else {
            let fonts = nsFonts(assigned)
            let fallback = fonts.values.first ?? NSFont.systemFont(ofSize: size)
            VStack(alignment: .leading, spacing: 4) {
                MixEditor(
                    text: $text,
                    fonts: fonts,
                    fallback: fallback,
                    marked: markedOffsets(letters),
                    markColor: theme.ink.withAlphaComponent(0.14),
                    pointSize: size,
                    tracking: tracking * size,
                    leading: leading,
                    textColor: theme.ink,
                    background: paper,
                    measuredHeight: $editorHeight,
                    onEdit: { range, length in
                        model.byPosition = MixText.shift(model.byPosition, replacing: range, with: length)
                        model.dealt = MixText.shift(model.dealt, replacing: range, with: length)
                    },
                    onSelect: { selection = $0 },
                    onDropFont: { identities, offset in
                        guard let offset,
                              let identity = identities.first(where: store.hasFace(identity:)) else { return }
                        let inside = selection.length > 0 && NSLocationInRange(offset, selection)
                        let targets = inside ? selectedLetters(letters) : letters.filter { $0.location == offset }
                        assign(identity, to: targets)
                    }
                )
                .frame(maxWidth: .infinity, minHeight: max(editorHeight, size * max(leading, 1.2) + 48), alignment: .topLeading)
                .padding(.horizontal, -14)
                Text("Type straight into the text. Select letters to give them a cut, or drop a font on a letter.")
                    .font(.uiCaption)
                    .foregroundStyle(ink.opacity(0.55))
            }
        }
    }

    /// Cuts for the selected letters: one tap gives them the cut, and Other cut… brings in any cut of the library.
    private func letterBar(_ picked: [NSRange], letters: [NSRange], cuts: [FontFace]) -> some View {
        let string = text as NSString
        let sample = picked.prefix(8).map { string.substring(with: $0) }.joined()
        let current = Set(picked.compactMap { handPicked(at: $0.location, letter: string.substring(with: $0)) })
        let title: String
        if picked.count == 1 {
            title = sameLetter ? "Every “\(sample)”" : "Letter “\(sample)”"
        } else {
            title = "\(picked.count) letters"
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.uiHeadline)
                    .foregroundStyle(ink)
                if !current.isEmpty {
                    Button("Back to the shuffle") { assign(nil, to: picked) }
                        .buttonStyle(.paper)
                        .help("The selected letters take a cut from the shuffle again")
                }
                Spacer(minLength: 0)
                AddFontButton(
                    title: "Other cut…",
                    help: "Give the selected letters any cut from the library",
                    onPick: { face in assign(face.identity, to: picked) },
                    isChosen: { current.contains($0.identity) }
                )
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(cuts) { cut in
                        Button {
                            assign(cut.identity, to: picked)
                        } label: {
                            VStack(spacing: 2) {
                                glyphs(sample, face: cut)
                                Text(cut.family)
                                    .font(.uiCaption2)
                                    .lineLimit(1)
                                    .frame(maxWidth: 90)
                            }
                            .padding(6)
                            .background(
                                ink.opacity(current.contains(cut.identity) ? 0.18 : 0.06),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(current.contains(cut.identity) ? ink.opacity(0.6) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ink)
                        .help("\(cut.family) \(cut.style)")
                    }
                }
            }
        }
        .padding(10)
        .background(ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func glyphs(_ sample: String, face: FontFace) -> some View {
        if let font = SpecimenFont.make(path: face.filePath, index: face.faceIndex, size: 28, variations: [:]) {
            Text(sample).font(Font(font as CTFont)).lineLimit(1).frame(height: 40)
        } else {
            Text(sample).font(.system(size: 28)).lineLimit(1).frame(height: 40)
        }
    }

    private var poolTitle: String {
        switch source {
        case .chosen: return "Pinned cuts"
        case .random: return "Random cuts"
        case .similar: return "Similar cuts"
        }
    }

    private var poolNote: String {
        switch source {
        case .chosen:
            return "The pinned cuts in the row at the top. Each one takes part in the mix."
        case .random:
            return "Picked at random from what the library column shows, filters included. New cuts deals again."
        case .similar:
            return "Families close to the first preview font in x-height, cap height, and letter width, with the reference itself first."
        }
    }

    private var emptyText: String {
        switch source {
        case .chosen: return "Pin two or more cuts in Preview, or drop them here, to mix their letters."
        case .random: return finding ? "Picking cuts…" : "The view holds no cuts to pick from."
        case .similar:
            if store.previewFace == nil { return "Select a font in the library: the mix looks for families close to it." }
            return finding ? "Looking for close families…" : "No family is close enough."
        }
    }

    // MARK: Logic

    /// Random cuts are dealt again when the source or the count changes; similar ones also when the reference does.
    private var refillKey: String {
        switch source {
        case .chosen: return "chosen"
        case .random: return "random|\(count)|\(store.fonts.count)"
        case .similar: return "similar|\(count)|\(store.previewFace?.identity ?? "")"
        }
    }

    private func poolFaces(_ known: [String: FontFace]) -> [FontFace] {
        switch source {
        case .chosen: return store.pinnedFaces
        case .random, .similar: return pool.compactMap { known[$0] }
        }
    }

    @discardableResult
    private func addToPool(_ identities: [String]) -> Bool {
        let valid = identities.filter(store.hasFace(identity:))
        guard !valid.isEmpty else { return false }
        if source == .chosen {
            return store.addToPreview(valid)
        }
        model.change(undoManager, "Add Cut") {
            for identity in valid where !model.pool.contains(identity) {
                model.pool.append(identity)
            }
        }
        return true
    }

    private func remove(_ face: FontFace) {
        model.change(undoManager, "Remove Cut") { removeNow(face) }
    }

    private func removeNow(_ face: FontFace) {
        switch source {
        case .chosen:
            store.removeFromPreview(face)
        case .random, .similar:
            model.pool.removeAll { $0 == face.identity }
        }
        model.byPosition = model.byPosition.filter { $0.value != face.identity }
        model.byLetter = model.byLetter.filter { $0.value != face.identity }
    }

    private func refill() async {
        let wanted = max(2, count)
        let key = refillKey
        defer { model.poolKey = key }
        switch source {
        case .chosen:
            return
        case .random:
            var candidates = store.visibleFaces
            if candidates.isEmpty { candidates = store.fonts }
            candidates.shuffle()
            var seenFamilies = Set<String>()
            var picked: [String] = []
            // One cut per family first, so the mix shows different designs rather than one family's weights.
            for face in candidates where seenFamilies.insert(face.family.lowercased()).inserted {
                picked.append(face.identity)
                if picked.count == wanted { break }
            }
            if picked.count < wanted {
                for face in candidates where !picked.contains(face.identity) {
                    picked.append(face.identity)
                    if picked.count == wanted { break }
                }
            }
            model.pool = picked
        case .similar:
            guard let reference = store.previewFace else {
                model.pool = []
                return
            }
            finding = true
            let library = store.fonts
            var tuning = MatchTuning()
            tuning.weight = false
            tuning.contrast = false
            tuning.slant = false
            tuning.category = false
            tuning.compareLetters = false
            let neighbors = await Task.detached(priority: .userInitiated) {
                FormMatch.neighbors(of: reference, in: library, tuning: tuning, limit: 40)
            }.value
            let others = neighbors.map(\.face.identity).shuffled().prefix(wanted - 1)
            model.pool = [reference.identity] + others
            finding = false
        }
    }

    /// Gives every letter a random number to pick its cut with; with `keepingDealt`, only letters that have none yet.
    private func deal(keepingDealt: Bool) {
        var next = keepingDealt ? dealt : [:]
        let offsets = MixText.letters(in: text).map(\.location)
        let present = Set(offsets)
        next = next.filter { present.contains($0.key) }
        for offset in offsets where next[offset] == nil {
            next[offset] = UInt64.random(in: 0...UInt64.max)
        }
        if next != dealt { model.dealt = next }
    }

    private func selectedLetters(_ letters: [NSRange]) -> [NSRange] {
        guard selection.length > 0 else { return [] }
        let string = text as NSString
        return letters.filter { range in
            NSIntersectionRange(range, selection).length > 0
                && !string.substring(with: range).allSatisfy(\.isWhitespace)
        }
    }

    private func markedOffsets(_ letters: [NSRange]) -> Set<Int> {
        let string = text as NSString
        return Set(letters.filter { handPicked(at: $0.location, letter: string.substring(with: $0)) != nil }.map(\.location))
    }

    private func handPicked(at offset: Int, letter: String) -> String? {
        sameLetter ? byLetter[letter] : byPosition[offset]
    }

    private func assign(_ identity: String?, to letters: [NSRange]) {
        let string = text as NSString
        model.change(undoManager, identity == nil ? "Back to the Shuffle" : "Pick Cut") {
            for range in letters {
                if sameLetter {
                    model.byLetter[string.substring(with: range)] = identity
                } else {
                    model.byPosition[range.location] = identity
                }
            }
        }
    }

    /// A binding that records each change for Undo.
    private func undoable<Value>(_ binding: Binding<Value>, _ name: String) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { value in model.change(undoManager, name) { binding.wrappedValue = value } }
        )
    }

    /// The cut of every letter, keyed by its offset.
    private func assignment(_ letters: [NSRange], cuts: [FontFace], known: [String: FontFace]) -> [Int: FontFace] {
        guard !cuts.isEmpty else { return [:] }
        let string = text as NSString
        var result: [Int: FontFace] = [:]
        var turns: [String: Int] = [:]
        var nextTurn = 0
        for range in letters {
            let letter = string.substring(with: range)
            if !letter.allSatisfy(\.isWhitespace), let identity = handPicked(at: range.location, letter: letter), let face = known[identity] {
                result[range.location] = face
                continue
            }
            switch order {
            case .random:
                let number: UInt64 = sameLetter
                    ? mix(seed ^ letter.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 })
                    : (dealt[range.location] ?? mix(seed ^ UInt64(range.location)))
                result[range.location] = cuts[Int(number % UInt64(cuts.count))]
            case .inTurn:
                if letter.allSatisfy(\.isWhitespace) {
                    result[range.location] = cuts[max(nextTurn - 1, 0) % cuts.count]
                    continue
                }
                let turn: Int
                if sameLetter, let first = turns[letter] {
                    turn = first
                } else {
                    turn = nextTurn
                    turns[letter] = turn
                    nextTurn += 1
                }
                result[range.location] = cuts[turn % cuts.count]
            }
        }
        return result
    }

    private func nsFonts(_ assigned: [Int: FontFace]) -> [Int: NSFont] {
        var made: [String: NSFont] = [:]
        var result: [Int: NSFont] = [:]
        for (offset, face) in assigned {
            if let font = made[face.identity] {
                result[offset] = font
            } else if let font = SpecimenFont.make(path: face.filePath, index: face.faceIndex, size: size, variations: [:]) {
                made[face.identity] = font
                result[offset] = font
            }
        }
        return result
    }

    private func sendToPlayground(_ cuts: [FontFace]) {
        let known = store.facesKeyedByIdentity
        let assigned = assignment(MixText.letters(in: text), cuts: cuts, known: known)
        let letters = assigned.map { MixLetter(at: $0.key, font: $0.value.identity) }.sorted { $0.at < $1.at }
        PlaygroundDocument.shared.change(undoManager, "Add Mix to Playground") {
            PlaygroundDocument.shared.addMix(text: text, letters: letters, size: size, tracking: tracking, leading: leading)
        }
        store.statusText = "Mix added to the Playground."
    }

    private func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private var paper: NSColor { theme.paper }
    private var ink: Color { Color(nsColor: theme.ink) }
}

/// What Mix holds besides its text, kept in a class so Undo can step back through it.
/// Typing is undone by the text view itself, on the same undo stack.
@MainActor
final class MixModel: ObservableObject {
    @Published var pool: [String] = []
    /// The source, count, and reference the pool was dealt for.
    @Published var poolKey = ""
    @Published var seed = UInt64.random(in: 1...UInt64.max)
    /// A random number per letter offset, moved along with edits, so typing elsewhere leaves dealt letters as they are.
    @Published var dealt: [Int: UInt64] = [:]
    /// Cuts given by hand, keyed by letter offset, or by the letter itself when the same letter keeps the same cut.
    @Published var byPosition: [Int: String] = [:]
    @Published var byLetter: [String: String] = [:]

    struct Snapshot {
        var pool: [String]
        var poolKey: String
        var seed: UInt64
        var dealt: [Int: UInt64]
        var byPosition: [Int: String]
        var byLetter: [String: String]
        var settings: [String: Any]
    }

    /// The Mix settings stored in the defaults that Undo also steps back.
    private static let settingKeys = ["fontso.mix.cuts", "fontso.mix.count", "fontso.mix.order", "fontso.mix.sameLetter"]

    var snapshot: Snapshot {
        var settings: [String: Any] = [:]
        for key in MixModel.settingKeys {
            if let value = UserDefaults.standard.object(forKey: key) { settings[key] = value }
        }
        return Snapshot(pool: pool, poolKey: poolKey, seed: seed, dealt: dealt, byPosition: byPosition, byLetter: byLetter, settings: settings)
    }

    private func apply(_ snapshot: Snapshot) {
        for key in MixModel.settingKeys {
            UserDefaults.standard.set(snapshot.settings[key], forKey: key)
        }
        pool = snapshot.pool
        poolKey = snapshot.poolKey
        seed = snapshot.seed
        dealt = snapshot.dealt
        byPosition = snapshot.byPosition
        byLetter = snapshot.byLetter
    }

    func change(_ undoManager: UndoManager?, _ name: String, _ body: () -> Void) {
        let before = snapshot
        body()
        registerUndo(from: before, undoManager, name)
    }

    func registerUndo(from before: Snapshot, _ undoManager: UndoManager?, _ name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            let now = model.snapshot
            model.apply(before)
            model.registerUndo(from: now, undoManager, name)
        }
        undoManager.setActionName(name)
    }
}

enum MixSource: String, CaseIterable, Identifiable {
    case chosen, random, similar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chosen: return "Pinned cuts"
        case .random: return "Random"
        case .similar: return "Similar"
        }
    }

    var help: String {
        switch self {
        case .chosen: return "Mix the pinned cuts"
        case .random: return "Mix cuts picked at random from the library view"
        case .similar: return "Mix cuts close to the selected font in x-height and letter width"
        }
    }
}

enum MixOrder: String, CaseIterable, Identifiable {
    case random, inTurn
    var id: String { rawValue }
    var title: String {
        switch self {
        case .random: return "Shuffled"
        case .inTurn: return "In turn"
        }
    }

    var help: String {
        switch self {
        case .random: return "Letters take a cut at random"
        case .inTurn: return "Letters take the cuts one after another"
        }
    }
}
