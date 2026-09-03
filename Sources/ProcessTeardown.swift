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
    }
}
