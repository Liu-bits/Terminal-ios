// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Full-text search over snapshots.
///
/// Ranking exists because the interesting hit is usually the one where the user
/// typed the words, not the one where a `cat` happened to print them. A command
/// match therefore scores far above an output match, and a whole-word command
/// match above a substring.
enum HistorySearch {

    static func search(_ entries: [HistoryEntry], filter: HistoryFilter) -> [HistoryMatch] {
        var matches: [HistoryMatch] = []
        for entry in entries {
            if filter.failedOnly, entry.succeeded {
                continue
            }
            if filter.pinnedOnly, !entry.pinned {
                continue
            }
            if let directory = filter.directory, entry.directory != directory {
                continue
            }
            if let since = filter.since, entry.date < since {
                continue
            }
            guard let text = filter.text, !text.isEmpty else {
                matches.append(HistoryMatch(entry: entry, score: 0, matchedCommand: false, outputLines: []))
                continue
            }
            if let hit = match(entry: entry, text: text) {
                matches.append(hit)
            }
        }

        // With a query: best match first, then newest. Without one: newest first.
        if filter.text?.isEmpty == false {
            matches.sort { left, right in
                if left.score != right.score {
                    return left.score > right.score
                }
                return left.entry.date > right.entry.date
            }
        } else {
            matches.sort { $0.entry.date > $1.entry.date }
        }
        if let limit = filter.limit {
            return Array(matches.prefix(max(0, limit)))
        }
        return matches
    }

    /// Scores one entry against a query, or returns nil when it does not match.
    static func match(entry: HistoryEntry, text: String) -> HistoryMatch? {
        var score = 0
        var matchedCommand = false

        let command = entry.command
        let loweredCommand = command.lowercased()
        let lowered = text.lowercased()

        if loweredCommand == lowered {
            score += 100
            matchedCommand = true
        } else if loweredCommand.hasPrefix(lowered) {
            score += 60
            matchedCommand = true
        } else if let range = loweredCommand.range(of: lowered) {
            // A match at a word boundary beats one in the middle of a word.
            let before = range.lowerBound
            let boundary = before == command.startIndex
                || command[command.index(before: before)] == " "
            score += boundary ? 40 : 25
            matchedCommand = true
        }

        // The pinned title counts as a command-level clue.
        if let title = entry.title, title.lowercased().contains(lowered) {
            score += 30
            matchedCommand = true
        }

        var outputLines: [String] = []
        var occurrences = 0
        for line in entry.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.lowercased().contains(lowered) {
                occurrences += 1
                if outputLines.count < 3 {
                    outputLines.append(String(line))
                }
            }
        }
        if occurrences > 0 {
            score += min(20, 2 + occurrences)
        }

        // No textual match at all: this entry is not a hit, however interesting
        // it looks. Ranking fails here instead - a failed run is more likely
        // what the user is digging for than a successful one.
        guard score > 0 else {
            return nil
        }
        if !entry.succeeded {
            score += 5
        }
        return HistoryMatch(entry: entry, score: score, matchedCommand: matchedCommand, outputLines: outputLines)
    }

    /// Plain-text export of snapshots, for the "text export" feature in the plan.
    static func export(_ entries: [HistoryEntry], includeOutput: Bool = true) -> String {
        var lines: [String] = []
        let formatter = ISO8601DateFormatter()
        for entry in entries {
            lines.append("$ \(entry.command)")
            lines.append("  id \(entry.shortID)  \(formatter.string(from: entry.date))")
            lines.append("  dir \(entry.directory)  exit \(entry.exitCode)  \(String(format: "%.2fs", entry.duration))")
            if includeOutput, !entry.stdout.isEmpty {
                for line in entry.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("  | \(line)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
