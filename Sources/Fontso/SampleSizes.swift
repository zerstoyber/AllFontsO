import SwiftUI

/// Size, spacing, and line height of the samples. The main window has one set. A window of its own follows
/// that set while its chain is closed; with the chain open it keeps a set of its own.
@Observable
final class SampleSizes {
    /// The set of the main window, kept in the settings.
    static let shared = SampleSizes()

    private var ownSize: Double
    private var ownTracking: Double
    private var ownLeading: Double
    /// Closed chain: this window shows the sizes of the main window, and a change here changes them there.
    private(set) var linked: Bool

    @ObservationIgnored private let parent: SampleSizes?
    /// The window these sizes belong to; nil for the main window.
    @ObservationIgnored private let window: String?

    private static let sizeKey = "fontso.specimenSize"
    private static let trackingKey = "fontso.specimen.tracking"
    private static let leadingKey = "fontso.specimen.leading"
    private static let windowsKey = "fontso.window.sizes"

    private init() {
        let defaults = UserDefaults.standard
        ownSize = defaults.object(forKey: Self.sizeKey) as? Double ?? 48
        ownTracking = defaults.object(forKey: Self.trackingKey) as? Double ?? 0
        ownLeading = defaults.object(forKey: Self.leadingKey) as? Double ?? 1.2
        linked = false
        parent = nil
        window = nil
    }

    /// The sizes of a window of its own. A window opened again finds what it had: its chain, and its own sizes.
    init(window: WorkspaceWindow) {
        let key = "\(window.tab.rawValue)|\(window.source ?? "")"
        let saved = (UserDefaults.standard.dictionary(forKey: Self.windowsKey)?[key] as? [String: Any]) ?? [:]
        let main = SampleSizes.shared
        linked = saved["linked"] as? Bool ?? true
        ownSize = saved["size"] as? Double ?? main.size
        ownTracking = saved["tracking"] as? Double ?? main.tracking
        ownLeading = saved["leading"] as? Double ?? main.leading
        parent = main
        self.window = key
    }

    /// True for a window of its own: only there is a chain to open.
    var hasLink: Bool { parent != nil }

    private var source: SampleSizes { linked ? (parent ?? self) : self }

    var size: Double {
        get { source.ownSize }
        set {
            let target = source
            target.ownSize = newValue
            target.save()
        }
    }

    var tracking: Double {
        get { source.ownTracking }
        set {
            let target = source
            target.ownTracking = newValue
            target.save()
        }
    }

    var leading: Double {
        get { source.ownLeading }
        set {
            let target = source
            target.ownLeading = newValue
            target.save()
        }
    }

    /// Opens or closes the chain. Opening it starts from the sizes on show, so nothing jumps.
    func setLinked(_ value: Bool) {
        guard let parent, value != linked else { return }
        if !value {
            ownSize = parent.size
            ownTracking = parent.tracking
            ownLeading = parent.leading
        }
        linked = value
        save()
    }

    private func save() {
        let defaults = UserDefaults.standard
        guard let window else {
            defaults.set(ownSize, forKey: Self.sizeKey)
            defaults.set(ownTracking, forKey: Self.trackingKey)
            defaults.set(ownLeading, forKey: Self.leadingKey)
            return
        }
        var all = defaults.dictionary(forKey: Self.windowsKey) ?? [:]
        if linked {
            // A window that follows the main one has nothing of its own to keep.
            all[window] = nil
        } else {
            all[window] = ["linked": false, "size": ownSize, "tracking": ownTracking, "leading": ownLeading]
        }
        defaults.set(all, forKey: Self.windowsKey)
    }
}

private struct SampleSizesKey: EnvironmentKey {
    static let defaultValue = SampleSizes.shared
}

extension EnvironmentValues {
    /// The sample sizes of the window a view sits in.
    var sampleSizes: SampleSizes {
        get { self[SampleSizesKey.self] }
        set { self[SampleSizesKey.self] = newValue }
    }
}

/// The chain in the Adjust header of a window of its own. Closed, the window shows the sizes of the main window;
/// open, it keeps its own, so two lists can stand side by side at different sizes.
struct SizeLinkChip: View {
    @Environment(\.sampleSizes) private var sizes
    @Environment(\.surface) private var surface
    @Environment(\.paperColor) private var paperColor

    var body: some View {
        if sizes.hasLink {
            let linked = sizes.linked
            let tone = linked ? (paperColor ?? AppChrome.panel) : surface.ink
            IconChip(
                symbol: "link",
                on: linked,
                help: linked
                    ? "Sizes follow the main window. Click to give this window its own size, spacing, and line height."
                    : "This window has its own size, spacing, and line height. Click to follow the main window again.",
                action: { sizes.setLinked(!linked) }
            ) {
                Image(systemName: "link")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(tone.opacity(linked ? 1 : 0.55))
                    .overlay {
                        if !linked {
                            // An open chain: struck through, as there is no symbol for it.
                            Capsule()
                                .fill(tone)
                                .frame(width: 13, height: 1)
                                .rotationEffect(.degrees(45))
                        }
                    }
            }
        }
    }
}
