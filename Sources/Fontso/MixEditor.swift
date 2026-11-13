import AppKit
import SwiftUI

/// One letter of a mix and the cut it is set in. `at` is the letter's UTF-16 offset in the text.
struct MixLetter: Codable, Hashable {
    var at: Int
    var font: String
}

enum MixText {
    /// The UTF-16 range of every letter (composed character) in the text.
    static func letters(in text: String) -> [NSRange] {
        let string = text as NSString
        var ranges: [NSRange] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byComposedCharacterSequences, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }

    /// Moves values keyed by text offset along with an edit: replacing `range` with `length` UTF-16 units.
    static func shift<Value>(_ values: [Int: Value], replacing range: NSRange, with length: Int) -> [Int: Value] {
        let delta = length - range.length
        var result: [Int: Value] = [:]
        for (offset, value) in values {
            if offset < range.location {
                result[offset] = value
            } else if offset >= NSMaxRange(range) {
                result[offset + delta] = value
            }
        }
        return result
    }
}

/// An editable sample where every letter can carry its own font. Selecting letters reports them;
/// a font dropped on a letter is handed back with that letter's offset.
struct MixEditor: NSViewRepresentable {
    @Binding var text: String
    /// Font per letter, keyed by the letter's UTF-16 offset. Letters without one use `fallback`.
    var fonts: [Int: NSFont]
    var fallback: NSFont
    /// Letters given a cut by hand, marked with a soft underlay.
    var marked: Set<Int> = []
    var markColor: NSColor = .clear
    var pointSize: Double
    var tracking: Double
    var leading: Double
    var textColor: NSColor
    var background: NSColor
    @Binding var measuredHeight: CGFloat
    var onEdit: (NSRange, Int) -> Void = { _, _ in }
    var onSelect: (NSRange) -> Void = { _ in }
    /// A click into the text, before the cursor moves there.
    var onClick: () -> Void = {}
    /// A font dropped on the text, with the offset of the letter under it (nil off the letters).
    var onDropFont: ([String], Int?) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MixTextView {
        let textView = MixTextView()
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 14, height: 16)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.string = text
        return textView
    }

    func updateNSView(_ textView: MixTextView, context: Context) {
        context.coordinator.parent = self
        textView.onDropFont = onDropFont
        textView.onClick = onClick
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
        }
        let desired = CGFloat(pointSize * leading)
        let used = Set(fonts.values).union([fallback])
        var pad: CGFloat = 16
        for font in used {
            let overflow = SpecimenInk.overflow(font: font, text: textView.string)
            let natural = font.ascender + abs(font.descender) + max(font.leading, 0)
            pad = max(pad, 16 + max(overflow.top, overflow.bottom) + max(0, natural - desired))
        }
        if abs(textView.textContainerInset.height - pad) > 0.5 {
            textView.textContainerInset = NSSize(width: 14, height: pad)
        }
        textView.layoutManager?.usesFontLeading = false
        let paragraph = SpecimenParagraph.style(lineHeight: desired)
        let base: [NSAttributedString.Key: Any] = [
            .font: fallback,
            .foregroundColor: textColor,
            .kern: tracking,
            .paragraphStyle: paragraph
        ]
        textView.backgroundColor = background
        textView.insertionPointColor = textColor
        textView.typingAttributes = base
        if let storage = textView.textStorage, storage.length > 0 {
            let selected = textView.selectedRanges
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(base, range: all)
            for range in MixText.letters(in: storage.string) {
                if let font = fonts[range.location] {
                    storage.addAttribute(.font, value: font, range: range)
                }
            }
            storage.endEditing()
            textView.selectedRanges = selected
            if let layout = textView.layoutManager {
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
                for offset in marked where offset < storage.length {
                    let range = (storage.string as NSString).rangeOfComposedCharacterSequence(at: offset)
                    layout.addTemporaryAttribute(.backgroundColor, value: markColor, forCharacterRange: range)
                }
            }
        }
        context.coordinator.report(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MixEditor

        init(parent: MixEditor) {
            self.parent = parent
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            if let replacementString {
                parent.onEdit(range, (replacementString as NSString).length)
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string {
                parent.text = view.string
            }
            report(view)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            DispatchQueue.main.async { self.parent.onSelect(range) }
        }

        func report(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let height = max(used.height + view.textContainerInset.height * 2 + 8, 80)
            guard abs(parent.measuredHeight - height) > 1 else { return }
            DispatchQueue.main.async {
                self.parent.measuredHeight = height
            }
        }
    }
}

/// TextKit 1 text view that takes font drags itself: a font dropped on a letter goes to that letter
/// (or to the whole selection when dropped inside it) instead of being inserted as text.
final class MixTextView: NSTextView {
    var onDropFont: ([String], Int?) -> Void = { _, _ in }
    var onClick: () -> Void = {}
    private static let fontType = NSPasteboard.PasteboardType("public.json")

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.usesFontLeading = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        clipsToBounds = false
        unregisterDraggedTypes()
        registerForDraggedTypes([MixTextView.fontType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unused")
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [MixTextView.fontType] }

    override func mouseDown(with event: NSEvent) {
        onClick()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clipsToBounds = false
        layer?.masksToBounds = false
        superview?.clipsToBounds = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {}

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let data = sender.draggingPasteboard.data(forType: MixTextView.fontType),
              let item = try? JSONDecoder().decode(FontDragItem.self, from: data),
              !item.identities.isEmpty else { return false }
        onDropFont(item.identities, letterOffset(at: sender))
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {}

    /// The letter under the pointer, by its UTF-16 offset.
    private func letterOffset(at sender: NSDraggingInfo) -> Int? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        var point = convert(sender.draggingLocation, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        // Off to the side of the text, glyphIndex still answers with the nearest glyph; only a hit counts.
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        let character = layout.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        return (storage.string as NSString).rangeOfComposedCharacterSequence(at: character).location
    }

    override func scrollWheel(with event: NSEvent) {
        ScrollWheelForwarding.pass(event, from: self)
    }
}
