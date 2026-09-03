import Foundation

/// The outcome of launching a server and trying to speak MCP to it.
///
/// Deliberately three states rather than pass/fail. A correctly configured server
/// will still fail to reach its backend whenever you're off the network or the
/// far end is down, and painting that red would teach you to ignore the result.
/// What this app can actually vouch for is narrower: does it start, and does it
/// answer.
struct TestResult {
    enum Status {
        case wontStart      // bad path, missing variable, crash on startup
        case responded      // completed an MCP handshake
        case noResponse     // launched, but never answered
    }

    var status: Status
    var headline: String
    var detail: String
    var serverName: String?
    var serverVersion: String?
    var protocolVersion: String?
    var toolCount: Int?
    /// Things the server complained about after starting successfully — surfaced
    /// as information, since they're usually about the service, not the config.
    var downstreamNotes: [String] = []
    var log: String = ""
}

/// Live progress while a test runs, so a slow first launch doesn't look frozen.
struct TestProgress: Sendable {
    var stage: String
    /// The most recent thing the server printed, if anything yet.
    var lastLine: String?
    var elapsed: TimeInterval
}

/// Lets the UI stop a test that is already running.
final class TestCancellation: @unchecked Sendable {
    private let flag = Locked(false)
    var isCancelled: Bool { flag.value }
    func cancel() { flag.mutate { $0 = true } }
}

enum ServerTester {
    /// Writing to a pipe whose reader has gone raises SIGPIPE, whose default
    /// action is to kill the process — so a server that answered and exited took
    /// the whole app down, unsaved edits included. Ignore it and let `write` fail
    /// with an error instead.
    private static let ignoreBrokenPipe: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()
    /// Launches the server, completes an `initialize` handshake, and asks for its
    /// tool list.
    ///
    /// The environment is deliberately sparse, mirroring how Claude Desktop is
    /// launched by Finder — that's what makes a bare command name fail there but
    /// work in Terminal, and this test should reproduce it rather than hide it.
    static func test(
        _ server: MCPServer,
        timeout: TimeInterval = 180,
        cancellation: TestCancellation = TestCancellation(),
        onProgress: @escaping @Sendable (TestProgress) -> Void = { _ in }
    ) async -> TestResult {
        _ = ignoreBrokenPipe
        switch server.kind {
        case .local:
            return await testLocal(server, timeout: timeout, cancellation: cancellation, onProgress: onProgress)
        case .remote:
            return await testRemote(server, timeout: min(timeout, 30), onProgress: onProgress)
        }
    }

    // MARK: - Local (stdio)

