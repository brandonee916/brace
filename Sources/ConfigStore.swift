import AppKit
import Combine
import Foundation

@MainActor
final class ConfigStore: ObservableObject {
    @Published var servers: [MCPServer] = []
    @Published var loadError: String?
    @Published var statusMessage: String?
    @Published private(set) var lastLoadedText: String = ""

    /// The whole file as parsed, so keys this app knows nothing about survive a save.
    private var root: JSONValue = .object([])

    /// The order servers appear in on disk.
    ///
    /// The sidebar sorts alphabetically for browsing, but rewriting the file in
    /// that order would reshuffle a section the user may well have arranged
    /// themselves. New servers go on the end; everything else stays put.
    private var fileOrder: [String] = []

    /// The `mcpServers` section exactly as it was when we read it, so a save can
    /// tell whether somebody else has touched the part we own.
    private var loadedServersJSON: String = ""

    /// The switched-off servers as they were when we read them, so the sidecar
    /// gets the same conflict check the config does.
    private var loadedDisabledJSON: String = ""


    /// Where Claude Desktop keeps its configuration.
    ///
    /// `BRACE_CONFIG_DIR` redirects this, which is how the test suite
    /// and the documentation screenshots run against sample data instead of a real
    /// config. It only changes which directory is edited; nothing else.
    nonisolated static var claudeSupportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["BRACE_CONFIG_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude")
    }

    let configURL: URL

    /// Turning a server off shouldn't destroy it. Disabled servers are lifted out
    /// of the real config into this sidecar, so Claude stops loading them but the
    /// full definition — env vars and all — is still here when you switch it back on.
    let disabledURL: URL

    let backupDirectory: URL

    /// The store the main window is using, so the app can ask about unsaved work
    /// before it quits.
    static weak var active: ConfigStore?

    /// The directory is injectable so the save path can be exercised against a
    /// scratch copy instead of the live config.
    init(directory: URL = ConfigStore.claudeSupportDirectory) {
        // Resolve symlinks: people keep this file in a dotfiles repo and link to
        // it. An atomic write renames over the link, which would silently replace
        // it with a regular file and leave the real config untouched.
        configURL = directory.appendingPathComponent("claude_desktop_config.json")
            .resolvingSymlinksInPath()
        disabledURL = directory.appendingPathComponent("mcp-manager-disabled.json")
            .resolvingSymlinksInPath()
        backupDirectory = directory.appendingPathComponent("MCP Manager Backups")
        ConfigStore.active = self
    }

    var hasUnsavedChanges: Bool { serversSnapshot != savedSnapshot }
    private var savedSnapshot: String = ""
    private var serversSnapshot: String {
        servers.map { "\($0.name)|\($0.enabled)|\($0.jsonValue.serialized(pretty: false))" }
            .joined(separator: "\n")
    }

    // MARK: - Loading

    func load() {
        loadError = nil
        let manager = FileManager.default

        var enabledServers: [MCPServer] = []
        if manager.fileExists(atPath: configURL.path) {
            do {
                let text = try String(contentsOf: configURL, encoding: .utf8)
                lastLoadedText = text
                let parsed = try JSONValue.parse(text)
                guard let topLevel = parsed.objectPairs else {
                    loadError = "The config file's top level isn't a JSON object."
                    return
                }
                // JSON parsers disagree about repeated keys — JavaScript keeps the
                // last, we keep the first — so we would edit a block Claude Desktop
                // ignores. Refuse rather than silently pick a side.
                var seenKeys = Set<String>()
                if let duplicate = topLevel.map(\.key).first(where: { !seenKeys.insert($0).inserted }) {
                    loadError = "The config file has more than one \"\(duplicate)\" entry at the top level. "
                        + "Different tools disagree about which one wins, so fix that in a text editor first."
                    return
                }
                root = parsed
                let pairs = root["mcpServers"]?.objectPairs ?? []
                fileOrder = pairs.map(\.key)
                loadedServersJSON = root["mcpServers"]?.serialized() ?? ""
                for pair in pairs {
                    enabledServers.append(MCPServer(name: pair.key, json: pair.value))
                }
            } catch let error as JSONParseError {
                loadError = "The config file has a syntax error — \(error.localizedDescription). "
                    + "Fix it in a text editor, or use Revert to Backup, then reopen this app."
                return
            } catch {
                loadError = "Couldn't read the config file: \(error.localizedDescription)"
                return
            }
        } else {
            root = .object([(key: "mcpServers", value: .object([]))])
            fileOrder = []
            loadedServersJSON = ""
            lastLoadedText = ""
        }

        var disabledServers: [MCPServer] = []
        if let text = try? String(contentsOf: disabledURL, encoding: .utf8),
           let parsed = try? JSONValue.parse(text) {
            loadedDisabledJSON = parsed["mcpServers"]?.serialized() ?? ""
            for pair in parsed["mcpServers"]?.objectPairs ?? [] {
                var server = MCPServer(name: pair.key, json: pair.value)
                server.enabled = false
                disabledServers.append(server)
            }
        }

        if !manager.fileExists(atPath: disabledURL.path) { loadedDisabledJSON = "" }

        servers = (enabledServers + disabledServers)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        savedSnapshot = serversSnapshot
    }

    // MARK: - Saving

    @discardableResult
    func save() -> Bool {
        // Refuse outright if the file we loaded could not be understood. Writing
        // now would replace a config we never read with one built from an empty
        // root, taking every existing server and Claude Desktop's own settings
        // with it.
        guard loadError == nil else {
            statusMessage = "Can't save while the config file has a syntax error. "
                + "Fix it in a text editor, or restore a backup, then choose Reload from Disk."
            return false
        }

        // A blank name used to drop the server silently, along with its secrets.
        if let unnamed = servers.first(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
            _ = unnamed
            statusMessage = "Can't save: one of the servers has no name."
            return false
        }

        let named = servers
        var seen = Set<String>()
        for server in named where !seen.insert(server.name).inserted {
            statusMessage = "Can't save: two servers are both named \"\(server.name)\"."
            return false
        }

        // Claude Desktop rewrites this file on its own schedule — it stores its
        // preferences here too. Build on what is actually on disk, and fail closed
        // if that cannot be read: unreadable is exactly when writing is riskiest.
        let manager = FileManager.default
        if manager.fileExists(atPath: configURL.path) {
            guard let currentText = try? String(contentsOf: configURL, encoding: .utf8) else {
                statusMessage = "Can't save: the config file can't be read right now."
                return false
            }
            guard let currentRoot = try? JSONValue.parse(currentText),
                  currentRoot.objectPairs != nil else {
                statusMessage = "Can't save: the config file on disk is no longer valid JSON — "
                    + "something else may have written it. Choose Reload from Disk to see it."
                return false
            }
            if currentText != lastLoadedText {
                let theirServers = currentRoot["mcpServers"]?.serialized() ?? ""
                guard theirServers == loadedServersJSON else {
                    // Someone changed the servers themselves. Overwriting would lose
                    // their edit, and merging two sets of changes isn't ours to guess.
                    statusMessage = "The config file changed since you opened it — its MCP servers "
                        + "are no longer the ones shown here. Choose Reload from Disk to pick up the "
                        + "change, then make your edits again."
                    return false
                }
                // Only the parts we don't own changed, so adopt them and carry on.
                root = currentRoot
                fileOrder = currentRoot["mcpServers"]?.objectPairs?.map(\.key) ?? fileOrder
            }
        }

        // The sidecar holds the settings of switched-off servers, so it deserves
        // the same conflict check as the config itself.
        if manager.fileExists(atPath: disabledURL.path) {
            let currentSidecar = (try? String(contentsOf: disabledURL, encoding: .utf8))
                .flatMap { try? JSONValue.parse($0) }?["mcpServers"]?.serialized() ?? ""
            guard currentSidecar == loadedDisabledJSON else {
                statusMessage = "The list of switched-off servers changed since you opened it. "
                    + "Choose Reload from Disk, then make your edits again."
                return false
            }
        }

        do {
            try backupCurrentConfig()

            let enabled = named.filter(\.enabled)
            let positions = Dictionary(uniqueKeysWithValues: fileOrder.enumerated().map { ($1, $0) })
            let enabledPairs = enabled
                .enumerated()
                .sorted { left, right in
                    // Known servers keep their place; new ones follow, in the
                    // order they were added.
                    let a = positions[left.element.name] ?? (fileOrder.count + left.offset)
                    let b = positions[right.element.name] ?? (fileOrder.count + right.offset)
                    return a < b
                }
                .map { (key: $0.element.name, value: $0.element.jsonValue) }

            // The sidecar is written first. If the second write fails, a disabled
            // server exists in both files rather than in neither — duplicated is
            // recoverable, lost is not.
            let disabledPairs = named.filter { !$0.enabled }
                .map { (key: $0.name, value: $0.jsonValue) }
            if disabledPairs.isEmpty {
                if manager.fileExists(atPath: disabledURL.path) {
                    try manager.removeItem(at: disabledURL)
                }
            } else {
                let sidecar = JSONValue.object([
                    (key: "_comment", value: .string("Servers turned off in Brace. Claude Desktop never reads this file.")),
                    (key: "mcpServers", value: .object(disabledPairs)),
                ])
                try writeAtomically(sidecar.serialized() + "\n", to: disabledURL)
            }
            loadedDisabledJSON = JSONValue.object(disabledPairs).serialized()

            root["mcpServers"] = .object(enabledPairs)
            fileOrder = enabledPairs.map(\.key)
            try writeAtomically(root.serialized() + "\n", to: configURL)

            lastLoadedText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? lastLoadedText
            loadedServersJSON = root["mcpServers"]?.serialized() ?? loadedServersJSON
            savedSnapshot = serversSnapshot
            let count = enabledPairs.count
            statusMessage = "Saved — \(count) server\(count == 1 ? "" : "s") active. Restart Claude Desktop to apply."
            return true
        } catch {
            statusMessage = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    /// Writes to a sibling temp file and swaps it in, so a crash mid-write can
    /// never leave Claude Desktop with a half-written config.
    private func writeAtomically(_ text: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Backups

    /// How many backups to keep. 0 means keep everything.
    static let retentionKey = "backupRetention"
    static let defaultRetention = 25

    var backupRetention: Int {
        let stored = UserDefaults.standard.object(forKey: Self.retentionKey) as? Int
        return stored ?? Self.defaultRetention
    }

    private func backupCurrentConfig() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: configURL.path) else { return }
        try manager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        // A fixed locale: otherwise a Thai or Arabic system writes names this code
        // can't read back, and pruning then sorts by the wrong date.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let stamp = formatter.string(from: Date())

        // Names are only second-resolution, so two saves in the same second would
        // collide. If the existing file already holds exactly this content there's
        // nothing to add; otherwise number it so no state is silently skipped.
        func url(for suffix: Int) -> URL {
            let name = suffix == 1
                ? "claude_desktop_config \(stamp).json"
                : "claude_desktop_config \(stamp) (\(suffix)).json"
            return backupDirectory.appendingPathComponent(name)
        }

        let current = try Data(contentsOf: configURL)
        var suffix = 1
        while manager.fileExists(atPath: url(for: suffix).path) {
            if (try? Data(contentsOf: url(for: suffix))) == current {
                pruneBackups(keeping: backupRetention)
                return
            }
            suffix += 1
        }
        // Write the bytes rather than copying the item: copyItem duplicates a
        // symlink, which would make the "backup" a pointer at the file it is
        // supposed to protect.
        try current.write(to: url(for: suffix), options: .atomic)

        // Switched-off servers live only in the sidecar, so back that up too or
        // they have no recovery path at all.
        if let sidecar = try? Data(contentsOf: disabledURL) {
            let name = "mcp-manager-disabled \(stamp)\(suffix == 1 ? "" : " (\(suffix))").json"
            try? sidecar.write(to: backupDirectory.appendingPathComponent(name), options: .atomic)
        }
        pruneBackups(keeping: backupRetention)
    }

    /// Applies the current retention setting immediately, so lowering it in the
    /// backup manager cleans up without waiting for the next save.
    @discardableResult
    func pruneBackupsNow() -> Int {
        let before = availableBackups().count
        pruneBackups(keeping: backupRetention)
        let removed = before - availableBackups().count
        if removed > 0 {
            statusMessage = "Removed \(removed) old backup\(removed == 1 ? "" : "s")."
        }
        return removed
    }

    private func pruneBackups(keeping limit: Int) {
        guard limit > 0 else { return }
        for file in availableBackups().dropFirst(limit) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// When a backup was taken.
    ///
    /// Not the file's modification date: `copyItem` carries the source's date
    /// across, so that would report when Claude Desktop last wrote the config,
    /// which can be hours before the backup was made. The name is the real record.
    nonisolated static func backupDate(of url: URL) -> Date {
        backupOrder(of: url).date
    }

    /// Sort key for a backup: when it was taken, plus the within-second sequence
    /// number. Names are only second-resolution, so several backups can share a
    /// date; without the sequence, ties would order arbitrarily.
    nonisolated static func backupOrder(of url: URL) -> (date: Date, sequence: Int) {
        let name = url.deletingPathExtension().lastPathComponent
        var stamp = name
            .replacingOccurrences(of: "claude_desktop_config ", with: "")
            .replacingOccurrences(of: "mcp-manager-disabled ", with: "")

        var sequence = 1
        if let match = stamp.range(of: #"\s+\((\d+)\)$"#, options: .regularExpression) {
            let digits = stamp[match].filter(\.isNumber)
            sequence = Int(digits) ?? 1
            stamp = String(stamp[..<match.lowerBound])
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        if let date = formatter.date(from: stamp) { return (date, sequence) }
        let fallback = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return (fallback, sequence)
    }

    /// Newest first.
    func availableBackups() -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("claude_desktop_config") }
            .sorted { lhs, rhs in
                let left = Self.backupOrder(of: lhs)
                let right = Self.backupOrder(of: rhs)
                if left.date != right.date { return left.date > right.date }
                return left.sequence > right.sequence
            }
    }

    struct BackupInfo: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let date: Date
        let byteCount: Int
        /// nil when the file can't be parsed, so the UI can flag it.
        let serverNames: [String]?
        /// True when this backup's servers match what's on disk right now.
        let matchesCurrent: Bool
    }

    func backupInfos() -> [BackupInfo] {
        let currentServers = (try? String(contentsOf: configURL, encoding: .utf8))
            .flatMap { try? JSONValue.parse($0) }?["mcpServers"]?.serialized()

        return availableBackups().map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            let text = try? String(contentsOf: url, encoding: .utf8)
            let parsed = text.flatMap { try? JSONValue.parse($0) }
            let servers = parsed?["mcpServers"]
            return BackupInfo(
                url: url,
                date: Self.backupDate(of: url),
                byteCount: values?.fileSize ?? (text.map { $0.utf8.count } ?? 0),
                serverNames: servers?.objectPairs?.map(\.key),
                matchesCurrent: servers != nil && servers?.serialized() == currentServers
            )
        }
    }

    var totalBackupBytes: Int {
        backupInfos().reduce(0) { $0 + $1.byteCount }
    }

    @discardableResult
    func deleteBackups(_ urls: [URL]) -> Int {
        // Resolve both sides before comparing: the same directory can be spelled
        // /var/... or /private/var/..., and plain URL equality would reject every
        // real backup while still letting a crafted path through.
        let root = backupDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        var deleted = 0
        for url in urls {
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            guard parent == root else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { deleted += 1 }
        }
        if deleted > 0 {
            statusMessage = "Deleted \(deleted) backup\(deleted == 1 ? "" : "s")."
        }
        return deleted
    }

    @discardableResult
    func deleteAllBackups() -> Int {
        deleteBackups(availableBackups())
    }

    func revealBackupsInFinder() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: backupDirectory.path) {
            try? manager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backupDirectory.path)
    }

    /// Puts a backup's MCP servers back, leaving everything else alone.
    ///
    /// Only the servers: the rest of the file is Claude Desktop's, and rolling its
    /// preferences back to whenever the backup was taken is not what the button
    /// says it does.
    func restore(from backup: URL) {
        do {
            let text = try String(contentsOf: backup, encoding: .utf8)
            let parsed = try JSONValue.parse(text)
            guard let restoredServers = parsed["mcpServers"] else {
                statusMessage = "That backup has no MCP servers in it."
                return
            }
            try backupCurrentConfig()

            var target: JSONValue
            if let currentText = try? String(contentsOf: configURL, encoding: .utf8),
               let currentRoot = try? JSONValue.parse(currentText),
               currentRoot.objectPairs != nil {
                target = currentRoot
            } else {
                target = parsed
            }
            target["mcpServers"] = restoredServers
            try writeAtomically(target.serialized() + "\n", to: configURL)
            load()
            statusMessage = "Restored the servers from \(backup.lastPathComponent). "
                + "Restart Claude Desktop to apply."
        } catch {
            statusMessage = "Couldn't restore that backup: \(error.localizedDescription)"
        }
    }

    // MARK: - Importing

    struct ImportResult {
        var servers: [MCPServer]
        /// What the cleanup step changed, so the UI can say so.
        var notes: [String]
        /// The tidied, canonical JSON, for the "Tidy Up" button.
        var formatted: String
    }

    /// Accepts the shapes people actually paste from a README — a full config, a
    /// bare `{"name": {...}}` map, or a single server body — after tidying away
    /// comments, code fences, curly quotes and trailing commas.
    func importServers(from text: String, suggestedName: String = "new-server") throws -> ImportResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JSONParseError(message: "nothing to import", line: 1, column: 1)
        }
        let cleaned = JSONLenient.clean(text)
        guard !cleaned.text.isEmpty else {
            throw JSONParseError(message: "nothing to import once the comments were removed", line: 1, column: 1)
        }
        let parsed = try JSONValue.parse(cleaned.text)
        guard parsed.objectPairs != nil else {
            throw JSONParseError(message: "expected a JSON object", line: 1, column: 1)
        }

        func result(_ servers: [MCPServer]) -> ImportResult {
            let canonical = JSONValue.object([
                (key: "mcpServers", value: .object(servers.map { (key: $0.name, value: $0.jsonValue) })),
            ])
            return ImportResult(servers: servers, notes: cleaned.notes, formatted: canonical.serialized())
        }

        if let servers = parsed["mcpServers"]?.objectPairs {
            return result(servers.map { MCPServer(name: $0.key, json: $0.value) })
        }
        if parsed["command"] != nil || parsed["url"] != nil {
            return result([MCPServer(name: suggestedName, json: parsed)])
        }
        // A map of names to server bodies.
        let pairs = parsed.objectPairs ?? []
        let looksLikeServerMap = !pairs.isEmpty && pairs.allSatisfy {
            $0.value["command"] != nil || $0.value["url"] != nil
        }
        if looksLikeServerMap {
            return result(pairs.map { MCPServer(name: $0.key, json: $0.value) })
        }
        throw JSONParseError(
            message: "couldn't find a server definition — expected a \"command\" or \"url\" key somewhere",
            line: 1,
            column: 1
        )
    }

    /// Makes `name` unique by appending a number, ignoring `excluding`.
    func uniqueName(from name: String, excluding id: UUID? = nil) -> String {
        let taken = Set(servers.filter { $0.id != id }.map(\.name))
        guard taken.contains(name) else { return name }
        var counter = 2
        while taken.contains("\(name) \(counter)") { counter += 1 }
        return "\(name) \(counter)"
    }

    // MARK: - Claude Desktop

    var claudeIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").isEmpty
    }

    func restartClaudeDesktop() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
        for app in running { app.terminate() }

        statusMessage = "Restarting Claude Desktop…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            let stillRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
            for app in stillRunning { app.forceTerminate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let url = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.anthropic.claudefordesktop"
                ) else {
                    self.statusMessage = "Couldn't find Claude Desktop to relaunch it."
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                    DispatchQueue.main.async {
                        self.statusMessage = error == nil
                            ? "Claude Desktop restarted."
                            : "Couldn't relaunch Claude Desktop: \(error!.localizedDescription)"
                    }
                }
            }
        }
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }
}
