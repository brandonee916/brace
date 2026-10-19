import Foundation

/// An MCP server that ships inside an app already on this Mac.
///
/// These never appear in the MCP registry: there's no package to publish, just a
/// program the app installs and a flag that switches it into MCP mode. So instead
/// of searching for them, the app looks for them on disk.
struct BuiltInServer: Identifiable, Hashable {
    let id: String
    /// The key the entry is written under in the config file.
    let name: String
    let title: String
    let summary: String
    /// Lowercased words a search should match, besides the title.
    let keywords: [String]
    /// Where the program may live, best first.
    let locations: [BuiltInLocation]
    /// Things to switch on in the app itself. A config entry can't do these, and
    /// without them the server starts and then refuses every request.
    let setupSteps: [String]
    let documentationURL: String?
    /// Where to get the app when no location is found.
    let downloadURL: String?

    func matches(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        if term.isEmpty { return true }
        return title.lowercased().contains(term) || keywords.contains { $0.contains(term) || term.contains($0) }
    }
}

struct BuiltInLocation: Hashable {
    let path: String
    /// Which app this copy belongs to, e.g. "Safari Technology Preview".
    let label: String
    let args: [String]
    /// When set, the program's `--help` must mention this before it counts.
    /// For a copy that exists on every Mac but only gained MCP support in some
    /// versions, existing on disk proves nothing.
    let requiredHelpText: String?
}

enum BuiltInCatalog {
    static let safari = BuiltInServer(
        id: "builtin:safari",
        name: "safari-mcp",
        title: "Safari",
        summary: "Apple's own MCP server for Safari: inspect pages, read the console and network requests, run JavaScript, take screenshots, click and scroll. It's built into safaridriver, which comes with Safari 27 and Safari Technology Preview, so there's nothing to install.",
        keywords: ["safari", "webkit", "safaridriver", "browser", "apple"],
        locations: [
            // Safari 27 and later. Older Safaris have this file too, without the flag.
            BuiltInLocation(
                path: "/usr/bin/safaridriver",
                label: "Safari",
                args: ["--mcp"],
                requiredHelpText: "--mcp"
            ),
            // Technology Preview had it first, from release 247.
            BuiltInLocation(
                path: "/Applications/Safari Technology Preview.app/Contents/MacOS/safaridriver",
                label: "Safari Technology Preview",
                args: ["--mcp"],
                requiredHelpText: nil
            ),
        ],
        setupSteps: [
            "In Safari's Settings → Advanced, turn on \"Show features for web developers\".",
            "In Settings → Developer, turn on \"Allow remote automation\" and \"Allow external agents\".",
            "Restart Claude Desktop after saving so it starts the server.",
        ],
        documentationURL: "https://webkit.org/blog/18136/introducing-the-safari-mcp-server-for-web-developers/",
        downloadURL: "https://developer.apple.com/safari/technology-preview/"
    )

    static let all: [BuiltInServer] = [safari]

    static func matching(_ query: String) -> [BuiltInServer] {
        all.filter { $0.matches(query) }
    }

    /// The first location that's present and able to serve MCP.
    ///
    /// The checks are passed in so tests can describe a Mac without needing one.
    static func detect(
        _ server: BuiltInServer,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        helpText: (String) -> String? = BuiltInCatalog.helpText(of:)
    ) -> BuiltInLocation? {
        server.locations.first { location in
            guard isExecutable(location.path) else { return false }
            guard let required = location.requiredHelpText else { return true }
            return helpText(location.path)?.contains(required) ?? false
        }
    }

    /// What a program prints for `--help`, or nil if it doesn't answer promptly.
    static func helpText(of path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        var data = Data()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        if finished.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Whether the config already has an entry that runs this location.
    static func existingEntry(for location: BuiltInLocation, in servers: [MCPServer]) -> MCPServer? {
        servers.first { server in
            server.kind == .local
                && server.command == location.path
                && location.args.allSatisfy { arg in server.args.contains { $0.value == arg } }
        }
    }
}

extension MCPServer {
    /// A ready-to-save entry for a server found on this Mac.
    init(builtIn server: BuiltInServer, location: BuiltInLocation) {
        self.init()
        name = server.name
        kind = .local
        command = location.path
        args = location.args.map(ArgItem.init)
    }
}
