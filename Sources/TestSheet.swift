import SwiftUI

/// Runs the server and reports what happened.
struct TestSheet: View {
    let server: MCPServer
    @Environment(\.dismiss) private var dismiss

    @State private var result: TestResult?
    @State private var progress: TestProgress?
    @State private var isRunning = true
    @State private var showsLog = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Testing \(server.name.isEmpty ? "this server" : server.name)")
                .font(.title3.weight(.semibold))

            if isRunning {
                running
            } else if let result {
                outcome(result)
            }

            Spacer(minLength: 0)

            HStack {
                if let result, !result.log.isEmpty {
                    Toggle("Show full output", isOn: $showsLog)
                        .toggleStyle(.checkbox)
                }
                Spacer()
                if isRunning {
                    Button("Stop") {
                        task?.cancel()
                        isRunning = false
                        result = TestResult(status: .noResponse, headline: "Stopped",
                                            detail: "You cancelled the test.")
                    }
                } else {
                    Button("Test Again") { run() }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: showsLog ? 560 : 400)
        .onAppear(perform: run)
        .onDisappear { task?.cancel() }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress?.stage ?? "Starting…")
                    .fontWeight(.medium)
                Spacer(minLength: 8)
                Text(elapsedText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(server.kind == .local
                 ? "It's launched exactly the way Claude Desktop launches it, then asked to introduce itself. A first run can take a minute or two while the package downloads."
                 : "Sending an MCP handshake to the address you configured.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The server's own output is the most informative thing to show while
            // waiting — it's usually saying what it's downloading or connecting to.
            if let line = progress?.lastLine {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Latest from the server")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: progress?.stage)
    }

    private var elapsedText: String {
        let seconds = Int(progress?.elapsed ?? 0)
        return seconds < 60 ? "\(seconds)s" : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder
    private func outcome(_ result: TestResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol(result.status))
                    .foregroundStyle(tint(result.status))
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.headline).font(.headline)
                    Text(result.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if result.status == .responded {
                VStack(alignment: .leading, spacing: 4) {
                    if let name = result.serverName {
                        detailRow("Identifies as", name + (result.serverVersion.map { " \($0)" } ?? ""))
                    }
                    if let version = result.protocolVersion {
                        detailRow("MCP version", version)
                    }
                    if let count = result.toolCount {
                        detailRow("Tools offered", count == 0 ? "none yet" : "\(count)")
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            }

            if !result.downstreamNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        result.status == .responded
                            ? "The server reported this while starting"
                            : "What it said",
                        systemImage: "text.bubble"
                    )
                    .font(.subheadline.weight(.medium))
                    ForEach(result.downstreamNotes, id: \.self) { note in
                        Text("• " + note)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if result.status == .responded {
                        Text("Your configuration is fine — this is the server talking about its own connection. If it can't reach something on your network, being away from that network is enough to cause it.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }

            if showsLog, !result.log.isEmpty {
                ScrollView {
                    Text(result.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func symbol(_ status: TestResult.Status) -> String {
        switch status {
        case .responded: return "checkmark.circle.fill"
        case .wontStart: return "exclamationmark.octagon.fill"
        case .noResponse: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ status: TestResult.Status) -> Color {
        switch status {
        case .responded: return .green
        case .wontStart: return .red
        case .noResponse: return .orange
        }
    }

    private func run() {
        task?.cancel()
        isRunning = true
        result = nil
        progress = nil
        let target = server
        task = Task {
            let outcome = await ServerTester.test(target) { update in
                // Reported from the reader thread, so hop to the main actor.
                Task { @MainActor in progress = update }
            }
            if Task.isCancelled { return }
            result = outcome
            isRunning = false
        }
    }
}
