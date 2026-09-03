import Foundation
import SwiftUI

/// A parsed Markdown document, limited to the constructs the guide actually uses.
///
/// The app's guide is `README.md`, bundled as a resource and rendered here, so
/// there's one source of truth rather than a copy in the repo and another copy in
/// the app that quietly drift apart.
struct HelpDocument {
    enum Block: Identifiable {
        case heading(level: Int, text: AttributedString, plain: String)
        case paragraph(AttributedString)
        case bullets([AttributedString])
        case code(String)
        case table(header: [AttributedString], rows: [[AttributedString]])
        case image(source: String, width: Double?)

        var id: String {
            switch self {
            case .heading(let level, _, let plain): return "h\(level):\(plain)"
            case .paragraph(let text): return "p:\(text.description.prefix(60))"
            case .bullets(let items): return "l:\(items.first?.description.prefix(40) ?? "")\(items.count)"
            case .code(let text): return "c:\(text.prefix(40))"
            case .table(let header, let rows): return "t:\(header.map(\.description).joined())\(rows.count)"
            case .image(let source, _): return "i:\(source)"
            }
        }
    }

    var blocks: [Block] = []

    /// A stable anchor for a block, used by the contents list to scroll to it.
    ///
    /// Keyed on position rather than on the block's text: two paragraphs sharing
    /// an opening line would otherwise collide, and a duplicate id inside a
    /// `ForEach` makes scrolling land in the wrong place with no error.
    static func anchor(_ index: Int) -> String { "block-\(index)" }

    /// Level-2 headings, for the contents list.
    var sections: [(id: String, title: String)] {
        blocks.enumerated().compactMap { index, block in
            if case .heading(let level, _, let plain) = block, level == 2 {
                return (id: HelpDocument.anchor(index), title: plain)
            }
            return nil
        }
    }

    // MARK: - Parsing

