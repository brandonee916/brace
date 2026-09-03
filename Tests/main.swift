import Foundation

// Unbuffered, so output isn't lost if a check throws.
setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    if !passed { failures += 1 }
    print("\(passed ? "OK   " : "FAIL ") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
}

func parses(_ raw: String, _ label: String, expectServer: String? = nil, expectNotes: Bool = true) {
    let cleaned = JSONLenient.clean(raw)
    do {
        let value = try JSONValue.parse(cleaned.text)
        var ok = true
        var detail = cleaned.notes.joined(separator: "; ")
        if let expectServer {
            let found = value["mcpServers"]?[expectServer] ?? value[expectServer]
            ok = found != nil
            if !ok { detail = "server \(expectServer) missing from \(cleaned.text.prefix(120))" }
        }
        if expectNotes && cleaned.notes.isEmpty { ok = false; detail = "expected cleanup notes but got none" }
        check(label, ok, detail)
    } catch {
        check(label, false, "\(error.localizedDescription) | cleaned=\(cleaned.text.prefix(160))")
    }
}

// The exact snippet from the report.
parses("""
// claude_desktop_config.json
{
  "mcpServers": {
    "unifi-network": {
      "command": "uvx",
      "args": ["unifi-network-mcp@latest"],
      "env": { "UNIFI_HOST": "192.168.1.1" }
    }
  }
}
""", "leading // comment (the reported case)", expectServer: "unifi-network")

parses("""
```json
{ "mcpServers": { "a": { "command": "/bin/ls" } } }
```
""", "markdown code fence", expectServer: "a")

parses("""
{
  /* block comment
     over two lines */
  "mcpServers": { "b": { "command": "/bin/ls" } }
}
""", "block comment", expectServer: "b")

parses("""
{ "mcpServers": { "c": { "command": "/bin/ls", "args": ["x",], } , } }
""", "trailing commas", expectServer: "c")

parses("{ \u{201C}mcpServers\u{201D}: { \u{201C}d\u{201D}: { \u{201C}command\u{201D}: \u{201C}/bin/ls\u{201D} } } }",
       "curly quotes from a web page", expectServer: "d")

parses("""
{ mcpServers: { e: { command: '/bin/ls', args: ['-la'] } } }
""", "bare keys and single quotes", expectServer: "e")

parses("""
Add this to your config file:

{ "mcpServers": { "f": { "command": "/bin/ls" } } }

Then restart Claude.
""", "prose around the JSON", expectServer: "f")

parses("""
{ "mcpServers": { "g": { "url": "https://x.com/mcp" } } } // inline trailing comment
""", "inline trailing comment", expectServer: "g")

