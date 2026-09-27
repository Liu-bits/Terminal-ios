// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// `ed` - the standard line editor, which is exactly the shape this channel
/// supports: it reads commands as lines and answers with text.
///
/// Supported: `a`, `i`, `c`, `d`, `p`, `n`, `=`, `w`, `q`, `Q`, `h`, `s/old/new/`
/// with addresses (`N`, `.`, `$`, `N,M`). Not supported: `r`/`e` on other files,
/// `g`/`v` global commands, marks and the `u` undo - ed's answers here say so
/// instead of pretending.
///
/// Without a terminal it does what `ed` does on a pipe: it takes the commands
/// from standard input, so `printf '1,$p\nq\n' | ed notes.txt` works.
enum EdBuiltin {

    static let all: [ShellBuiltin] = [
        ShellBuiltin("ed", "the line editor: a/i/c/d/p/n/w/q with addresses") { args, context in
            run(args, context)
        }
    ]

    private static func run(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, valueFlags: ["p"])
        let fileName = parsed.operands.first

        var initial: [String] = []
        if let fileName, let text = context.readText(fileName) {
            initial = shellEdLines(text)
        }

        let session = EdSession(
            fileName: fileName,
            lines: initial,
            readFile: { path in context.readText(path).map(shellEdLines) },
            writeFile: { path, body in context.writeText(body, to: path, append: false) }
        )

        guard context.interactive else {
            // No screen: treat standard input as the command stream.
            let script = (context.stdin ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            var output: [String] = []
            for command in script {
                switch session.handle(line: String(command)) {
                case .append(let text), .finished(let text, _):
                    if !text.isEmpty {
                        output.append(text)
                    }
                case .frame(let text):
                    output.append(text)
                }
                if session.isFinished {
                    break
                }
            }
            return .ok(output.joined(separator: "\n"))
        }

        return ShellResult(
            output: session.initialFrame,
            exitCode: 0,
            clearScreen: false,
            session: session
        )
    }

    /// Splits file text into ed's line buffer: a single trailing newline does not
    /// create an empty last line.
    static func shellEdLines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}

/// The editor's state machine.
final class EdSession: InteractiveSession {

    private var lines: [String]
    private var fileName: String?
    private var modified = false
    /// 1-based current line; 0 means "before the first line", like ed's `.` on an
    /// empty buffer.
    private var current = 0

    private enum InsertMode {
        /// `a`: lines go after `current`.
        case append
        /// `i`: lines go before `current` (or at the top when empty).
        case insert
        /// `c`: the addressed range is replaced.
        case change(range: ClosedRange<Int>)
    }
    private var inserting: InsertMode?
    private var pendingInsert: [String] = []

    private(set) var isFinished = false

    private let readFile: (String) -> [String]?
    private let writeFile: (String, String) -> Bool

    init(
        fileName: String?,
        lines: [String],
        readFile: @escaping (String) -> [String]?,
        writeFile: @escaping (String, String) -> Bool
    ) {
        self.fileName = fileName
        self.lines = lines
        self.readFile = readFile
        self.writeFile = writeFile
        // ed puts `.` on the last line after opening a file.
        self.current = lines.count
    }

    var inputMode: InteractiveInputMode { .line }

    var initialFrame: String {
        guard let fileName else {
            return "ed: a line editor. `h` for help, `q` to quit.\n"
        }
        return "\(fileName): \(lines.count) line(s). `h` for help, `q` to quit.\n"
    }

    // MARK: - Input

    func handle(line: String) -> InteractiveStep {
        if let inserting {
            return handleInsertLine(line, mode: inserting)
        }
        return run(command: line)
    }

    func handle(key: String) -> InteractiveStep {
        // Esc and Ctrl-C abandon the buffer, the same as a program that has no
        // "stop" key would have to be killed. Say what happened.
        guard InteractiveKey.isQuit(key) else {
            return .append("")
        }
        isFinished = true
        let note = modified ? "ed: buffer not saved (use `w` next time)\n" : ""
        return .finished(note, 0)
    }

