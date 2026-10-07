import AppKit
import SwiftUI

enum ArrowDirection {
    case up, down, left, right

    init?(keyCode: UInt16) {
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        default: return nil
        }
    }

    var isVertical: Bool { self == .up || self == .down }
}

/// Hands arrow keys pressed in this view's window to the closure. Multi-line text keeps its arrows; a single-line
/// field only keeps left and right, so stepping through fonts works straight from the search field.
/// Sheets, alerts, and popovers are separate windows and stay untouched.
struct ArrowKeyCatcher: NSViewRepresentable {
    var handle: (ArrowDirection, NSEvent.ModifierFlags) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.handle = handle
    }

    final class CatcherView: NSView {
        var handle: ((ArrowDirection, NSEvent.ModifierFlags) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      let direction = ArrowDirection(keyCode: event.keyCode) else { return event }
                if let text = window.firstResponder as? NSTextView {
                    if !text.isFieldEditor { return event }
                    if !direction.isVertical { return event }
                }
                let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
                if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) { return event }
                return self.handle?(direction, flags) == true ? nil : event
            }
        }

        deinit {
            removeMonitor()
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
