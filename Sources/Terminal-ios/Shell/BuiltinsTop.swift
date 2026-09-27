// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// `top` - what this terminal has been doing.
///
/// Not a process monitor: everything runs in-process, so there are no
/// processes to watch. What it shows instead is real: session uptime, the
/// working directory, how many snapshots and packages there are, the device's
/// memory, and the recent runs with their exit codes and durations. Enter opens
/// the selected run's output, Esc goes back, `f` filters to failures and `s`
/// sorts by duration.
enum TopBuiltin {

    static let all: [ShellBuiltin] = [
        ShellBuiltin("top", "recent activity: runs, timings, failures") { args, context in
            run(args, context)
        }
    ]

    private static func run(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, valueFlags: ["n"])
        let count = parsed.value("n").flatMap { Int($0) } ?? 50

        func snapshot() -> TopSession.Snapshot {
            let manager = context.packages()
            return TopSession.Snapshot(
                uptime: context.session.map { Date().timeIntervalSince($0.startedAt) } ?? 0,
                directory: context.environment.displayPath(context.environment.currentDirectory),
                runs: context.snapshots.entries().count,
                packages: manager.installedNames().count,
                memoryMegabytes: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
                entries: context.snapshots.recent(count),
                columns: context.terminalColumns,
                rows: context.terminalRows
            )
        }

        let session = TopSession(source: snapshot)

        guard context.interactive else {
            // No screen: print the same rows once, like `top -b`.
            return .ok(session.plainReport())
        }
        return ShellResult(
            output: session.initialFrame,
            exitCode: 0,
            clearScreen: false,
            session: session
        )
    }
}

/// The viewer's state.
final class TopSession: InteractiveSession {

    /// Everything the view shows, gathered in one place so the command can
    /// re-read it and the session stays testable with fixed numbers.
    struct Snapshot {
        var uptime: TimeInterval
        var directory: String
        var runs: Int
        var packages: Int
        var memoryMegabytes: Int
        var entries: [HistoryEntry]
        var columns: Int
        var rows: Int
    }

    private var snapshot: Snapshot
    private var selected = 0
    private var failedOnly = false
    private var slowestFirst = false
    private var detail: HistoryEntry?

    private let reload: () -> Snapshot

    init(source: @escaping () -> Snapshot) {
        self.reload = source
        self.snapshot = source()
    }

    var inputMode: InteractiveInputMode { .key }

    var initialFrame: String { frame() }

    /// The rows the header leaves room for: one header, one blank, one status.
    private var listRows: Int { max(1, snapshot.rows - 3) }

    /// Entries after the filter and the sort, in display order.
    private(set) var visible: [HistoryEntry] = []

    /// The highlighted row, as an index into `visible`.
    var selectedIndex: Int { selected }

    private func refreshVisible() {
        var entries = snapshot.entries
        if failedOnly {
            entries = entries.filter { !$0.succeeded }
        }
        if slowestFirst {
            entries.sort { $0.duration > $1.duration }
        }
        visible = entries
        selected = min(max(0, selected), max(0, visible.count - 1))
    }

    func handle(key: String) -> InteractiveStep {
        if detail != nil {
            switch key {
            case "q", InteractiveKey.interrupt:
                return .finished("", 0)
            default:
                // Anything else, Esc included, goes back to the list.
                detail = nil
                return .frame(frame())
            }
        }
        switch key {
        case "q", InteractiveKey.escape, InteractiveKey.interrupt:
            return .finished("", 0)
        case "j", InteractiveKey.down:
            selected = min(max(0, visible.count - 1), selected + 1)
        case "k", InteractiveKey.up:
            selected = max(0, selected - 1)
        case "G":
            selected = max(0, visible.count - 1)
        case "g":
            selected = 0
        case "f":
            failedOnly.toggle()
            selected = 0
        case "s":
            slowestFirst.toggle()
        case InteractiveKey.enter:
            if visible.indices.contains(selected) {
                detail = visible[selected]
            }
        default:
            break
        }
        return .frame(frame())
    }

    func handle(line: String) -> InteractiveStep {
        handle(key: InteractiveKey.enter)
    }

    // MARK: - Drawing

    func frame() -> String {
        refreshVisible()
        if let detail {
            return detailFrame(detail)
        }
        var text = "\u{1B}[H\u{1B}[2J"
        text += header() + "\n\n"

        let start = windowStart()
        for offset in 0..<listRows {
            let index = start + offset
            guard index < visible.count else {
                break
            }
            let entry = visible[index]
            let marker = index == selected ? "\u{1B}[7m" : ""
            text += marker + row(entry) + "\u{1B}[0m\n"
        }
        let hint = failedOnly ? "f:all  s:duration  j/k  enter  q" : "f:failures  s:duration  j/k  enter  q"
        text += "\u{1B}[\(snapshot.rows);1H\u{1B}[7m" + pad(hint) + "\u{1B}[0m"
        return text
    }

    private func detailFrame(_ entry: HistoryEntry) -> String {
        var text = "\u{1B}[H\u{1B}[2J"
        text += "$ \(entry.command)\n"
        text += "id \(entry.shortID)   exit \(entry.exitCode)   \(String(format: "%.3fs", entry.duration))\n"
        text += "dir \(entry.directory)\n"
        let body = entry.stdout.isEmpty ? "(no output stored)" : entry.stdout
        let bodyLines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in bodyLines.prefix(max(0, snapshot.rows - 5)) {
            text += line + "\n"
        }
        if bodyLines.count > max(0, snapshot.rows - 5) {
            text += "… \(bodyLines.count - max(0, snapshot.rows - 5)) more line(s)\n"
        }
        text += "\u{1B}[\(snapshot.rows);1H\u{1B}[7m" + pad("esc:back  q:quit") + "\u{1B}[0m"
        return text
    }

    private func header() -> String {
        let minutes = Int(snapshot.uptime) / 60
        let seconds = Int(snapshot.uptime) % 60
        return "TimeShell top   up \(minutes)m\(String(format: "%02d", seconds))s   \(snapshot.directory)   "
            + "runs \(snapshot.runs)   packages \(snapshot.packages)   mem \(snapshot.memoryMegabytes) MB"
    }

    private func row(_ entry: HistoryEntry) -> String {
        let status = entry.succeeded ? "ok  " : "fail"
        let time = String(format: "%6.2fs", entry.duration)
        return "\(status) \(time)  \(entry.command)"
    }

    /// Keeps the selection on screen without scrolling the whole list around.
    private func windowStart() -> Int {
        guard visible.count > listRows else {
            return 0
        }
        let half = listRows / 2
        return min(max(0, selected - half), visible.count - listRows)
    }

    private func pad(_ text: String) -> String {
        let visible = ANSIParser.strip(text)
        if visible.count >= snapshot.columns - 1 {
            return String(visible.prefix(snapshot.columns - 1))
        }
        return visible + String(repeating: " ", count: snapshot.columns - 1 - visible.count)
    }

    /// The one-shot version, for `top` without a screen.
    func plainReport() -> String {
        refreshVisible()
        var lines = [header(), ""]
        for entry in visible.prefix(listRows) {
            lines.append(row(entry))
        }
        if visible.isEmpty {
            lines.append("(nothing recorded yet)")
        }
        return lines.joined(separator: "\n")
    }
}
