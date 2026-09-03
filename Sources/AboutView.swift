import AppKit
import SwiftUI

/// The About window: what this is, who made it, and whether it's current.
struct AboutView: View {
    @StateObject private var updates = UpdateModel()
    @State private var showsNotes = false

    private var version: String { UpdateChecker.currentVersion }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                }

                VStack(spacing: 3) {
                    Text("Claude MCP Manager")
                        .font(.title2.weight(.semibold))
                    Text("Version \(version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("An editor for Claude Desktop's MCP servers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 5) {
                    Text("Created by Brandon")
                        .font(.callout.weight(.medium))
                    HStack(spacing: 14) {
                        Link("Source on GitHub", destination: UpdateChecker.repositoryURL)
                        Link("@brandonee916", destination: URL(string: "https://github.com/brandonee916")!)
                    }
                    .font(.callout)
                }
                .padding(.top, 2)

                updateRow
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 22)
        }
        .frame(width: 380)
        .fixedSize()
        .task { await updates.checkInBackgroundIfDue() }
        .sheet(isPresented: $showsNotes) {
            if let release = updates.available {
                ReleaseNotesSheet(release: release)
            }
        }
    }

    @ViewBuilder
    private var updateRow: some View {
        VStack(spacing: 7) {
            if updates.isChecking {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Checking for updates…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let release = updates.available {
                Label("Version \(release.version) is available", systemImage: "arrow.down.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                Button("See What's New") { showsNotes = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Check for Updates") {
                    Task { await updates.checkNow() }
                }
                if updates.confirmedUpToDate {
                    Text("You're on the latest version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = updates.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Shows a release's notes, rendered with the same Markdown parser as the guide.
struct ReleaseNotesSheet: View {
    let release: Release
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("What's new in \(release.version)")
                    .font(.title3.weight(.semibold))
                if let date = release.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                MarkdownText(release.notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220)

            HStack {
                Text("You have \(UpdateChecker.currentVersion).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Link("Open Download Page", destination: release.pageURL)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }
}

/// Renders Markdown with the parser the Help window already uses.
private struct MarkdownText: View {
    let document: HelpDocument

    init(_ markdown: String) {
        document = HelpDocument.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(document.blocks) { block in
                switch block {
                case .heading(_, let text, _):
                    Text(text).font(.headline).padding(.top, 4)
                case .paragraph(let text):
                    Text(text).fixedSize(horizontal: false, vertical: true)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("•").foregroundStyle(.secondary)
                                Text(item).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .code(let text):
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
                case .table, .image:
                    EmptyView()
                }
            }
        }
    }
}
