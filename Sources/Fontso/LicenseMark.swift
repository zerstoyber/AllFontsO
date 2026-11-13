import SwiftUI

/// A small seal that marks a licensed cut or family. Hovering names the project.
struct LicenseMark: View {
    var project: String
    var tint: Color = .secondary

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.uiCaption)
            .foregroundStyle(tint)
            .help(project.isEmpty ? "Licensed" : "Licensed for \(project)")
            .accessibilityLabel("Licensed for \(project)")
    }
}

/// The license of a font beside its name: until when it runs, or that it has run out. An expired license is the
/// one thing in the window that stands in red.
struct LicenseTag: View {
    var note: LicenseNote
    var action: (() -> Void)?
    @Environment(\.surface) private var surface

    /// The red of a license that has run out.
    static let alarm = Color(red: 0.93, green: 0.26, blue: 0.21)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        HStack(spacing: 3) {
            if note.expired {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
            }
            Text(note.text)
                .lineLimit(1)
        }
        .font(AppChrome.type(9, weight: .medium))
        .foregroundStyle(note.expired ? LicenseTag.alarm : surface.half)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(note.expired ? LicenseTag.alarm.opacity(0.12) : Color.clear, in: shape)
        .overlay(shape.stroke(note.expired ? LicenseTag.alarm.opacity(0.8) : surface.stroke, lineWidth: 0.5))
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .help(note.help + (action == nil ? "" : "\nClick to see the license under Info."))
        .accessibilityLabel(note.text)
    }
}
