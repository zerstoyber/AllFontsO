import FontsoCore
import SwiftUI

@main
enum FontsoEntry {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--mcp") {
            MCPStdioBridge.run()
        }
        FontsoApp.main()
    }
}

struct FontsoApp: App {
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1100, minHeight: 680)
        }
        // The title bar folds into the first column bar; see TitleBarIntegration.
        .windowStyle(.hiddenTitleBar)
        .commands {
            FontsoCommands(store: store)
        }
        .defaultSize(width: 1280, height: 800)
        // Its own window, so the library stays in view while families are checked.
        Window("Review", id: "review") {
            ReviewView()
                .environmentObject(store)
        }
        .defaultSize(width: 760, height: 640)
        .defaultPosition(.center)
    }
}
