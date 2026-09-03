import Foundation

/// One program on disk that could satisfy a bare command name like `uvx`.
struct CommandCandidate: Identifiable, Hashable {
    var id: String { path }
    let path: String
    /// Friendly name for where it came from, e.g. "Homebrew".
    let source: String
    /// Filled in lazily — running `--version` is too slow for live validation.
    var version: String?
    /// Set when this path is a symlink to another candidate already listed.
    var resolvesTo: String?
}

enum CommandResolver {
    /// Directories a GUI app can realistically find tools in.
    ///
    /// Claude Desktop is launched by Finder, so it inherits a minimal `PATH`
    /// rather than the one your shell profile builds. These are used only to
    /// *locate* a bare command so the app can suggest its absolute path.
    private static let wellKnownDirectories: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.deno/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }()

    /// The PATH a login shell builds, queried once per launch.
    ///
    /// Spawning a shell is far too slow to do while someone is typing, so this is
    /// resolved a single time and reused.
    private static let loginShellDirectories: [String] = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(separator: ":")
                .map(String.init)
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }()

    static let searchDirectories: [String] = {
        var seen = Set<String>()
        return (wellKnownDirectories + loginShellDirectories).filter { seen.insert($0).inserted }
    }()

    private static let lock = NSLock()
    private static var cache: [String: [CommandCandidate]] = [:]

    /// Every copy of `command` on this Mac, best guess first.
    ///
    /// Results are cached: validation runs on every keystroke, and hitting the
    /// filesystem for each one adds up.
    static func candidates(for command: String) -> [CommandCandidate] {
        let name = command.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return [] }

        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let manager = FileManager.default
        var results: [CommandCandidate] = []
        var seenPaths = Set<String>()
        var realPathOwner: [String: String] = [:]

        for directory in searchDirectories {
            let path = (directory as NSString).appendingPathComponent(name)
            guard manager.isExecutableFile(atPath: path), seenPaths.insert(path).inserted else { continue }

            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let duplicateOf = realPathOwner[real]
            if duplicateOf == nil { realPathOwner[real] = path }

            results.append(CommandCandidate(
                path: path,
                source: label(for: directory),
                version: nil,
                resolvesTo: duplicateOf == nil && real != path ? real : duplicateOf
            ))
        }

        lock.lock()
        cache[name] = results
        lock.unlock()
        return results
    }

    /// The single best candidate, or nil when there isn't one.
    static func preferred(for command: String) -> CommandCandidate? {
        candidates(for: command).first
    }

    static func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// Runs `<path> --version`. Slow and only used when the picker is open.
    ///
    /// Some tools ignore `--version` and sit waiting on stdin, so stdin is closed
    /// and the process is killed if it doesn't answer quickly.
    static func version(of path: String, timeout: TimeInterval = 3) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run() } catch { return nil }

        var output = Data()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // Reap it too — a terminated-but-unwaited child stays a zombie, and one
            // that ignores SIGTERM would otherwise never go away at all.
            process.endAndReap()
            _ = finished.wait(timeout: .now() + 0.5)
            return nil
        }
        process.waitUntilExit()

        let text = String(decoding: output, as: UTF8.self)
            .split(separator: "\n")
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !text.isEmpty else { return nil }
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }

    private static func label(for directory: String) -> String {
        let home = NSHomeDirectory()
        switch directory {
        case "/opt/homebrew/bin", "/opt/homebrew/sbin": return "Homebrew"
        case "/usr/local/bin", "/usr/local/sbin": return "Homebrew (Intel) or /usr/local"
        case "\(home)/.local/bin": return "uv / pipx"
        case "\(home)/.cargo/bin": return "Rust / Cargo"
        case "\(home)/.bun/bin": return "Bun"
        case "\(home)/.deno/bin": return "Deno"
        case "/usr/bin", "/bin", "/usr/sbin", "/sbin": return "macOS system"
        default:
            if directory.contains("/.nvm/") { return "nvm" }
            if directory.contains("/.volta/") { return "Volta" }
            if directory.contains("/.asdf/") { return "asdf" }
            if directory.hasPrefix(home) {
                return "~" + directory.dropFirst(home.count)
            }
            return directory
        }
    }
}
