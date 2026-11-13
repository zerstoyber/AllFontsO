import AppKit
import SwiftUI

/// SKETCHY chrome: panels on a grey window, grey selection, labels in the system font. Monochrome throughout.
/// Every colour comes in a dark and a light form and follows the theme chosen in the header.
enum AppChrome {
    static let window = Color(nsColor: windowNS)
    static let panel = Color(nsColor: panelNS)
    static let ink = Color(nsColor: inkNS)
    static let hairline = ink.opacity(0.10)
    static let half = ink.opacity(0.50)
    static let muted = ink.opacity(0.40)
    /// The grey of a selected row, an active segment, or a hovered control.
    static let selection = Color(nsColor: themed(
        dark: NSColor(white: 110 / 255, alpha: 0.4),
        light: NSColor(white: 0, alpha: 0.12)
    ))
    /// The resting grey behind a control.
    static let control = Color(nsColor: themed(
        dark: NSColor(white: 70 / 255, alpha: 0.4),
        light: NSColor(white: 0, alpha: 0.07)
    ))
    /// The grey that stands where the system would put an accent colour.
    static let highlight = Color(nsColor: themed(dark: NSColor(white: 0.82, alpha: 1), light: NSColor(white: 0.25, alpha: 1)))

    /// A colour that is one grey in the dark theme and another in the light one.
    static func themed(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let titleBarHeight: CGFloat = 30
    static let panelRadius: CGFloat = 15
    static let cardRadius: CGFloat = 5
    static let dockRadius: CGFloat = 10
    static let inset: CGFloat = 10
    /// How far the strip of settings floats in from the sides of its pane: further than the cards behind it, so
    /// its edges do not run on with theirs.
    static let dockInset: CGFloat = 30
    /// The open strip between the navigation and the preview. Dragging it sets the navigation's width.
    static let gap: CGFloat = 8

    /// Labels and rows.
    static let textSize: CGFloat = 12
    /// Card headers, dock labels, and the fonts inside an open list. The sketch sets these at 8; 10 stays readable.
    static let smallSize: CGFloat = 10

    static let windowNS = themed(
        dark: NSColor(srgbRed: 45 / 255, green: 45 / 255, blue: 45 / 255, alpha: 1),
        light: NSColor(srgbRed: 214 / 255, green: 214 / 255, blue: 214 / 255, alpha: 1)
    )
    static let panelNS = themed(
        dark: NSColor(srgbRed: 31 / 255, green: 31 / 255, blue: 31 / 255, alpha: 1),
        light: NSColor(srgbRed: 242 / 255, green: 242 / 255, blue: 242 / 255, alpha: 1)
    )
    static let inkNS = themed(
        dark: .white,
        light: NSColor(srgbRed: 31 / 255, green: 31 / 255, blue: 31 / 255, alpha: 1)
    )

    /// The Mac's own typeface, San Francisco, at a fixed size.
    static func type(_ size: CGFloat = textSize, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static var small: Font { type(smallSize) }

    static func nsFont(_ size: CGFloat = textSize, weight: Font.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: nsWeight(weight))
    }

    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    /// The version the bundle carries. Run outside a bundle, as in a debug build, it is the current one.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1"
    }

    static var versionText: String {
        "Version \(version)"
    }

    /// Counts the way the sketch writes them: 1.317, 10.000.
    static func count(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "."
        formatter.usesGroupingSeparator = true
        return formatter
    }()
}

/// The app's text styles in the system font, at the sizes macOS gives the matching system styles.
extension Font {
    static var uiCaption2: Font { AppChrome.type(10) }
    static var uiCaption: Font { AppChrome.type(10.5) }
    static var uiFootnote: Font { AppChrome.type(10.5) }
    static var uiSubheadline: Font { AppChrome.type(11) }
    static var uiCallout: Font { AppChrome.type(12) }
    static var uiBody: Font { AppChrome.type(12) }
    static var uiHeadline: Font { AppChrome.type(12, weight: .medium) }
    static var uiTitle3: Font { AppChrome.type(15) }
    static var uiTitle2: Font { AppChrome.type(17) }
    static var uiTitle: Font { AppChrome.type(22) }
    static var uiLargeTitle: Font { AppChrome.type(26) }
}

extension View {
    func chromePanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: AppChrome.panelRadius, style: .continuous)
        return self
            .background(AppChrome.panel, in: shape)
            .overlay(shape.stroke(AppChrome.hairline, lineWidth: 0.5))
            .clipShape(shape)
    }

    /// The system font as the standard face, grey as the tint, dark or light as the theme says.
    func chromeDefaults() -> some View {
        modifier(ChromeDefaults())
    }
}

/// A sheet or popover in the colours of the theme. Opened from the preview it would take the preview's paper and
/// ink along; this puts it back on the panel grey, so it reads the same whatever colours the preview has.
struct ChromeSheet: ViewModifier {
    @ObservedObject private var theme = PaperSettings.shared

    func body(content: Content) -> some View {
        content
            .paperColors(ink: AppChrome.ink, paper: AppChrome.panel)
            .environment(\.colorScheme, theme.themeDark ? .dark : .light)
            .font(AppChrome.type())
            .background(AppChrome.panel)
    }
}

private struct ChromeDefaults: ViewModifier {
    @ObservedObject private var theme = PaperSettings.shared

    func body(content: Content) -> some View {
        content
            .font(AppChrome.type())
            .preferredColorScheme(theme.mode.scheme)
            .tint(AppChrome.highlight)
    }
}

/// The small chevron of the sketch: down when open, up when folded.
struct ChromeChevron: View {
    var open: Bool
    var color: Color?
    var size: CGFloat = 7
    /// Sideways for the sections of the dock: left when open, right when folded.
    var sideways = false
    @Environment(\.surface) private var surface

    private var symbol: String {
        if sideways { return open ? "chevron.left" : "chevron.right" }
        return open ? "chevron.down" : "chevron.up"
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color ?? surface.ink)
            .frame(width: 10, height: 12)
            .contentShape(Rectangle())
    }
}

/// A grey rounded field behind a row while the pointer is over it, so every clickable row answers.
struct RowHover: ViewModifier {
    var radius: CGFloat = 5
    @State private var hovering = false
    @Environment(\.surface) private var surface

    func body(content: Content) -> some View {
        content
            .background(hovering ? surface.control : Color.clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
    }
}
