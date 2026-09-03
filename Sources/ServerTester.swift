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

enum ServerTester {
    /// Launches the server, completes an `initialize` handshake, and asks for its
    /// tool list.
    ///
    /// The environment is deliberately sparse, mirroring how Claude Desktop is
    /// launched by Finder — that's what makes a bare command name fail there but
    /// work in Terminal, and this test should reproduce it rather than hide it.
    static func test(_ server: MCPServer, timeout: TimeInterval = 90) async -> TestResult {
        switch server.kind {
        case .local: return await testLocal(server, timeout: timeout)
        case .remote: return await testRemote(server, timeout: min(timeout, 30))
        }
    }

    // MARK: - Local (stdio)

    private static func testLocal(_ server: MCPServer, timeout: TimeInterval) async -> TestResult {
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
                continuation.resume(returning: runHandshake(server, executable: resolved, timeout: timeout))
            }
        }
    }

    private static func runHandshake(_ server: MCPServer, executable: String, timeout: TimeInterval) -> TestResult {
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
            guard !data.isEmpty else { return }
            errorBuffer.mutate { $0 += String(decoding: data, as: UTF8.self) }
        }

        func send(_ message: String) {
            guard let data = (message + "\n").data(using: .utf8) else { return }
            try? input.fileHandleForWriting.write(contentsOf: data)
        }

        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Claude MCP Manager","version":"1.0"}}}"#)

        let deadline = Date().addingTimeInterval(timeout)
        var stdout = ""
        var initializeReply: JSONValue?
        var toolCount: Int?

        while Date() < deadline {
            if let reply = initializeReply, toolCount == nil {
                _ = reply
                send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
                send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            }

            guard let chunk = readAvailable(output.fileHandleForReading, until: deadline) else {
                break // the pipe closed: the process is gone
            }
            stdout += chunk

            for line in completeLines(in: &stdout) {
                guard let message = try? JSONValue.parse(line) else { continue }
                let id = message["id"]
                if initializeReply == nil, case .number("1")? = id {
                    if let error = message["error"] {
                        return finish(process, errorBuffer, stdout, TestResult(
                            status: .noResponse,
                            headline: "The server refused the handshake",
                            detail: error["message"]?.stringValue ?? error.serialized(pretty: false)
                        ))
                    }
                    initializeReply = message["result"]
                } else if case .number("2")? = id {
                    toolCount = message["result"]?["tools"]?.arrayValues?.count ?? 0
                }
            }

            if initializeReply != nil, toolCount != nil { break }
            if !process.isRunning, stdout.isEmpty { break }
        }

        guard let result = initializeReply else {
            let stderr = errorBuffer.value
            let exited = !process.isRunning
            let status = process.isRunning ? TestResult.Status.noResponse : .wontStart
            return finish(process, errorBuffer, stdout, TestResult(
                status: status,
                headline: exited ? "The server stopped before answering" : "No answer from the server",
                detail: exited
                    ? "It exited with code \(process.terminationStatus). The output below usually says what it needed."
                    : "It started but didn't complete an MCP handshake within \(Int(timeout)) seconds.",
                downstreamNotes: notableLines(in: stderr)
            ))
        }

        let info = result["serverInfo"]
        return finish(process, errorBuffer, stdout, TestResult(
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
        _ errorBuffer: Locked<String>,
        _ stdout: String,
        _ result: TestResult
    ) -> TestResult {
        if process.isRunning { process.terminate() }
        var finished = result
        if finished.downstreamNotes.isEmpty {
            finished.downstreamNotes = notableLines(in: errorBuffer.value)
        }
        let stderr = errorBuffer.value
        finished.log = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
        return finished
    }

    /// Reads whatever is available without blocking past the deadline.
    private static func readAvailable(_ handle: FileHandle, until deadline: Date) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        DispatchQueue.global(qos: .userInitiated).async {
            data = handle.availableData
            semaphore.signal()
        }
        let wait = max(0.1, min(1.0, deadline.timeIntervalSinceNow))
        if semaphore.wait(timeout: .now() + wait) == .timedOut { return "" }
        guard let data, !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Pulls whole lines out of the buffer, leaving any partial line behind.
    private static func completeLines(in buffer: inout String) -> [String] {
        guard buffer.contains("\n") else { return [] }
        var parts = buffer.components(separatedBy: "\n")
        buffer = parts.removeLast()
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
            guard message.count > 3, seen.insert(message).inserted else { continue }
            notes.append(message)
            if notes.count >= 6 { break }
        }
        return notes
    }

    // MARK: - Remote (http)

    private static func testRemote(_ server: MCPServer, timeout: TimeInterval) async -> TestResult {
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
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Claude MCP Manager","version":"1.0"}}}"#.utf8)

        do {
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
