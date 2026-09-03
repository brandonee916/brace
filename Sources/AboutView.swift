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
            if !updates.missed.isEmpty {
                ReleaseNotesSheet(releases: updates.missed)
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

/// Shows what changed since the running version, rendered with the same Markdown
/// parser as the guide.
///
/// Every release that was skipped, not only the newest one — someone three
/// versions behind should see all of it.
struct ReleaseNotesSheet: View {
    let releases: [Release]
    @Environment(\.dismiss) private var dismiss

    init(releases: [Release]) {
        self.releases = releases
    }

    init(release: Release) {
        self.releases = [release]
    }

    private var newest: Release? { releases.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(heading)
                    .font(.title3.weight(.semibold))
                Text(subheading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(releases.enumerated()), id: \.offset) { index, release in
                        VStack(alignment: .leading, spacing: 7) {
                            if releases.count > 1 {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(release.version)
                                        .font(.headline)
                                    if let date = release.publishedAt {
                                        Text(date.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            MarkdownText(release.notes, droppingHeadingFor: releases.count > 1 ? release.version : nil)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if index < releases.count - 1 { Divider() }
                    }
                }
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
                if let newest {
                    Link("Open Download Page", destination: newest.pageURL)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 580, height: 460)
    }

    private var heading: String {
        guard let newest else { return "What's new" }
        return releases.count > 1
            ? "What's new since \(UpdateChecker.currentVersion)"
            : "What's new in \(newest.version)"
    }

    private var subheading: String {
        guard let newest else { return "" }
        if releases.count > 1 {
            return "\(releases.count) releases, up to \(newest.version)"
        }
        return newest.publishedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
    }
}

/// Renders Markdown with the parser the Help window already uses.
private struct MarkdownText: View {
    let document: HelpDocument

    /// `droppingHeadingFor` removes a leading heading that just repeats the
    /// version — release notes come from the changelog, where each section starts
    /// with its own version heading, and the sheet already shows that above.
    init(_ markdown: String, droppingHeadingFor version: String? = nil) {
        var parsed = HelpDocument.parse(markdown)
        if let version,
           case .heading(_, _, let plain)? = parsed.blocks.first,
           plain.hasPrefix(version) {
            parsed.blocks.removeFirst()
        }
        document = parsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(document.blocks) { block in
                switch block {
                case .heading(_, let text, _):
                    Text(text).font(.subheadline.weight(.semibold)).padding(.top, 2)
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
