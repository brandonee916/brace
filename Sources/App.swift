import SwiftUI

@main
struct BraceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Owned by the app, not the window. Closing the window used to take the
    /// store — and any unsaved edits — with it, silently.
    @StateObject private var store = ConfigStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1000, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                OpenWindowButton(title: "About Brace", windowID: AboutWindow.id)
            }
            CommandGroup(replacing: .help) {
                OpenWindowButton(title: "Brace Help", windowID: HelpWindow.id)
                    .keyboardShortcut("?", modifiers: .command)
            }
        }

        Window("Brace Help", id: HelpWindow.id) {
            HelpView()
        }
        .defaultSize(width: 900, height: 680)

        Window("About Brace", id: AboutWindow.id) {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
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