    private func handleInsertLine(_ line: String, mode: InsertMode) -> InteractiveStep {
        if line == "." {
            inserting = nil
            let inserted = pendingInsert
            pendingInsert = []
            switch mode {
            case .append:
                let at = min(lines.count, current)
                lines.insert(contentsOf: inserted, at: at)
                current = at + inserted.count
            case .insert:
                let at = max(0, current - 1)
                lines.insert(contentsOf: inserted, at: at)
                current = at + inserted.count
            case .change(let range):
                let lower = max(1, range.lowerBound)
                let upper = min(lines.count, range.upperBound)
                guard lower <= upper else {
                    lines.insert(contentsOf: inserted, at: max(0, lower - 1))
                    break
                }
                lines.replaceSubrange((lower - 1)...(upper - 1), with: inserted)
                current = inserted.isEmpty ? max(1, lower) : lower + inserted.count - 1
            }
            if !inserted.isEmpty {
                modified = true
            }
            return .append("")
        }
        pendingInsert.append(line)
        return .append("")
    }

    // MARK: - Commands

    private func run(command: String) -> InteractiveStep {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            // A bare newline moves to the next line, exactly like ed.
            current = min(lines.count, current + 1)
            return .append("")
        }
        if let substitution = parseSubstitute(text) {
            return substitute(substitution.pattern, substitution.replacement, range: substitution.address, global: substitution.global)
        }
        let (address, rest) = parseAddress(text)
        guard let letter = rest.first else {
            return .append("? (no command)\n")
        }
        let target = resolved(address)

        switch letter {
        case "a":
            inserting = .append
            current = target.upperBound
            return .append("")
        case "i":
            inserting = .insert
            current = target.lowerBound
            return .append("")
        case "c":
            inserting = .change(range: target)
            return .append("")
        case "d":
            guard target.lowerBound >= 1, target.upperBound <= lines.count else {
                return .append("? (no such line)\n")
            }
            lines.removeSubrange((target.lowerBound - 1)...(target.upperBound - 1))
            modified = true
            current = min(lines.count, target.lowerBound)
            return .append("")
        case "p":
            return .append(printBuffer(target, numbered: false))
        case "n":
            return .append(printBuffer(target, numbered: true))
        case "=":
            return .append("\(target.upperBound)\n")
        case "w":
            return write(path: String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
        case "h":
            return .append(Self.help)
        case "q":
            guard !modified else {
                return .append("? (buffer modified; `w` to save or `Q` to discard)\n")
            }
            isFinished = true
            return .finished("", 0)
        case "Q":
            isFinished = true
            return .finished("", 0)
        case "u":
            return .append("? (undo is not implemented)\n")
        default:
            return .append("? (unknown command '\(letter)'; try h)\n")
        }
    }

    private func printBuffer(_ range: ClosedRange<Int>, numbered: Bool) -> String {
        guard !lines.isEmpty else {
            return ""
        }
        let lower = max(1, range.lowerBound)
        let upper = min(lines.count, range.upperBound)
        guard lower <= upper else {
            return "? (no such line)\n"
        }
        var output = ""
        for number in lower...upper {
            output += numbered ? "\(number)\t\(lines[number - 1])\n" : lines[number - 1] + "\n"
        }
        return output
    }

    private func write(path: String) -> InteractiveStep {
        let target = path.isEmpty ? fileName : path
        guard let target else {
            return .append("? (no file name; use `w name`)\n")
        }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        guard writeFile(target, body) else {
            return .append("\(target): cannot write\n")
        }
        fileName = target
        modified = false
        return .append("\(body.utf8.count) bytes written to \(target)\n")
    }

    private func substitute(
        _ pattern: String,
        _ replacement: String,
        range: Address,
        global: Bool
    ) -> InteractiveStep {
        let target = resolved(range)
        guard target.lowerBound >= 1, target.upperBound <= lines.count else {
            return .append("? (no such line)\n")
        }
        var changed = 0
        for number in target.lowerBound...target.upperBound {
            let (updated, didChange) = SedProgram.substitute(
                lines[number - 1],
                pattern: pattern,
                replacement: replacement,
                global: global,
                caseInsensitive: false,
                occurrence: 1
            )
            if didChange {
                lines[number - 1] = updated
                changed += 1
            }
        }
        if changed > 0 {
            modified = true
        }
        current = target.upperBound
        return .append(changed == 0 ? "? (no match)\n" : "")
    }

