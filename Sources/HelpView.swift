import AppKit
import SwiftUI

/// The in-app guide and release notes, rendered from the bundled `README.md` and
/// `CHANGELOG.md` — the same files the repository publishes, so there's nothing to
/// keep in sync by hand.
struct HelpView: View {
    enum Page: String, CaseIterable, Identifiable {
        case guide
        case releaseNotes

        var id: String { rawValue }
        var title: String { self == .guide ? "Guide" : "Release Notes" }
        var resource: String { self == .guide ? "README" : "CHANGELOG" }
    }

    @State private var page = Page.guide
    @State private var documents: [Page: HelpDocument] = [:]
    @State private var loadFailed = false
    @State private var selectedSection: String?

    private var document: HelpDocument { documents[page] ?? HelpDocument() }

    var body: some View {
        NavigationSplitView {
            contents
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            if loadFailed {
                ContentUnavailableView(
                    "Guide not found",
                    systemImage: "questionmark.circle",
                    description: Text("\(page.resource).md is missing from the app bundle. Rebuild with ./build.sh to include it.")
                )
            } else {
                body(of: document)
            }
        }
        .onAppear(perform: load)
        .onChange(of: page) { _, _ in selectedSection = nil }
    }

    // MARK: - Contents list

    private var contents: some View {
        List(selection: $selectedSection) {
            Section {
                Picker("", selection: $page) {
                    ForEach(Page.allCases) { page in
                        Text(page.title).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
            }
            Section("Contents") {
                ForEach(document.sections, id: \.id) { section in
                    Text(section.title)
                        .font(.callout)
                        .tag(section.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Document

    private func body(of document: HelpDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                        view(for: block)
                            .id(HelpDocument.anchor(index))
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .onChange(of: selectedSection) { _, section in
                guard let section else { return }
                withAnimation { proxy.scrollTo(section, anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private func view(for block: HelpDocument.Block) -> some View {
        switch block {
        case .heading(let level, let text, _):
            Text(text)
                .font(level == 1 ? .largeTitle.weight(.semibold) : level == 2 ? .title2.weight(.semibold) : .headline)
                .padding(.top, level == 1 ? 0 : 10)

        case .paragraph(let text):
            Text(text)
                .fixedSize(horizontal: false, vertical: true)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(item)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 2)

        case .code(let text):
            HStack {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))

        case .image(let source, let width):
            // The one image the guide uses is the app icon, which is already in the
            // bundle as .icns — so use the running app's icon rather than shipping
            // a second copy of the same artwork.
            if let image = imageNamed(source) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width ?? 128, height: width ?? 128)
                    .padding(.vertical, 2)
            }

        case .table(let header, let rows):
            VStack(alignment: .leading, spacing: 0) {
                tableRow(header, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    Divider()
                    tableRow(row, isHeader: false)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }

    private func tableRow(_ cells: [AttributedString], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(cell)
                    .font(isHeader ? .callout.weight(.semibold) : .callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if index < cells.count - 1 {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHeader ? Color.secondary.opacity(0.12) : Color.clear)
    }

    private func imageNamed(_ source: String) -> NSImage? {
        let name = (source as NSString).lastPathComponent
        if name.hasPrefix("AppIcon") { return NSApp.applicationIconImage }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if let url = Bundle.main.url(forResource: base, withExtension: ext.isEmpty ? nil : ext) {
            return NSImage(contentsOf: url)
        }
        return nil
    }

    private func load() {
        for page in Page.allCases {
            guard let url = Bundle.main.url(forResource: page.resource, withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            documents[page] = HelpDocument.parse(text)
        }
        loadFailed = documents[.guide] == nil
    }
}
