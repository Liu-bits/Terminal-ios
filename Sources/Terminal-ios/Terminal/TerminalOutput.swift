// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Everything the terminal screen shows: scrollback, the live grid, and the
/// cursor.
///
/// The view controller owns one of these instead of a `[String]`, which is what
/// makes the fancy output work: `\r` progress bars overwrite their own line,
/// `ESC[K` erases to the end of a line, wide (Chinese) characters take two
/// columns, and SGR colour survives into the attributed string the label draws.
struct TerminalOutput {

    private(set) var screen: TerminalScreen

    /// Column budget used when nothing measures the view (tests, `pipe`).
    static let defaultColumns = 200
    static let defaultRows = 400
    static let defaultScrollback = 1000

    init(
        columns: Int = TerminalOutput.defaultColumns,
        rows: Int = TerminalOutput.defaultRows,
        scrollbackLimit: Int = TerminalOutput.defaultScrollback
    ) {
        screen = TerminalScreen(columns: columns, rows: rows, scrollbackLimit: scrollbackLimit)
    }

    // MARK: - Feeding

    /// Appends program output verbatim, escapes and all.
    mutating func append(_ text: String) {
        screen.write(text)
    }

    /// Appends one logical line.
    mutating func appendLine(_ text: String) {
        screen.writeLine(text)
    }

    /// `clear`: blank the screen, keep the scrollback `TerminalScreen` holds.
    mutating func clear() {
        screen.clear()
    }

    /// A hard reset, including scrollback and attributes.
    mutating func reset() {
        screen.reset()
    }

    /// Tells the screen how wide the view is, in character cells.
    mutating func resize(columns: Int) {
        guard columns > 0, columns != screen.columns else {
            return
        }
        screen.resize(columns: columns, rows: screen.rows)
    }

    // MARK: - Reading

    /// Styled lines, ready to be turned into an attributed string.
    var renderedLines: [[ANSISegment]] { screen.renderedLines }

    var plainLines: [String] {
        var lines = screen.textLines
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return lines
    }

    var plainText: String { screen.plainText }

    /// Control sequences the screen saw but does not implement.
    var unsupported: [String] { screen.unsupported }
}
