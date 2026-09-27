// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// `tm` - the Time Machine over past executions.
///
/// Snapshots are written by the engine (`ShellEngine.onExecute`) and this is how
/// they are read back: list, search, inspect, page through, re-run, pin, export.
enum TimeMachineBuiltin {

    static let all: [ShellBuiltin] = [
        ShellBuiltin("tm", "Time Machine: list, search, show, page, replay, pin past runs") { args, context in
            run(args, context)
        }
    ]

    private static let usage = """
    tm: Time Machine over past runs
    usage:
      tm list [n]              recent snapshots, newest first
      tm search <text>         search commands and output (--failed, --pinned)
      tm show <id>             full snapshot: command, dir, env, output, timing
      tm page <id>             page a snapshot's output (same keys as less)
      tm replay <id>           run the same command again
      tm pin <id> [label]      pin a snapshot as an action card
      tm unpin <id>            unpin it
      tm export [file]         plain-text dump
      tm clear                 delete every snapshot
    ids are unique prefixes, as printed by `tm list`
    """

    private static func run(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let store = context.snapshots
        let parsed = ShellArgs.parse(args, valueFlags: ["n"])
        guard let subcommand = parsed.operands.first else {
            return .ok(usage)
        }
        let rest = Array(parsed.operands.dropFirst())

        switch subcommand {
        case "list", "ls":
            let count = rest.first.flatMap { Int($0) } ?? parsed.value("n").flatMap { Int($0) } ?? 20
            return list(store, count: count)
        case "search", "grep":
            return search(store, terms: rest, parsed: parsed)
        case "show", "cat":
            guard let id = rest.first else {
                return .fail("tm show: which snapshot?", code: 2)
            }
            return show(store, id: id)
        case "page", "pager", "less":
            guard let id = rest.first else {
                return .fail("tm page: which snapshot?", code: 2)
            }
            return page(store, id: id, context)
        case "replay", "run":
            guard let id = rest.first else {
                return .fail("tm replay: which snapshot?", code: 2)
            }
            return replay(store, id: id, context)
        case "pin":
            guard let id = rest.first else {
                return .fail("tm pin: which snapshot?", code: 2)
            }
            let label = rest.count > 1 ? rest.dropFirst().joined(separator: " ") : nil
            return pin(store, id: id, label: label, pinned: true)
        case "unpin":
            guard let id = rest.first else {
                return .fail("tm unpin: which snapshot?", code: 2)
            }
            return pin(store, id: id, label: nil, pinned: false)
        case "export":
            return export(store, path: rest.first, context)
        case "clear":
            let count = store.entries().count
            store.clear()
            // Every run is recorded, including this one, which is why the list is
            // not empty the moment after a clear.
            return .ok("Cleared \(count) snapshot(s). This run is recorded as the first new one.")
        case "help", "--help":
            return .ok(usage)
        default:
            return .fail("tm: unknown subcommand '\(subcommand)'\n\n\(usage)", code: 2)
        }
    }

    // MARK: - Subcommands

    private static func list(_ store: HistoryStore, count: Int) -> ShellResult {
        let entries = store.recent(count)
        guard !entries.isEmpty else {
            return .ok("No snapshots yet.")
        }
        var lines = ["#   id        status  time    command"]
        for (index, entry) in entries.enumerated() {
            let status = entry.succeeded ? "ok   " : "fail "
            let seconds = String(format: "%5.2fs", entry.duration)
            let pin = entry.pinned ? "* " : "  "
            lines.append("\(pin)\(index + 1)  \(entry.shortID)  \(status) \(seconds)  \(entry.command)")
        }
        lines.append("")
        lines.append("\(entries.count) of \(store.entries().count) snapshot(s). Use `tm show <id>` or `tm search <text>`.")
        return .ok(lines.joined(separator: "\n"))
    }

    private static func search(_ store: HistoryStore, terms: [String], parsed: ShellArgs) -> ShellResult {
        let text = terms.isEmpty ? nil : terms.joined(separator: " ")
        let filter = HistoryFilter(
            text: text,
            failedOnly: parsed.hasLong("failed"),
            pinnedOnly: parsed.hasLong("pinned"),
            limit: parsed.value("n").flatMap { Int($0) } ?? 20
        )
        let matches = store.search(filter)
        guard !matches.isEmpty else {
            return .ok("No snapshot matches\(text.map { " '\($0)'" } ?? "").")
        }
        var lines: [String] = []
        for match in matches {
            let marker = match.matchedCommand ? "$" : " "
            let status = match.entry.succeeded ? "ok  " : "fail"
            lines.append("\(marker) \(match.entry.shortID)  \(status)  \(match.entry.command)")
            for line in match.outputLines {
                lines.append("    | \(line.prefix(120))")
            }
        }
        lines.append("")
        lines.append("\(matches.count) match(es). `tm show <id>` for the whole snapshot.")
        return .ok(lines.joined(separator: "\n"))
    }

