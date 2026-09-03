import AppKit
import SwiftUI

/// Browse, restore and clean up the config backups the app writes before each save.
struct BackupsSheet: View {
    @ObservedObject var store: ConfigStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ConfigStore.retentionKey) private var retention = ConfigStore.defaultRetention

    @State private var backups: [ConfigStore.BackupInfo] = []
    @State private var selection: Set<URL> = []
    @State private var confirmingDeleteAll = false
    @State private var pendingRestore: ConfigStore.BackupInfo?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var selectedBackups: [ConfigStore.BackupInfo] {
        backups.filter { selection.contains($0.url) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if backups.isEmpty {
                emptyState
            } else {
                list
            }

            retentionRow
            Divider()
            buttonRow
        }
        .padding(20)
        .frame(width: 660, height: 520)
        .onAppear(perform: reload)
        .alert("Delete all \(backups.count) backups?", isPresented: $confirmingDeleteAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                store.deleteAllBackups()
                reload()
            }
        } message: {
            Text("This can't be undone. Your current config file isn't affected — only these saved copies.")
        }
        .alert(
            "Restore the backup from \(pendingRestore.map { Self.dateFormatter.string(from: $0.date) } ?? "")?",
            isPresented: .constant(pendingRestore != nil)
        ) {
            Button("Cancel", role: .cancel) { pendingRestore = nil }
            Button("Restore") {
                if let backup = pendingRestore { store.restore(from: backup.url) }
                pendingRestore = nil
                reload()
            }
        } message: {
            Text("This replaces your current MCP servers with the ones in that backup. Your current config is backed up first, so you can undo it.")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Backups")
                .font(.title3.weight(.semibold))
            Text("A copy of your config is saved here before every change. \(summaryLine)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryLine: String {
        guard !backups.isEmpty else { return "There aren't any yet." }
        let size = ByteCountFormatter.string(fromByteCount: Int64(store.totalBackupBytes), countStyle: .file)
        return "\(backups.count) backup\(backups.count == 1 ? "" : "s"), \(size) total."
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No backups yet")
                .font(.headline)
            Text("One gets written the first time you save a change.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(backups, selection: $selection) { backup in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Self.dateFormatter.string(from: backup.date))
                        if backup.matchesCurrent {
                            Text("Matches current")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                    Text(detail(for: backup))
                        .font(.caption)
                        .foregroundStyle(backup.serverNames == nil ? .red : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(ByteCountFormatter.string(fromByteCount: Int64(backup.byteCount), countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Restore") { pendingRestore = backup }
                    .controlSize(.small)
                    .disabled(backup.serverNames == nil)
            }
            .padding(.vertical, 2)
            .tag(backup.url)
            .contextMenu {
                Button("Restore…") { pendingRestore = backup }
                    .disabled(backup.serverNames == nil)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([backup.url])
                }
                Divider()
                Button("Delete", role: .destructive) {
                    store.deleteBackups([backup.url])
                    reload()
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private func detail(for backup: ConfigStore.BackupInfo) -> String {
        guard let names = backup.serverNames else {
            return "Unreadable — this file isn't valid JSON"
        }
        if names.isEmpty { return "No MCP servers" }
        return "\(names.count) server\(names.count == 1 ? "" : "s"): \(names.joined(separator: ", "))"
    }

    private var retentionRow: some View {
        HStack(spacing: 8) {
            Picker("Keep", selection: $retention) {
                Text("The last 10").tag(10)
                Text("The last 25").tag(25)
                Text("The last 50").tag(50)
                Text("All of them").tag(0)
            }
            .fixedSize()
            .onChange(of: retention) { _, _ in
                store.pruneBackupsNow()
                reload()
            }
            Text("Older backups are removed automatically when you save.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var buttonRow: some View {
        HStack(spacing: 8) {
            Button("Reveal Folder") { store.revealBackupsInFinder() }
            Button("Delete Selected") {
                store.deleteBackups(selectedBackups.map(\.url))
                selection.removeAll()
                reload()
            }
            .disabled(selection.isEmpty)
            Button("Delete All…") { confirmingDeleteAll = true }
                .disabled(backups.isEmpty)

            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func reload() {
        backups = store.backupInfos()
        selection = selection.intersection(Set(backups.map(\.url)))
    }
}
