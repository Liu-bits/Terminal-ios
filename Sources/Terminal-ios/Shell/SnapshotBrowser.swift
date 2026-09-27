// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// A browser over the Time Machine: `tm browse`.
///
/// The plan calls for a card stream in the UI; until that exists, the same
/// browsing works on the terminal itself, and it is the pure-logic half either
/// way - the UI can render the same steps later.
///
/// Keys: `j`/`k` move, Enter opens a snapshot, `/` searches, `r` replays it,
/// `p` pins or unpins, `x` deletes (it asks first), `q` quits.
final class SnapshotBrowserSession: InteractiveSession {

    private struct Screen {
        var entries: [HistoryEntry]
        var columns: Int
        var rows: Int
    }

    private let read: () -> Screen
    private let replay: (HistoryEntry) -> String
    private let delete: (HistoryEntry) -> Void
    private let pin: (HistoryEntry, Bool) -> Void

    private var screen: Screen

    private enum View {
        case list
        case detail(index: Int, scroll: Int)
        case search(draft: String)
        case confirmDelete(index: Int)
    }
    private var view: View = .list

    private var selected = 0
    private var pattern: String?
    private var statusMessage = ""

    init(
        read: @escaping () -> [HistoryEntry],
        columns: Int,
        rows: Int,
        replay: @escaping (HistoryEntry) -> String,
        delete: @escaping (HistoryEntry) -> Void,
        pin: @escaping (HistoryEntry, Bool) -> Void
    ) {
        self.read = {
            Screen(entries: read(), columns: columns, rows: rows)
        }
        self.replay = replay
        self.delete = delete
        self.pin = pin
        self.screen = Screen(entries: read(), columns: columns, rows: rows)
    }

    var inputMode: InteractiveInputMode { .key }

    var initialFrame: String { frame() }

    /// Rows available for content: one header, one status line.
    private var contentRows: Int { max(1, screen.rows - 2) }

    private var entries: [HistoryEntry] { screen.entries }

    // MARK: - Keys

    func handle(key: String) -> InteractiveStep {
        switch view {
        case .search(let draft):
            return searchKey(key, draft: draft)
        case .confirmDelete:
            if key == "y" {
                let entry = entries[min(selected, max(0, entries.count - 1))]
                delete(entry)
                view = .list
                statusMessage = "Deleted \(entry.shortID)."
                screen = read()
                selected = min(selected, max(0, entries.count - 1))
                return .frame(frame())
            }
            view = .list
            statusMessage = "Delete cancelled."
            return .frame(frame())
        case .detail(let index, let scroll):
            switch key {
            case "q", InteractiveKey.interrupt:
                return .finished("", 0)
            case "j", InteractiveKey.down:
                view = .detail(index: index, scroll: scroll + 1)
            case "k", InteractiveKey.up:
                view = .detail(index: index, scroll: max(0, scroll - 1))
            case "g":
                view = .detail(index: index, scroll: 0)
            case "G":
                view = .detail(index: index, scroll: Int.max)
            default:
                view = .list
            }
            return .frame(frame())
        case .list:
            break
        }

        switch key {
        case "q", InteractiveKey.escape, InteractiveKey.interrupt:
            return .finished("", 0)
        case "j", InteractiveKey.down:
            selected = min(max(0, entries.count - 1), selected + 1)
        case "k", InteractiveKey.up:
            selected = max(0, selected - 1)
        case "g":
            selected = 0
        case "G":
            selected = max(0, entries.count - 1)
        case InteractiveKey.enter:
            if entries.indices.contains(selected) {
                view = .detail(index: selected, scroll: 0)
                statusMessage = ""
            }
        case "/":
            view = .search(draft: "")
            statusMessage = ""
        case "p":
            if entries.indices.contains(selected) {
                let entry = entries[selected]
                pin(entry, !entry.pinned)
                statusMessage = entry.pinned ? "Unpinned \(entry.shortID)." : "Pinned \(entry.shortID)."
                screen = read()
            }
        case "x":
            if entries.indices.contains(selected) {
                view = .confirmDelete(index: selected)
                statusMessage = ""
            }
        case "r":
            // Re-running belongs in the shell's output, not inside a browser:
            // leave the screen and write the result there.
            if let output = replaySelected() {
                return .finished(output, 0)
            }
        default:
            break
        }
        return .frame(frame())
    }

