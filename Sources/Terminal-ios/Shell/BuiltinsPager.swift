// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// `less` and `more`: a pager that takes the screen, scrolls, searches and gives
/// the screen back.
///
/// It uses the alternate screen buffer (`?1049h`/`?1049l`), so the user's
/// scrollback is exactly as it was when the pager quits, and it redraws by
/// homing the cursor (`ESC[H`) plus an erase (`ESC[2J`) - the grid in
/// `Terminal/` does the rest, which is why no drawing code lives in the UI.
enum PagerBuiltins {

    static let all: [ShellBuiltin] = [
        ShellBuiltin("less", "page through a file or stdin") { args, context in
            run(args, context, name: "less")
        },
        ShellBuiltin("more", "page through a file or stdin") { args, context in
            run(args, context, name: "more")
        }
    ]

    private static func run(_ args: [String], _ context: ShellRunContext, name: String) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let files = parsed.operands
        let input = context.inputText(named: files, command: name)
        if let failure = input.failure {
            return failure
        }
        let text = input.text ?? ""
        let lines = text.isEmpty ? [] : context.lines(text)

        let title = files.first ?? "(stdin)"
        let session = PagerSession(
            title: title,
            lines: lines,
            rows: context.terminalRows,
            columns: context.terminalColumns,
            style: name == "more" ? .more : .less
        )

        // Without a screen to draw on (`less x | cat`, a script, the tests) the
        // honest behaviour is what `less` does on a pipe: copy the input.
        guard context.interactive else {
            return .ok(lines.joined(separator: "\n"))
        }
        return ShellResult(
            output: session.initialFrame,
            exitCode: 0,
            clearScreen: false,
            session: session
        )
    }
}

/// The pager's state: which lines are on screen, what is being searched for, and
/// whether a search is being typed.
final class PagerSession: InteractiveSession {

    enum Style {
        /// `less`: a full status line with the percentage and a key hint.
        case less
        /// `more`: the classic `--More--(42%)` prompt, Enter scrolls one line.
        case more
    }

    private let title: String
    private let lines: [String]
    private let rows: Int
    private let columns: Int
    private let style: Style

    /// First visible line.
    private(set) var top = 0
    private var statusMessage = ""
    private var pattern: String?
    private var isTypingSearch = false
    private var searchDraft = ""

    init(
        title: String,
        lines: [String],
        rows: Int,
        columns: Int,
        style: Style = .less
    ) {
        self.title = title
        self.lines = lines
        self.rows = max(4, rows)
        self.columns = max(20, columns)
        self.style = style
    }

    /// Lines of text shown at once: the last row is the status line.
    var pageSize: Int { max(1, rows - 1) }

    private var maxTop: Int { max(0, lines.count - pageSize) }

    var initialFrame: String {
        "\u{1B}[?1049h" + frame()
    }

    // MARK: - Keys

    func handle(key: String) -> InteractiveStep {
        if isTypingSearch {
            return handleSearchKey(key)
        }
        switch key {
        case "q", InteractiveKey.escape, InteractiveKey.interrupt, "Q":
            // Leaving the alternate screen is the whole point: whatever the user
            // had on screen comes back untouched.
            return .finished("\u{1B}[?1049l", 0)
        case " ", InteractiveKey.space, "f", InteractiveKey.pageDown:
            return .frame(goto(top + pageSize))
        case "b", InteractiveKey.pageUp:
            return .frame(goto(top - pageSize))
        case "j", InteractiveKey.down:
            return .frame(goto(top + 1))
        case "k", InteractiveKey.up:
            return .frame(goto(top - 1))
        case "g":
            return .frame(goto(0))
        case "G":
            return .frame(goto(maxTop))
        case "/":
            isTypingSearch = true
            searchDraft = ""
            statusMessage = ""
            return .frame(frame())
        case "n":
            return .frame(repeatSearch())
        case InteractiveKey.enter:
            // `more` walks one line at a time on Enter; `less` treats it as a
            // page turn like every other pager.
            return .frame(goto(top + (style == .more ? 1 : pageSize)))
        default:
            // An unbound key still redraws, so the screen never goes stale.
            return .frame(frame())
        }
    }

