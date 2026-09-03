import Foundation

/// Cleans up JSON that people actually paste.
///
/// Setup instructions in the wild are rarely strict JSON: they carry a
/// `// claude_desktop_config.json` header comment, sit inside a markdown code
/// fence, pick up curly quotes from a web page, or trail a comma after the last
/// entry. All of that is unambiguous to a human, so the import box accepts it and
/// tidies it into real JSON rather than making you hunt for the offending
/// character.
///
/// This is used *only* for pasted input. The config file on disk is still parsed
/// strictly, because a stray comment there is a genuine problem worth reporting.
enum JSONLenient {
    struct Cleaned {
        var text: String
        /// Human-readable notes about what was changed, for the UI to show.
        var notes: [String] = []
    }

    static func clean(_ raw: String) -> Cleaned {
        var result = Cleaned(text: raw.trimmingCharacters(in: .whitespacesAndNewlines))

        if let fenced = stripCodeFence(result.text) {
            result.text = fenced
            result.notes.append("removed the code fence")
        }

        let normalized = normalizeCharacters(result.text)
        if normalized != result.text {
            let hadCarriageReturns = result.text.unicodeScalars.contains("\r")
            result.text = normalized
            result.notes.append(hadCarriageReturns ? "normalised line endings" : "straightened curly quotes")
        }

        let pass = stripCommentsAndNormalizeQuotes(result.text)
        result.text = pass.text
        if pass.commentsRemoved > 0 {
            result.notes.append(pass.commentsRemoved == 1 ? "removed a comment" : "removed \(pass.commentsRemoved) comments")
        }
        if pass.quotesConverted > 0 {
            result.notes.append("switched single quotes to double quotes")
        }

        if let object = outermostObject(result.text), object != result.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            result.text = object
            result.notes.append("ignored the text around the JSON")
        }

        let keys = quoteBareKeys(result.text)
        if keys.count > 0 {
            result.text = keys.text
            result.notes.append(keys.count == 1 ? "added quotes around a key" : "added quotes around \(keys.count) keys")
        }

        let commas = stripTrailingCommas(result.text)
        if commas.count > 0 {
            result.text = commas.text
            result.notes.append(commas.count == 1 ? "removed a trailing comma" : "removed \(commas.count) trailing commas")
        }

        result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    // MARK: - Steps

    /// Pulls the body out of a ```json … ``` markdown fence.
    private static func stripCodeFence(_ text: String) -> String? {
        guard let fence = text.range(of: "```") else { return nil }
        let afterTicks = text[fence.upperBound...]
        // Skip the info string ("json", "jsonc", …) up to the end of that line.
        let body: Substring
        if let newline = afterTicks.firstIndex(of: "\n") {
            body = afterTicks[afterTicks.index(after: newline)...]
        } else {
            body = afterTicks
        }
        if let closing = body.range(of: "```") {
            return String(body[..<closing.lowerBound])
        }
        return String(body)
    }

