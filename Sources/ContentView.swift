import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var store = ConfigStore()
    @State private var selection: UUID?
    @State private var showsImport = false
    @State private var showsBackups = false
    @State private var showsRegistry = false
    @State private var showsReleaseNotes = false
    @StateObject private var updates = UpdateModel()
    @State private var showsRestartPrompt = false
    @State private var pendingDelete: MCPServer?

    private var allNames: [String] { store.servers.map(\.name) }

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return store.servers.firstIndex { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 400)
            } detail: {
                detail
            }
            Divider()
            statusBar
        }
        .toolbar { toolbarContent }
        .task { store.load() }
        .task { await updates.checkInBackgroundIfDue() }
        .sheet(isPresented: $showsImport) { ImportSheet(store: store) }
        .sheet(isPresented: $showsBackups) { BackupsSheet(store: store) }
        .sheet(isPresented: $showsRegistry) { RegistrySheet(store: store) }
        .sheet(isPresented: $showsReleaseNotes) {
            if let release = updates.available {
                ReleaseNotesSheet(release: release)
            }
        }
        .alert("Remove \(pendingDelete?.name ?? "this server")?", isPresented: .constant(pendingDelete != nil)) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Remove", role: .destructive) {
                if let target = pendingDelete {
                    store.servers.removeAll { $0.id == target.id }
                    if selection == target.id { selection = nil }
                }
                pendingDelete = nil
            }
        } message: {
            Text("It'll be gone from the list once you save. A backup of your current config is written before every save, so this is recoverable.")
        }
        .alert("Restart Claude Desktop now?", isPresented: $showsRestartPrompt) {
            Button("Not Now", role: .cancel) {}
            Button("Restart") { store.restartClaudeDesktop() }
        } message: {
            Text("Claude Desktop reads this config once at launch, so your changes won't show up until it restarts.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach($store.servers) { $server in
                    ServerRow(server: server, issues: Validator.issues(for: server, allNames: allNames))
                        .tag(server.id)
                        .contextMenu {
                            Button(server.enabled ? "Disable" : "Enable") { server.enabled.toggle() }
                            Button("Duplicate") { duplicate(server) }
                            Button("Copy as JSON") { copyJSON(for: server) }
                            Divider()
                            Button("Remove…", role: .destructive) { pendingDelete = server }
                        }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 8) {
                Menu {
                    Button("Add from Registry…") { showsRegistry = true }
                    Button("Paste JSON Snippet…") { showsImport = true }
                    Divider()
                    Button("New Local Server") { addServer(kind: .local) }
                    Button("New Remote Server") { addServer(kind: .remote) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .fixedSize()
                .help("Add a server")

                Button {
                    if let index = selectedIndex { pendingDelete = store.servers[index] }
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .buttonStyle(.bordered)
                .disabled(selectedIndex == nil)
                .help("Remove the selected server")

                Spacer(minLength: 4)
                Text("\(store.servers.filter(\.enabled).count) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let error = store.loadError {
            ContentUnavailableView {
                Label("Can't read your config", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Show in Finder") { store.revealConfigInFinder() }
                Button("Try Again") { store.load() }
            }
        } else if let index = selectedIndex {
            ServerDetailView(server: $store.servers[index], allNames: allNames)
        } else if store.servers.isEmpty {
            ContentUnavailableView {
                Label("No MCP servers yet", systemImage: "shippingbox")
            } description: {
                Text("Search the MCP registry and have the fields filled in for you, paste the JSON from a server's setup instructions, or start from scratch.")
            } actions: {
                Button("Add from Registry…") { showsRegistry = true }
                    .buttonStyle(.borderedProminent)
                Button("Paste JSON Snippet…") { showsImport = true }
                Button("New Local Server") { addServer(kind: .local) }
            }
        } else {
            ContentUnavailableView(
                "Select a server",
                systemImage: "sidebar.left",
                description: Text("Pick a server on the left to edit it.")
            )
        }
    }

    // MARK: - Toolbar and status

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                showsImport = true
            } label: {
                Label("Paste JSON", systemImage: "doc.on.clipboard")
            }
            .help("Add servers by pasting JSON")
        }
        ToolbarItem {
            Button {
                openWindow(id: HelpWindow.id)
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .help("How this app works")
        }
        ToolbarItem {
            Menu {
                Button("Reveal Config in Finder") { store.revealConfigInFinder() }
                Button("Copy Whole Config") { copyWholeConfig() }
                Button("Reload from Disk") { store.load() }
                Divider()
                Button("Manage Backups…") { showsBackups = true }
                Divider()
                Button("Help") { openWindow(id: HelpWindow.id) }
                Divider()
                Button("Restart Claude Desktop") { store.restartClaudeDesktop() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        ToolbarItem {
            Button("Save") {
                if store.save() { showsRestartPrompt = true }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!store.hasUnsavedChanges)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if store.hasUnsavedChanges {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
                Text("Unsaved changes")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(store.statusMessage ?? "Everything on disk is up to date.")
            }
            if store.hasUnsavedChanges, let message = store.statusMessage {
                Text("· \(message)").foregroundStyle(.secondary)
            }
            Spacer()
            // Quiet until there's genuinely something newer.
            if let release = updates.available {
                Button {
                    showsReleaseNotes = true
                } label: {
                    Label("Version \(release.version) available", systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
                .help("See what changed")
            }
            if store.hasUnsavedChanges {
                Button("Discard") { store.load() }
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Actions

    private func addServer(kind: ServerKind) {
        var server = MCPServer()
        server.kind = kind
        server.name = store.uniqueName(from: kind == .local ? "new-server" : "remote-server")
        store.servers.append(server)
        selection = server.id
    }

    private func duplicate(_ server: MCPServer) {
        var copy = MCPServer(name: store.uniqueName(from: server.name), json: server.jsonValue)
        copy.enabled = server.enabled
        store.servers.append(copy)
        selection = copy.id
    }

    private func copyJSON(for server: MCPServer) {
        let json = JSONValue.object([
            (key: "mcpServers", value: .object([(key: server.name, value: server.jsonValue)])),
        ]).serialized()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        store.statusMessage = "Copied \(server.name) as JSON."
    }

    private func copyWholeConfig() {
        guard let text = try? String(contentsOf: store.configURL, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.statusMessage = "Copied the config file to the clipboard."
    }
}

private struct ServerRow: View {
    let server: MCPServer
    let issues: [Issue]

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name.isEmpty ? "Untitled" : server.name)
                    .lineLimit(1)
                Text(server.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !server.enabled {
                Text("Off")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .padding(.vertical, 2)
        .help(helpText)
    }

    private var tint: Color {
        if !server.enabled { return .secondary.opacity(0.4) }
        if issues.contains(where: { $0.level == .error }) { return .red }
        if issues.contains(where: { $0.level == .warning }) { return .orange }
        return .green
    }

    private var helpText: String {
        if issues.isEmpty { return "Looks good." }
        return issues.map(\.message).joined(separator: "\n")
    }
}
