// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// A `sed` that does the common work and says what it cannot do.
///
/// Supported: multiple scripts (`-e`, `--expression=`, `;` and newline
/// separated), addresses (line number, `$`, `/regex/`), address ranges
/// (`2,4`, `/a/,/b/`, `3,$`), `!` negation, and the commands
/// `s///flags`, `p`, `d`, `q`, `=`, `y///`, plus `-n` and `-E`/`-r`.
///
/// Deliberately unsupported, and refused with a message rather than silently
/// ignored: `a`/`i`/`c` text, the hold space (`h`/`H`/`g`/`G`/`x`), branching
/// (`b`/`t`/`:`), reading and writing files (`r`/`w`), and `-i` in-place edits.
/// A shell that quietly skips half a script is worse than one that says so.
struct SedProgram {

    /// Where a command applies.
    enum Address: Equatable {
        case none
        /// A single line number, or the lower bound of a range.
        case line(Int)
        case last
        case pattern(String)
    }

    /// One parsed command.
    struct Command {
        var address: Address = .none
        var rangeEnd: Address?
        var negated = false
        var action: Action
    }

    enum Action {
        case substitute(
            pattern: String,
            replacement: String,
            global: Bool,
            caseInsensitive: Bool,
            occurrence: Int,
            printAfter: Bool
        )
        case print
        case delete
        case quit
        case number
        case transform(from: String, to: String)
    }

    /// Parsed commands, in script order.
    private(set) var commands: [Command] = []
    /// `-n`: only explicit `p` output is printed.
    private(set) var quiet = false
    /// `-E` / `-r`: treat the pattern as an extended regex.
    private(set) var extended = false
    /// A message describing what could not be parsed, if anything.
    private(set) var failure: String?

    // MARK: - Parsing