    // MARK: - Addressing

    /// `[addr][,addr]` at the start of a command line.
    private struct Address {
        var lower: Int?
        var upper: Int?

        /// The line range a command applies to.
        ///
        /// One address means **one line**, not "from here to the current line":
        /// `2p` prints line 2, and getting that wrong made `1d` delete the whole
        /// buffer.
        func resolved(lineCount: Int, current: Int) -> ClosedRange<Int> {
            switch (lower, upper) {
            case (nil, nil):
                return current...current
            case (let low?, nil):
                let value = resolve(low, lineCount: lineCount, current: current)
                return value...value
            case (nil, let high?):
                let value = resolve(high, lineCount: lineCount, current: current)
                return value...value
            case (let low?, let high?):
                let first = resolve(low, lineCount: lineCount, current: current)
                let second = resolve(high, lineCount: lineCount, current: current)
                return min(first, second)...max(first, second)
            }
        }

        private func resolve(_ value: Int?, lineCount: Int, current: Int) -> Int {
            guard let value else {
                return current
            }
            return value
        }
    }

    /// The special addresses as numbers.
    private func parseAddress(_ text: String) -> (Address, Substring) {
        var rest = Substring(text)
        var address = Address()
        var seen = false

        func readOne() -> Int? {
            guard let first = rest.first else {
                return nil
            }
            if first == "$" {
                rest = rest.dropFirst()
                return lines.count
            }
            if first == "." {
                rest = rest.dropFirst()
                return current
            }
            if first == "+" {
                rest = rest.dropFirst()
                return current + 1
            }
            if first == "-" {
                rest = rest.dropFirst()
                return current - 1
            }
            var digits = ""
            while let character = rest.first, character.isNumber {
                digits.append(character)
                rest = rest.dropFirst()
            }
            return Int(digits)
        }

        if let value = readOne() {
            address.lower = value
            seen = true
        }
        if rest.first == "," {
            rest = rest.dropFirst()
            // `,` alone means 1,$
            if rest.first == "p" || rest.first == "n" || rest.first == "d" || rest.first == "c" {
                address.lower = 1
                address.upper = lines.count
                return (address, rest)
            }
            if let value = readOne() {
                address.upper = value
                seen = true
            } else {
                address.upper = lines.count
            }
        }
        _ = seen
        return (address, rest)
    }

    /// `[addr]s/old/new/[g]`
    private func parseSubstitute(_ text: String) -> (address: Address, pattern: String, replacement: String, global: Bool)? {
        let (address, rest) = parseAddress(text)
        guard rest.first == "s" else {
            return nil
        }
        let body = Substring(rest.dropFirst())
        guard let delimiter = body.first else {
            return nil
        }
        var fields: [String] = []
        var current = ""
        var escaped = false
        for character in body.dropFirst() {
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
        guard fields.count >= 2 else {
            return nil
        }
        let flags = fields.count > 2 ? fields[2] : ""
        return (address, fields[0], fields[1], flags.contains("g"))
    }

    private func resolved(_ address: Address) -> ClosedRange<Int> {
        // An empty buffer has no lines; keep the range inside 0...0 so callers
        // can test for validity instead of trapping.
        guard !lines.isEmpty else {
            return 0...0
        }
        return address.resolved(lineCount: lines.count, current: current)
    }

    static let help = """
    ed commands:
      a, i, c      append / insert / change (end the text with a line containing .)
      d            delete lines
      p, n         print lines (n numbers them)
      =            print the line number
      s/old/new/g  substitute on the addressed lines
      w [file]     write the buffer
      q, Q         quit (q refuses when the buffer is modified)
    addresses:  N  .  $  N,M  ,  (+/- for one line on)
    """
}