    static func parse(_ markdown: String) -> HelpDocument {
        var document = HelpDocument()
        let lines = markdown.components(separatedBy: .newlines)
        var index = 0

        func isTableRow(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Images, written either as Markdown or as an <img> tag.
            if let image = parseImage(trimmed) {
                document.blocks.append(image)
                index += 1
                continue
            }

            // A lone HTML tag is layout for GitHub's renderer; it shouldn't appear
            // as literal text in the app's Help window.
            if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), !trimmed.contains(" `") {
                index += 1
                continue
            }

            // Fenced code
            if trimmed.hasPrefix("```") {
                index += 1
                var body: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                index += 1 // closing fence
                document.blocks.append(.code(body.joined(separator: "\n")))
                continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let text = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                document.blocks.append(.heading(level: hashes, text: inline(text), plain: text))
                index += 1
                continue
            }

            // Table: a header row, a separator row, then body rows.
            if isTableRow(trimmed), index + 1 < lines.count,
               lines[index + 1].contains("---"), isTableRow(lines[index + 1]) {
                let header = cells(in: trimmed)
                index += 2
                var rows: [[AttributedString]] = []
                while index < lines.count, isTableRow(lines[index]) {
                    rows.append(cells(in: lines[index]))
                    index += 1
                }
                document.blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Bullet list
            if trimmed.hasPrefix("- ") {
                var items: [AttributedString] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix("- ") {
                        var text = String(candidate.dropFirst(2))
                        // Continuation lines are indented under the bullet.
                        while index + 1 < lines.count,
                              lines[index + 1].hasPrefix("  "),
                              !lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("- "),
                              !lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty {
                            index += 1
                            text += " " + lines[index].trimmingCharacters(in: .whitespaces)
                        }
                        items.append(inline(text))
                        index += 1
                    } else {
                        break
                    }
                }
                document.blocks.append(.bullets(items))
                continue
            }

            // Paragraph: run of non-blank lines, rewrapped.
            var paragraph: [String] = []
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty || candidate.hasPrefix("#") || candidate.hasPrefix("- ")
                    || candidate.hasPrefix("```") || isTableRow(candidate) {
                    break
                }
                paragraph.append(candidate)
                index += 1
            }
            if !paragraph.isEmpty {
                document.blocks.append(.paragraph(inline(paragraph.joined(separator: " "))))
            }
        }

        return document
    }

    /// Handles `![alt](src)` and `<img src="…" width="…">`.
    private static func parseImage(_ line: String) -> Block? {
        if line.hasPrefix("!["), let open = line.firstIndex(of: "("), line.hasSuffix(")") {
            let source = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
            return .image(source: source, width: nil)
        }
        guard line.hasPrefix("<img") else { return nil }
        func attribute(_ name: String) -> String? {
            guard let range = line.range(of: "\(name)=\"") else { return nil }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        guard let source = attribute("src") else { return nil }
        return .image(source: source, width: attribute("width").flatMap(Double.init))
    }

    private static func cells(in row: String) -> [AttributedString] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { inline($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - Inline formatting

    /// Handles `code`, **bold** and *italic*.
    ///
    /// Code spans are matched by backtick-run length, so a span written with four
    /// backticks can itself contain backticks — which the guide relies on to show
    /// a fenced code marker literally.
    static func inline(_ text: String) -> AttributedString {
        var output = AttributedString()
        let characters = Array(text)
        var index = 0
        var plain = ""

        func flushPlain() {
            guard !plain.isEmpty else { return }
            output.append(AttributedString(plain))
            plain = ""
        }

        while index < characters.count {
            let character = characters[index]

            if character == "`" {
                let fenceLength = characters[index...].prefix { $0 == "`" }.count
                let contentStart = index + fenceLength
                if let closing = findRun(of: "`", length: fenceLength, in: characters, from: contentStart) {
                    flushPlain()
                    var code = String(characters[contentStart..<closing])
                    if code.hasPrefix(" ") && code.hasSuffix(" ") && code.count > 1 {
                        code = String(code.dropFirst().dropLast())
                    }
                    var run = AttributedString(code)
                    run.font = .system(.callout, design: .monospaced)
                    run.foregroundColor = .primary
                    output.append(run)
                    index = closing + fenceLength
                    continue
                }
            }

            if character == "[", let close = findCharacter("]", in: characters, from: index + 1),
               close + 1 < characters.count, characters[close + 1] == "(",
               let end = findCharacter(")", in: characters, from: close + 2) {
                flushPlain()
                var run = inline(String(characters[(index + 1)..<close]))
                let destination = String(characters[(close + 2)..<end])
                if let url = URL(string: destination), url.scheme != nil {
                    run.link = url
                    run.foregroundColor = .accentColor
                }
                output.append(run)
                index = end + 1
                continue
            }

            if character == "*" {
                let markerLength = characters[index...].prefix { $0 == "*" }.count
                let width = min(markerLength, 2)
                let contentStart = index + width
                if let closing = findRun(of: "*", length: width, in: characters, from: contentStart) {
                    flushPlain()
                    var run = inline(String(characters[contentStart..<closing]))
                    run.inlinePresentationIntent = width == 2 ? .stronglyEmphasized : .emphasized
                    output.append(run)
                    index = closing + width
                    continue
                }
            }

            plain.append(character)
            index += 1
        }

        flushPlain()
        return output
    }

    private static func findCharacter(_ character: Character, in characters: [Character], from start: Int) -> Int? {
        var index = start
        while index < characters.count {
            if characters[index] == character { return index }
            if characters[index] == "\n" { return nil }
            index += 1
        }
        return nil
    }

    /// Finds the next run of exactly `length` copies of `marker`.
    private static func findRun(
        of marker: Character,
        length: Int,
        in characters: [Character],
        from start: Int
    ) -> Int? {
        var index = start
        while index < characters.count {
            guard characters[index] == marker else {
                index += 1
                continue
            }
            let run = characters[index...].prefix { $0 == marker }.count
            if run == length, index > start { return index }
            index += run
        }
        return nil
    }
}