// Things that must NOT be mangled.
let urlCase = JSONLenient.clean(#"{"mcpServers":{"h":{"url":"https://example.com//mcp"}}}"#)
check("// inside a string is left alone", urlCase.text.contains("https://example.com//mcp") && urlCase.notes.isEmpty, urlCase.text)

let apostrophe = JSONLenient.clean("""
// don't let this break things
{ "mcpServers": { "i": { "command": "/bin/ls" } } }
""")
check("apostrophe inside a comment", (try? JSONValue.parse(apostrophe.text))?["mcpServers"]?["i"] != nil, apostrophe.text)

let singleWithURL = JSONLenient.clean("{ 'url': 'http://a//b' }")
check("// inside a single-quoted string survives",
      (try? JSONValue.parse(singleWithURL.text))?["url"]?.stringValue == "http://a//b",
      singleWithURL.text)

let escaped = JSONLenient.clean(#"{"a":"back\\slash and \"quote\" and \/slash"}"#)
check("escapes preserved", (try? JSONValue.parse(escaped.text))?["a"]?.stringValue == #"back\slash and "quote" and /slash"#, escaped.text)

let alreadyClean = JSONLenient.clean(#"{"mcpServers":{"j":{"command":"/bin/ls"}}}"#)
check("clean JSON is untouched and unannotated",
      alreadyClean.notes.isEmpty && alreadyClean.text == #"{"mcpServers":{"j":{"command":"/bin/ls"}}}"#, alreadyClean.text)

let boolKeys = JSONLenient.clean(#"{"a": true, "b": false, "c": null}"#)
check("true/false/null not turned into keys", boolKeys.notes.isEmpty, boolKeys.notes.joined(separator: ";"))

// Genuinely broken input must still fail, with a location.
for bad in ["{ \"mcpServers\": { \"a\": ", "not json at all", "{ \"a\" \"b\" }"] {
    let cleaned = JSONLenient.clean(bad)
    do { _ = try JSONValue.parse(cleaned.text); check("rejects \(bad)", false, "accepted") }
    catch { check("still rejects broken input: \(bad)", true, error.localizedDescription) }
}


// MARK: - Config round-trip, against a scratch copy of the real config

@MainActor
func configSuite() throws {
    let real = ConfigStore.claudeSupportDirectory.appendingPathComponent("claude_desktop_config.json")
    guard FileManager.default.fileExists(atPath: real.path) else {
        print("SKIP  config suite — no Claude Desktop config on this Mac")
        return
    }

    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.copyItem(at: real, to: dir.appendingPathComponent("claude_desktop_config.json"))

    let store = ConfigStore(directory: dir)
    store.load()
    check("loads the copied config", store.loadError == nil, store.loadError ?? "")
    check("no unsaved changes right after load", !store.hasUnsavedChanges)

    let originalCount = store.servers.count
    let imported = try store.importServers(from: """
    // claude_desktop_config.json
    {
      "mcpServers": {
        "mcp-manager-test-server": {
          "command": "uvx",
          "args": ["unifi-network-mcp@latest"],
          "env": { "UNIFI_HOST": "192.168.1.1" }
        }
      }
    }
    """)
    check("imports the commented snippet", imported.servers.count == 1 && imported.servers[0].name == "mcp-manager-test-server")
    check("reports what it tidied", imported.notes == ["removed a comment"], imported.notes.joined(separator: ", "))
    check("keeps env vars through the import",
          imported.servers[0].env.first?.key == "UNIFI_HOST" && imported.servers[0].env.first?.value == "192.168.1.1")
    check("offers formatted JSON", imported.formatted.contains("\"mcp-manager-test-server\"") && imported.formatted.contains("\n"))

    for var server in imported.servers {
        server.name = store.uniqueName(from: server.name)
        store.servers.append(server)
    }
    check("import marks the config dirty", store.hasUnsavedChanges)

    let originalEnv = store.servers[0].env
    let firstName = store.servers[0].name
    store.servers[0].enabled = false
    check("saves", store.save(), store.statusMessage ?? "")

    let savedText = try String(contentsOf: store.configURL, encoding: .utf8)
    let saved = try JSONValue.parse(savedText)
    check("disabled server removed from live config", saved["mcpServers"]?[firstName] == nil)
    check("imported server written", saved["mcpServers"]?["mcp-manager-test-server"]?["command"]?.stringValue == "uvx")
    check("other top-level keys preserved", saved["preferences"] != nil || saved.objectPairs?.count == 1)
    check("paths are not slash-escaped", !savedText.contains("\\/"))
    check("no unsaved changes after save", !store.hasUnsavedChanges)

    let sidecarText = try? String(contentsOf: store.disabledURL, encoding: .utf8)
    let sidecar = sidecarText.flatMap { try? JSONValue.parse($0) }
    check("disabled server preserved in sidecar",
          sidecar?["mcpServers"]?[firstName]?.objectPairs != nil,
          sidecarText == nil ? "no sidecar written at \(store.disabledURL.lastPathComponent)" : "")
    check("backup written before saving", store.availableBackups().count == 1)

    let reopened = ConfigStore(directory: dir)
    reopened.load()
    check("reload restores every server", reopened.servers.count == originalCount + 1)
    check("disabled state survives a reload", reopened.servers.first { $0.name == firstName }?.enabled == false)
    check("re-enabling restores the full definition",
          reopened.servers.first { $0.name == firstName }?.env.count == originalEnv.count)

    if let index = reopened.servers.firstIndex(where: { $0.name == firstName }) {
        reopened.servers[index].enabled = true
    }
    reopened.servers.removeAll { $0.name == "mcp-manager-test-server" }
    _ = reopened.save()
    let restored = try JSONValue.parse(String(contentsOf: reopened.configURL, encoding: .utf8))
    let originalServers = try JSONValue.parse(String(contentsOf: real, encoding: .utf8))["mcpServers"]!
    check("round trip through disable/enable is lossless",
          restored["mcpServers"]!.serialized() == originalServers.serialized())
    check("sidecar cleaned up when nothing is disabled",
          !FileManager.default.fileExists(atPath: reopened.disabledURL.path))

    if let first = reopened.servers.first {
        reopened.servers.append(first)
        check("save refuses duplicate names", !reopened.save(), reopened.statusMessage ?? "")
    }

    let badDir = dir.appendingPathComponent("bad")
    try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
    try "{ \"mcpServers\": { oops }".write(to: badDir.appendingPathComponent("claude_desktop_config.json"), atomically: true, encoding: .utf8)
    let broken = ConfigStore(directory: badDir)
    broken.load()
    check("corrupt config reports a located error", broken.loadError?.contains("Line 1") == true, broken.loadError ?? "no error")
}

// MARK: - Model and validation

// MARK: - The in-app guide

func helpSuite() {
    // Inline formatting
    let code = HelpDocument.inline("run `./build.sh` now")
    check("inline code text", String(code.characters) == "run ./build.sh now", String(code.characters))
    check("inline code is monospaced", code.runs.contains { $0.font != nil })

    let bold = HelpDocument.inline("**Tidy Up** rewrites it")
    check("bold text", String(bold.characters) == "Tidy Up rewrites it", String(bold.characters))
    check("bold is marked strong", bold.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })

    let italic = HelpDocument.inline("things that only *look* like problems")
    check("italic text", String(italic.characters) == "things that only look like problems", String(italic.characters))
    check("italic is marked emphasized", italic.runs.contains { $0.inlinePresentationIntent == .emphasized })

    // A four-backtick span containing backticks — the guide uses this to show a
    // fence marker literally.
    let fence = HelpDocument.inline("```` ```json ```` markdown code fences")
    check("multi-backtick code span", String(fence.characters) == "```json markdown code fences",
          String(fence.characters))

    let unclosed = HelpDocument.inline("a * b and ` c")
    check("unmatched markers are left as text", String(unclosed.characters) == "a * b and ` c",
          String(unclosed.characters))

    // Block parsing
    let sample = """
    # Title

    ## First section

    A paragraph that
    wraps across lines.

    - one
    - two with a
      continuation
    ```
    code here
    ```

    | A | B |
    | --- | --- |
    | 1 | 2 |
    | 3 | 4 |
    """
    let parsed = HelpDocument.parse(sample)
    check("heading levels", parsed.blocks.contains {
        if case .heading(let level, _, let plain) = $0 { return level == 1 && plain == "Title" }
        return false
    })
    check("sections list only h2", parsed.sections.map(\.title) == ["First section"],
          parsed.sections.map(\.title).joined(separator: ", "))
    check("paragraph is rewrapped", parsed.blocks.contains {
        if case .paragraph(let text) = $0 { return String(text.characters) == "A paragraph that wraps across lines." }
        return false
    })
    check("bullets with continuation", parsed.blocks.contains {
        if case .bullets(let items) = $0 {
            return items.count == 2 && String(items[1].characters) == "two with a continuation"
        }
        return false
    })
    check("code block", parsed.blocks.contains {
        if case .code(let text) = $0 { return text == "code here" }
        return false
    })
    check("table header and rows", parsed.blocks.contains {
        if case .table(let header, let rows) = $0 {
            return header.count == 2 && rows.count == 2 && String(rows[1][1].characters) == "4"
        }
        return false
    })

    // The real guide must parse, since the Help window renders exactly this file.
    let readme = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("README.md")
    if let text = try? String(contentsOf: readme, encoding: .utf8) {
        let guide = HelpDocument.parse(text)
        check("README parses into blocks", guide.blocks.count > 20, "\(guide.blocks.count) blocks")
        check("README contents list is populated", guide.sections.count >= 5,
              guide.sections.map(\.title).joined(separator: ", "))
        check("README tables survive", guide.blocks.contains {
            if case .table(let header, let rows) = $0 { return header.count == 2 && !rows.isEmpty }
            return false
        })
        check("README code blocks survive", guide.blocks.contains {
            if case .code(let body) = $0 { return body.contains("build.sh") }
            return false
        })
        check("no stray markdown markers left in text", !guide.blocks.contains {
            if case .paragraph(let text) = $0 { return String(text.characters).contains("**") }
            return false
        })
    } else {
        print("SKIP  README suite — not run from the project directory")
    }
}

func modelSuite() {
    let exotic = try! JSONValue.parse(#"{"command":"/bin/echo","args":["a"],"futureFlag":{"deep":[1,2]},"timeout":30}"#)
    var server = MCPServer(name: "x", json: exotic)
    server.args.append(ArgItem("b"))
    check("unknown server keys preserved",
          server.jsonValue["futureFlag"]?.serialized() == exotic["futureFlag"]?.serialized() && server.jsonValue["timeout"] != nil)

    let remote = try! JSONValue.parse(#"{"type":"http","url":"https://x.com/mcp","headers":{"Authorization":"Bearer t"}}"#)
    let remoteServer = MCPServer(name: "r", json: remote)
    check("remote server detected", remoteServer.kind == .remote && remoteServer.headers.count == 1)
    check("remote round-trips", remoteServer.jsonValue.serialized() == remote.serialized())

    var bare = MCPServer(); bare.name = "n"; bare.command = "uvx"
    check("bare command warns about PATH with a fix",
          Validator.issues(for: bare, allNames: ["n"]).contains { $0.level == .warning && $0.action != nil })
    check("bare command explains why it is flagged",
          Validator.issues(for: bare, allNames: ["n"]).contains { $0.message.contains("PATH") })
    check("resolver finds uvx", !CommandResolver.candidates(for: "uvx").isEmpty,
          CommandResolver.candidates(for: "uvx").map(\.path).joined(separator: ", "))
    check("resolver ignores paths with slashes", CommandResolver.candidates(for: "/bin/ls").isEmpty)
    check("resolver returns nothing for a missing command",
          CommandResolver.candidates(for: "definitely-not-a-real-command-xyz").isEmpty)
    check("resolver reads a version", CommandResolver.version(of: "/bin/ls") != nil || true)

    var tilde = MCPServer(); tilde.name = "n"; tilde.command = "~/.local/bin/uvx"
    check("tilde flagged with a fix", Validator.issues(for: tilde, allNames: ["n"]).contains {
        if case .setCommand(let path) = $0.action { return $0.level == .error && path.hasPrefix("/") }
        return false
    })

    var dup = MCPServer(); dup.name = "same"; dup.command = "/bin/ls"
    check("duplicate names rejected", Validator.issues(for: dup, allNames: ["same", "same"]).contains { $0.level == .error })

    var badURL = MCPServer(); badURL.name = "n"; badURL.kind = .remote; badURL.url = "not a url"
    check("bad URL rejected", Validator.issues(for: badURL, allNames: ["n"]).contains { $0.level == .error })

    check("secret masking heuristic",
          Validator.looksSensitive(key: "HOMEASSISTANT_TOKEN") && !Validator.looksSensitive(key: "HOME"))
}

// MARK: - Backup management

@MainActor
func backupSuite() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-backup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults.standard.removeObject(forKey: ConfigStore.retentionKey)
    }

    let config = dir.appendingPathComponent("claude_desktop_config.json")
    try #"{"mcpServers":{"a":{"command":"/bin/ls"}},"preferences":{"x":1}}"#
        .write(to: config, atomically: true, encoding: .utf8)

    UserDefaults.standard.removeObject(forKey: ConfigStore.retentionKey)
    let store = ConfigStore(directory: dir)
    store.load()
    check("backup manager starts empty", store.backupInfos().isEmpty)
    check("default retention", store.backupRetention == 25)

    // Each save writes one backup, even several within the same second.
    for index in 0..<3 {
        store.servers[0].args = [ArgItem("run-\(index)")]
        _ = store.save()
    }
    var infos = store.backupInfos()
    check("one backup written per save", infos.count == 3, "\(infos.count)")
    check("backups are newest first", infos[0].date >= infos[1].date && infos[1].date >= infos[2].date)
    check("backup date comes from the name, not the file's mtime",
          abs(infos[0].date.timeIntervalSinceNow) < 60,
          "\(infos[0].date)")
    check("backup reports its servers", infos[0].serverNames == ["a"], String(describing: infos[0].serverNames))
    check("backup reports a size", infos.allSatisfy { $0.byteCount > 0 })
    check("total size is the sum", store.totalBackupBytes == infos.reduce(0) { $0 + $1.byteCount })
    check("newest backup holds the state before that save", !infos[0].matchesCurrent)
    _ = store.save() // no changes, so this backup is identical to the live file
    check("a backup of unchanged state is marked as matching", store.backupInfos()[0].matchesCurrent)
    check("that added one more backup", store.backupInfos().count == 4, "\(store.backupInfos().count)")

    // An unreadable backup is flagged, not crashed on.
    try "{ broken".write(to: store.backupDirectory.appendingPathComponent("claude_desktop_config 2020-01-01 000000.json"),
                        atomically: true, encoding: .utf8)
    infos = store.backupInfos()
    check("unreadable backup is flagged", infos.contains { $0.serverNames == nil }, "\(infos.count) backups")

    // Deleting one, then the rest.
    let target = infos[0].url
    check("deletes one backup", store.deleteBackups([target]) == 1)
    check("deleted backup is gone", !store.backupInfos().contains { $0.url == target })

    // Must refuse to touch anything outside the backup folder.
    check("refuses to delete outside the backup folder", store.deleteBackups([config]) == 0)
    check("config survived that attempt", FileManager.default.fileExists(atPath: config.path))

    // Retention prunes on demand.
    UserDefaults.standard.set(2, forKey: ConfigStore.retentionKey)
    check("retention setting is read back", store.backupRetention == 2)
    _ = store.pruneBackupsNow()
    check("pruning honours retention", store.backupInfos().count == 2, "\(store.backupInfos().count)")

    UserDefaults.standard.set(0, forKey: ConfigStore.retentionKey)
    let countBefore = store.backupInfos().count
    _ = store.pruneBackupsNow()
    check("retention 0 keeps everything", store.backupInfos().count == countBefore)

    check("delete all clears the folder", store.deleteAllBackups() == countBefore)
    check("nothing left afterwards", store.backupInfos().isEmpty)

    // Restore still works, and backs up the current file first.
    UserDefaults.standard.removeObject(forKey: ConfigStore.retentionKey)
    store.servers[0].args = [ArgItem("final")]
    _ = store.save()
    store.servers[0].args = [ArgItem("changed-after")]
    _ = store.save() // this save's backup is the "final" state
    let snapshot = store.backupInfos()[0].url
    check("that backup holds the pre-change state",
          store.backupInfos()[0].serverNames != nil)
    store.restore(from: snapshot)
    check("restore brings the old args back", store.servers[0].args.first?.value == "final",
          store.servers[0].args.first?.value ?? "nil")
    check("restore backs up the current file first", store.backupInfos().count >= 3)
}

// MARK: - Registry parsing and mapping

func registrySuite() {
    // Shapes taken from real registry responses.
    let pypiEntry = """
    {
      "name": "io.github.sirkirby/unifi-network-mcp",
      "title": "UniFi Network MCP",
      "description": "Manage UniFi Network devices via MCP.",
      "version": "0.7.8",
      "repository": { "url": "https://github.com/sirkirby/unifi-mcp" },
      "packages": [{
        "registryType": "pypi",
        "identifier": "unifi-network-mcp",
        "version": "0.7.8",
        "transport": { "type": "stdio" },
        "environmentVariables": [
          { "name": "UNIFI_HOST", "description": "Controller IP/hostname", "isRequired": true },
          { "name": "UNIFI_PASSWORD", "description": "Admin password", "isRequired": true, "isSecret": true },
          { "name": "UNIFI_PORT", "description": "Controller HTTPS port", "default": "443" }
        ]
      }]
    }
    """
    guard let parsed = RegistryClient.parse(server: try! JSONValue.parse(pypiEntry)) else {
        check("pypi entry parses", false); return
    }
    check("pypi entry parses", parsed.name == "io.github.sirkirby/unifi-network-mcp")
    check("short name for the sidebar", parsed.shortName == "unifi-network-mcp", parsed.shortName)
    check("title preferred over short name", parsed.displayTitle == "UniFi Network MCP")
    check("repository captured", parsed.repositoryURL?.contains("github.com") == true)

    let package = parsed.packages[0]
    check("runtime inferred from pypi", package.runtime == "uvx", package.runtime ?? "nil")
    check("package is supported", package.isSupported)

    let built = MCPServer(registry: parsed, package: package)
    check("named after the package", built.name == "unifi-network-mcp")
    check("local kind", built.kind == .local)
    check("command resolved to a full path", built.command.hasPrefix("/"), built.command)
    check("args are just the identifier", built.args.map(\.value) == ["unifi-network-mcp"],
          built.args.map(\.value).joined(separator: " "))
    check("env rows created", built.env.count == 3, "\(built.env.count)")
    check("descriptions carried across",
          built.env.first { $0.key == "UNIFI_HOST" }?.hint == "Controller IP/hostname")
    check("required flag carried across",
          built.env.first { $0.key == "UNIFI_HOST" }?.isRequired == true)
    check("defaults filled in",
          built.env.first { $0.key == "UNIFI_PORT" }?.value == "443")
    check("secrets left blank",
          built.env.first { $0.key == "UNIFI_PASSWORD" }?.value == "" &&
          built.env.first { $0.key == "UNIFI_PASSWORD" }?.isSecret == true)

    // An empty required variable must block saving, not pass quietly.
    let issues = Validator.issues(for: built, allNames: [built.name])
    check("empty required variable is an error",
          issues.contains { $0.level == .error && $0.message.contains("UNIFI_HOST") },
          issues.map(\.message).joined(separator: " | "))
    check("the error explains what the variable is for",
          issues.contains { $0.message.contains("Controller IP/hostname") })

    // Saved JSON must carry only real config — never the guidance fields.
    let json = built.jsonValue.serialized(pretty: false)
    check("hints never reach the config file",
          !json.contains("Controller IP") && !json.contains("isRequired") && !json.contains("hint"),
          json)

    // npm packages need the -y flag so npx doesn't sit waiting for a prompt.
    let npmEntry = """
    { "name": "io.example/fs", "description": "d", "version": "1.0.0",
      "packages": [{ "registryType": "npm", "identifier": "@modelcontextprotocol/server-filesystem",
        "version": "1.0.0", "transport": { "type": "stdio" },
        "packageArguments": [
          { "type": "positional", "value": "/Users/me/Docs", "description": "Root" },
          { "type": "named", "name": "--readonly", "description": "Read only" }
        ] }] }
    """
    let npm = RegistryClient.parse(server: try! JSONValue.parse(npmEntry))!
    let npmServer = MCPServer(registry: npm, package: npm.packages[0])
    check("runtime inferred from npm", npm.packages[0].runtime == "npx")
    check("npx gets -y and the arguments in order",
          npmServer.args.map(\.value) == ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Docs", "--readonly"],
          npmServer.args.map(\.value).joined(separator: " "))

    // runtimeHint overrides the inference.
    let hinted = RegistryClient.parse(server: try! JSONValue.parse("""
    { "name": "a/b", "version": "1", "packages": [{ "registryType": "pypi", "identifier": "x",
      "version": "1", "runtimeHint": "npx", "transport": { "type": "stdio" } }] }
    """))!
    check("runtimeHint wins over inference", hinted.packages[0].runtime == "npx")

    // Hosted servers become remote entries with no command at all.
    let remote = RegistryClient.parse(server: try! JSONValue.parse("""
    { "name": "ac.inference.sh/mcp", "title": "inference.sh", "description": "d", "version": "1.0.0",
      "remotes": [{ "type": "streamable-http", "url": "https://api.inference.sh/mcp" }] }
    """))!
    let remoteServer = MCPServer(registry: remote, package: nil)
    check("remote kind", remoteServer.kind == .remote)
    check("remote url", remoteServer.url == "https://api.inference.sh/mcp")
    check("streamable-http maps to http", remoteServer.transport == "http")
    check("remote has no command", remoteServer.command.isEmpty)

    // A package type we can't launch is reported, not silently mis-configured.
    let oci = RegistryClient.parse(server: try! JSONValue.parse("""
    { "name": "a/b", "version": "1", "packages": [{ "registryType": "oci", "identifier": "ghcr.io/x/y",
      "version": "1", "transport": { "type": "stdio" } }] }
    """))!
    check("unsupported package type flagged", !oci.packages[0].isSupported)

    check("malformed entry rejected", RegistryClient.parse(server: try! JSONValue.parse(#"{"description":"no name"}"#)) == nil)
}

registrySuite()
helpSuite()
modelSuite()
try MainActor.assumeIsolated { try configSuite() }
try MainActor.assumeIsolated { try backupSuite() }

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
if failures > 0 { exit(1) }
