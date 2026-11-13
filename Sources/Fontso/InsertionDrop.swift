import SwiftUI
import UniformTypeIdentifiers

/// Which side of a row a dragged item will land on. `inside` only occurs on rows that can take children.
enum DropEdge: Equatable {
    case above
    case below
    case inside
}

/// Accepts dragged fonts, lists, and sidebar rows on one row. While something hovers, the row shows where it will land:
/// a line above or below it when the drag rearranges rows, a frame around it when the drag adds to it.
struct InsertionDrop: ViewModifier {
    /// Decides from the dragged items whether they rearrange rows (line) or add to this row (frame).
    var isReorder: ([FontDragItem]) -> Bool
    /// Draws the frame for drags that add to this row. Off when the row paints its own highlight.
    var framesOthers = false
    /// Told when a drag that adds to this row starts and stops hovering.
    var hoveringOthers: ((Bool) -> Void)? = nil
    /// When on, the middle of the row means "put it inside this row" for rearranging drags (nested lists).
    var allowsInside = false
    var perform: ([FontDragItem], DropEdge) -> Bool

    @State private var hovering = false
    @State private var items: [FontDragItem]?
    @State private var edge: DropEdge?
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { height = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, value in height = value }
                }
            )
            .overlay { marker }
            .onDrop(
                of: [UTType.json],
                delegate: Delegate(
                    hovering: $hovering,
                    items: $items,
                    edge: $edge,
                    height: height,
                    allowsInside: allowsInside,
                    perform: perform
                )
            )
            .onChange(of: othersHovered) { _, value in
                hoveringOthers?(value)
            }
    }

    private var reordering: Bool {
        guard let items else { return false }
        return isReorder(items)
    }

    private var othersHovered: Bool {
        hovering && items != nil && !reordering
    }

    @ViewBuilder
    private var marker: some View {
        if hovering, reordering, edge == .inside {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppChrome.highlight, lineWidth: 2)
                .allowsHitTesting(false)
        } else if hovering, reordering, let edge {
            VStack(spacing: 0) {
                if edge == .below { Spacer(minLength: 0) }
                InsertionLine()
                if edge == .above { Spacer(minLength: 0) }
            }
            .offset(y: edge == .above ? -3.5 : 3.5)
            .allowsHitTesting(false)
        } else if framesOthers, othersHovered {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppChrome.highlight, lineWidth: 2)
                .allowsHitTesting(false)
        }
    }

    private struct Delegate: DropDelegate {
        @Binding var hovering: Bool
        @Binding var items: [FontDragItem]?
        @Binding var edge: DropEdge?
        var height: CGFloat
        var allowsInside: Bool
        var perform: ([FontDragItem], DropEdge) -> Bool

        func dropEntered(info: DropInfo) {
            hovering = true
            items = nil
            edge = side(of: info)
            FontDragItem.load(info.itemProviders(for: [UTType.json])) { loaded in
                items = loaded
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            let side = side(of: info)
            if edge != side { edge = side }
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            hovering = false
            edge = nil
        }

        func performDrop(info: DropInfo) -> Bool {
            let landing = side(of: info)
            hovering = false
            edge = nil
            if let items {
                return perform(items, landing)
            }
            FontDragItem.load(info.itemProviders(for: [UTType.json])) { loaded in
                _ = perform(loaded, landing)
            }
            return true
        }

        private func side(of info: DropInfo) -> DropEdge {
            guard height > 0 else { return .above }
            let y = info.location.y
            if allowsInside, y > height * 0.3, y < height * 0.7 { return .inside }
            return y > height / 2 ? .below : .above
        }
    }
}

/// A thin accent line with a dot at its start, drawn between two rows.
struct InsertionLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(AppChrome.highlight)
                .frame(width: 7, height: 7)
            Rectangle()
                .fill(AppChrome.highlight)
                .frame(height: 2)
        }
        .frame(height: 7)
        .padding(.horizontal, 2)
    }
}

extension FontDragItem {
    /// Reads the dragged items from the pasteboard. Works while the drag still hovers, so the row can show where it will land.
    static func load(_ providers: [NSItemProvider], completion: @escaping ([FontDragItem]) -> Void) {
        let type = UTType.json.identifier
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [FontDragItem] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(type) {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                if let data, let item = try? JSONDecoder().decode(FontDragItem.self, from: data) {
                    lock.lock()
                    results.append(item)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(results)
        }
    }
}
