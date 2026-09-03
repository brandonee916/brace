import AppKit

/// Guards against quitting on top of unsaved edits.
///
/// Everything in this app is one keystroke from being lost otherwise: there is no
/// document to auto-save, and the config file is only written when you press Save.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CommandResolver.warmUp()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = ConfigStore.active, store.hasUnsavedChanges else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save your changes before quitting?"
        alert.informativeText = "Your edits haven't been written to Claude Desktop's "
            + "configuration yet. If you quit now they're lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // A refused save — a conflict, or a duplicate name — must not quit,
            // or pressing Save would lose the work it was meant to keep.
            return store.save() ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// Closing the window deliberately does *not* quit.
    ///
    /// Quitting there sounds tidier, and routes ⌘W through the prompt above —
    /// but cancelling that prompt leaves an app with no window, and the reopen
    /// that should bring it back re-runs the terminate check instead, so the
    /// prompt returns and the window never does. Staying alive is what makes
    /// the window recoverable: the store lives on `BraceApp`, and `loadIfNeeded`
    /// keeps a reopened window from re-reading the file over unsaved edits, so
    /// ⌘W hides the work rather than losing it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