    private static func testLocal(
        _ server: MCPServer,
        timeout: TimeInterval,
        cancellation: TestCancellation,
        onProgress: @escaping @Sendable (TestProgress) -> Void
    ) async -> TestResult {
        let command = server.command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else {
            return TestResult(status: .wontStart, headline: "No command set",
                              detail: "Fill in the program Claude should run, then test again.")
        }
        let resolved = command.contains("/") ? command : (CommandResolver.preferred(for: command)?.path ?? command)
        guard FileManager.default.isExecutableFile(atPath: resolved) else {
            return TestResult(
                status: .wontStart,
                headline: "Couldn't run that command",
                detail: "There's no executable at \(resolved). Fix the command, then test again."
            )
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runHandshake(server, executable: resolved, timeout: timeout, cancellation: cancellation, onProgress: onProgress))
            }
        }
    }

    private static func runHandshake(
        _ server: MCPServer,
        executable: String,
        timeout: TimeInterval,
        cancellation: TestCancellation,
        onProgress: @escaping @Sendable (TestProgress) -> Void
    ) -> TestResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = server.args.map(\.value).filter { !$0.isEmpty }

        // A GUI-launched app inherits almost nothing; reproduce that.
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        for pair in server.env where !pair.key.isEmpty {
            environment[pair.key] = pair.value
        }
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let started = Date()
        onProgress(TestProgress(
            stage: "Launching \((executable as NSString).lastPathComponent)…",
            lastLine: nil,
            elapsed: 0
        ))

        do {
            try process.run()
        } catch {
            return TestResult(
                status: .wontStart,
                headline: "Couldn't start the server",
                detail: error.localizedDescription
            )
        }

        // Collect stderr continuously so a chatty server can't fill the pipe and block.
        let errorBuffer = Locked("")
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Empty means end of file. Returning without clearing the handler
            // leaves it firing in a tight loop for the rest of the test.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            errorBuffer.mutate { $0 += String(decoding: data, as: UTF8.self) }
        }

        func send(_ message: String) {
            guard let data = (message + "\n").data(using: .utf8) else { return }
            try? input.fileHandleForWriting.write(contentsOf: data)
        }

        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Brace","version":"1.0"}}}"#)

        // Read stdout through a readability handler rather than polling.
        // Polling meant a timed-out read left a thread still blocked on the pipe;
        // the next poll started another, and whichever one eventually woke up
        // discarded the bytes it had taken. The handshake reply vanished that way.
        let outputBuffer = Locked("")
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            outputBuffer.mutate { $0 += String(decoding: data, as: UTF8.self) }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var pending = ""
        var initializeReply: JSONValue?
        var toolCount: Int?
        var askedForTools = false

        /// Consumes whatever has arrived. Returns an early result if the server
        /// rejected the handshake outright.
        func drain() -> TestResult? {
            var chunk = ""
            outputBuffer.mutate { chunk = $0; $0 = "" }
            pending += chunk
            for line in completeLines(in: &pending) {
                guard let message = try? JSONValue.parse(line) else { continue }
                switch message["id"] {
                case .number("1")?:
                    guard initializeReply == nil else { continue }
                    if let error = message["error"] {
                        return TestResult(
                            status: .noResponse,
                            headline: "The server refused the handshake",
                            detail: error["message"]?.stringValue ?? error.serialized(pretty: false)
                        )
                    }
                    initializeReply = message["result"]
                case .number("2")?:
                    toolCount = message["result"]?["tools"]?.arrayValues?.count ?? 0
                default:
                    continue
                }
            }
            return nil
        }

        var stage = "Waiting for the server to start…"
        var lastReported = Date.distantPast

        while Date() < deadline {
            if cancellation.isCancelled {
                return finish(process, (input, output, errors), errorBuffer, pending, TestResult(
                    status: .noResponse,
                    headline: "Stopped",
                    detail: "You stopped the test, and the server was shut down."
                ))
            }

            // Refresh roughly four times a second: enough to look alive, cheap
            // enough not to matter.
            if Date().timeIntervalSince(lastReported) > 0.25 {
                lastReported = Date()
                onProgress(TestProgress(
                    stage: stage,
                    lastLine: lastMeaningfulLine(in: errorBuffer.value),
                    elapsed: Date().timeIntervalSince(started)
                ))
            }

            if let rejected = drain() {
                return finish(process, (input, output, errors), errorBuffer, pending, rejected)
            }

            // Exactly once, and only after initialize is acknowledged.
            if initializeReply != nil, !askedForTools {
                askedForTools = true
                stage = "It answered — asking what tools it offers…"
                send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
                send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            } else if !askedForTools, !errorBuffer.value.isEmpty,
                      stage == "Waiting for the server to start…" {
                stage = "It's running — waiting for it to answer the handshake…"
            }

            if initializeReply != nil, toolCount != nil { break }

            if !process.isRunning {
                // It has exited; take one last look at what it left behind.
                _ = drain()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = drain()

        guard let result = initializeReply else {
            let stderr = errorBuffer.value
            let exited = !process.isRunning
            let status = process.isRunning ? TestResult.Status.noResponse : .wontStart
            return finish(process, (input, output, errors), errorBuffer, pending, TestResult(
                status: status,
                headline: exited ? "The server stopped before answering" : "No answer from the server",
                detail: exited
                    ? "It exited with code \(process.terminationStatus). The output below usually says what it needed."
                    : "It started but didn't complete an MCP handshake within \(Int(timeout)) seconds.",
                downstreamNotes: notableLines(in: stderr)
            ))
        }

        let info = result["serverInfo"]
        return finish(process, (input, output, errors), errorBuffer, pending, TestResult(
            status: .responded,
            headline: "The server started and answered",
            detail: "Your configuration works. Anything below is what the server itself reported.",
            serverName: info?["name"]?.stringValue,
            serverVersion: info?["version"]?.stringValue,
            protocolVersion: result["protocolVersion"]?.stringValue,
            toolCount: toolCount,
            downstreamNotes: notableLines(in: errorBuffer.value)
        ))
    }

    private static func finish(
        _ process: Process,
        _ pipes: (input: Pipe, output: Pipe, errors: Pipe),
        _ errorBuffer: Locked<String>,
        _ stdout: String,
        _ result: TestResult
    ) -> TestResult {
        // Both handlers must go, not just stdout's: each one holds a dispatch
        // source on its descriptor and captures the buffer, so a missed one leaks
        // for every test run and can keep firing after the test is over.
        pipes.output.fileHandleForReading.readabilityHandler = nil
        pipes.errors.fileHandleForReading.readabilityHandler = nil
        process.endAndReap(closing: pipes.input)
        var finished = result
        if finished.downstreamNotes.isEmpty {
            finished.downstreamNotes = notableLines(in: errorBuffer.value)
        }
        let stderr = errorBuffer.value
        finished.log = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
        // A failure with nothing to show is the least useful result possible.
        if finished.downstreamNotes.isEmpty, finished.status != .responded {
            finished.downstreamNotes = lastLines(in: finished.log)
        }
        return finished
    }

    /// Pulls whole lines out of the buffer, leaving any partial line behind.
    private static func completeLines(in buffer: inout String) -> [String] {
        guard buffer.contains("\n") else { return [] }
        var parts = buffer.components(separatedBy: "\n")
        buffer = parts.removeLast()
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The newest line worth showing while a test is in flight — usually the
    /// package manager reporting a download on a first run.
    static func lastMeaningfulLine(in text: String) -> String? {
        for line in text.components(separatedBy: .newlines).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 3 else { continue }
            let message = trimmed.components(separatedBy: " - ").last ?? trimmed
            return message.count > 110 ? String(message.prefix(110)) + "…" : message
        }
        return nil
    }

    /// The tail of whatever the server printed.
    ///
    /// Used when a server fails without saying anything that looks like an error —
    /// "No module named x" matches no keyword, and reporting an exit code with no
    /// explanation is useless to whoever has to fix it.
    static func lastLines(in text: String, count: Int = 6) -> [String] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 1 }
        return Array(lines.suffix(count))
    }

    /// Error and warning lines worth showing, deduplicated.
    static func notableLines(in text: String) -> [String] {
        var seen = Set<String>()
        var notes: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let upper = trimmed.uppercased()
            guard upper.contains("ERROR") || upper.contains("WARN") || upper.contains("FAIL") else { continue }
            // Strip a leading timestamp/logger prefix so the message reads cleanly.
            let message = trimmed.components(separatedBy: " - ").last ?? trimmed
            // Skip banner rules and bare log-level residue like "ERROR -".
            guard message.count > 8,
                  message.contains(where: \.isLetter),
                  message.rangeOfCharacter(from: .alphanumerics) != nil,
                  Set(message).count > 4,
                  seen.insert(message).inserted
            else { continue }
            notes.append(message)
            if notes.count >= 6 { break }
        }
        return notes
    }

    // MARK: - Remote (http)

    private static func testRemote(
        _ server: MCPServer,
        timeout: TimeInterval,
        onProgress: @escaping @Sendable (TestProgress) -> Void
    ) async -> TestResult {
        let started = Date()
        onProgress(TestProgress(stage: "Connecting to the server…", lastLine: nil, elapsed: 0))
        guard let url = URL(string: server.url.trimmingCharacters(in: .whitespaces)),
              url.scheme?.hasPrefix("http") == true else {
            return TestResult(status: .wontStart, headline: "That URL isn't valid",
                              detail: "Enter an http or https address, then test again.")
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for pair in server.headers where !pair.key.isEmpty {
            request.setValue(pair.value, forHTTPHeaderField: pair.key)
        }
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Brace","version":"1.0"}}}"#.utf8)

        do {
            onProgress(TestProgress(stage: "Sending the MCP handshake…", lastLine: nil, elapsed: Date().timeIntervalSince(started)))
            let (data, response) = try await URLSession.shared.data(for: request)
            let body = String(decoding: data, as: UTF8.self)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard (200..<300).contains(code) else {
                return TestResult(
                    status: code == 401 || code == 403 ? .wontStart : .noResponse,
                    headline: code == 401 || code == 403
                        ? "The server refused your credentials"
                        : "The server answered with an error",
                    detail: "HTTP \(code)."
                        + (code == 401 || code == 403 ? " Check the Authorization header." : ""),
                    log: body
                )
            }

            // A streamable-http reply may arrive as SSE, so find the JSON payload.
            let payload = body.components(separatedBy: .newlines)
                .map { $0.hasPrefix("data:") ? String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) : $0 }
                .compactMap { try? JSONValue.parse($0) }
                .first { $0["result"] != nil || $0["error"] != nil }

            if let error = payload?["error"] {
                return TestResult(status: .noResponse, headline: "The server refused the handshake",
                                  detail: error["message"]?.stringValue ?? "", log: body)
            }
            guard let result = payload?["result"] else {
                return TestResult(status: .noResponse, headline: "Unexpected reply",
                                  detail: "The server answered, but not with an MCP handshake.", log: body)
            }
            let info = result["serverInfo"]
            return TestResult(
                status: .responded,
                headline: "The server answered",
                detail: "Your configuration works.",
                serverName: info?["name"]?.stringValue,
                serverVersion: info?["version"]?.stringValue,
                protocolVersion: result["protocolVersion"]?.stringValue,
                log: body
            )
        } catch {
            return TestResult(
                status: .noResponse,
                headline: "Couldn't reach the server",
                detail: error.localizedDescription
                    + " This can just mean you're off the network it lives on.",
                log: ""
            )
        }
    }
}

/// Minimal lock around a value shared with a pipe's reader thread.
final class Locked<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock = NSLock()

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storage)
    }
}
