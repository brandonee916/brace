import Foundation

/// Identifiers for the app's auxiliary windows.
///
/// Kept out of the app's entry point so views can refer to them without pulling in
/// the `@main` type.
enum HelpWindow {
    static let id = "help"
}

enum AboutWindow {
    static let id = "about"
}
