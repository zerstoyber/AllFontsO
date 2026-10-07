import AppKit
import SwiftUI

/// Scroll view locked to the space the column actually offers.
/// Content starts at the top-left, and that top stays reachable.
struct OverlayHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func reportOverlayHeight() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: OverlayHeightKey.self, value: proxy.size.height)
            }
        }
    }
}

struct ColumnScroll<Content: View>: View {
    var axes: Axis.Set = .vertical
    var resetID: AnyHashable?
    var bottomInset: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            ScrollViewReader { scroll in
                ScrollView(axes) {
                    // The height frame must not be the proposal the content sees.
                    // A minimum on that same frame clamps the content to the window
                    // and clips whatever does not fit. Measure the real height first.
                    VStack(spacing: 0) {
                        content()
                        Color.clear.frame(height: bottomInset)
                    }
                    .frame(
                        maxWidth: axes.contains(.horizontal) ? nil : width,
                        alignment: .topLeading
                    )
                        .fixedSize(horizontal: false, vertical: axes.contains(.vertical))
                        .frame(
                            minWidth: axes.contains(.horizontal) ? width : nil,
                            minHeight: axes.contains(.vertical) ? height : nil,
                            alignment: .topLeading
                        )
                        .id("column-scroll-top")
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .onChange(of: resetID) { _, _ in
                    scroll.scrollTo("column-scroll-top", anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

enum ScrollWheelForwarding {
    static func pass(_ event: NSEvent, from view: NSView) {
        var ancestor = view.superview
        while let current = ancestor {
            if let scroll = current as? NSScrollView {
                scroll.scrollWheel(with: event)
                return
            }
            ancestor = current.superview
        }
        view.nextResponder?.scrollWheel(with: event)
    }
}
