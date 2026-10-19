import AppKit
import SwiftUI

/// Search the MCP registry and add a server with its fields already laid out.
///
/// Servers built into apps on this Mac are listed above the registry results:
/// they're never published there, so a search alone would never find them.
struct RegistrySheet: View {
    @ObservedObject var store: ConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [RegistryServer] = []
    /// A registry server's name or a built-in server's id; the two never collide.
    @State private var selection: String?
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var latestVersions: [String: String] = [:]
    @State private var searchTask: Task<Void, Never>?
    /// Where each built-in server was found, by id. Absent until looked for;
    /// looking can run a program, so it's done once, off the main thread.
    @State private var builtInLocations: [String: BuiltInLocation?] = [:]

    private var selected: RegistryServer? {
        results.first { $0.id == selection }
    }

    private var selectedBuiltIn: BuiltInServer? {
        BuiltInCatalog.all.first { $0.id == selection }
    }

    /// Filtered as you type, and all of them before you type anything.
    private var visibleBuiltIns: [BuiltInServer] {
        BuiltInCatalog.matching(query)
    }

    /// The package we'd actually install — first one with a runtime we support.
    private func chosenPackage(for server: RegistryServer) -> RegistryPackage? {
        server.packages.first(where: \.isSupported) ?? server.packages.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                resultsList
                    .frame(minWidth: 250, idealWidth: 290)
                detail
                    .frame(minWidth: 380)
            }
            Divider()
            footer
        }
        .frame(width: 860, height: 580)
        .onDisappear { searchTask?.cancel() }
        .task { await detectBuiltIns() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add from the MCP registry")
                .font(.title3.weight(.semibold))
            Text("Search the official registry and the fields get laid out for you. Entries are published by each server's author, so treat them as a starting point — you still review everything before saving. Servers built into apps on this Mac are listed first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("", text: $query, prompt: Text("Search for a server, e.g. unifi, github, postgres"))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .onSubmit(runSearch)
                if isSearching { ProgressView().controlSize(.small) }
                Button("Search", action: runSearch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
        }
        .padding(16)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsList: some View {
        if !visibleBuiltIns.isEmpty {
            List(selection: $selection) {
                Section("On this Mac") {
                    ForEach(visibleBuiltIns) { server in
                        builtInRow(server).tag(server.id)
                    }
                }
                Section("Registry") {
                    if let errorMessage {
                        inlineMessage(errorMessage)
                    } else if results.isEmpty {
                        inlineMessage(hasSearched ? "No matches." : "Search to see published servers.")
                    } else {
                        ForEach(results) { server in
                            registryRow(server).tag(server.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
        } else if let errorMessage {
            centeredMessage(
                title: "Couldn't search",
                detail: errorMessage,
                symbol: "wifi.exclamationmark"
            )
        } else if results.isEmpty {
            centeredMessage(
                title: hasSearched ? "No matches" : "Search the registry",
                detail: hasSearched
                    ? "Nothing published under that name. Try a shorter or more general term."
                    : "Over a thousand servers are published. Try a product name.",
                symbol: hasSearched ? "questionmark.folder" : "magnifyingglass"
            )
        } else {
            List(results, selection: $selection) { server in
                registryRow(server).tag(server.id)
            }
            .listStyle(.inset)
        }
    }

    private func registryRow(_ server: RegistryServer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(server.displayTitle).lineLimit(1)
            Text(server.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(packageLabel(for: server))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func builtInRow(_ server: BuiltInServer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(server.title).lineLimit(1)
            Text(server.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(builtInLabel(for: server))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func builtInLabel(for server: BuiltInServer) -> String {
        guard let found = builtInLocations[server.id] else { return "looking…" }
        guard let location = found else { return "not found on this Mac" }
        if BuiltInCatalog.existingEntry(for: location, in: store.servers) != nil {
            return "already in your config"
        }
        return "found · \(location.label)"
    }

    private func inlineMessage(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func packageLabel(for server: RegistryServer) -> String {
        if let package = chosenPackage(for: server) {
            return "\(package.registryType) · \(package.identifier)"
        }
        if server.remotes.first != nil { return "remote server" }
        return "no installable package"
    }

    private func centeredMessage(title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let server = selectedBuiltIn {
            builtInDetail(server)
        } else if let server = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.displayTitle).font(.title3.weight(.semibold))
                        Text(server.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !server.summary.isEmpty {
                            Text(server.summary)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }

                    versionRow(for: server)

                    if let package = chosenPackage(for: server) {
                        if package.isSupported {
                            previewRow(for: server, package: package)
                            let preview = MCPServer(registry: server, package: package)
                            ForEach(Validator.safetyIssues(for: preview)) { issue in
                                note(issue.message, symbol: "exclamationmark.shield.fill", tint: .orange)
                            }
                            if !package.environmentVariables.isEmpty {
                                environmentRows(package)
                            }
                        } else {
                            note(
                                "This is published as a \(package.registryType) package, which this app can't launch for you. You can still add it by hand.",
                                symbol: "exclamationmark.triangle.fill",
                                tint: .orange
                            )
                        }
                    } else if let remote = server.remotes.first {
                        note(
                            "A hosted server — Claude connects to \(remote.url) over the network. Nothing gets installed.",
                            symbol: "network",
                            tint: .secondary
                        )
                    }

                    // Only http(s): the URL comes from the entry's author.
                    if let repo = server.repositoryURL,
                       let repoURL = URL(string: repo),
                       repoURL.scheme == "https" || repoURL.scheme == "http" {
                        Link(destination: repoURL) {
                            Label("View the source repository", systemImage: "arrow.up.forward.square")
                                .font(.callout)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            centeredMessage(
                title: "Nothing selected",
                detail: "Pick a result to see what it installs and which settings it needs.",
                symbol: "sidebar.right"
            )
        }
    }

    private func builtInDetail(_ server: BuiltInServer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.title).font(.title3.weight(.semibold))
                    Text("Built into an app on this Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(server.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }

                switch builtInLocations[server.id] {
                case .none:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking for it…").font(.caption).foregroundStyle(.secondary)
                    }
                case .some(.none):
                    note(
                        "Not found. It comes with Safari 27 or later, and with Safari Technology Preview. Update macOS or install Technology Preview, then open this sheet again.",
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                    if let download = server.downloadURL, let url = URL(string: download) {
                        Link(destination: url) {
                            Label("Get Safari Technology Preview", systemImage: "arrow.down.circle")
                                .font(.callout)
                        }
                    }
                case .some(.some(let location)):
                    if let existing = BuiltInCatalog.existingEntry(for: location, in: store.servers) {
                        note(
                            "Already set up as \"\(existing.name)\" in your config. Adding it again would only give Claude a second copy.",
                            symbol: "checkmark.circle",
                            tint: .green
                        )
                    } else {
                        note("Found the copy that comes with \(location.label).", symbol: "checkmark.circle", tint: .green)
                    }
                    let preview = MCPServer(builtIn: server, location: location)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Claude will run")
                            .font(.subheadline.weight(.medium))
                        Text(([preview.command] + preview.args.map(\.value)).joined(separator: " "))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                    }
                }

                if !server.setupSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Also switch on, once")
                            .font(.subheadline.weight(.medium))
                        ForEach(Array(server.setupSteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(index + 1).").font(.caption).foregroundStyle(.secondary)
                                Text(step)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("The config entry alone isn't enough: without these the server starts but turns every request away.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                    }
                }

                if let docs = server.documentationURL, let url = URL(string: docs) {
                    Link(destination: url) {
                        Label("Read Apple's announcement", systemImage: "arrow.up.forward.square")
                            .font(.callout)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func versionRow(for server: RegistryServer) -> some View {
        let package = chosenPackage(for: server)
        let published = package?.version ?? server.version
        let latest = package.flatMap { latestVersions[$0.identifier] }

        if let latest, !published.isEmpty, latest != published {
            note(
                "This registry entry describes version \(published), but \(package?.registryType ?? "the package registry") currently ships \(latest). Entries are updated by hand and this one is behind, so the settings below may be out of date — check the project's README if something doesn't work.",
                symbol: "clock.badge.exclamationmark",
                tint: .orange
            )
        } else if let latest {
            note("Registry entry matches the published version (\(latest)).", symbol: "checkmark.circle", tint: .green)
        } else if !published.isEmpty {
            note("Registry entry describes version \(published).", symbol: "info.circle", tint: .secondary)
        }
    }

    private func previewRow(for server: RegistryServer, package: RegistryPackage) -> some View {
        let preview = MCPServer(registry: server, package: package)
        return VStack(alignment: .leading, spacing: 5) {
            Text("Claude will run")
                .font(.subheadline.weight(.medium))
            Text(([preview.command] + preview.args.map(\.value)).joined(separator: " "))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        }
    }

    private func environmentRows(_ package: RegistryPackage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Settings it needs")
                .font(.subheadline.weight(.medium))
            ForEach(package.environmentVariables, id: \.name) { variable in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(variable.name)
                        .font(.system(.caption, design: .monospaced))
                    if variable.isRequired {
                        tag("required", tint: .orange)
                    }
                    if variable.isSecret {
                        tag("secret", tint: .secondary)
                    }
                    if let value = variable.defaultValue, !value.isEmpty {
                        tag("default \(value)", tint: .secondary)
                    }
                    Text(variable.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if package.environmentVariables.contains(where: \.isSecret) {
                Text("Secrets are left blank on purpose — you'll fill them in on the next screen.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
        }
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.15)))
    }

    private func note(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(selectedBuiltIn != nil ? "Source: this Mac" : "Source: registry.modelcontextprotocol.io")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add Server") { commit() }
                .disabled(!canAdd)
        }
        .padding(12)
    }

    private var canAdd: Bool {
        if let server = selectedBuiltIn {
            return builtInLocations[server.id].flatMap { $0 } != nil
        }
        guard let server = selected else { return false }
        if let package = chosenPackage(for: server) { return package.isSupported }
        return server.remotes.first != nil
    }

    // MARK: - Actions

    private func runSearch() {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        searchTask?.cancel()
        isSearching = true
        errorMessage = nil

        searchTask = Task {
            do {
                let found = try await RegistryClient.search(term)
                if Task.isCancelled { return }
                results = found
                selection = found.first?.id
                hasSearched = true
                isSearching = false
                await loadLatestVersions(for: found)
            } catch {
                if Task.isCancelled { return }
                results = []
                selection = nil
                hasSearched = true
                isSearching = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Cross-checks each result against npm/PyPI, since registry entries drift.
    private func loadLatestVersions(for servers: [RegistryServer]) async {
        for server in servers {
            guard let package = chosenPackage(for: server), package.isSupported,
                  latestVersions[package.identifier] == nil else { continue }
            if let latest = await RegistryClient.latestPublishedVersion(of: package) {
                if Task.isCancelled { return }
                latestVersions[package.identifier] = latest
            }
        }
    }

    private func detectBuiltIns() async {
        let found = await Task.detached(priority: .userInitiated) {
            BuiltInCatalog.all.map { ($0.id, BuiltInCatalog.detect($0)) }
        }.value
        for (id, location) in found {
            builtInLocations[id] = .some(location)
        }
        // Nothing picked yet: a server that's here and not yet set up is the
        // likeliest reason to have opened this sheet.
        if selection == nil,
           let ready = BuiltInCatalog.all.first(where: { server in
               guard let location = builtInLocations[server.id].flatMap({ $0 }) else { return false }
               return BuiltInCatalog.existingEntry(for: location, in: store.servers) == nil
           }) {
            selection = ready.id
        }
    }

    private func commit() {
        if let server = selectedBuiltIn {
            guard let location = builtInLocations[server.id].flatMap({ $0 }) else { return }
            var newServer = MCPServer(builtIn: server, location: location)
            newServer.name = store.uniqueName(from: newServer.name)
            store.servers.append(newServer)
            store.servers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            store.statusMessage = "Added \(newServer.name). Save, then restart Claude Desktop — and switch on \(server.title)'s developer settings if you haven't."
            dismiss()
            return
        }
        guard let server = selected else { return }
        var newServer = MCPServer(registry: server, package: chosenPackage(for: server))
        newServer.name = store.uniqueName(from: newServer.name)
        store.servers.append(newServer)
        store.servers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        store.statusMessage = "Added \(newServer.name) from the registry. Fill in any required settings, then save."
        dismiss()
    }
}
