import FontsoCore
import SwiftUI
import UniformTypeIdentifiers

/// A grey segmented switch: the chosen segment sits on a lighter grey, the rest stay dim.
struct ChromeSegments<Value: Hashable>: View {
    struct Item {
        var title: String
        var value: Value
        var help: String
    }

    var items: [Item]
    @Binding var selection: Value
    /// The tiny form in the dock header.
    var compact = false
    var onSelect: ((Value) -> Void)?
    @Environment(\.surface) private var surface

    var body: some View {
        HStack(spacing: 1) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let active = item.value == selection
                Button {
                    selection = item.value
                    onSelect?(item.value)
                } label: {
                    Text(item.title)
                        .font(AppChrome.type(compact ? 9 : 11, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? surface.ink : surface.half)
                        .padding(.horizontal, compact ? 5 : 14)
                        .padding(.vertical, compact ? 1.5 : 4)
                        .background(
                            active ? surface.selection : Color.clear,
                            in: RoundedRectangle(cornerRadius: compact ? 2 : 4, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.help)
            }
        }
        .padding(1)
        .background(surface.control, in: RoundedRectangle(cornerRadius: compact ? 3 : 5, style: .continuous))
    }
}

/// The second row of navigation inside a tab: Match and Mix in Shape, Align and Overlay in Compare. The open
/// entry is ink with a line under it; a hairline closes the row.
struct SubNavigation<Value: Hashable>: View {
    struct Item {
        var title: String
        var value: Value
        var help: String
    }

    var items: [Item]
    @Binding var selection: Value
    var onSelect: ((Value) -> Void)?
    @Environment(\.surface) private var surface

    var body: some View {
        HStack(spacing: 18) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let active = item.value == selection
                Button {
                    selection = item.value
                    onSelect?(item.value)
                } label: {
                    Text(item.title)
                        .font(AppChrome.type(11, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? surface.ink : surface.half)
                        .frame(height: 27)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(active ? surface.ink : Color.clear)
                                .frame(height: 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.help)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        // Room above the tabs, so they read as the modes of what follows and not as part of the pinned fonts.
        .padding(.top, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(surface.hairline).frame(height: 0.5)
        }
    }
}

extension View {
    /// The row of settings under a sub-navigation: the same margins in every mode, closed by a hairline.
    func settingsBar() -> some View {
        modifier(SettingsBar())
    }
}

private struct SettingsBar: ViewModifier {
    @Environment(\.surface) private var surface

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(surface.hairline).frame(height: 0.5)
            }
    }
}

/// A chip that carries a symbol and opens a menu: the three dots, to Playground.
struct ChipMenu<Content: View>: View {
    var symbol: String
    var help: String
    @ViewBuilder var content: Content
    @Environment(\.surface) private var surface

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: symbol)
                .font(.system(size: symbol == "ellipsis" ? 10 : 9, weight: .semibold))
                .foregroundStyle(surface.ink)
                .frame(width: 20, height: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(surface.control, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .help(help)
    }
}

/// The slider of the sketch: a hairline with a round knob. A double-click goes back to the default.
struct ThinSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var onReset: (() -> Void)?
    @Environment(\.surface) private var surface

    var body: some View {
        GeometryReader { proxy in
            let knob: CGFloat = 9
            let track = max(proxy.size.width - knob, 1)
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? min(1, max(0, (value - range.lowerBound) / span)) : 0
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(surface.half)
                    .frame(height: 0.5)
                    .padding(.horizontal, knob / 2)
                Circle()
                    .fill(surface.ink)
                    .frame(width: knob, height: knob)
                    .offset(x: track * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let position = min(1, max(0, (drag.location.x - knob / 2) / track))
                        value = range.lowerBound + span * position
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onReset?() })
        }
        .frame(height: 14)
    }
}

/// One line of Adjust in the dock: label, hairline slider, and the number, which can also be typed.
struct DockSliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var fraction: Int
    var reset: () -> Void
    @Environment(\.surface) private var surface

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AppChrome.small)
                .foregroundStyle(surface.ink)
                .lineLimit(1)
                .frame(width: 58, alignment: .leading)
            ThinSlider(
                value: Binding(
                    get: { value },
                    set: { value = SpecimenView.snap($0, step: step, range: range) }
                ),
                range: range,
                onReset: reset
            )
            .help("Drag to change \(title). Double-click for the default.")
            DockNumberField(value: $value, range: range, fraction: fraction)
                .help("Type a value for \(title), then press Return")
            IconChip(symbol: "arrow.counterclockwise", quiet: true, help: "Reset \(title)", action: reset)
        }
    }
}