    /// Replaces characters that word processors and web pages substitute in.
    private static func normalizeCharacters(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            switch character {
            // Swift reads "\r\n" as a single Character, so the comment scanner's
            // check for "\n" never matched it and a snippet with Windows line
            // endings was swallowed whole as one comment.
            case "\r\n", "\r": output.append("\n")
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{2033}": output.append("\"")
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{2032}": output.append("'")
            case "\u{00A0}", "\u{202F}", "\u{2007}": output.append(" ")
            case "\u{2028}", "\u{2029}": output.append("\n")
            case "\u{FEFF}": break
            default: output.append(character)
            }
        }
        return output
    }

    /// Removes `//` and `/* */` comments and rewrites single-quoted strings as
    /// double-quoted ones.
    ///
    /// Both jobs share one state machine on purpose. Done separately, a comment
    /// stripper would mangle `'http://example.com'` and a quote converter would
    /// choke on the apostrophe in `// don't do this`.
    private static func stripCommentsAndNormalizeQuotes(
        _ text: String
    ) -> (text: String, commentsRemoved: Int, quotesConverted: Int) {
        enum State {
            case normal
            case doubleString
            case singleString
            case lineComment
            case blockComment
        }

        var output = ""
        output.reserveCapacity(text.count)
        var state = State.normal
        var comments = 0
        var quotes = 0

        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil

            switch state {
            case .normal:
                if character == "\"" {
                    state = .doubleString
                    output.append(character)
                } else if character == "'" {
                    state = .singleString
                    quotes += 1
                    output.append("\"")
                } else if character == "/", next == "/" {
                    state = .lineComment
                    comments += 1
                    index += 1
                } else if character == "/", next == "*" {
                    state = .blockComment
                    comments += 1
                    index += 1
                } else {
                    output.append(character)
                }

            case .doubleString:
                output.append(character)
                if character == "\\", let next {
                    output.append(next)
                    index += 1
                } else if character == "\"" {
                    state = .normal
                }

            case .singleString:
                if character == "\\", let next {
                    // A \' escape has no meaning once the string is double-quoted.
                    if next == "'" {
                        output.append("'")
                    } else {
                        output.append(character)
                        output.append(next)
                    }
                    index += 1
                } else if character == "'" {
                    state = .normal
                    output.append("\"")
                } else if character == "\"" {
                    output.append("\\\"")
                } else {
                    output.append(character)
                }

            case .lineComment:
                if character == "\n" {
                    state = .normal
                    output.append(character)
                }

            case .blockComment:
                if character == "*", next == "/" {
                    state = .normal
                    index += 1
                }
            }
            index += 1
        }

        return (output, comments, quotes)
    }

    /// Returns the outermost `{ … }` region, dropping prose around it.
    private static func outermostObject(_ text: String) -> String? {
        let characters = Array(text)
        guard let start = characters.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<characters.count {
            let character = characters[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(characters[start...index])
                }
            default: break
            }
        }
        return nil
    }

    /// Wraps bare JavaScript-style keys in quotes: `{ command: "x" }`.
    private static func quoteBareKeys(_ text: String) -> (text: String, count: Int) {
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(characters.count)
        var inString = false
        var escaped = false
        var lastSignificant: Character?
        var count = 0
        var index = 0

        func isIdentifierStart(_ character: Character) -> Bool {
            character.isLetter || character == "_" || character == "$"
        }
        func isIdentifierBody(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_" || character == "$" || character == "-"
        }

        while index < characters.count {
            let character = characters[index]

            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                    lastSignificant = character
                }
                index += 1
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index += 1
                continue
            }

            // A bare key can only follow the start of an object or a comma.
            if isIdentifierStart(character), lastSignificant == "{" || lastSignificant == "," {
                var end = index
                while end < characters.count, isIdentifierBody(characters[end]) { end += 1 }
                var lookahead = end
                while lookahead < characters.count, characters[lookahead].isWhitespace { lookahead += 1 }
                let word = String(characters[index..<end])
                if lookahead < characters.count, characters[lookahead] == ":",
                   !["true", "false", "null"].contains(word) {
                    output.append("\"\(word)\"")
                    count += 1
                    lastSignificant = "\""
                    index = end
                    continue
                }
            }

            output.append(character)
            if !character.isWhitespace { lastSignificant = character }
            index += 1
        }

        return (output, count)
    }

    /// Drops the comma in `[1, 2, ]` and `{ "a": 1, }`.
    private static func stripTrailingCommas(_ text: String) -> (text: String, count: Int) {
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(characters.count)
        var inString = false
        var escaped = false
        var count = 0

        for (index, character) in characters.enumerated() {
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                continue
            }
            if character == "," {
                var lookahead = index + 1
                while lookahead < characters.count, characters[lookahead].isWhitespace { lookahead += 1 }
                if lookahead < characters.count, characters[lookahead] == "}" || characters[lookahead] == "]" {
                    count += 1
                    continue
                }
            }
            output.append(character)
        }

        return (output, count)
    }
}
