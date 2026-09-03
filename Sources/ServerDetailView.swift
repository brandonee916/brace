import AppKit
import SwiftUI

/// A labelled row that spans the full width of the form.
///
/// A grouped `Form` on macOS puts a `TextField`'s label in a left-hand column
/// and right-aligns the value, which reads badly for long file paths. Stacking
/// the label above a full-width field keeps paths and arguments left-aligned
/// and readable.
private struct Field<Content: View>: View {
    let title: String
    var hint: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.medium))
            content
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
}

private struct MonoField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .labelsHidden()
    }
}

struct ServerDetailView: View {
    @Binding var server: MCPServer
    let allNames: [String]

    @State private var revealedKeys: Set<UUID> = []
    @State private var showsJSON = false
    @State private var showsCommandPicker = false
    @State private var showsTest = false

    /// Testing needs something to launch or connect to.
    private var canTest: Bool {
        switch server.kind {
        case .local: return !server.command.trimmingCharacters(in: .whitespaces).isEmpty
        case .remote: return !server.url.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// The program name without its folder, for the "Find…" picker.
    private var commandBaseName: String {
        let trimmed = server.command.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("/") ? (trimmed as NSString).lastPathComponent : trimmed
    }

    private var issues: [Issue] { Validator.issues(for: server, allNames: allNames) }

    var body: some View {
        Form {
            if !issues.isEmpty {
                Section("Checks") {
                    ForEach(issues) { issue in
                        IssueRow(issue: issue) { action in apply(action) }
                    }
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button {
                        showsTest = true
                    } label: {
                        Label("Test Connection", systemImage: "play.circle")
                    }
                    .disabled(!canTest)
                    Text("Launches the server the way Claude Desktop would and checks that it answers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }

            Section("General") {
                Field(
                    title: "Name",
                    hint: "The label you'll see inside Claude. Anything readable works."
                ) {
                    TextField("", text: $server.name, prompt: Text("My Server"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }

                Field(title: "Connection", hint: server.kind.explanation) {
                    Picker("", selection: $server.kind) {
                        ForEach(ServerKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Toggle(isOn: $server.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enabled")
                        if !server.enabled {
                            Text("Kept safely aside and not loaded by Claude. Nothing is lost — switch it back on any time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 3)
            }

            if server.kind == .local {
                localSections
            } else {
                remoteSections
            }

            Section {
                DisclosureGroup("Show the JSON this produces", isExpanded: $showsJSON) {
                    ScrollView(.horizontal) {
                        Text(previewJSON)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                }
            } footer: {
                Text("You never have to type this — it's here so you can see what the app writes for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsTest) {
            TestSheet(server: server)
        }
        .sheet(isPresented: $showsCommandPicker) {
            CommandPickerSheet(
                commandName: commandBaseName,
                currentPath: server.command
            ) { picked in
                server.command = picked
            }
        }
    }

    // MARK: - Local

    @ViewBuilder
    private var localSections: some View {
        Section("Command") {
            Field(
                title: "Program to run",
                hint: "The full path to the program Claude should launch. Claude Desktop doesn't read your shell's PATH, so a full path is far more reliable than a bare name like \"npx\"."
            ) {
                HStack(spacing: 8) {
                    MonoField(placeholder: "/opt/homebrew/bin/uvx", text: $server.command)
                    Button("Find…") { showsCommandPicker = true }
                        .disabled(commandBaseName.isEmpty)
                        .help("List every copy of this program on your Mac, with versions")
                    Button("Browse…", action: browseForCommand)
                }
            }
        }

        Section {
            if server.args.isEmpty {
                Text("No arguments yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array($server.args.enumerated()), id: \.element.id) { index, $arg in
                ListRow(
                    canMoveUp: index > 0,
                    canMoveDown: index < server.args.count - 1,
                    onMoveUp: { move(argID: arg.id, by: -1) },
                    onMoveDown: { move(argID: arg.id, by: 1) },
                    onDelete: { server.args.removeAll { $0.id == arg.id } }
                ) {
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        MonoField(placeholder: "argument", text: $arg.value)
                    }
                }
            }
            Button {
                server.args.append(ArgItem())
            } label: {
                Label("Add argument", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        } header: {
            Text("Arguments")
        } footer: {
            Text("One box per argument — the same pieces you'd separate with spaces on a command line. Order matters, so use the arrows to rearrange.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            if server.env.isEmpty {
                Text("No environment variables yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach($server.env) { $pair in
                ListRow(
                    canMoveUp: false,
                    canMoveDown: false,
                    onMoveUp: {},
                    onMoveDown: {},
                    onDelete: { server.env.removeAll { $0.id == pair.id } }
                ) {
                    HStack(spacing: 8) {
                        MonoField(placeholder: "NAME", text: $pair.key)
                            .frame(width: 200)
                        secretField(for: $pair)
                    }
                }
            }
            Button {
                server.env.append(PairItem())
            } label: {
                Label("Add variable", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        } header: {
            Text("Environment variables")
        } footer: {
            Text("Where API keys and tokens go. Values that look like secrets stay hidden until you click the eye.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func secretField(for pair: Binding<PairItem>) -> some View {
        let sensitive = pair.wrappedValue.isSecret || Validator.looksSensitive(key: pair.wrappedValue.key)
        let revealed = revealedKeys.contains(pair.wrappedValue.id)
        HStack(spacing: 4) {
            if sensitive && !revealed {
                SecureField("", text: pair.value, prompt: Text(placeholder(for: pair.wrappedValue)))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            } else {
                MonoField(placeholder: placeholder(for: pair.wrappedValue), text: pair.value)
            }
            if sensitive {
                Button {
                    let id = pair.wrappedValue.id
                    if revealed { revealedKeys.remove(id) } else { revealedKeys.insert(id) }
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed ? "Hide value" : "Show value")
            }
        }
    }

    /// Prefers the registry's own description of a variable over a generic label.
    private func placeholder(for pair: PairItem) -> String {
        if let hint = pair.hint, !hint.isEmpty {
            return pair.isRequired ? "\(hint) (required)" : hint
        }
        return pair.isRequired ? "required" : "value"
    }

    // MARK: - Remote

    @ViewBuilder
    private var remoteSections: some View {
        Section("Server") {
            Field(title: "URL", hint: "The address Claude connects to.") {
                MonoField(placeholder: "https://example.com/mcp", text: $server.url)
            }
            Field(title: "Transport") {
                Picker("", selection: $server.transport) {
                    Text("HTTP").tag("http")
                    Text("SSE").tag("sse")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }

        Section {
            if server.headers.isEmpty {
                Text("No headers yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach($server.headers) { $pair in
                ListRow(
                    canMoveUp: false,
                    canMoveDown: false,
                    onMoveUp: {},
                    onMoveDown: {},
                    onDelete: { server.headers.removeAll { $0.id == pair.id } }
                ) {
                    HStack(spacing: 8) {
                        TextField("", text: $pair.key, prompt: Text("Header"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 200)
                        secretField(for: $pair)
                    }
                }
            }
            Button {
                server.headers.append(PairItem())
            } label: {
                Label("Add header", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        } header: {
            Text("Headers")
        } footer: {
            Text("Usually where an Authorization header goes, if the server needs one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private var previewJSON: String {
        JSONValue.object([
            (key: server.name.isEmpty ? "server-name" : server.name, value: server.jsonValue),
        ]).serialized()
    }

    private func move(argID: UUID, by offset: Int) {
        guard let index = server.args.firstIndex(where: { $0.id == argID }) else { return }
        let target = index + offset
        guard server.args.indices.contains(target) else { return }
        server.args.swapAt(index, target)
    }

    private func apply(_ action: Issue.Action) {
        switch action {
        case .setCommand(let path):
            server.command = path
        case .chooseCommand:
            showsCommandPicker = true
        }
    }

    private func browseForCommand() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the program Claude should launch"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            server.command = url.path
        }
    }
}

/// A row with reorder and delete controls lined up on the trailing edge.
private struct ListRow<Content: View>: View {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
            HStack(spacing: 4) {
                if canMoveUp || canMoveDown {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up").frame(width: 14, height: 14)
                    }
                    .disabled(!canMoveUp)
                    .help("Move up")
                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down").frame(width: 14, height: 14)
                    }
                    .disabled(!canMoveDown)
                    .help("Move down")
                }
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                }
                .help("Remove this row")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 1)
    }
}

private struct IssueRow: View {
    let issue: Issue
    let apply: (Issue.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.level.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(issue.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action = issue.action, let label = issue.actionLabel {
                Button(label) { apply(action) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private var symbol: String {
        switch issue.level {
        case .error: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private var tint: Color {
        switch issue.level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}
