import SwiftUI

/// Lists every copy of a command on this Mac so you can pick which one Claude runs.
struct CommandPickerSheet: View {
    let commandName: String
    let currentPath: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [CommandCandidate] = []
    @State private var selection: String?
    @State private var isLoadingVersions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose which \"\(commandName)\" to use")
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if candidates.isEmpty {
                Text("No copies of \"\(commandName)\" were found on this Mac.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A List fills whatever it is given, so one result in a fixed sheet
                // shows one row and six empty ones. Height follows the count.
                List(candidates, selection: $selection) { candidate in
                    row(for: candidate)
                        .tag(candidate.path)
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
                .frame(height: min(max(Double(candidates.count) * 54 + 12, 66), 320))
            }

            HStack {
                if isLoadingVersions && !candidates.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Checking versions…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use This One") {
                    if let selection { onPick(selection) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear(perform: load)
    }

    private var subtitle: String {
        candidates.count > 1
            ? "There are \(candidates.count) copies installed. Claude Desktop doesn't load your Terminal's PATH, so picking one explicitly is the only way to be sure which it runs."
            : "Claude Desktop doesn't load your Terminal's PATH, so the full path is the reliable way to point at a program."
    }

    private func row(for candidate: CommandCandidate) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    if candidate.path == currentPath {
                        Text("Current")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                HStack(spacing: 6) {
                    Text(candidate.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let version = candidate.version {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if !isLoadingVersions {
                        Text("· version unavailable")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let target = candidate.resolvesTo {
                        Text("· symlink to \(target)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func load() {
        candidates = CommandResolver.candidates(for: commandName)
        selection = candidates.first { $0.path == currentPath }?.path ?? candidates.first?.path

        // Versions mean launching each binary, so they're fetched off the main
        // thread and filled in as they arrive.
        let paths = candidates.map(\.path)
        DispatchQueue.global(qos: .userInitiated).async {
            let versions = paths.map { ($0, CommandResolver.version(of: $0)) }
            DispatchQueue.main.async {
                for (path, version) in versions {
                    if let index = candidates.firstIndex(where: { $0.path == path }) {
                        candidates[index].version = version
                    }
                }
                isLoadingVersions = false
            }
        }
    }
}
