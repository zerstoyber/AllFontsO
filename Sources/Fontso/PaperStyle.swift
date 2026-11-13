import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Ink and paper of the preview the view sits on. Nil outside the preview, where system colours apply.
    @Entry var paperInk: Color? = nil
    @Entry var paperColor: Color? = nil

    /// The greys of the surface a control sits on: from the preview's ink on its paper, from white on the dark chrome.
    var surface: Surface { Surface(ink: paperInk ?? AppChrome.ink) }
}

/// Every grey of the interface as a share of one ink, so the same controls read on dark and on light paper.
struct Surface {
    var ink: Color
    var half: Color { ink.opacity(0.5) }
    var muted: Color { ink.opacity(0.4) }
    var dim: Color { ink.opacity(0.3) }
    var hairline: Color { ink.opacity(0.1) }
    /// The outline of a specimen card.
    var stroke: Color { ink.opacity(0.22) }
    /// Behind a control at rest.
    var control: Color { ink.opacity(0.1) }
    /// Behind what is selected or switched on.
    var selection: Color { ink.opacity(0.18) }
    var card: Color { ink.opacity(0.05) }
    var field: Color { ink.opacity(0.06) }
}

/// Dark, light, or whatever the Mac is set to.
enum ThemeMode: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

/// The theme of the app, and paper and ink of the whole preview area. The paper goes with the theme until a
/// colour is chosen by hand.
@MainActor
final class PaperSettings: ObservableObject {
    static let shared = PaperSettings()

    static let darkPaper = "1F1F1F"
    static let darkInk = "F5F5F5"
    static let lightPaper = "F2F2F2"
    static let lightInk = "1F1F1F"

    @Published private(set) var systemDark: Bool
    @Published private(set) var mode: ThemeMode
    @Published private(set) var custom: Bool
    @Published private(set) var customPaper: String
    @Published private(set) var customInk: String
    private var observer: NSObjectProtocol?

    private init() {
        let defaults = UserDefaults.standard
        let storedPaper = defaults.string(forKey: "fontso.specimen.background") ?? ""
        let storedInk = defaults.string(forKey: "fontso.specimen.foreground") ?? ""
        customPaper = storedPaper.isEmpty ? PaperSettings.darkPaper : storedPaper
        customInk = storedInk.isEmpty ? PaperSettings.darkInk : storedInk
        if let flag = defaults.object(forKey: "fontso.specimen.customColors") as? Bool {
            custom = flag
        } else {
            // Colours picked before the paper followed the Mac stay; the two former defaults do not count as a choice.
            let formerDefaults = [PaperSettings.darkPaper, "F6F3EE", ""]
            custom = !formerDefaults.contains(storedPaper.uppercased())
        }
        systemDark = PaperSettings.readSystemDark()
        mode = ThemeMode(rawValue: defaults.string(forKey: "fontso.theme") ?? "") ?? .system
        applyAppearance()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The setting lands a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated {
                    self?.systemDark = PaperSettings.readSystemDark()
                }
            }
        }
    }

    private static func readSystemDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }

    /// Whether the theme is dark right now: the chosen one, or the Mac's.
    var themeDark: Bool { mode == .system ? systemDark : mode == .dark }

    var paperHex: String { custom ? customPaper : (themeDark ? PaperSettings.darkPaper : PaperSettings.lightPaper) }
    var inkHex: String { custom ? customInk : (themeDark ? PaperSettings.darkInk : PaperSettings.lightInk) }

    /// Dark, light, or with the Mac. The paper goes back to the theme's own, so the whole window changes together.
    func setMode(_ next: ThemeMode) {
        mode = next
        custom = false
        let defaults = UserDefaults.standard
        defaults.set(next.rawValue, forKey: "fontso.theme")
        defaults.set(false, forKey: "fontso.specimen.customColors")
        applyAppearance()
    }

    /// Menus, popovers, and sheets follow the theme too.
    private func applyAppearance() {
        switch mode {
        case .system: NSApplication.shared.appearance = nil
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        }
    }
    var paper: NSColor { PaperSettings.color(paperHex, fallback: .white) }
    var ink: NSColor { PaperSettings.color(inkHex, fallback: isDark ? .white : .black) }

    var isDark: Bool {
        let color = paper.usingColorSpace(.sRGB) ?? paper
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        return luminance < 0.45
    }

    /// A colour chosen by hand. From here on the paper keeps it, whatever the Mac's appearance.
    func choose(paper: String? = nil, ink: String? = nil) {
        let nextPaper = paper ?? paperHex
        let nextInk = ink ?? inkHex
        customPaper = nextPaper
        customInk = nextInk
        custom = true
        let defaults = UserDefaults.standard
        defaults.set(nextPaper, forKey: "fontso.specimen.background")
        defaults.set(nextInk, forKey: "fontso.specimen.foreground")
        defaults.set(true, forKey: "fontso.specimen.customColors")
    }

    /// Back to the paper of the theme.
    func followSystem() {
        custom = false
        UserDefaults.standard.set(false, forKey: "fontso.specimen.customColors")
    }

    static func color(_ hex: String, fallback: NSColor) -> NSColor {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let number = Int(cleaned, radix: 16) else { return fallback }
        return NSColor(
            srgbRed: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Puts a pane of the workspace on the preview's paper: background, ink, and the matching light or dark controls.
struct WorkspacePaper: ViewModifier {
    /// News and the chat are no previews of fonts: they keep the colours of the theme, whatever paper and ink
    /// the preview has.
    var themed = false
    @ObservedObject private var theme = PaperSettings.shared

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppChrome.panelRadius, style: .continuous)
        let ink = themed ? AppChrome.ink : Color(nsColor: theme.ink)
        let paper = themed ? AppChrome.panel : Color(nsColor: theme.paper)
        content
            .paperColors(ink: ink, paper: paper)
            .environment(\.colorScheme, (themed ? theme.themeDark : theme.isDark) ? .dark : .light)
            .background(paper, in: shape)
            .overlay(shape.stroke(AppChrome.hairline, lineWidth: 0.5))
            .clipShape(shape)
    }
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
    /// The small chip on specimen cards and in the dock.
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PaperButtonBody(configuration: configuration, prominent: prominent, compact: compact)
    }
}

extension ButtonStyle where Self == PaperButtonStyle {
    static var paper: PaperButtonStyle { PaperButtonStyle() }
    static var paperProminent: PaperButtonStyle { PaperButtonStyle(prominent: true) }
    /// A chip: grey at rest, filled when `on`.
    static func chip(on: Bool = false) -> PaperButtonStyle { PaperButtonStyle(prominent: on, compact: true) }
}

private struct PaperButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let compact: Bool
    @Environment(\.paperInk) private var paperInk
    @Environment(\.paperColor) private var paperColor
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let ink = paperInk ?? Color.primary
        let paper = paperColor ?? Color(nsColor: .windowBackgroundColor)
        let pressed = configuration.isPressed
        // Resting grey, a lighter grey under the pointer, lighter again while pressed. Prominent is the "on" state:
        // ink filled, paper text.
        let fill = prominent
            ? ink.opacity(pressed ? 0.7 : hovering ? 0.85 : 1)
            : ink.opacity(pressed ? 0.34 : hovering ? 0.26 : 0.14)
        configuration.label
            .font(AppChrome.type(compact ? AppChrome.smallSize : 11, weight: prominent ? .medium : .regular))
            .lineLimit(1)
            .foregroundStyle(prominent ? paper : ink)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2.5 : 4)
            .background(fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(ink.opacity(prominent ? 0 : 0.22), lineWidth: 0.5)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