/// The number beside a slider. What is typed stays as typed until Return or a click elsewhere; only then it is
/// read, kept inside the range, and handed on. So a half-typed number never moves the value under the cursor.
struct DockNumberField: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var fraction: Int
    var width: CGFloat = 40
    @State private var text = ""
    @State private var edited = false
    @FocusState private var focused: Bool
    @Environment(\.surface) private var surface

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(AppChrome.small.monospacedDigit())
            .foregroundStyle(surface.ink)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .frame(width: width)
            .background(surface.control, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .focused($focused)
            .onAppear { text = shown(value) }
            .onChange(of: text) { _, typed in
                if focused, typed != shown(value) { edited = true }
            }
            .onChange(of: value) { _, next in
                // The slider or a reset moved the value: show it, unless a number is being typed right now.
                if !(focused && edited) { text = shown(next) }
            }
            .onChange(of: focused) { _, now in
                if !now { commit() }
            }
            .onSubmit(commit)
    }

    private func shown(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0...fraction)).grouping(.never))
    }

    /// Reads what was typed, with a comma or a point as the decimal mark.
    private func commit() {
        defer {
            edited = false
            text = shown(value)
        }
        guard edited else { return }
        let cleaned = text
            .replacingOccurrences(of: ",", with: ".")
            .filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard let typed = Double(cleaned), typed.isFinite else { return }
        value = min(range.upperBound, max(range.lowerBound, typed))
    }
}

/// The chip on the card of a variable font. It opens that font's own axes, one slider each. Every font keeps its
/// own values.
struct VariableAxesButton: View {
    @Environment(LibraryStore.self) private var store
    var face: FontFace
    @State private var open = false

    var body: some View {
        let changed = store.axisValues[face.id] != nil
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 8, weight: .medium))
                Text("Axes")
            }
        }
        .buttonStyle(.chip(on: changed || open))
        .help(changed
            ? "The axes of this variable font were changed. Click to adjust or reset them."
            : "Variable font. Click to adjust its axes; the values belong to this font only.")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VariableAxesPanel(face: face)
        }
    }
}

private struct VariableAxesPanel: View {
    @Environment(LibraryStore.self) private var store
    var face: FontFace
    /// The values the named instance itself sets.
    @State private var base: [UInt32: Double] = [:]

    var body: some View {
        let values = store.axisValues[face.id] ?? [:]
        let axes = face.axes.filter { $0.max > $0.min }
        let instances = store.instances(of: face)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(face.family)
                        .font(AppChrome.type(12, weight: .medium))
                        .foregroundStyle(AppChrome.ink)
                        .lineLimit(1)
                    Text(values.isEmpty ? "Instance: \(face.style)" : "From \(face.style), changed")
                        .font(AppChrome.small)
                        .foregroundStyle(AppChrome.half)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if instances.count > 1 {
                    Menu {
                        ForEach(instances) { instance in
                            Button(instance.style) { take(instance, axes: axes) }
                        }
                    } label: {
                        Text("Instances")
                    }
                    .chromeMenuChip(compact: true)
                    .help("Set the sliders to one of the named instances of this file")
                }
                IconChip(symbol: "arrow.counterclockwise", help: "Reset every axis to \(face.style)") {
                    store.axisValues[face.id] = nil
                }
                .disabled(values.isEmpty)
            }
            Rectangle()
                .fill(AppChrome.hairline)
                .frame(height: 0.5)
            ForEach(axes) { axis in
                let span = axis.max - axis.min
                DockSliderRow(
                    title: axis.name.isEmpty ? axis.tagName : axis.name,
                    value: Binding(
                        get: { values[axis.tag] ?? base[axis.tag] ?? axis.defaultValue },
                        set: { store.setAxis(axis.tag, to: $0, for: face) }
                    ),
                    range: axis.min...axis.max,
                    step: span >= 50 ? 1 : span >= 5 ? 0.1 : 0.01,
                    fraction: span >= 50 ? 0 : span >= 5 ? 1 : 2,
                    reset: { store.setAxis(axis.tag, to: nil, for: face) }
                )
            }
            if axes.isEmpty {
                Text("This file names no axis that can be changed.")
                    .font(AppChrome.small)
                    .foregroundStyle(AppChrome.half)
            }
        }
        .padding(12)
        .frame(width: 320)
        .background { Rectangle().fill(AppChrome.panel).ignoresSafeArea() }
        .paperColors(ink: AppChrome.ink, paper: AppChrome.panel)
        .onAppear { base = Self.instanceValues(face) }
    }

    /// Moves every slider to the values of a named instance.
    private func take(_ instance: FontFace, axes: [VariationAxis]) {
        if instance.id == face.id {
            store.axisValues[face.id] = nil
            return
        }
        let target = Self.instanceValues(instance)
        var next: [UInt32: Double] = [:]
        for axis in axes {
            next[axis.tag] = target[axis.tag] ?? axis.defaultValue
        }
        store.axisValues[face.id] = next
    }

    /// The axis values a named instance sets. Axes it leaves alone are at the font's default.
    static func instanceValues(_ face: FontFace) -> [UInt32: Double] {
        guard let font = SpecimenFont.make(path: face.filePath, index: face.faceIndex, size: 12, variations: [:]),
              let raw = CTFontCopyVariation(font) as? [NSNumber: NSNumber] else { return [:] }
        var result: [UInt32: Double] = [:]
        for (tag, value) in raw {
            result[tag.uint32Value] = value.doubleValue
        }
        return result
    }
}

