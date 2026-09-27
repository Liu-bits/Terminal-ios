// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// One position on the grid.
///
/// `text` is a `String` rather than a `Character` because a base letter plus its
/// combining marks has to travel together, and `""` marks the second half of a
/// wide character (so the renderer can skip it instead of drawing a gap).
struct TerminalCell: Equatable {
    var text: String = " "
    var style: TerminalStyle = .plain

    static let blank = TerminalCell()

    var isBlank: Bool { text == " " && style.isPlain }
    var isContinuation: Bool { text.isEmpty }
}

/// A terminal grid: cursor, attributes, scrollback, and the escape sequences
/// that drive them.
///
/// This is the model behind the screen. It is deliberately a value type with no
/// UIKit import, so the whole thing - including `\r` progress bars, cursor
/// addressing and wide characters - is unit-testable on a machine without a
/// simulator.
///
/// One honest limitation: the scrolling region (`CSI r`, used by `less`/`vim`)
/// is **not** supported. Instead of silently mis-rendering, those sequences are
/// recorded in `unsupported` so callers and tests can see what was dropped.
struct TerminalScreen {

    private(set) var columns: Int
    private(set) var rows: Int
    let scrollbackLimit: Int

    private(set) var grid: [[TerminalCell]]
    /// Rows pushed off the top, oldest first.
    private(set) var scrollback: [[TerminalCell]] = []

    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    private(set) var cursorVisible = true
    private(set) var style = TerminalStyle.plain

    /// Control sequences we recognised but do not implement, in order.
    private(set) var unsupported: [String] = []

    private var savedCursor: (row: Int, column: Int, style: TerminalStyle)?
    /// Set when writing filled the last column: the next printable character
    /// wraps first, which is what makes `printf "1234567890"` on a 10-column
    /// screen leave the cursor at the end rather than on a new line.
    private(set) var pendingWrap = false

