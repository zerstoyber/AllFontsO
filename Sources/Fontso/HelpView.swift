import SwiftUI

enum HelpTopic: String, Identifiable {
    case capabilities
    case credits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capabilities: return "What you can do"
        case .credits: return "Credits"
        }
    }
}

extension Notification.Name {
    static let fontsoShowHelp = Notification.Name("fontso.showHelp")
}

enum HelpWindow {
    static func show(_ topic: HelpTopic) {
        NotificationCenter.default.post(name: .fontsoShowHelp, object: topic)
    }
}

struct HelpSheet: View {
    let topic: HelpTopic
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(topic.title)
                .font(.title2.weight(.semibold))
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close the help")
            }
        }
        .padding(24)
        .frame(width: 500, height: topic == .credits ? 240 : 540)
    }

    @ViewBuilder
    private var content: some View {
        switch topic {
        case .capabilities:
            VStack(alignment: .leading, spacing: 14) {
                helpBlock(
                    "Library",
                    "Add folders of fonts, including WOFF and WOFF2, rescan them, search, and sort. Sort by x-height, cap height, letter width, contrast, or scripts. Categories group fonts by their own classification. Set the sample text and its size with −A+ in the column bar; open a family to see every cut in that text. Filters (Hide trials, Only active, variable, licensed, OTF/TTF/webfont) stay on across views; a banner shows what is held back, with one click to clear."
                )
                helpBlock(
                    "Activation and licenses",
                    "Activate a font so other apps can use it, or deactivate it without deleting the file. A webfont is unpacked first, so other apps see a normal font. Note a license per cut under Info › License; licensed cuts are collected in the sidebar."
                )
                helpBlock(
                    "Lists",
                    "Make your own lists and nest them: drag a list into another, or right-click for a sub-list. Drag a family onto a list, add a cut from Research, and order a list by hand. Collapse lists you are not using."
                )
                helpBlock(
                    "Preview",
                    "Type your own text, change size (pt, px, rem), tracking, leading, colours, and variable axes. Pin a font so it stays in the preview while you browse others. Info holds the metadata, notes, license, OpenType features to switch on and off, and a character map you can search by character, code point, or Unicode name; clicking a character copies its HTML code. Info is for one font; with several selected, only Adjust stays."
                )
                helpBlock(
                    "Align, Overlay, Mix, Playground",
                    "Drag fonts from the library or a list onto the preview to show them there. Used cuts, folded into Adjust (and floating at the foot of the Playground), lists the cuts on screen: pin or unpin them there, take one out, file one or all of them in a list, or drag a card onto a list in the sidebar. Align sets fonts on a shared baseline, x-height, or cap height; Overlay lays them over each other in colours. Add a font with Add font… or drop one in. Mix sets every letter of a word in its own cut: Chosen uses the cuts in the preview, Random deals cuts from the library column, Similar picks families close to the first preview font in x-height, cap height, and letter width. Type straight into the mixed text; size, spacing, and line height are the preview's. Letters take their cut shuffled or in turn; select letters, or drop a font on one, to give them a cut by hand. To Playground adds the mix as a block that keeps every letter's cut, also in the export. In any Playground block, select letters and pick a cut from the letters menu in its toolbar, or drop a font onto the selection. Command-Z steps back through typing and these changes in Mix and Playground. Playground is a free page: several blocks, each with its own font, size, tracking, leading, and padding, hover a block for its controls. Export as PDF or PNG in screen, A4, A3, or a custom size."
                )
                helpBlock(
                    "Shape, News, Research",
                    "Shape finds fonts by proportion, with a sample text and size at the bottom of the column — the same templates as the lists (pangram, alphabet, cases, every character). News shows new type releases; what you have seen moves to Old, and Edit… corrects a name or link, also for items saved in a list. Research answers questions about type, foundries, or similar fonts; it ranks families by category, contrast, x-height, and width from the files. When you ask for a list it is filed under Lists. Drag a font from the library, a list, or the preview onto the chat to name it. Research runs free on this Mac with Apple Intelligence, Ollama, or LM Studio, with your own Claude key, or, once you turn MCP on, from your own agent."
                )
                helpBlock(
                    "Review",
                    "Library › Review library… walks through your families one at a time: a big sample, the cuts, and the category AllFontsO gave the family, with the reason. Confirm it, change it, mark a trial, or drop the family into one of your lists on the way. Families you confirmed move to the back of the queue, so you can go round again any time."
                )
            }
        case .credits:
            VStack(alignment: .leading, spacing: 10) {
                Text("AllFontsO, HIP009, Version 1.0")
                Text("By Büro Bum Bum and Humans In Process")
                HStack(spacing: 4) {
                    Text("Contact us via")
                    Link(
                        "office@humansinprocess.biz",
                        destination: URL(string: "mailto:office@humansinprocess.biz")!
                    )
                    .help("Write an email to Humans In Process")
                }
            }
            .font(.body)
        }
    }

    private func helpBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.semibold))
            Text(body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