/// A chip that carries a symbol instead of a word: pin, to Playground, the three dots.
struct IconChip: View {
    var symbol: String
    var on = false
    /// Only the symbol, with a grey field under the pointer. For rows of small cards, where a filled chip is too loud.
    var quiet = false
    var help: String
    var action: () -> Void
    @Environment(\.surface) private var surface
    @Environment(\.paperColor) private var paperColor
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(quiet ? (on || hovering ? surface.ink : surface.half) : on ? (paperColor ?? AppChrome.panel) : surface.ink)
                .frame(width: quiet ? 14 : 16, height: quiet ? 14 : 15)
                .background(
                    quiet
                        ? surface.ink.opacity(hovering ? 0.16 : 0)
                        : on ? surface.ink.opacity(hovering ? 0.85 : 1) : surface.ink.opacity(hovering ? 0.26 : 0.14),
                    in: RoundedRectangle(cornerRadius: quiet ? 3 : 4, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(surface.ink.opacity(on || quiet ? 0 : 0.22), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: Dock

/// The strip that floats over a preview mode: sections side by side on a blurred field, hairlines between them.
/// Every section folds to its title; the arrow at the right hides the whole strip.
struct ChromeDock<Content: View>: View {
    var hideHelp = "Hide this strip"
    var onHide: (() -> Void)?
    /// What lies across the strip above its sections: the pinned fonts while they are shown large.
    var above: AnyView?
    @ViewBuilder var content: Content
    @Environment(\.surface) private var surface

    var body: some View {
        VStack(spacing: 0) {
            if let above {
                above
                Rectangle()
                    .fill(surface.hairline)
                    .frame(height: 0.5)
            }
            HStack(alignment: .top, spacing: 0) {
                content
                Spacer(minLength: 0)
                    .layoutPriority(-1)
                if let onHide {
                    Button(action: onHide) {
                        ChromeChevron(open: true)
                            .frame(width: 22)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(RowHover(radius: 0))
                    .help(hideHelp)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(DockBackground())
        .clipShape(RoundedRectangle(cornerRadius: AppChrome.dockRadius, style: .continuous))
    }
}

/// The blurred field of the dock, tinted with the paper it floats over.
struct DockBackground: View {
    @Environment(\.paperColor) private var paperColor
    @Environment(\.surface) private var surface

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppChrome.dockRadius, style: .continuous)
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill((paperColor ?? AppChrome.panel).opacity(0.6)))
            .overlay(shape.stroke(surface.stroke, lineWidth: 0.5))
    }
}

/// The dock while hidden: one chip that brings it back.
struct DockPill: View {
    var title: String
    var help: String
    var action: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(title)
                    ChromeChevron(open: false)
                }
            }
            .buttonStyle(.chip())
            .padding(6)
            .background(DockBackground())
            .help(help)
        }
    }
}

/// One section of the dock. The arrow beside the title folds it to a narrow strip, so the others get its room.
struct DockSection<Accessory: View, Content: View>: View {
    var title: String
    var detail: String?
    /// The least width of the open section.
    var minWidth: CGFloat = 150
    /// Fonts dropped anywhere on the section, its title included. Without it the section takes no drops.
    var onFonts: (([String]) -> Bool)?
    @AppStorage private var open: Bool
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @Environment(\.surface) private var surface
    @State private var targeted = false

