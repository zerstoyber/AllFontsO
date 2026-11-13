import FontsoCore
import SwiftUI

/// The floating sample-text card used under Lists and Shape: editor, template menu, size, collapse.
struct SampleDock: View {
    @Binding var isOpen: Bool
    var placeholder: String
    var faceForCharacters: FontFace?

    @AppStorage("fontso.sampleText") private var sample = SpecimenText.standard
    @AppStorage("fontso.listSampleSize") private var sampleSize = 16.0
    @State private var sampleChoice = SampleChoice.custom
    @State private var appliedSample: String?

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 10)
            Group {
                if isOpen {
                    card
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.primary.opacity(0.08))
                        )
                        .shadow(color: Color.black.opacity(0.16), radius: 16, y: 6)
                } else {
                    Button {
                        isOpen = true
                    } label: {
                        Label("Sample", systemImage: "textformat")
                            .font(.uiCaption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
                    .shadow(color: Color.black.opacity(0.16), radius: 10, y: 4)
                    .help("Show the sample text")
                }
            }
            .frame(maxWidth: 720)
            Spacer(minLength: 10)
        }
        .padding(.bottom, 12)
        .onAppear { sampleChoice = SampleChoice.matching(sample) }
        .onChange(of: sample) { _, text in
            if text == appliedSample {
                appliedSample = nil
                return
            }
            let match = SampleChoice.matching(text)
            if sampleChoice != match { sampleChoice = match }
        }
        .onChange(of: faceForCharacters?.id) { _, _ in
            if sampleChoice == .characters { loadAllCharacters() }
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 8) {
            TextEditor(text: $sample)
                .font(.uiBody)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .frame(minHeight: 22, maxHeight: 84)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .topLeading) {
                    if sample.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            Menu {
                ForEach(SampleChoice.allCases) { choice in
                    Button {
                        sampleChoice = choice
                    } label: {
                        if sampleChoice == choice {
                            Label(choice.title, systemImage: "checkmark")
                        } else {
                            Text(choice.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "text.quote")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 12, weight: .medium))
                .frame(height: 20)
                .padding(.horizontal, 7)
                .modifier(BarButtonChrome())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sample text: pangram, alphabet, cases, or every character")
            .onChange(of: sampleChoice) { _, choice in
                applySample(choice)
            }
            SampleSizeStepper(size: $sampleSize)
            Button {
                isOpen = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.uiCaption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Hide the sample text")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .font(.uiCallout)
    }

    private func applySample(_ choice: SampleChoice) {
        if choice == .characters {
            loadAllCharacters()
            return
        }
        guard let text = choice.text else {
            if SampleChoice.matching(sample) != .custom {
                setSample("")
            }
            return
        }
        if sample != text {
            setSample(text)
        }
    }

    private func setSample(_ text: String) {
        appliedSample = text
        sample = text
    }

    private func loadAllCharacters() {
        guard let face = faceForCharacters else { return }
        let path = face.filePath
        let index = face.faceIndex
        Task { @MainActor in
            let loaded = await Task.detached(priority: .utility) {
                SpecimenCharacters.glyphs(filePath: path, faceIndex: index)
            }.value
            let text = loaded?.shown ?? ""
            guard sampleChoice == .characters, !text.isEmpty else { return }
            setSample(text)
        }
    }
}
