import SwiftUI

/// A small seal that marks a licensed cut or family. Hovering names the project.
struct LicenseMark: View {
    var project: String
    var tint: Color = .secondary

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.caption)
            .foregroundStyle(tint)
            .help(project.isEmpty ? "Licensed" : "Licensed for \(project)")
            .accessibilityLabel("Licensed for \(project)")
    }
}