    private static func show(_ store: HistoryStore, id: String) -> ShellResult {
        guard let entry = store.find(id: id) else {
            return .fail("tm: no snapshot matching '\(id)'", code: 1)
        }
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("snapshot \(entry.id)")
        lines.append("  command   \(entry.command)")
        if !entry.argv.isEmpty {
            lines.append("  argv      \(entry.argv.joined(separator: " "))")
        }
        lines.append("  directory \(entry.directory)")
        lines.append("  when      \(formatter.string(from: entry.date))")
        lines.append("  exit      \(entry.exitCode)   duration \(String(format: "%.3fs", entry.duration))")
        lines.append("  pinned    \(entry.pinned ? (entry.title.map { "yes (\($0))" } ?? "yes") : "no")")
        if !entry.environment.isEmpty {
            let pairs = entry.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            lines.append("  env       \(pairs.joined(separator: " "))")
        }
        lines.append("  output    \(entry.stdout.isEmpty ? "(none)" : "")")
        if !entry.stdout.isEmpty {
            for line in entry.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("    \(line)")
            }
        }
        if !entry.stderr.isEmpty {
            lines.append("  stderr")
            for line in entry.stderr.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("    \(line)")
            }
        }
        return .ok(lines.joined(separator: "\n"))
    }

    /// Pages a snapshot with the same session `less` uses, so a long output is
    /// read with the keys the user already knows.
    private static func page(_ store: HistoryStore, id: String, _ context: ShellRunContext) -> ShellResult {
        guard let entry = store.find(id: id) else {
            return .fail("tm: no snapshot matching '\(id)'", code: 1)
        }
        let body = entry.stdout.isEmpty ? "(no output)" : entry.stdout
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let title = "snapshot \(entry.shortID)  $ \(entry.command)"
        let session = PagerSession(
            title: title,
            lines: lines,
            rows: context.terminalRows,
            columns: context.terminalColumns
        )
        guard context.interactive else {
            return .ok(lines.joined(separator: "\n"))
        }
        return ShellResult(output: session.initialFrame, exitCode: 0, clearScreen: false, session: session)
    }

    private static func replay(_ store: HistoryStore, id: String, _ context: ShellRunContext) -> ShellResult {
        guard let entry = store.find(id: id) else {
            return .fail("tm: no snapshot matching '\(id)'", code: 1)
        }
        // Replaying re-enters the command as it was typed, so `cd`, `$VAR` and
        // everything else behave exactly as they did the first time. The replay
        // itself becomes a new snapshot, which is what makes replay-with-edits
        // work: run it, see the result, run it again.
        if !entry.directory.isEmpty, entry.directory != context.environment.displayPath(context.environment.currentDirectory) {
            _ = context.evaluate("cd \(entry.directory)")
        }
        return context.evaluate(entry.command)
    }

    private static func pin(
        _ store: HistoryStore,
        id: String,
        label: String?,
        pinned: Bool
    ) -> ShellResult {
        guard var entry = store.find(id: id) else {
            return .fail("tm: no snapshot matching '\(id)'", code: 1)
        }
        entry.pinned = pinned
        entry.title = pinned ? label : nil
        store.update(entry)
        guard pinned else {
            return .ok("Unpinned \(entry.shortID).")
        }
        return .ok("Pinned \(entry.shortID)\(label.map { " as '\($0)'" } ?? "").")
    }

    private static func export(_ store: HistoryStore, path: String?, _ context: ShellRunContext) -> ShellResult {
        let text = HistorySearch.export(store.entries())
        guard let path else {
            return .ok(text.isEmpty ? "No snapshots to export." : text)
        }
        guard context.writeText(text + "\n", to: path, append: false) else {
            return .fail("tm export: cannot write '\(path)'")
        }
        return .ok("Exported \(store.entries().count) snapshot(s) to \(path).")
    }
}
