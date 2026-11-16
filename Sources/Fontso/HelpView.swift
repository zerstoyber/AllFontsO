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
                    "Add folders of fonts, including WOFF and WOFF2, rescan them, search, and sort. Source Folders also lists System Fonts from macOS; those stay and cannot be removed. Library includes Active (fonts available to apps). Click a list or a library view in the navigation: Preview stacks every font from that source. The arrow beside a list, a library view, or a source folder shows its families right in the navigation; an arrow points up while its part is open and down while it is folded, and the strip at the bottom goes the other way since it rises from the edge; while you scroll through them, the section’s title and the title of that list stay at the top. Drag a section by the two lines beside its title to move it: a line shows where it lands. Search, Sort, and Filter (Hide trials, Only active, variable, licensed, OTF/TTF/webfont) sit above the preview. Search looks through the view that is open; when nothing matches there and other fonts of the library do, Search all fonts takes the search to All fonts. Sort orders the fonts in the preview, with the name of each group above it, and runs either way. A filter stays on across views; the arrow beside Filter resets it, and so does the button that shows when a filter hides every font of a view. The four icons in the header hide or show the navigation, set the theme of the whole window (dark, light, or the same as the Mac), rescan the folders, and clear the font cache: rendered samples, Shape letter drawings, and unpacked webfonts, which the next draw rebuilds. Rest the cursor on an icon to read its name."
                )
                helpBlock(
                    "Activation and licenses",
                    "Activate a font so other apps can use it, or deactivate it without deleting the file. A webfont is unpacked first, so other apps see a normal font. Note a license per cut under Info › License: one entry for every project the font is used in, each with the day it runs out if it has one. A licensed font carries a tag beside its name in Preview, with that day; licensed cuts are collected in the navigation. Once the day has passed the tag turns red, and a red mark stands on the font and on Licensed in the navigation."
                )
                helpBlock(
                    "Lists",
                    "Make your own lists and nest them: drag a list into another, or right-click for a sub-list. Drag a family onto a list, add a cut from Research, and order a list by hand. Fonts you do not have yet stand under the list’s library fonts as Not in library, in the preview and in the navigation: save one from the news, or add a name and a link yourself with the plus on that line. They have no file, so they show the foundry’s page. Collapse lists you are not using. Right-click a font’s name in Preview, or a family under an open list, and choose Remove from list; the Delete key does the same for the fonts that are selected. A folded family leaves the list as a whole. AllFontsO asks before it removes them. Click a list or a chat and the Delete key deletes that, and asks first."
                )
                helpBlock(
                    "Preview",
                    "Type your own text or pick a standard sample (pangram, alphabet, case pairs, every character) from the three dots beside Text, change size (pt, px, rem), tracking, and leading in the strip at the bottom; Text, Adjust, and Pinned each fold away, and a folded one stands on its side as a narrow strip with its title; the arrow beside a slider resets it. Type a number into the field beside a slider and press Return. A variable font carries an Axes button on its card: it opens that font’s own sliders, one per axis, and each font keeps its own values. The two-tone circle at the end of the tabs is Colors: it sets paper and ink for the whole preview area; until you choose, it goes with the theme. Pin fonts with the pin to use them in Compare, Shape, and Use, or drag a font from the navigation onto Pinned or onto one of the tabs. Click a font's name or its text to select it: it turns grey, and the Info panel under the navigation shows its metadata, activation, lists, license, OpenType features, characters, and notes. A folded Info panel stays folded when you select a font; the Info button on a card, or Show Info, opens it. The window icon on Info opens it in a window of its own, and Info leaves the bottom left while that window is open. With no font selected, that panel is greyed out."
                )
                helpBlock(
                    "Compare, Use",
                    "The tabs are Preview, Pinned, Compare, Shape, and Use. Preview stacks the clicked list. Pin a cut to keep it for the other modes; Pinned stacks the pinned cuts the way Preview stacks a list, with its own search and order. The window icon at the end of the tabs opens the mode in a window of its own, beside the main one; so does a right-click on a tab and Library › Open in own window. A mode in its own window leaves the tabs of the main window and returns when that window closes. Preview always stays: its own window keeps the list it was opened with, named beside Preview, while the main window moves on to other lists, so several lists can stand side by side; right-click a list in the navigation for Open in its own window. A font dragged into such a window is added to its list. A window of its own carries a chain beside pt, px, rem under Adjust: closed, its size, spacing, and line height are those of the main window; click it open and the window keeps its own, so two lists can stand side by side at different sizes. Click it again to follow the main window. Compare shows the pinned fonts in a row at the top; the one you click is the font the others line up to, and the plus pins another. Under it, Align sets them on a shared baseline and Overlay lays them over each other, each in the colour of the dot on its pinned card; click the dot to change it. In Overlay the pinned font you click lies on top and is the one a drag moves. The row of settings below shifts the fonts with X-height or Cap height to meet the reference until you move a font by hand. The three dots beside Pinned sort the pinned fonts, file them in a list, send them to Use, or unpin them. The two arrows beside them show the pinned fonts large, in rows, here and in the dock at the bottom: drag a font onto another to move it there, or sort them all by name, weight, width, or category. In Compare and Shape the large view is the standard. Use is a free page of blocks; click a block to choose it: its tools appear, the strip at the bottom adjusts its size, tracking, leading, and padding, and Info shows the font the cursor is in. A click beside the blocks lets go of it. The name on a block’s tools opens the font search, with the pinned cuts and the family’s other cuts first. The arrow icon beside Colors exports as PDF or PNG, as wide as Use or on a page. In Preview and Pinned it writes the fonts shown the same way. Sizes are points as in a layout app; a point on a Mac display is smaller than a point on paper, so the same size looks larger in a PDF shown at print size."
                )
                helpBlock(
                    "Shape, News, Research",
                    "Shape shows the pinned fonts in a row at the top; the one you click is the reference, and under it Match ranks the library by how close each family comes to it, each match on a card as in Preview. The chips in the row of settings choose what counts: x-height, cap-height, width, weight, contrast, slant, category, and drawn letters. Image, beside them, takes a picture instead of a pinned font: Match ranks the library by letterform, on this Mac, without sending the picture away. Mix, beside Match, sets every letter of the sample text in another of the pinned cuts; it can also take random or similar cuts, and the three dots beside Pinned send the mix to Use. News from Foundries lists new type releases under New and Seen, beside the foundry’s own page for the one you click; you can also make your own news lists there; drag the line between the two to make either wider. Browse on inside the page: the arrow goes back, Use this page keeps the page you reached as the font’s link, and Add to list saves the font with that page in one of your lists. AllFontsO reads the foundries you follow again every few hours while it is open, and at once with Check now; what you have seen moves to Seen, and Edit corrects a name or link, also for items saved in a list. Research answers questions about type, foundries, or similar fonts; it ranks families by category, contrast, x-height, and width from the files. Drop a picture on the chat to identify fonts the same way Match does. When you ask for a list it is filed under Lists. Fonts in an answer show as in Preview: a sample, Info, Activate, the pin, and an arrow that unfolds a family into its cuts. The strip at the bottom holds Text and Adjust beside the message field, folded until you open them: they set the sample text, size, spacing, and line height of the fonts in the answers, and a click into a sample selects that cut and lets you type there. Drag a font or a list from the navigation or the preview onto the chat to name it. Research is answered on this Mac by Apple Intelligence. Under Model you can hand it to an AI program of your own instead, such as Claude Desktop, which then drives AllFontsO over MCP."
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
