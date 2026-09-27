// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// One execution, captured whole.
///
/// This is the Phase 1 differentiator: not a list of command strings but a
/// structured snapshot, so a past run can be inspected, searched, replayed with
/// edits and pinned as a reusable action.
struct HistoryEntry: Codable, Equatable, Identifiable {

    var id: String
    var date: Date
    /// The line exactly as it was typed.
    var command: String
    /// Words of the first command as written, before variable expansion, so the
    /// snapshot shows what the user meant rather than what the environment
    /// happened to hold.
    var argv: [String]
    /// Working directory at the time.
    var directory: String
    /// Variables exported at the time (the shell's environment).
    var environment: [String: String]
    /// Output. The engine renders one stream, so `stderr` stays empty until the
    /// UI splits them; the field exists so snapshots written today stay valid.
    var stdout: String
    var stderr: String
    var exitCode: Int
    /// Wall-clock duration in seconds.
    var duration: TimeInterval
    /// Pinned snapshots become action cards the user can re-run.
    var pinned: Bool
    /// Short label for a pinned card.
    var title: String?

    /// Output is capped before it is stored: a snapshot is a convenience, and a
    /// `cat` of a huge file must not become one.
    static let outputLimit = 64 * 1024

    init(
        id: String = UUID().uuidString,
        date: Date = Date(),
        command: String,
        argv: [String] = [],
        directory: String,
        environment: [String: String] = [:],
        stdout: String = "",
        stderr: String = "",
        exitCode: Int = 0,
        duration: TimeInterval = 0,
        pinned: Bool = false,
        title: String? = nil
    ) {
        self.id = id
        self.date = date
        self.command = command
        self.argv = argv
        self.directory = directory
        self.environment = environment
        self.stdout = HistoryEntry.capped(stdout)
        self.stderr = HistoryEntry.capped(stderr)
        self.exitCode = exitCode
        self.duration = duration
        self.pinned = pinned
        self.title = title
    }

    static func capped(_ text: String) -> String {
        guard text.utf8.count > outputLimit else {
            return text
        }
        // Take a byte prefix and let `String(decoding:)` repair a partial
        // trailing sequence: cheaper than trimming characters one at a time and
        // safe for multi-byte text.
        let prefix = Array(text.utf8.prefix(outputLimit))
        let cut = String(decoding: prefix, as: UTF8.self)
        return cut + "\n[output truncated at \(outputLimit / 1024) KB]"
    }

    /// First ten characters of the id, which is what the UI and `tm` show.
    var shortID: String { String(id.prefix(8)) }

    var succeeded: Bool { exitCode == 0 }

    /// One-line summary for a list.
    var summary: String {
        let status = succeeded ? "ok" : "exit \(exitCode)"
        let seconds = String(format: "%.2fs", duration)
        return "\(shortID)  \(status)  \(seconds)  \(command)"
    }
}

/// What a snapshot can be searched by.
struct HistoryFilter: Equatable {
    /// Free text matched against the command and the output.
    var text: String?
    /// Only runs that failed.
    var failedOnly = false
    /// Only runs from one directory.
    var directory: String?
    /// Only runs at or after this date.
    var since: Date?
    /// Only pinned snapshots.
    var pinnedOnly = false
    /// Maximum number of results.
    var limit: Int?

    init(
        text: String? = nil,
        failedOnly: Bool = false,
        directory: String? = nil,
        since: Date? = nil,
        pinnedOnly: Bool = false,
        limit: Int? = nil
    ) {
        self.text = text
        self.failedOnly = failedOnly
        self.directory = directory
        self.since = since
        self.pinnedOnly = pinnedOnly
        self.limit = limit
    }
}

/// A search hit, with the reason it matched so the UI can say why.
struct HistoryMatch: Equatable {
    var entry: HistoryEntry
    var score: Int
    /// True when the command itself matched, not just the output.
    var matchedCommand: Bool
    /// The output lines that matched, for a preview.
    var outputLines: [String]
}