    init(columns: Int = 80, rows: Int = 24, scrollbackLimit: Int = 500) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.scrollbackLimit = max(0, scrollbackLimit)
        self.grid = Array(
            repeating: Array(repeating: TerminalCell.blank, count: max(1, columns)),
            count: max(1, rows)
        )
    }

    // MARK: - Writing

    /// Feeds a chunk of program output through the screen.
    mutating func write(_ text: String) {
        var scanner = ANSIParser.Scanner(text: text)
        while let step = scanner.next() {
            switch step {
            case .character(let character):
                // Control characters drive the grid; they must never land in a
                // cell, or `\n` becomes a visible character and every line ends
                // up on one row.
                if let scalar = singleScalar(of: character), isControl(scalar) {
                    handle(control: scalar)
                } else {
                    put(character)
                }
            case .sgr(let parameters):
                style = style.applying(sgr: parameters)
            case .control(let sequence):
                apply(sequence)
            case .ignored:
                continue
            }
        }
    }

    private func singleScalar(of character: Character) -> Unicode.Scalar? {
        let scalars = character.unicodeScalars
        guard scalars.count == 1 else {
            return nil
        }
        return scalars.first
    }

    private func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// Acts on one C0 control character.
    ///
    /// `\n` behaves as CR+LF, which is what the tty layer does for every
    /// program by default (`ONLCR`). Without a tty between the program and this
    /// grid that translation has to happen here.
    private mutating func handle(control scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x07:
            break                           // BEL: there is no bell to ring
        case 0x08:
            backspace()
        case 0x09:
            tab()
        case 0x0A, 0x0B, 0x0C:
            newLine()
        case 0x0D:
            cursorColumn = 0
            pendingWrap = false
        case 0x0E, 0x0F:
            break                           // SO/SI: no alternate charset
        default:
            break
        }
    }

    private mutating func backspace() {
        pendingWrap = false
        cursorColumn = max(0, cursorColumn - 1)
    }

    /// Advances to the next multiple-of-eight tab stop, clamped to the row.
    private mutating func tab() {
        guard !pendingWrap else {
            return
        }
        let next = min(columns - 1, ((cursorColumn / 8) + 1) * 8)
        cursorColumn = next
    }

    /// Writes one line and moves to the next.
    mutating func writeLine(_ text: String) {
        write(text)
        write("\n")
    }

    // MARK: - Editing

    /// `clear`: home the cursor and blank the grid, keeping scrollback.
    mutating func clear() {
        grid = blankGrid()
        cursorRow = 0
        cursorColumn = 0
        pendingWrap = false
    }

    /// A full reset, as `ESC c` asks for.
    mutating func reset() {
        scrollback = []
        style = .plain
        cursorVisible = true
        savedCursor = nil
        unsupported = []
        clear()
    }

    /// Resizes the grid, keeping the top-left of the content.
    mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let width = max(1, newColumns)
        let height = max(1, newRows)
        var resized = Array(
            repeating: Array(repeating: TerminalCell.blank, count: width),
            count: height
        )
        for row in 0..<min(rows, height) {
            for column in 0..<min(columns, width) {
                resized[row][column] = grid[row][column]
            }
        }
        grid = resized
        columns = width
        rows = height
        cursorRow = min(cursorRow, height - 1)
        cursorColumn = min(cursorColumn, width - 1)
        pendingWrap = false
    }

    // MARK: - Rendering

    /// Every line the UI should show: scrollback first, then the visible grid.
    ///
    /// Trailing blank rows are dropped so a half-filled screen does not render
    /// dozens of empty lines, and each line is split into styled runs.
    var renderedLines: [[ANSISegment]] {
        var lines = scrollback.map(segments(of:))
        let visible = grid.map(segments(of:))
        var lastUsed = visible.count - 1
        while lastUsed >= 0, visible[lastUsed].isEmpty {
            lastUsed -= 1
        }
        if lastUsed >= 0 {
            lines.append(contentsOf: visible[0...lastUsed])
        }
        return lines
    }

    /// The same content as plain strings, ready to compare in tests.
    var textLines: [String] {
        (scrollback + grid).map { row in
            row.reduce(into: "") { text, cell in
                if !cell.isContinuation {
                    text += cell.text
                }
            }
        }
        .map { line -> String in
            // Right-trim: blank cells at the end carry no meaning.
            var trimmed = line
            while trimmed.hasSuffix(" ") {
                trimmed.removeLast()
            }
            return trimmed
        }
    }

    /// Scrollback plus grid as text, with trailing blank lines removed.
    var plainText: String {
        var lines = textLines
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// Groups a row into runs of equal style, skipping what is not visible.
    private func segments(of row: [TerminalCell]) -> [ANSISegment] {
        var lastVisible = -1
        for (index, cell) in row.enumerated() where !cell.isBlank && !cell.isContinuation {
            lastVisible = index
        }
        guard lastVisible >= 0 else {
            return []
        }
        var result: [ANSISegment] = []
        var text = ""
        var current = TerminalCell.blank.style
        for index in 0...lastVisible {
            let cell = row[index]
            if cell.isContinuation {
                continue
            }
            if !text.isEmpty, cell.style != current {
                result.append(ANSISegment(text, current))
                text = ""
            }
            current = cell.style
            text += cell.text
        }
        if !text.isEmpty {
            result.append(ANSISegment(text, current))
        }
        return result
    }

    // MARK: - Character placement

    private mutating func put(_ character: Character) {
        let scalars = character.unicodeScalars
        let width = scalars.reduce(0) { $0 + TerminalWidth.of($1) }

        if width == 0 {
            // Combining mark: attach it to whatever is already there.
            attachZeroWidth(character)
            return
        }
        if pendingWrap {
            newLine()
        }
        if cursorColumn + width > columns {
            newLine()
        }
        grid[cursorRow][cursorColumn] = TerminalCell(text: String(character), style: style)
        if width == 2, cursorColumn + 1 < columns {
            // Second half of a CJK glyph: no text of its own, so the renderer
            // will not draw a gap where the glyph already covers two columns.
            grid[cursorRow][cursorColumn + 1] = TerminalCell(text: "", style: style)
        }
        cursorColumn += width
        if cursorColumn >= columns {
            cursorColumn = columns - 1
            pendingWrap = true
        }
    }

    private mutating func attachZeroWidth(_ character: Character) {
        var column = cursorColumn
        if pendingWrap {
            column = columns - 1
        } else if column > 0 {
            column -= 1
        }
        guard column >= 0, column < columns else {
            return
        }
        let existing = grid[cursorRow][column]
        guard !existing.isContinuation else {
            return
        }
        grid[cursorRow][column] = TerminalCell(
            text: existing.text + String(character),
            style: existing.style
        )
    }

    // MARK: - Cursor and erasing

    /// Moves to the start of the next row, scrolling when already at the bottom.
    private mutating func newLine() {
        cursorColumn = 0
        pendingWrap = false
        cursorRow += 1
        if cursorRow >= rows {
            scrollUp(lines: 1)
            cursorRow = rows - 1
        }
    }

    private mutating func scrollUp(lines count: Int) {
        for _ in 0..<max(1, count) {
            let row = grid.removeFirst()
            if scrollbackLimit > 0, row.contains(where: { !$0.isBlank }) {
                scrollback.append(row)
                if scrollback.count > scrollbackLimit {
                    scrollback.removeFirst(scrollback.count - scrollbackLimit)
                }
            }
            grid.append(Array(repeating: TerminalCell.blank, count: columns))
        }
    }

    private mutating func scrollDown(lines count: Int) {
        for _ in 0..<max(1, count) {
            grid.removeLast()
            grid.insert(Array(repeating: TerminalCell.blank, count: columns), at: 0)
        }
    }

    private mutating func apply(_ sequence: ANSIParser.CSI) {
        if sequence.isPrivate {
            switch (sequence.final, sequence.parameter(0)) {
            case ("h", 25):
                cursorVisible = true
            case ("l", 25):
                cursorVisible = false
            case ("h", 1049), ("l", 1049), ("h", 1047), ("l", 1047):
                // Alternate screen: the app has one screen, so a tool asking for
                // the alternate buffer keeps drawing on the main one.
                record(sequence, reason: "alternate screen buffer")
            case ("h", _), ("l", _):
                record(sequence, reason: "private mode")
            default:
                record(sequence, reason: "private sequence")
            }
            return
        }
        if sequence.intermediate != nil {
            record(sequence, reason: "intermediate byte")
            return
        }
        let first = sequence.parameter(0, default: 1)
        switch sequence.final {
        case "A", "e":
            cursorRow = max(0, cursorRow - max(1, first))
        case "B":
            cursorRow = min(rows - 1, cursorRow + max(1, first))
        case "C", "a":
            cursorColumn = min(columns - 1, cursorColumn + max(1, first))
            pendingWrap = false
        case "D":
            cursorColumn = max(0, cursorColumn - max(1, first))
            pendingWrap = false
        case "E":
            cursorRow = min(rows - 1, cursorRow + max(1, first))
            cursorColumn = 0
            pendingWrap = false
        case "F":
            cursorRow = max(0, cursorRow - max(1, first))
            cursorColumn = 0
            pendingWrap = false
        case "G":
            cursorColumn = min(columns - 1, max(0, first - 1))
            pendingWrap = false
        case "d":
            cursorRow = min(rows - 1, max(0, first - 1))
        case "H", "f":
            cursorRow = min(rows - 1, max(0, sequence.parameter(0, default: 1) - 1))
            cursorColumn = min(columns - 1, max(0, sequence.parameter(1, default: 1) - 1))
            pendingWrap = false
        case "J":
            eraseDisplay(mode: sequence.parameter(0, default: 0))
        case "K":
            eraseLine(mode: sequence.parameter(0, default: 0))
        case "L":
            insertLines(count: first)
        case "M":
            deleteLines(count: first)
        case "P":
            deleteCharacters(count: first)
        case "@":
            insertCharacters(count: first)
        case "X":
            eraseCharacters(count: first)
        case "S":
            scrollUp(lines: first)
        case "T":
            scrollDown(lines: first)
        case "s":
            savedCursor = (cursorRow, cursorColumn, style)
        case "u":
            if let saved = savedCursor {
                cursorRow = min(rows - 1, saved.row)
                cursorColumn = min(columns - 1, saved.column)
                style = saved.style
                pendingWrap = false
            }
        case "r":
            record(sequence, reason: "scrolling region")
        case "h", "l":
            record(sequence, reason: "mode")
        default:
            record(sequence, reason: "unhandled sequence")
        }
    }

    private mutating func eraseDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseLine(mode: 0)
            for row in (cursorRow + 1)..<rows {
                grid[row] = Array(repeating: TerminalCell.blank, count: columns)
            }
        case 1:
            eraseLine(mode: 1)
            for row in 0..<cursorRow {
                grid[row] = Array(repeating: TerminalCell.blank, count: columns)
            }
        case 2:
            grid = blankGrid()
        case 3:
            grid = blankGrid()
            scrollback = []
        default:
            break
        }
    }

    private mutating func eraseLine(mode: Int) {
        switch mode {
        case 0:
            for column in cursorColumn..<columns {
                grid[cursorRow][column] = .blank
            }
        case 1:
            for column in 0...min(cursorColumn, columns - 1) {
                grid[cursorRow][column] = .blank
            }
        case 2:
            grid[cursorRow] = Array(repeating: TerminalCell.blank, count: columns)
        default:
            break
        }
    }

    private mutating func insertLines(count: Int) {
        for _ in 0..<max(1, count) {
            grid.insert(Array(repeating: TerminalCell.blank, count: columns), at: cursorRow)
            grid.removeLast()
        }
    }

    private mutating func deleteLines(count: Int) {
        for _ in 0..<max(1, count) {
            grid.remove(at: cursorRow)
            grid.append(Array(repeating: TerminalCell.blank, count: columns))
        }
    }

    private mutating func deleteCharacters(count: Int) {
        let amount = min(max(1, count), columns - cursorColumn)
        for _ in 0..<amount {
            grid[cursorRow].remove(at: cursorColumn)
            grid[cursorRow].append(.blank)
        }
    }

    private mutating func insertCharacters(count: Int) {
        let amount = min(max(1, count), columns - cursorColumn)
        for _ in 0..<amount {
            grid[cursorRow].insert(.blank, at: cursorColumn)
            grid[cursorRow].removeLast()
        }
    }

    private mutating func eraseCharacters(count: Int) {
        let amount = min(max(1, count), columns - cursorColumn)
        for column in cursorColumn..<(cursorColumn + amount) {
            grid[cursorRow][column] = .blank
        }
    }

    private mutating func record(_ sequence: ANSIParser.CSI, reason: String) {
        let description = "ESC[\(sequence.isPrivate ? "?" : "")"
            + sequence.parameters.map(String.init).joined(separator: ";")
            + "\(sequence.final) (\(reason))"
        if !unsupported.contains(description) {
            unsupported.append(description)
        }
    }

    private func blankGrid() -> [[TerminalCell]] {
        Array(repeating: Array(repeating: TerminalCell.blank, count: columns), count: rows)
    }
}
