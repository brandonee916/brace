import Foundation

extension Process {
    /// Shuts a child process down and reaps it.
    ///
    /// `terminate()` alone is not enough. It returns immediately, so the child is
    /// left unreaped — a zombie for as long as the app runs — and a process that
    /// ignores SIGTERM is never cleaned up at all. MCP servers also conventionally
    /// exit when their standard input closes, which is gentler than a signal, so
    /// that is tried first.
    func endAndReap(closing stdin: Pipe? = nil, graceSeconds: TimeInterval = 1.5) {
        // Note the descendants before the parent dies. A launcher like `uvx` or a
        // shell often runs the real server as a child of its own, and once the
        // parent is gone those are reparented to launchd and can no longer be
        // found this way — they would simply keep running.
        let descendants = isRunning ? Process.descendants(of: processIdentifier) : []

        if let stdin {
            try? stdin.fileHandleForWriting.close()
        }
        guard isRunning else {
            waitUntilExit()
            return
        }

        // Give it a moment to notice the closed input before signalling.
        let softDeadline = Date().addingTimeInterval(min(graceSeconds, 0.4))
        while isRunning, Date() < softDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if isRunning { terminate() }

        let deadline = Date().addingTimeInterval(graceSeconds)
        while isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        // Still there: it is ignoring SIGTERM, so stop asking.
        if isRunning {
            kill(processIdentifier, SIGKILL)
        }
        waitUntilExit()

        // Anything the child started and did not clean up.
        for pid in descendants where kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
        }
    }

    /// Process ids descended from `pid`, deepest last.
    ///
    /// Uses `pgrep`, which is present on every macOS install. Failure here is not
    /// worth surfacing: it only means a stray helper outlives the test.
    static func descendants(of pid: pid_t, depth: Int = 0) -> [pid_t] {
        guard depth < 4 else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let children = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        return children + children.flatMap { descendants(of: $0, depth: depth + 1) }
    }
}
