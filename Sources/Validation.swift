import Foundation

struct Issue: Identifiable {
    enum Level {
        case error
        case warning
        case info

        var label: String {
            switch self {
            case .error: return "Problem"
            case .warning: return "Worth checking"
            case .info: return "Note"
            }
        }
    }

    /// Something the UI can offer to do about the issue.
    enum Action: Equatable {
        case setCommand(String)
        /// Several copies exist — let the user pick.
        case chooseCommand
    }

    let id = UUID()
    let level: Level
    let message: String
    var action: Action?
    var actionLabel: String?
}

enum Validator {
    static func issues(for server: MCPServer, allNames: [String]) -> [Issue] {
        var issues: [Issue] = []

        let trimmedName = server.name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty {
            issues.append(Issue(level: .error, message: "This server needs a name."))
        }
        if allNames.filter({ $0 == server.name }).count > 1 {
            issues.append(Issue(
                level: .error,
                message: "Another server is already called \"\(server.name)\". Names must be unique."
            ))
        }

        issues.append(contentsOf: safetyIssues(for: server))

        switch server.kind {
        case .local:
            issues.append(contentsOf: commandIssues(for: server))

            var seenKeys = Set<String>()
            for pair in server.env where !pair.key.isEmpty {
                if !seenKeys.insert(pair.key).inserted {
                    issues.append(Issue(level: .error, message: "The variable \(pair.key) is set twice."))
                }
                if pair.value.isEmpty {
                    if pair.isRequired {
                        let detail = pair.hint.map { " — \($0)." } ?? "."
                        issues.append(Issue(
                            level: .error,
                            message: "\(pair.key) is required and still empty\(detail)"
                        ))
                    } else {
                        issues.append(Issue(level: .warning, message: "\(pair.key) is empty."))
                    }
                }
            }
            if server.env.contains(where: { $0.key.isEmpty && !$0.value.isEmpty }) {
                issues.append(Issue(level: .warning, message: "An environment row has a value but no name, so it won't be saved."))
            }

        case .remote:
            let trimmed = server.url.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                issues.append(Issue(level: .error, message: "Set the server URL."))
            } else if let components = URLComponents(string: trimmed),
                      let scheme = components.scheme?.lowercased(),
                      scheme == "http" || scheme == "https",
                      components.host != nil {
                if scheme == "http", components.host != "localhost", components.host != "127.0.0.1" {
                    issues.append(Issue(level: .warning, message: "This URL isn't encrypted. Prefer https for anything off this Mac."))
                }
            } else {
                issues.append(Issue(level: .error, message: "That doesn't look like a valid http or https URL."))
            }
        }

        return issues
    }

    private static func commandIssues(for server: MCPServer) -> [Issue] {
        let manager = FileManager.default
        let command = server.command.trimmingCharacters(in: .whitespaces)

        if command.isEmpty {
            return [Issue(level: .error, message: "Set the command Claude should run.")]
        }

        if command.hasPrefix("~") {
            return [Issue(
                level: .error,
                message: "A leading ~ isn't expanded in this config file, so Claude will look for a folder literally named \"~\".",
                action: .setCommand((command as NSString).expandingTildeInPath),
                actionLabel: "Use full path"
            )]
        }

        if command.contains("/") {
            if !manager.fileExists(atPath: command) {
                return [Issue(level: .error, message: "Nothing exists at \(command).")]
            }
            if !manager.isExecutableFile(atPath: command) {
                return [Issue(level: .error, message: "\(command) isn't executable.")]
            }
            return []
        }

        // A bare command name: the classic "works in Terminal, fails in Claude" trap.
        let candidates = CommandResolver.candidates(for: command)
        switch candidates.count {
        case 0:
            return [Issue(
                level: .error,
                message: "\"\(command)\" wasn't found anywhere on this Mac. Enter the full path to it."
            )]
        case 1:
            return [Issue(
                level: .warning,
                message: "\"\(command)\" has no folder in front of it. Claude Desktop is launched by Finder, so it doesn't load the PATH your Terminal uses — a bare name often works when you test it in Terminal and then fails here. The full path always works.",
                action: .setCommand(candidates[0].path),
                actionLabel: "Use full path"
            )]
        default:
            return [Issue(
                level: .warning,
                message: "\"\(command)\" has no folder in front of it, and there are \(candidates.count) copies of it on this Mac. Claude Desktop doesn't load your Terminal's PATH, so it may not pick the one you expect — or find any at all. Choose the one you want.",
                action: .chooseCommand,
                actionLabel: "Choose…"
            )]
        }
    }

    // MARK: - Safety

    /// Programs whose whole purpose is to run whatever you hand them.
    private static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh",
        "python", "python2", "python3", "ruby", "perl", "php", "lua",
        "node", "deno", "bun", "osascript", "swift", "Rscript", "env",
    ]

    /// Flags that mean "the next argument is code, not a filename".
    private static let inlineCodeFlags: Set<String> = [
        "-c", "-e", "-E", "--eval", "-eval", "--command", "--exec", "-exec",
    ]

    /// Flags a server config should never need, because they fetch and run code.
    private static let downloadAndRunMarkers = ["| sh", "| bash", "|sh", "|bash", "curl ", "wget "]

    /// Looks for the shape of a snippet that runs arbitrary code rather than
    /// starting a server.
    ///
    /// Nothing here is injection — the app never passes a command through a shell.
    /// The risk is simpler: a config file *names the program Claude will run*, so a
    /// snippet copied from somewhere untrustworthy can name an interpreter and hand
    /// it a script. Real MCP servers essentially never look like this, so it's worth
    /// saying out loud before it gets saved.
    static func safetyIssues(for server: MCPServer) -> [Issue] {
        guard server.kind == .local else { return [] }
        var issues: [Issue] = []

        let program = (server.command as NSString).lastPathComponent
        let args = server.args.map(\.value).filter { !$0.isEmpty }

        if interpreters.contains(program), args.contains(where: { inlineCodeFlags.contains($0) }) {
            issues.append(Issue(
                level: .warning,
                message: "This doesn't start a server — it hands a block of code to \"\(program)\" to run. "
                    + "Legitimate MCP servers don't need that. Unless you wrote this yourself, read the code below carefully before saving or testing it."
            ))
        }

        let wholeCommand = ([server.command] + args).joined(separator: " ")
        if downloadAndRunMarkers.contains(where: { wholeCommand.lowercased().contains($0) }) {
            issues.append(Issue(
                level: .warning,
                message: "This downloads something from the internet and runs it. That is how a machine gets compromised. "
                    + "Don't save this unless you know exactly what it fetches."
            ))
        }

        return issues
    }

    /// Values that look like secrets, so the UI can mask them by default.
    static func looksSensitive(key: String) -> Bool {
        let lowered = key.lowercased()
        return ["token", "key", "secret", "password", "passwd", "credential", "auth"]
            .contains { lowered.contains($0) }
    }
}