    private func handleSearchKey(_ key: String) -> InteractiveStep {
        switch key {
        case InteractiveKey.enter:
            isTypingSearch = false
            let query = searchDraft
            searchDraft = ""
            guard !query.isEmpty else {
                pattern = nil
                return .frame(frame())
            }
            pattern = query
            let found = find(query, from: top + 1)
            if let found {
                statusMessage = ""
                return .frame(goto(found))
            }
            statusMessage = "Pattern not found: \(query)"
            return .frame(frame())
        case InteractiveKey.escape, InteractiveKey.interrupt:
            isTypingSearch = false
            searchDraft = ""
            return .frame(frame())
        case InteractiveKey.backspace:
            if !searchDraft.isEmpty {
                searchDraft.removeLast()
            }
            return .frame(frame())
        default:
            if let character = InteractiveKey.printable(key) {
                searchDraft.append(character)
            }
            return .frame(frame())
        }
    }

    // MARK: - Movement and search

    private func goto(_ position: Int) -> String {
        top = min(maxTop, max(0, position))
        return frame()
    }

    private func repeatSearch() -> String {
        guard let pattern else {
            return frame()
        }
        if let found = find(pattern, from: top + 1) {
            top = min(maxTop, found)
            statusMessage = ""
        } else if let wrapped = find(pattern, from: 0) {
            top = min(maxTop, wrapped)
            statusMessage = "(wrapped)"
        } else {
            statusMessage = "Pattern not found: \(pattern)"
        }
        return frame()
    }

    /// First line at or after `start` containing `pattern`, case-insensitive
    /// like `less -i` (a plain `less` is case-sensitive, but a phone keyboard
    /// makes that a trap rather than a feature).
    private func find(_ pattern: String, from start: Int) -> Int? {
        guard !pattern.isEmpty else {
            return nil
        }
        var index = max(0, start)
        while index < lines.count {
            if lines[index].range(of: pattern, options: [.caseInsensitive]) != nil {
                return index
            }
            index += 1
        }
        return nil
    }

    // MARK: - Drawing

    /// A full frame: home, erase, the visible lines, then the status on the last
    /// row. Redrawing from scratch is what makes the grid's erase semantics do
    /// the work instead of the UI.
    func frame() -> String {
        var text = "\u{1B}[H\u{1B}[2J"
        for offset in 0..<pageSize {
            let index = top + offset
            guard index < lines.count else {
                break
            }
            text += render(line: index) + "\n"
        }
        text += "\u{1B}[\(rows);1H\u{1B}[7m" + status() + "\u{1B}[0m"
        return text
    }

    private func render(line index: Int) -> String {
        let line = lines[index]
        guard let pattern, !pattern.isEmpty else {
            return truncated(line)
        }
        return truncated(highlight(line, pattern: pattern))
    }

    /// Marks every match with reverse video, the way `less` does, and leaves the
    /// text itself untouched so copying a line out still works.
    private func highlight(_ line: String, pattern: String) -> String {
        var result = ""
        var rest = Substring(line)
        while let range = rest.range(of: pattern, options: [.caseInsensitive]) {
            result += rest[rest.startIndex..<range.lowerBound]
            result += "\u{1B}[7m" + rest[range] + "\u{1B}[27m"
            rest = rest[range.upperBound...]
        }
        result += rest
        return result
    }

    private func truncated(_ line: String) -> String {
        // The grid wraps rather than truncates, so a long line simply becomes
        // two rows. That is the honest behaviour for a terminal this size.
        line
    }

    private func status() -> String {
        if isTypingSearch {
            return padded("/" + searchDraft)
        }
        if !statusMessage.isEmpty {
            return padded(statusMessage)
        }
        let first = lines.isEmpty ? 0 : top + 1
        let last = min(lines.count, top + pageSize)
        let percent = lines.isEmpty ? 100 : Int((Double(last) / Double(lines.count)) * 100)
        let counts = "\(title)  \(first)-\(last)/\(lines.count)  \(percent)%"

        // On a narrow screen the key hint is the first thing to lose: the
        // position is what the user actually needs. `more` always shows its
        // prompt, because that is the only thing it has.
        if style == .more {
            let prompt = room(for: counts) >= "--More--".count ? "  --More--" : ""
            return padded(counts + prompt)
        }
        let full = "space:next  b:back  /:search  q:quit"
        let short = "spc/b/j/k/G/q"
        let room = room(for: counts)
        if room >= full.count {
            return padded(counts + "  " + full)
        }
        if room >= short.count {
            return padded(counts + "  " + short)
        }
        return padded(counts)
    }

    /// Columns left on the status row after `text`.
    private func room(for text: String) -> Int {
        columns - 1 - text.count
    }

    private func padded(_ text: String) -> String {
        var visible = ANSIParser.strip(text)
        if visible.count > columns - 1 {
            visible = String(visible.prefix(columns - 1))
        }
        // Pad with spaces so reverse video covers the whole row.
        return visible + String(repeating: " ", count: max(0, columns - visible.count))
    }
}