    init(
        _ title: String,
        key: String,
        detail: String? = nil,
        minWidth: CGFloat = 150,
        startsOpen: Bool = true,
        onFonts: (([String]) -> Bool)? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.minWidth = minWidth
        self.onFonts = onFonts
        _open = AppStorage(wrappedValue: startsOpen, "fontso.dock.\(key)")
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Button {
                        open.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text(title)
                                .font(AppChrome.small)
                                .foregroundStyle(surface.ink)
                            if let detail {
                                Text(detail)
                                    .font(AppChrome.small.monospacedDigit())
                                    .foregroundStyle(surface.half)
                            }
                            ChromeChevron(open: open, color: surface.half, size: 6, sideways: true)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(open ? "Fold \(title) away" : "Show \(title)")
                    if open {
                        Spacer(minLength: 4)
                        accessory
                    }
                }
                .frame(height: 16)
                if open {
                    content
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: open ? minWidth : nil, maxWidth: open ? .infinity : nil, maxHeight: .infinity, alignment: .topLeading)
            .background {
                Rectangle().fill(targeted ? surface.selection : Color.clear)
            }
            .modifier(FontDrop(onFonts: onFonts, targeted: $targeted))
            Rectangle()
                .fill(surface.hairline)
                .frame(width: 0.5)
        }
    }
}

extension DockSection where Accessory == EmptyView {
    init(_ title: String, key: String, detail: String? = nil, minWidth: CGFloat = 150, startsOpen: Bool = true, onFonts: (([String]) -> Bool)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, key: key, detail: detail, minWidth: minWidth, startsOpen: startsOpen, onFonts: onFonts, accessory: { EmptyView() }, content: content)
    }
}

/// Takes dragged fonts when there is somewhere for them to go.
private struct FontDrop: ViewModifier {
    var onFonts: (([String]) -> Bool)?
    @Binding var targeted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onFonts {
            content
                .contentShape(Rectangle())
                .dropDestination(for: FontDragItem.self) { items, _ in
                    let identities = items.flatMap(\.identities)
                    guard !identities.isEmpty else { return false }
                    return onFonts(identities)
                } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

/// The standard sample texts as chips: one click sets the pangram, the alphabet, the case pairs, or every character.
struct SampleChips: View {
    @Binding var text: String
    /// The cut whose characters "Glyphs" lists.
    var face: FontFace?
    @State private var showingCharacters = false

    var body: some View {
        let current = showingCharacters ? SampleChoice.characters : SampleChoice.matching(text)
        // The standard samples sit behind the three dots, so the header of Text stays one small button.
        ChipMenu(symbol: "ellipsis", help: "Standard sample texts: pangram, alphabet, case pairs, or every character of the font") {
            chip("Pangram", .pangram, current, help: "The quick brown fox, then figures")
            chip("Alphabet", .alphabet, current, help: "Capitals, lowercase, and figures")
            chip("Aa Bb", .cases, current, help: "Every capital beside its lowercase letter")
            chip("Glyphs", .characters, current, help: "Every character of the selected font")
                .disabled(face == nil)
        }
        .onChange(of: text) { _, value in
            if showingCharacters, SampleChoice.matching(value) != .custom { showingCharacters = false }
        }
        .onChange(of: face?.id) { _, _ in
            if showingCharacters { loadCharacters() }
        }
    }

    private func chip(_ title: String, _ choice: SampleChoice, _ current: SampleChoice, help: String) -> some View {
        Button {
            if choice == .characters {
                loadCharacters()
            } else if let sample = choice.text {
                showingCharacters = false
                text = sample
            }
        } label: {
            if current == choice {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .help(help)
    }

    private func loadCharacters() {
        guard let face else { return }
        let path = face.filePath
        let index = face.faceIndex
        Task { @MainActor in
            let loaded = await Task.detached(priority: .utility) {
                SpecimenCharacters.glyphs(filePath: path, faceIndex: index)
            }.value
            guard let shown = loaded?.shown, !shown.isEmpty else { return }
            showingCharacters = true
            text = shown
        }
    }
}

// MARK: Pinned

/// The three dots of the pin tray: what can be done with every pinned font at once.
struct PinnedMenu: View {
    @Environment(LibraryStore.self) private var store
    /// What the mode itself can send on, such as the mix of Shape.
    var extra: [Extra] = []

    struct Extra: Identifiable {
        var title: String
        var action: () -> Void
        var id: String { title }
    }

    var body: some View {
        let identities = store.pinnedFaces.map(\.identity)
        ChipMenu(symbol: "ellipsis", help: "Sort the pinned fonts, file them in a list, send them to Playground, or unpin them all") {
            ForEach(extra) { item in
                Button(item.title, action: item.action)
            }
            if !extra.isEmpty { Divider() }
            Menu("Sort pinned fonts") {
                PinnedSortItems()
            }
            .disabled(identities.count < 2)
            Menu("Move pinned fonts to list") {
                if store.groups.isEmpty {
                    Button("New list…") { store.showNewGroup = true }
                }
                ForEach(store.menuGroups) { group in
                    Button(store.menuTitle(group)) { store.addToGroup(group.id, identities: identities) }
                }
            }
            Button("Send pinned fonts to Playground") { store.addToPlayground(identities) }
            Divider()
            Button("Unpin all") { store.unpinAll() }
        }
        .disabled(identities.isEmpty)
    }
}

/// The orders the pinned fonts can be put into, as the entries of a menu. Each sorts once; the fonts can be
/// moved by hand afterwards.
struct PinnedSortItems: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        ForEach(PinOrder.Key.allCases, id: \.self) { key in
            Button(key.title) {
                withAnimation(.easeOut(duration: 0.18)) { store.sortPinned(key) }
            }
        }
        Divider()
        Button("Reverse the order") {
            withAnimation(.easeOut(duration: 0.18)) { store.reversePinned() }
        }
    }
}

/// Sort, as a chip with its name: shown while the pinned fonts are large.
struct PinnedSortMenu: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Menu("Sort") {
            PinnedSortItems()
        }
        .chromeMenuChip(compact: true)
        .disabled(store.pinnedFaces.count < 2)
        .help("Sort the pinned fonts by name, weight, width, or category. Drag a font to move it by hand.")
    }
}

