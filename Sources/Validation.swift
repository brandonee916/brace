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
    ///
    /// Compared after stripping a trailing version, so `python3.12` and `perl5.34`
    /// are caught along with `python` and `perl`.
    private static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "pwsh", "powershell",
        "python", "ruby", "perl", "php", "lua", "tclsh", "awk", "gawk", "sed",
        "node", "deno", "bun", "osascript", "swift", "rscript", "julia", "elixir",
    ]

    /// Programs that exist to run another program, so the real command is further
    /// along the argument list.
    private static let wrappers: Set<String> = ["env", "arch", "nice", "time", "xargs", "sudo", "doas", "script"]

    /// Flags that mean "what follows is code, not a filename". Matched by prefix so
    /// `-ec`, `--eval=…` and `-e` are all covered.
    private static let inlineCodeFlags = ["-c", "-e", "-E", "--eval", "--command", "--exec", "--run"]

    /// Arguments that redirect where a package manager fetches code from.
    private static let sourceOverrideFlags = [
        "--registry", "--index", "--index-url", "--extra-index-url", "--repo",
        "--find-links", "--default-index",
    ]

    /// Environment variables that change what gets downloaded or loaded into the
    /// process, which is another way to run code without naming an interpreter.
    private static let dangerousEnvironmentKeys: Set<String> = [
        "dyld_insert_libraries", "dyld_library_path", "dyld_framework_path",
        "ld_preload", "ld_library_path",
        "node_options", "nodepath", "node_path",
        "pythonpath", "pythonstartup", "pythonhome",
        "perl5lib", "perl5opt", "rubyopt", "rubylib",
        "npm_config_registry", "yarn_registry", "uv_index_url", "uv_extra_index_url",
        "pip_index_url", "pip_extra_index_url", "uv_default_index",
        "gem_source", "bundle_mirror",
    ]

    /// Flags a server config should never need, because they fetch and run code.
    private static let downloadAndRunMarkers = ["| sh", "| bash", "|sh", "|bash", "curl ", "wget "]

    /// The interpreter name with any trailing version removed: `python3.12` → `python`.
    private static func baseName(of program: String) -> String {
        var name = (program as NSString).lastPathComponent.lowercased()
        while let last = name.last, last.isNumber || last == "." { name.removeLast() }
        return name.isEmpty ? (program as NSString).lastPathComponent.lowercased() : name
    }

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

        var args = server.args.map(\.value).filter { !$0.isEmpty }
        var program = baseName(of: server.command)

        // Step past wrappers so `env python -c …` is judged on python, not env.
        while wrappers.contains(program), let next = args.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) {
            program = baseName(of: next)
            args = Array(args.drop(while: { $0 != next }).dropFirst())
        }

        for pair in server.env where dangerousEnvironmentKeys.contains(pair.key.lowercased()) {
            issues.append(Issue(
                level: .warning,
                message: "\(pair.key) changes what code this server loads or downloads. "
                    + "That is a way to run something other than the server itself — only keep it if you know why it's there."
            ))
        }

        if let override = args.first(where: { arg in
            sourceOverrideFlags.contains { arg == $0 || arg.hasPrefix($0 + "=") }
        }) {
            issues.append(Issue(
                level: .warning,
                message: "\(override) points the package manager at a different source, so the code that runs "
                    + "won't be what the public registry publishes. Only keep it if that's deliberate."
            ))
        }

        if interpreters.contains(program),
           args.contains(where: { arg in inlineCodeFlags.contains { arg == $0 || arg.hasPrefix($0 + "=") }
               || (arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.count <= 4
                   && arg.dropFirst().contains(where: { $0 == "c" || $0 == "e" })) }) {
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
