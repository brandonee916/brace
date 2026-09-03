import AppKit
import SwiftUI

/// Paste-a-snippet import.
///
/// Most MCP servers document themselves as a block of JSON in a README, and
/// hand-merging that into an existing config is exactly the bracket-counting this
/// app exists to avoid. What gets pasted is usually not strict JSON — it has a
/// `// claude_desktop_config.json` header, or sits in a code fence — so the box
/// tidies it up instead of complaining.
struct ImportSheet: View {
    @ObservedObject var store: ConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var errorMessage: String?
    @State private var result: ConfigStore.ImportResult?

    private var servers: [MCPServer] { result?.servers ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a server snippet")
                .font(.title3.weight(.semibold))
            Text("Copy the JSON from a server's setup instructions and paste it below. A whole config, just the \"mcpServers\" block, or a single server all work — and comments, code fences and stray commas are cleaned up for you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The editor takes whatever room the status area isn't using, so an
            // empty dialog is all editor rather than editor plus a void.
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 140, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            if hasStatus {
                // A ScrollView always claims the height it is offered, so a bare
                // frame leaves a gap under one short row and overflows under six.
                // ViewThatFits uses the plain stack while it fits and only falls
                // back to scrolling when the content genuinely exceeds the cap.
                ViewThatFits(in: .vertical) {
                    status.frame(maxWidth: .infinity, alignment: .leading)
                    ScrollView {
                        status.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: 240)
            }

            HStack {
                Button("Paste from Clipboard") {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        text = clip
                    }
                }
                Button("Tidy Up") {
                    if let formatted = result?.formatted { text = formatted }
                }
                .disabled(result == nil)
                .help("Rewrite the box as clean, formatted JSON")

                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(servers.count > 1 ? "Add \(servers.count) Servers" : "Add Server") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(servers.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .onAppear(perform: prefillFromClipboard)
        .onChange(of: text) { _, _ in revalidate() }
    }

    @ViewBuilder
    private var status: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } else if !servers.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label(
                    servers.count == 1 ? "Ready to add one server" : "Ready to add \(servers.count) servers",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .font(.callout)

                // Safety warnings go above the list, not inside it. With several
                // servers the risky one can be last, and a warning you have to
                // scroll to find is a warning that goes unread.
                if !flaggedServers.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(flaggedServers.enumerated()), id: \.offset) { _, server in
                            ForEach(Validator.safetyIssues(for: server)) { issue in
                                Label {
                                    Text("\(server.name): ").fontWeight(.semibold)
                                        + Text(issue.message)
                                } icon: {
                                    Image(systemName: "exclamationmark.shield.fill")
                                }
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.orange.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.orange.opacity(0.4)))
                }

                // A config file names the program Claude will run, so show exactly
                // what that is before it gets added rather than after.
                ForEach(Array(servers.enumerated()), id: \.offset) { _, server in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                            .font(.callout.weight(.semibold))
                        Text(commandLine(for: server))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }

                if let notes = result?.notes, !notes.isEmpty {
                    Label("Tidied up for you — \(notes.joined(separator: ", ")).", systemImage: "wand.and.sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Whether there is anything to show under the editor. Nothing to say means no
    /// space reserved.
    private var hasStatus: Bool {
        errorMessage != nil || !servers.isEmpty
    }

    /// Servers whose command shape means "run arbitrary code".
    private var flaggedServers: [MCPServer] {
        servers.filter { !Validator.safetyIssues(for: $0).isEmpty }
    }

    /// What Claude would actually launch, for the preview.
    private func commandLine(for server: MCPServer) -> String {
        switch server.kind {
        case .local:
            return ([server.command] + server.args.map(\.value)).joined(separator: " ")
        case .remote:
            return "connects to \(server.url)"
        }
    }

    /// If the clipboard already holds a usable snippet, fill it in — that's almost
    /// always why this sheet was opened.
    private func prefillFromClipboard() {
        guard text.isEmpty,
              let clip = NSPasteboard.general.string(forType: .string),
              clip.contains("{"),
              let parsed = try? store.importServers(from: clip),
              !parsed.servers.isEmpty
        else { return }
        text = clip
    }

    private func revalidate() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result = nil
            errorMessage = nil
            return
        }
        guard text.contains("{") else {
            result = nil
            errorMessage = "That doesn't look like JSON — paste the block that starts with a {."
            return
        }
        do {
            let parsed = try store.importServers(from: text)
            result = parsed.servers.isEmpty ? nil : parsed
            errorMessage = parsed.servers.isEmpty ? "No servers found in that snippet." : nil
        } catch let error as JSONParseError {
            result = nil
            errorMessage = "That isn't valid JSON — \(error.localizedDescription)"
        } catch {
            result = nil
            errorMessage = error.localizedDescription
        }
    }

    private func commit() {
        for var server in servers {
            server.name = store.uniqueName(from: server.name)
            store.servers.append(server)
        }
        store.servers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        dismiss()
    }
}
