// Copyright © 2026 Liu-bits. All rights reserved.

/// A single lexical token of a shell command line.
enum ShellToken: Equatable {
    case word(String)
    case pipe
    case redirectOut(append: Bool)
    case redirectIn
    case and
    case or
    case sequence
}

/// Splits a command line into tokens.
///
/// Handles single quotes, double quotes (with `\`, `$` escapes), backslash
/// escapes, and the `|`, `>`, `>>`, `<`, `&&`, `||`, `;` operators. Returns
/// `nil` when quotes are left unterminated.
enum ShellTokenizer {

    static func tokenize(_ line: String) -> [ShellToken]? {
        var tokens: [ShellToken] = []
        var current = ""
        var hasCurrent = false
        let chars = Array(line)
        var index = chars.startIndex

        func flush() {
            if hasCurrent {
                tokens.append(.word(current))
                current = ""
                hasCurrent = false
            }
        }

        while index < chars.endIndex {
            let char = chars[index]
            switch char {
            case " ", "\t":
                flush()
                index = chars.index(after: index)
            case "|":
                flush()
                let next = chars.index(after: index)
                if next < chars.endIndex, chars[next] == "|" {
                    tokens.append(.or)
                    index = chars.index(after: next)
                } else {
                    tokens.append(.pipe)
                    index = next
                }
            case ">":
                flush()
                let next = chars.index(after: index)
                if next < chars.endIndex, chars[next] == ">" {
                    tokens.append(.redirectOut(append: true))
                    index = chars.index(after: next)
                } else {
                    tokens.append(.redirectOut(append: false))
                    index = next
                }
            case "<":
                flush()
                tokens.append(.redirectIn)
                index = chars.index(after: index)
            case "&":
                flush()
                let next = chars.index(after: index)
                if next < chars.endIndex, chars[next] == "&" {
                    tokens.append(.and)
                    index = chars.index(after: next)
                } else {
                    // Background execution is not supported: treat as literal.
                    current.append(char)
                    hasCurrent = true
                    index = next
                }
            case ";":
                flush()
                tokens.append(.sequence)
                index = chars.index(after: index)
            case "'":
                // The quotes are kept in the word: `ShellEnvironment.expand`
                // needs to see them to know which characters must not be
                // expanded, and the engine strips them on the way out.
                current.append(char)
                index = chars.index(after: index)
                var closedQuote = false
                while index < chars.endIndex {
                    if chars[index] == "'" {
                        closedQuote = true
                        current.append(chars[index])
                        index = chars.index(after: index)
                        break
                    }
                    current.append(chars[index])
                    index = chars.index(after: index)
                }
                if closedQuote == false {
                    return nil
                }
                hasCurrent = true
            case "\"":
                index = chars.index(after: index)
                var closedDQuote = false
                while index < chars.endIndex {
                    let quoted = chars[index]
                    if quoted == "\"" {
                        closedDQuote = true
                        index = chars.index(after: index)
                        break
                    }
                    if quoted == "\\" {
                        let escaped = chars.index(after: index)
                        if escaped < chars.endIndex {
                            current.append(chars[escaped])
                            index = chars.index(after: escaped)
                            continue
                        }
                    }
                    current.append(quoted)
                    index = chars.index(after: index)
                }
                if closedDQuote == false {
                    return nil
                }
                hasCurrent = true
            case "\\":
                let next = chars.index(after: index)
                if next < chars.endIndex {
                    current.append(chars[next])
                    hasCurrent = true
                    index = chars.index(after: next)
                } else {
                    index = next
                }
            default:
                current.append(char)
                hasCurrent = true
                index = chars.index(after: index)
            }
        }
        flush()
        return tokens
    }
}
