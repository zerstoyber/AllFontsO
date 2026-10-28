import SwiftUI

extension EnvironmentValues {
    /// Ink and paper of the preview the view sits on. Nil outside the preview, where system colours apply.
    @Entry var paperInk: Color? = nil
    @Entry var paperColor: Color? = nil
}

extension View {
    /// Lets buttons and cards below take the preview's own ink and paper, so they read on any paper colour.
    /// The tint follows the ink too, so borderless icons, sliders, and switches never vanish into a coloured paper.
    func paperColors(ink: Color, paper: Color) -> some View {
        environment(\.paperInk, ink).environment(\.paperColor, paper).tint(ink)
    }
}

/// The one button look on the preview's paper: ink text in an ink outline, or ink filled with paper text when prominent.
/// Outside the preview it falls back to the system's primary colour and window background.
struct PaperButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PaperButtonBody(configuration: configuration, prominent: prominent)
    }
}

extension ButtonStyle where Self == PaperButtonStyle {
    static var paper: PaperButtonStyle { PaperButtonStyle() }
    static var paperProminent: PaperButtonStyle { PaperButtonStyle(prominent: true) }
}

private struct PaperButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.paperInk) private var paperInk
    @Environment(\.paperColor) private var paperColor
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let ink = paperInk ?? Color.primary
        let paper = paperColor ?? Color(nsColor: .windowBackgroundColor)
        let pressed = configuration.isPressed
        let fill = prominent
            ? ink.opacity(pressed ? 0.7 : hovering ? 0.85 : 1)
            : ink.opacity(pressed ? 0.26 : hovering ? 0.18 : 0.1)
        configuration.label
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(prominent ? paper : ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(ink.opacity(prominent ? 0 : 0.45))
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