/// Switches the pinned fonts between the small row and large cards in rows.
struct PinnedSizeChip: View {
    @Binding var large: Bool

    var body: some View {
        IconChip(
            symbol: large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            on: large,
            help: large ? "Back to the small row" : "Show the pinned fonts large, to sort and move them"
        ) {
            large.toggle()
        }
    }
}

/// The pinned fonts: one small card each, side by side, or large cards in rows. A font dropped here from the
/// navigation is pinned; a font dropped on a card lands beside it, which is how the order is changed.
struct PinnedStrip: View {
    @Environment(LibraryStore.self) private var store
    /// Shape picks its reference here; the other modes open Info.
    var chosen: Int64?
    var onChoose: ((FontFace) -> Void)?
    var emptyNote = "Pin a font, or drag one here from the navigation."
    var swatch: ((FontFace) -> AnyView)?
    var large = false
    /// Three rows of large cards and the top of a fourth, which shows that there is more to scroll to.
    var maxHeight: CGFloat = 278

    var body: some View {
        CutStrip(
            faces: store.pinnedFaces,
            emptyNote: emptyNote,
            chosen: chosen,
            onChoose: onChoose,
            swatch: swatch,
            large: large,
            maxHeight: maxHeight,
            reorders: true
        )
    }
}

/// The pinned fonts large across the dock, above its sections.
struct DockPinnedBoard: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.surface) private var surface
    @Binding var large: Bool
    var emptyNote = "Pin a font, or drag one here from the navigation."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Pinned")
                    .font(AppChrome.small)
                    .foregroundStyle(surface.ink)
                Text("\(store.pinnedFaces.count)")
                    .font(AppChrome.small.monospacedDigit())
                    .foregroundStyle(surface.half)
                Spacer(minLength: 8)
                PinnedSortMenu()
                PinnedSizeChip(large: $large)
                PinnedMenu()
            }
            .frame(height: 16)
            PinnedStrip(emptyNote: emptyNote, large: true, maxHeight: 192)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The pinned fonts in a row at the top of Compare and Shape. The card that is clicked is the reference of the mode.
struct PinnedBar: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.surface) private var surface
    var reference: FontFace?
    /// What the chosen card is in this mode: "Reference", "Lines up to".
    var referenceTitle = "Reference"
    var pickHelp: String
    var emptyNote: String
    var onChoose: (FontFace) -> Void
    var onPick: (FontFace) -> Void
    /// What the three dots offer beside the usual, such as sending the mix on.
    var menuExtra: [PinnedMenu.Extra] = []
    /// Something of the mode on each card, in front of its sample: the colour a font has in Overlay.
    var swatch: ((FontFace) -> AnyView)?

    /// Large cards in rows, to sort and move the fonts. Compare and Shape share the choice.
    @AppStorage("fontso.pinned.large") private var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Pinned")
                    .font(AppChrome.small)
                    .foregroundStyle(surface.ink)
                Text("\(store.pinnedFaces.count)")
                    .font(AppChrome.small.monospacedDigit())
                    .foregroundStyle(surface.half)
                if let reference {
                    Text("\(referenceTitle): \(reference.family) \(reference.style)")
                        .font(AppChrome.small)
                        .foregroundStyle(surface.half)
                        .lineLimit(1)
                        .padding(.leading, 6)
                }
                Spacer(minLength: 8)
                if large { PinnedSortMenu() }
                AddFontButton(title: "Pin font", help: pickHelp, onPick: onPick, iconOnly: true)
                PinnedSizeChip(large: $large)
                PinnedMenu(extra: menuExtra)
            }
            PinnedStrip(chosen: reference?.id, onChoose: onChoose, emptyNote: emptyNote, swatch: swatch, large: large)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }
}

