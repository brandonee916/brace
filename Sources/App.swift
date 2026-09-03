import SwiftUI

@main
struct ClaudeMCPManagerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1000, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                OpenHelpButton(title: "Claude MCP Manager Help")
                    .keyboardShortcut("?", modifiers: .command)
            }
        }

        Window("Claude MCP Manager Help", id: HelpWindow.id) {
            HelpView()
        }
        .defaultSize(width: 900, height: 680)
    }
}

enum HelpWindow {
    static let id = "help"
}

/// `openWindow` is only reachable from a view, so menu commands wrap it in one.
struct OpenHelpButton: View {
    let title: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) { openWindow(id: HelpWindow.id) }
    }
}