    /// Builds a program from the `-e` scripts plus the leading operand.
    ///
    /// A parse failure stops at the first bad command and is reported through
    /// `failure`, so the caller can print it instead of running half a script.
    static func parse(scripts: [String], quiet: Bool, extended: Bool) -> SedProgram {
        var program = SedProgram()
        program.quiet = quiet
        program.extended = extended

        for script in scripts {
            for text in split(script) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    continue
                }
                guard let command = parseCommand(trimmed, extended: extended) else {
                    program.failure = "sed: invalid command: \(trimmed)"
                    return program
                }
                program.commands.append(command)
            }
        }
        if program.commands.isEmpty {
            program.failure = "sed: no script"
        }
        return program
    }

    /// Splits a script into commands on `;` and newlines, ignoring separators
    /// inside a regex address or an `s`/`y` body (`s/a;b/c/` is one command).
    static func split(_ script: String) -> [String] {
        var commands: [String] = []
        var current = ""
        var index = script.startIndex

        enum State {
            case normal
            case regex
            case body(Character)
        }
        var state = State.normal
        var bodyDelimiters = 0

        func advance(_ position: String.Index) -> String.Index {
            script.index(after: position)
        }

        while index < script.endIndex {
            let character = script[index]
            switch state {
            case .normal:
                if character == "\\" {
                    current.append(character)
                    let next = advance(index)
                    if next < script.endIndex {
                        current.append(script[next])
                        index = advance(next)
                        continue
                    }
                    index = next
                    continue
                }
                if character == "/" {
                    current.append(character)
                    state = .regex
                    index = advance(index)
                    continue
                }
                if (character == "s" || character == "y"), isCommandPosition(current) {
                    current.append(character)
                    let delimiterIndex = advance(index)
                    guard delimiterIndex < script.endIndex else {
                        index = delimiterIndex
                        continue
                    }
                    let delimiter = script[delimiterIndex]
                    current.append(delimiter)
                    state = .body(delimiter)
                    bodyDelimiters = 0
                    index = advance(delimiterIndex)
                    continue
                }
                if character == ";" || character == "\n" {
                    commands.append(current)
                    current = ""
                    index = advance(index)
                    continue
                }
                current.append(character)
                index = advance(index)
            case .regex:
                if character == "\\" {
                    current.append(character)
                    let next = advance(index)
                    if next < script.endIndex {
                        current.append(script[next])
                        index = advance(next)
                        continue
                    }
                    index = next
                    continue
                }
                current.append(character)
                if character == "/" {
                    state = .normal
                }
                index = advance(index)
            case .body(let delimiter):
                if character == "\\" {
                    current.append(character)
                    let next = advance(index)
                    if next < script.endIndex {
                        current.append(script[next])
                        index = advance(next)
                        continue
                    }
                    index = next
                    continue
                }
                current.append(character)
                if character == delimiter {
                    bodyDelimiters += 1
                    if bodyDelimiters == 2 {
                        state = .normal
                        bodyDelimiters = 0
                    }
                }
                index = advance(index)
            }
        }
        commands.append(current)
        return commands
    }

    /// True when everything in `buffer` is address syntax, so the next `s`/`y`
    /// really is a command letter and not a character inside a regex.
    private static func isCommandPosition(_ buffer: String) -> Bool {
        buffer.allSatisfy { "0123456789$,! \t".contains($0) }
    }

    private static func parseCommand(_ text: String, extended: Bool) -> Command? {
        var rest = Substring(text)
        var address: Address = .none
        var rangeEnd: Address?

        if let (parsed, remainder) = parseAddress(rest, extended: extended) {
            address = parsed
            rest = remainder
            if rest.first == "," {
                rest = rest.dropFirst()
                if let (end, remainder2) = parseAddress(rest, extended: extended) {
                    rangeEnd = end
                    rest = remainder2
                } else {
                    return nil
                }
            }
        }

        var negated = false
        if rest.first == "!" {
            negated = true
            rest = rest.dropFirst()
        }
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard let letter = rest.first else {
            return nil
        }
        rest = rest.dropFirst()

        switch letter {
        case "s":
            guard let (pattern, replacement, flags) = parseSubstitution(rest, extended: extended) else {
                return nil
            }
            var global = false
            var caseInsensitive = false
            var occurrence = 1
            var printAfter = false
            for flag in flags {
                switch flag {
                case "g":
                    global = true
                case "p":
                    printAfter = true
                case "I", "i":
                    caseInsensitive = true
                case "0"..."9":
                    occurrence = Int(String(flag)) ?? occurrence
                default:
                    // `m`, `M`, `w` and friends are not implemented; a wrong
                    // flag is better refused than misread.
                    return nil
                }
            }
            return Command(
                address: address,
                rangeEnd: rangeEnd,
                negated: negated,
                action: .substitute(
                    pattern: pattern,
                    replacement: replacement,
                    global: global,
                    caseInsensitive: caseInsensitive,
                    occurrence: occurrence,
                    printAfter: printAfter
                )
            )
        case "y":
            guard let (from, to) = parseTransform(rest) else {
                return nil
            }
            return Command(address: address, rangeEnd: rangeEnd, negated: negated, action: .transform(from: from, to: to))
        case "p":
            return Command(address: address, rangeEnd: rangeEnd, negated: negated, action: .print)
        case "d":
            return Command(address: address, rangeEnd: rangeEnd, negated: negated, action: .delete)
        case "q":
            return Command(address: address, rangeEnd: rangeEnd, negated: negated, action: .quit)
        case "=":
            return Command(address: address, rangeEnd: rangeEnd, negated: negated, action: .number)
        default:
            return nil
        }
    }

    private static func parseAddress(_ text: Substring, extended: Bool) -> (Address, Substring)? {
        guard let first = text.first else {
            return nil
        }
        if first.isNumber {
            var digits = ""
            var rest = text
            while let character = rest.first, character.isNumber {
                digits.append(character)
                rest = rest.dropFirst()
            }
            guard let value = Int(digits) else {
                return nil
            }
            return (.line(value), rest)
        }
        if first == "$" {
            return (.last, text.dropFirst())
        }
        if first == "/" {
            var pattern = ""
            var rest = text.dropFirst()
            var escaped = false
            while let character = rest.first {
                rest = rest.dropFirst()
                if escaped {
                    pattern.append(character)
                    escaped = false
                    continue
                }
                if character == "\\" {
                    pattern.append(character)
                    escaped = true
                    continue
                }
                if character == "/" {
                    return (.pattern(pattern), rest)
                }
                pattern.append(character)
            }
            return nil
        }
        _ = extended
        return nil
    }

    /// `s<delim>pattern<delim>replacement<delim>flags`
    private static func parseSubstitution(
        _ text: Substring,
        extended: Bool
    ) -> (pattern: String, replacement: String, flags: String)? {
        guard let delimiter = text.first else {
            return nil
        }
        let fields = splitFields(text.dropFirst(), delimiter: delimiter)
        guard fields.count >= 2 else {
            return nil
        }
        let pattern = extended ? fields[0] : breToExtended(fields[0])
        return (pattern, fields[1], fields.count > 2 ? fields[2] : "")
    }

    /// `y<delim>from<delim>to<delim>`
    private static func parseTransform(_ text: Substring) -> (String, String)? {
        guard let delimiter = text.first else {
            return nil
        }
        let fields = splitFields(text.dropFirst(), delimiter: delimiter)
        guard fields.count >= 2, fields[0].count == fields[1].count else {
            return nil
        }
        return (unescape(fields[0], delimiter: delimiter), unescape(fields[1], delimiter: delimiter))
    }

    /// Splits on an unescaped delimiter; `\` escapes the next character.
    private static func splitFields(_ text: Substring, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == delimiter {
                fields.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        fields.append(current)
        return fields
    }

    /// Removes the escaping used in the fields above.
    private static func unescape(_ text: String, delimiter: Character) -> String {
        var result = ""
        var iterator = Array(text)
        var index = 0
        while index < iterator.count {
            let character = iterator[index]
            index += 1
            if character == "\\", index < iterator.count {
                let next = iterator[index]
                index += 1
                if next == delimiter || next == "\\" {
                    result.append(next)
                } else {
                    result.append("\\")
                    result.append(next)
                }
                continue
            }
            result.append(character)
        }
        return result
    }

    /// Translates a basic regular expression into the extended dialect
    /// `NSRegularExpression` speaks.
    ///
    /// In BRE, `( ) { } + ? |` are ordinary characters and only become special
    /// with a backslash; the engine wants the opposite. Getting this backwards
    /// is how `s/a|b/x/` silently replaces nothing.
    static func breToExtended(_ pattern: String) -> String {
        var result = ""
        var characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "\\" {
                guard index < characters.count else {
                    result.append("\\\\")
                    break
                }
                let next = characters[index]
                index += 1
                if "()|+?{}".contains(next) {
                    result.append(next)
                } else {
                    result.append("\\")
                    result.append(next)
                }
                continue
            }
            if "()|?".contains(character) {
                result.append("\\")
                result.append(character)
                continue
            }
            if character == "{" || character == "}" {
                result.append("\\")
                result.append(character)
                continue
            }
            result.append(character)
        }
        return result
    }

    // MARK: - Execution

    /// Runs the program over `lines`.
    func run(_ lines: [String]) -> [String] {
        var output: [String] = []
        var rangeActive = [Bool](repeating: false, count: commands.count)

        lineLoop: for (index, rawLine) in lines.enumerated() {
            var current = rawLine
            var autoPrint = true
            let lineNumber = index + 1
            let isLast = index == lines.count - 1

            for (position, command) in commands.enumerated() {
                guard applies(
                    command,
                    line: current,
                    number: lineNumber,
                    isLast: isLast,
                    active: &rangeActive[position]
                ) else {
                    continue
                }
                switch command.action {
                case .substitute(let pattern, let replacement, let global, let insensitive, let occurrence, let printAfter):
                    let (updated, didChange) = Self.substitute(
                        current,
                        pattern: pattern,
                        replacement: replacement,
                        global: global,
                        caseInsensitive: insensitive,
                        occurrence: occurrence
                    )
                    current = updated
                    if printAfter, didChange {
                        output.append(current)
                    }
                case .print:
                    output.append(current)
                case .delete:
                    autoPrint = false
                    continue lineLoop
                case .quit:
                    if !quiet {
                        output.append(current)
                    }
                    return output
                case .number:
                    output.append("\(lineNumber)")
                case .transform(let from, let to):
                    current = Self.transform(current, from: from, to: to)
                }
            }
            if autoPrint, !quiet {
                output.append(current)
            }
        }
        return output
    }

    private func applies(
        _ command: Command,
        line: String,
        number: Int,
        isLast: Bool,
        active: inout Bool
    ) -> Bool {
        let start = Self.matches(command.address, line: line, number: number, isLast: isLast)
        guard let end = command.rangeEnd else {
            return command.negated ? !start : start
        }
        if active {
            // Inside the range the command applies until the end address hits.
            let reachedEnd: Bool
            switch end {
            case .none:
                reachedEnd = false
            case .line(let value):
                reachedEnd = number >= value
            case .last:
                reachedEnd = isLast
            case .pattern(let pattern):
                reachedEnd = Self.firstMatch(pattern, in: line) != nil
            }
            if reachedEnd {
                active = false
            }
            return true
        }
        let started = command.negated ? !start : start
        if started {
            active = true
        }
        return started
    }

    private static func matches(_ address: Address, line: String, number: Int, isLast: Bool) -> Bool {
        switch address {
        case .none:
            return true
        case .line(let value):
            return number == value
        case .last:
            return isLast
        case .pattern(let pattern):
            return firstMatch(pattern, in: line) != nil
        }
    }

    private static func expression(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        var options: NSRegularExpression.Options = []
        if caseInsensitive {
            options.insert(.caseInsensitive)
        }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Range<String.Index>? {
        guard let expression = expression(pattern, caseInsensitive: false) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        return Range(match.range, in: text)
    }

    /// Applies one `s///`, reporting whether anything changed.
    static func substitute(
        _ text: String,
        pattern: String,
        replacement: String,
        global: Bool,
        caseInsensitive: Bool,
        occurrence: Int
    ) -> (String, Bool) {
        guard let expression = expression(pattern, caseInsensitive: caseInsensitive) else {
            return (text, false)
        }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else {
            return (text, false)
        }
        let selected: [NSTextCheckingResult]
        if global {
            selected = occurrence > 1
                ? matches.enumerated().filter { ($0.offset + 1) % occurrence == 0 }.map(\.element)
                : matches
        } else {
            let wanted = max(1, occurrence)
            guard wanted <= matches.count else {
                return (text, false)
            }
            selected = [matches[wanted - 1]]
        }

        var result = ""
        var cursor = text.startIndex
        for match in selected {
            guard let range = Range(match.range, in: text) else {
                continue
            }
            result += text[cursor..<range.lowerBound]
            result += Self.expand(replacement, match: match, in: text)
            cursor = range.upperBound
        }
        result += text[cursor...]
        return (result, true)
    }

    /// Expands `&`, `\1`..`\9` and `\&` in a replacement, keeping the rest
    /// literal (a bare `$` must not become a template reference).
    private static func expand(_ replacement: String, match: NSTextCheckingResult, in text: String) -> String {
        var result = ""
        var characters = Array(replacement)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "&" {
                if let range = Range(match.range, in: text) {
                    result += text[range]
                }
                continue
            }
            if character == "\\", index < characters.count {
                let next = characters[index]
                index += 1
                if next.isNumber, let group = Int(String(next)), group < match.numberOfRanges {
                    if let range = Range(match.range(at: group), in: text) {
                        result += text[range]
                    }
                } else if next == "&" {
                    result.append("&")
                } else if next == "\\" {
                    result.append("\\")
                } else if next == "t" {
                    result.append("\t")
                } else if next == "n" {
                    result.append("\n")
                } else {
                    result.append(next)
                }
                continue
            }
            result.append(character)
        }
        return result
    }

    /// `y/abc/xyz/`: character-by-character replacement.
    static func transform(_ text: String, from: String, to: String) -> String {
        let source = Array(from)
        let target = Array(to)
        var map: [Character: Character] = [:]
        for (index, character) in source.enumerated() where index < target.count {
            map[character] = target[index]
        }
        return String(text.map { map[$0] ?? $0 })
    }
}