/// Cuts as small cards in one row: a sample, the name, the pin, and where it applies a button that takes the cut out.
/// Fonts dropped on the row are pinned unless the mode takes them itself. Shown large, the cards stand in rows
/// with a word of each cut.
struct CutStrip: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.surface) private var surface
    var faces: [FontFace]
    var emptyNote: String
    /// The card that stands out. Without `onChoose` it is the cut selected for Info.
    var chosen: Int64?
    var onChoose: ((FontFace) -> Void)?
    /// Takes a cut out of what the mode shows.
    var onRemove: ((FontFace) -> Void)?
    var onDrop: (([String]) -> Bool)?
    /// Something of the mode in front of each name.
    var swatch: ((FontFace) -> AnyView)?
    /// Large cards in rows instead of the small row.
    var large = false
    /// The most height the rows take before they scroll.
    var maxHeight: CGFloat = 240
    /// The row is the pinned fonts: a font dropped on a card lands beside it, so the order can be changed.
    var reorders = false
    @State private var targeted = false
    @State private var rowsHeight: CGFloat = 76

    /// Room at both ends for the line that shows where a dragged font lands.
    private let edge: CGFloat = 4

    var body: some View {
        Group {
            if faces.isEmpty {
                Text(emptyNote)
                    .font(AppChrome.small)
                    .foregroundStyle(surface.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
            } else if large {
                ScrollView(.vertical, showsIndicators: rowsHeight > maxHeight) {
                    CardRows(minWidth: 172, spacing: 6) {
                        ForEach(faces) { face in
                            card(face)
                        }
                    }
                    .padding(.horizontal, edge)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
                .frame(height: min(max(rowsHeight, 1), maxHeight))
                .padding(.horizontal, -edge)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(faces) { face in
                            card(face)
                        }
                    }
                    .padding(.horizontal, edge)
                }
                .padding(.horizontal, -edge)
            }
        }
        .background(
            targeted ? surface.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: AppChrome.cardRadius, style: .continuous)
        )
        .contentShape(Rectangle())
        .dropDestination(for: FontDragItem.self) { items, _ in
            let identities = items.flatMap(\.identities)
            guard !identities.isEmpty else { return false }
            if let onDrop { return onDrop(identities) }
            return store.addToPreview(identities)
        } isTargeted: { targeted = $0 }
    }

    private func card(_ face: FontFace) -> some View {
        let selected = onChoose == nil ? store.selection.contains(face.id) : chosen == face.id
        let pinned = store.isPinned(face)
        let moves = reorders && faces.count > 1
        return Group {
            if large {
                largeFace(face, pinned: pinned)
            } else {
                smallFace(face, pinned: pinned)
            }
        }
        .background(
            selected ? surface.selection : surface.card,
            in: RoundedRectangle(cornerRadius: AppChrome.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppChrome.cardRadius, style: .continuous)
                .stroke(selected ? surface.half : surface.hairline, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let onChoose {
                onChoose(face)
            } else {
                store.selectInPreview(face)
            }
        }
        .draggable(FontDragItem(identities: [face.identity]))
        .modifier(CardPlaceDrop(enabled: reorders, gap: large ? 6 : 5) { identities, after in
            place(identities, at: face, after: after)
        })
        .help(
            (onChoose == nil
                ? "\(face.family) \(face.style). Click for its Info; drag it onto a list, a letter, or a text block."
                : "\(face.family) \(face.style). Click to make it the reference.")
                + (moves ? " Drag it onto another pinned font to move it there." : "")
        )
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin") { store.togglePin(face) }
            Button("Show Info") { store.selectInPreview(face) }
            Menu("Add to list") {
                if store.groups.isEmpty {
                    Button("New list…") { store.showNewGroup = true }
                }
                ForEach(store.menuGroups) { group in
                    Button(store.menuTitle(group)) { store.addToGroup(group.id, identities: [face.identity]) }
                }
            }
            if moves {
                Divider()
                Button("Move to the start") { move { store.placePinned([face.identity], before: faces.first?.identity) } }
                    .disabled(faces.first?.id == face.id)
                Button("Move left") { move { store.stepPinned(face, by: -1) } }
                    .disabled(faces.first?.id == face.id)
                Button("Move right") { move { store.stepPinned(face, by: 1) } }
                    .disabled(faces.last?.id == face.id)
                Button("Move to the end") { move { store.placePinned([face.identity], before: nil) } }
                    .disabled(faces.last?.id == face.id)
            }
            if let onRemove {
                Divider()
                Button("Remove") { onRemove(face) }
            }
        }
    }

    private func smallFace(_ face: FontFace, pinned: Bool) -> some View {
        HStack(spacing: 6) {
            if let swatch { swatch(face) }
            FamilySample(face: face, text: "Ag", size: 14)
                .frame(width: 24, height: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(face.family)
                    .foregroundStyle(surface.ink)
                    .lineLimit(1)
                Text(face.style)
                    .foregroundStyle(surface.muted)
                    .lineLimit(1)
            }
            .font(AppChrome.small)
            .frame(maxWidth: 110, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            cardButtons(face, pinned: pinned)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
    }

    /// The large card: a word in the cut, then its whole name with style and category.
    private func largeFace(_ face: FontFace, pinned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            FamilySample(face: face, text: "Hamburgefonts", size: 22)
                .frame(height: 32, alignment: .leading)
            HStack(spacing: 6) {
                if let swatch { swatch(face) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(face.family)
                        .foregroundStyle(surface.ink)
                        .lineLimit(1)
                    Text("\(face.style) · \(face.category.rawValue)")
                        .foregroundStyle(surface.muted)
                        .lineLimit(1)
                }
                .font(AppChrome.small)
                Spacer(minLength: 4)
                cardButtons(face, pinned: pinned)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cardButtons(_ face: FontFace, pinned: Bool) -> some View {
        IconChip(
            symbol: pinned ? "pin.fill" : "pin",
            on: pinned,
            quiet: true,
            help: pinned ? "Pinned. Click to unpin." : "Pin this cut for Compare, Shape, and Playground"
        ) {
            store.togglePin(face)
        }
        if let onRemove {
            IconChip(symbol: "xmark", quiet: true, help: "Take this cut out") { onRemove(face) }
        }
    }

    private func move(_ change: () -> Void) {
        withAnimation(.easeOut(duration: 0.18)) { change() }
    }

    /// Fonts dropped on a card: in front of it, or behind it when they land on its right half.
    private func place(_ identities: [String], at face: FontFace, after: Bool) -> Bool {
        var target: String? = face.identity
        if after {
            let index = faces.firstIndex { $0.id == face.id }
            target = index.flatMap { $0 + 1 < faces.count ? faces[$0 + 1].identity : nil }
        }
        var placed = false
        move { placed = store.placePinned(identities, before: target) }
        return placed
    }
}

/// Cards in rows of equal columns, as many as the width holds. A few cards keep their width and stand at the left.
struct CardRows: Layout {
    var minWidth: CGFloat = 172
    var spacing: CGFloat = 6

    private func grid(_ width: CGFloat) -> (columns: Int, cell: CGFloat) {
        let columns = max(1, Int((width + spacing) / (minWidth + spacing)))
        let cell = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        return (columns, cell)
    }

    private func rowHeights(_ subviews: Subviews, columns: Int, cell: CGFloat) -> [CGFloat] {
        var heights: [CGFloat] = []
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height
            if index % columns == 0 {
                heights.append(height)
            } else {
                heights[heights.count - 1] = max(heights[heights.count - 1], height)
            }
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Asked for its ideal or its widest, the grid is one row of cards at their least width.
        let oneRow = CGFloat(max(subviews.count, 1)) * (minWidth + spacing) - spacing
        let width = proposal.width.map { $0.isFinite ? max($0, 0) : oneRow } ?? oneRow
        let (columns, cell) = grid(width)
        let heights = rowHeights(subviews, columns: columns, cell: cell)
        let total = heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * spacing
        return CGSize(width: width, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard bounds.width.isFinite, !subviews.isEmpty else { return }
        let (columns, cell) = grid(bounds.width)
        let heights = rowHeights(subviews, columns: columns, cell: cell)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let row = index / columns
            let column = index % columns
            if column == 0, row > 0 { y += heights[row - 1] + spacing }
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(column) * (cell + spacing), y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: cell, height: heights[row])
            )
        }
    }
}

/// Takes fonts dropped on one card of the pinned row. While a font hovers, a line at the left or right of the
/// card shows on which side it will land.
private struct CardPlaceDrop: ViewModifier {
    var enabled: Bool
    /// The room between two cards; the line stands in the middle of it.
    var gap: CGFloat
    var perform: ([String], Bool) -> Bool
    @State private var after: Bool?
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        if enabled {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .overlay(alignment: after == true ? .trailing : .leading) {
                    if let after {
                        Capsule()
                            .fill(AppChrome.highlight)
                            .frame(width: 2)
                            .offset(x: (after ? 1 : -1) * (gap / 2 + 1))
                            .allowsHitTesting(false)
                    }
                }
                .onDrop(of: [UTType.json], delegate: Delegate(after: $after, width: width, perform: perform))
        } else {
            content
        }
    }

    private struct Delegate: DropDelegate {
        @Binding var after: Bool?
        var width: CGFloat
        var perform: ([String], Bool) -> Bool

        private func side(_ info: DropInfo) -> Bool {
            width > 0 && info.location.x > width / 2
        }

        func dropEntered(info: DropInfo) {
            after = side(info)
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            let side = side(info)
            if after != side { after = side }
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            after = nil
        }

        func performDrop(info: DropInfo) -> Bool {
            let landing = side(info)
            after = nil
            FontDragItem.load(info.itemProviders(for: [UTType.json])) { items in
                let identities = items.flatMap(\.identities)
                if !identities.isEmpty { _ = perform(identities, landing) }
            }
            return true
        }
    }
}

