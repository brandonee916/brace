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

            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            ScrollView {
                status.frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 260)

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
        .frame(width: 640)
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

                // A config file names the program Claude will run, so show exactly
                // what that is before it gets added rather than after.
                ForEach(servers) { server in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                            .font(.callout.weight(.semibold))
                        Text(commandLine(for: server))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Validator.safetyIssues(for: server)) { issue in
                            Label(issue.message, systemImage: "exclamationmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 1)
                        }
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
        } else {
            // Keeps the dialog from resizing as you type.
            Text(" ").font(.callout)
        }
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