    private func searchKey(_ key: String, draft: String) -> InteractiveStep {
        switch key {
        case InteractiveKey.enter:
            view = .list
            let query = draft
            guard !query.isEmpty else {
                pattern = nil
                statusMessage = ""
                return .frame(frame())
            }
            pattern = query
            let matches = entries.enumerated().filter { contains($0.element, query) }.map(\.offset)
            if let first = matches.first {
                selected = first
                statusMessage = "\(matches.count) match(es) for \(query)."
            } else {
                statusMessage = "No snapshot matches \(query)."
            }
            return .frame(frame())
        case InteractiveKey.escape, InteractiveKey.interrupt:
            view = .list
            return .frame(frame())
        case InteractiveKey.backspace:
            view = .search(draft: String(draft.dropLast()))
            return .frame(frame())
        default:
            if let character = InteractiveKey.printable(key) {
                view = .search(draft: draft + String(character))
            }
            return .frame(frame())
        }
    }

    private func contains(_ entry: HistoryEntry, _ query: String) -> Bool {
        entry.command.localizedCaseInsensitiveContains(query)
            || entry.stdout.localizedCaseInsensitiveContains(query)
            || (entry.title?.localizedCaseInsensitiveContains(query) ?? false)
    }

    func handle(line: String) -> InteractiveStep {
        handle(key: InteractiveKey.enter)
    }

    /// `r` replays the selected run on the main screen, because the result of
    /// re-running something belongs in the shell's output, not inside a browser.
    func replaySelected() -> String? {
        guard entries.indices.contains(selected) else {
            return nil
        }
        return replay(entries[selected])
    }

    // MARK: - Drawing

    func frame() -> String {
        screen = read()
        selected = min(selected, max(0, entries.count - 1))
        var text = "\u{1B}[H\u{1B}[2J"
        switch view {
        case .list:
            text += listFrame()
        case .detail(let index, let scroll):
            text += detailFrame(index: index, scroll: scroll)
        case .search(let draft):
            text += listFrame(search: "/" + draft)
        case .confirmDelete(let index):
            text += listFrame(confirmDeleteFor: index)
        }
        return text
    }

    private func listFrame(search: String? = nil, confirmDeleteFor index: Int? = nil) -> String {
        var text = header() + "\n"
        let start = windowStart()
        for offset in 0..<contentRows {
            let number = start + offset
            guard number < entries.count else {
                break
            }
            let entry = entries[number]
            let marker = number == selected ? "\u{1B}[7m" : ""
            let pin = entry.pinned ? "*" : " "
            let status = entry.succeeded ? "ok  " : "fail"
            text += "\(marker)\(pin) \(entry.shortID)  \(status)   \(entry.command)\u{1B}[0m\n"
        }
        let hint: String
        if let index {
            hint = "delete \(entries[index].shortID)? y / n"
        } else if let search {
            hint = search
        } else {
            hint = statusMessage.isEmpty ? "j/k  enter open  / search  r replay  p pin  x delete  q" : statusMessage
        }
        text += "\u{1B}[\(screen.rows);1H\u{1B}[7m" + pad(hint) + "\u{1B}[0m"
        return text
    }

    private func detailFrame(index: Int, scroll: Int) -> String {
        guard entries.indices.contains(index) else {
            view = .list
            return listFrame()
        }
        let entry = entries[index]
        var text = "$ \(entry.command)\n"
        text += "id \(entry.shortID)   exit \(entry.exitCode)   \(String(format: "%.3fs", entry.duration))   \(entry.directory)\n"
        let body = entry.stdout.isEmpty ? ["(no output stored)"] : entry.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let limit = max(1, screen.rows - 3)
        let offset = min(max(0, scroll), max(0, body.count - limit))
        for line in body.dropFirst(offset).prefix(limit) {
            text += line + "\n"
        }
        if body.count > limit {
            text += "… \(body.count - limit - offset) more line(s)\n"
        }
        text += "\u{1B}[\(screen.rows);1H\u{1B}[7m" + pad("j/k scroll  esc back  q quit") + "\u{1B}[0m"
        return text
    }

    private func header() -> String {
        var text = "tm browse   \(entries.count) snapshot(s)"
        if let pattern {
            text += "   filter: \(pattern)"
        }
        return text
    }

    private func windowStart() -> Int {
        guard entries.count > contentRows else {
            return 0
        }
        let half = contentRows / 2
        return min(max(0, selected - half), entries.count - contentRows)
    }

    private func pad(_ text: String) -> String {
        let visible = ANSIParser.strip(text)
        if visible.count >= screen.columns - 1 {
            return String(visible.prefix(screen.columns - 1))
        }
        return visible + String(repeating: " ", count: screen.columns - 1 - visible.count)
    }

    /// The one-shot version, for `tm browse` without a screen.
    func plainList() -> String {
        screen = read()
        var lines = [header()]
        for entry in entries {
            let pin = entry.pinned ? "*" : " "
            let status = entry.succeeded ? "ok  " : "fail"
            lines.append("\(pin) \(entry.shortID)  \(status)   \(entry.command)")
        }
        if entries.isEmpty {
            lines.append("(no snapshots yet)")
        }
        return lines.joined(separator: "\n")
    }
}