/// Size, spacing, and line height of the sample, the values Preview and Mix share.
struct SampleAdjustRows: View {
    @AppStorage("fontso.specimenSize") private var size = 48.0
    @AppStorage("fontso.specimen.unit") private var unitRaw = SpecimenUnit.point.rawValue
    @AppStorage("fontso.specimen.tracking") private var tracking = 0.0
    @AppStorage("fontso.specimen.leading") private var leading = 1.2

    private var unit: SpecimenUnit { SpecimenUnit(rawValue: unitRaw) ?? .point }

    var body: some View {
        let displaySize = Binding<Double>(
            get: { unit.display(from: size) },
            set: { size = unit.points(from: $0) }
        )
        let step: Double = unit == .rem ? 0.05 : 1
        let fraction = unit == .rem ? 2 : 1
        let displayLeading = Binding<Double>(
            get: { unit.display(from: size * leading) },
            set: { newValue in
                let points = unit.points(from: newValue)
                leading = size > 0 ? min(2.4, max(0.5, points / size)) : 1.2
            }
        )
        let lower = unit.display(from: size * 0.5)
        let upper = unit.display(from: size * 2.4)
        VStack(alignment: .leading, spacing: 3) {
            DockSliderRow(title: "Size", value: displaySize, range: unit.display(from: 8)...unit.display(from: 240), step: step, fraction: fraction, reset: { size = 48 })
            DockSliderRow(title: "Spacing", value: $tracking, range: -0.08...0.4, step: 0.01, fraction: 2, reset: { tracking = 0 })
            DockSliderRow(title: "Height", value: displayLeading, range: lower...max(lower, upper), step: step, fraction: fraction, reset: { leading = 1.2 })
        }
    }
}

/// The unit switch in the header of an Adjust section.
struct UnitSegments: View {
    @AppStorage("fontso.specimen.unit") private var unitRaw = SpecimenUnit.point.rawValue

    var body: some View {
        ChromeSegments(
            items: SpecimenUnit.allCases.map { .init(title: $0.title, value: $0.rawValue, help: "Sizes in \($0.title)") },
            selection: $unitRaw,
            compact: true
        )
    }
}

extension View {
    /// Dresses a menu as a grey chip with its arrow, so it reads as a control that opens.
    func chromeMenuChip(compact: Bool = false) -> some View {
        modifier(MenuChip(compact: compact))
    }
}

private struct MenuChip: ViewModifier {
    var compact: Bool
    @Environment(\.surface) private var surface

    func body(content: Content) -> some View {
        content
            .menuStyle(.borderlessButton)
            .controlSize(compact ? .mini : .small)
            .fixedSize()
            .font(AppChrome.type(compact ? AppChrome.smallSize : 11))
            .foregroundStyle(surface.ink)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 1.5 : 3)
            .background(surface.control, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(surface.stroke, lineWidth: 0.5)
            )
    }
}
