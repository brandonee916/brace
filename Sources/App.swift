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
            CommandGroup(replacing: .appInfo) {
                OpenWindowButton(title: "About Claude MCP Manager", windowID: AboutWindow.id)
            }
            CommandGroup(replacing: .help) {
                OpenWindowButton(title: "Claude MCP Manager Help", windowID: HelpWindow.id)
                    .keyboardShortcut("?", modifiers: .command)
            }
        }

        Window("Claude MCP Manager Help", id: HelpWindow.id) {
            HelpView()
        }
        .defaultSize(width: 900, height: 680)

        Window("About Claude MCP Manager", id: AboutWindow.id) {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

enum AboutWindow {
    static let id = "about"
}

enum HelpWindow {
    static let id = "help"
}

/// `openWindow` is only reachable from a view, so menu commands wrap it in one.
struct OpenWindowButton: View {
    let title: String
    let windowID: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) { openWindow(id: windowID) }
    }
}
