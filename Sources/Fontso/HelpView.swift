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
                .font(.uiTitle2.weight(.semibold))
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
                    "Add folders of fonts, including WOFF and WOFF2, rescan them, search, and sort. Click a list or a library view in the navigation: Preview stacks every font from that source. The chevron beside a list, a library view, or a source folder shows its families right in the navigation; while you scroll through them, the section’s title and the title of that list stay at the top. Drag a section by the two lines beside its title to move it: a line shows where it lands. Search, Sort, and Filter (Hide trials, Only active, variable, licensed, OTF/TTF/webfont) sit above the preview. Sort orders the fonts in the preview, with the name of each group above it, and runs either way. A filter stays on across views; the arrow beside Filter resets it, and so does the button that shows when a filter hides every font of a view. Theme in the header sets the whole window dark, light, or the same as the Mac."
                )
                helpBlock(
                    "Activation and licenses",
                    "Activate a font so other apps can use it, or deactivate it without deleting the file. A webfont is unpacked first, so other apps see a normal font. Note a license per cut under Info › License: one entry for every project the font is used in, each with the day it runs out if it has one. A licensed font carries a tag beside its name in Preview, with that day; licensed cuts are collected in the navigation. Once the day has passed the tag turns red, and a red mark stands on the font and on Licensed in the navigation."
                )
                helpBlock(
                    "Lists",
                    "Make your own lists and nest them: drag a list into another, or right-click for a sub-list. Drag a family onto a list, add a cut from Research, and order a list by hand. Fonts you do not have yet stand under the list’s library fonts as Not in library, in the preview and in the navigation: save one from the news, or add a name and a link yourself with the plus on that line. They have no file, so they show the foundry’s page. Collapse lists you are not using."
                )
                helpBlock(
                    "Preview",
                    "Type your own text or pick a standard sample (pangram, alphabet, case pairs, every character) from the three dots beside Text, change size (pt, px, rem), tracking, and leading in the strip at the bottom; Text, Adjust, and Pinned each fold away, and the arrow beside a slider resets it. Type a number into the field beside a slider and press Return. A variable font carries an Axes button on its card: it opens that font’s own sliders, one per axis, and each font keeps its own values. Colors sets paper and ink for the whole preview area; until you choose, it goes with the theme. Pin fonts with the pin to use them in Compare, Shape, and Playground, or drag a font from the navigation onto Pinned or onto one of the tabs. Click a font's name, its text, or Info to select it: it turns grey, and its Info opens in the panel under the navigation with metadata, activation, lists, license, OpenType features, characters, and notes. With no font selected, that panel is greyed out."
                )
                helpBlock(
                    "Compare, Playground",
                    "Preview stacks the clicked list. Pin a cut to keep it for the other modes. Compare shows the pinned fonts in a row at the top; the one you click is the font the others line up to, and the plus pins another. Under it, Align sets them on a shared baseline and Overlay lays them over each other, each in the colour of the dot on its pinned card; click the dot to change it. In Overlay the pinned font you click lies on top and is the one a drag moves. The row of settings below shifts the fonts with X-height or Cap height to meet the reference until you move a font by hand. The three dots beside Pinned sort the pinned fonts, file them in a list, send them to Playground, or unpin them. The two arrows beside them show the pinned fonts large, in rows, here and in the dock at the bottom: drag a font onto another to move it there, or sort them all by name, weight, width, or category. Playground is a free page of blocks; click a block to choose it: its tools appear, the strip at the bottom adjusts its size, tracking, leading, and padding, and Info shows the font the cursor is in. A click beside the blocks lets go of it. The name on a block’s tools opens the font search, with the pinned cuts and the family’s other cuts first. Export as PDF or PNG, as wide as the Playground or on a page. Sizes are points as in a layout app; a point on a Mac display is smaller than a point on paper, so the same size looks larger in a PDF shown at print size."
                )
                helpBlock(
                    "Shape, News, Research",
                    "Shape shows the pinned fonts in a row at the top; the one you click is the reference, and under it Match ranks the library by how close each family comes to it, each match on a card as in Preview. The chips in the row of settings choose what counts: x-height, cap-height, width, weight, contrast, slant, category, and drawn letters. Mix, beside Match, sets every letter of the sample text in another of the pinned cuts; it can also take random or similar cuts, and the three dots beside Pinned send the mix to Playground. News lists new type releases, the newest first, beside the foundry’s own page for the one you click; drag the line between the two to make either wider. Browse on inside the page: the arrow goes back, Use this page keeps the page you reached as the font’s link, and Add to list saves the font with that page in one of your lists. AllFontsO reads the foundries you follow again every few hours while it is open, and at once with Check now; what you have seen moves to Old, and Edit corrects a name or link, also for items saved in a list. Research answers questions about type, foundries, or similar fonts; it ranks families by category, contrast, x-height, and width from the files. When you ask for a list it is filed under Lists. Fonts in an answer show as in Preview: a sample, Info, Activate, the pin, and an arrow that unfolds a family into its cuts. Drag a font or a list from the navigation or the preview onto the chat to name it. Research is answered on this Mac by Apple Intelligence. Under Model you can hand it to an AI program of your own instead, such as Claude Desktop, which then drives AllFontsO over MCP."
                )
                helpBlock(
                    "Review",
                    "Library › Review library… walks through your families one at a time: a big sample, the cuts, and the category AllFontsO gave the family, with the reason. Confirm it, change it, mark a trial, or drop the family into one of your lists on the way. Families you confirmed move to the back of the queue, so you can go round again any time."
                )
            }
        case .credits:
            VStack(alignment: .leading, spacing: 10) {
                Text("AllFontsO, HIP009, Version \(AppChrome.version)")
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
            .font(.uiBody)
        }
    }

    private func helpBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.uiBody.weight(.semibold))
            Text(body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
