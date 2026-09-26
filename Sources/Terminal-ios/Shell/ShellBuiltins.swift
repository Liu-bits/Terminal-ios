// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// The command table: every built-in this shell ships in-process.
///
/// Grouping is kept so `help` can print a readable inventory. Commands that
/// need engine-owned state (`cd`, `clear`, `history`, `exit`) are dispatched by
/// `ShellEngine` itself and are listed here only for `help`/`type`.
enum ShellBuiltins {

    static let shellVersion = "0.2.0"

    /// Commands implemented by the engine rather than by a value type.
    static let engineCommands: [(name: String, summary: String)] = [
        ("cd", "change the working directory"),
        ("pwd", "print the working directory"),
        ("clear", "clear the screen"),
        ("history", "show command history"),
        ("exit", "leave the shell or the running script")
    ]

    /// The full built-in table. Later entries win, so a name is defined once.
    static let table: [String: ShellBuiltin] = {
        var result: [String: ShellBuiltin] = [:]
        for builtin in FileBuiltins.all + TextBuiltins.all + SystemBuiltins.all {
            result[builtin.name] = builtin
        }
        return result
    }()

    static var names: [String] {
        table.keys.sorted()
    }

    /// Catalog compiled into this build, used by `help`, `which` and the
    /// runtime shims.
    static let catalog = Catalog.bundled()

    static var packageCommandNames: [String] {
        catalog.providedCommands
    }

    static func helpText() -> String {
        var lines: [String] = []
        lines.append("Built-ins: \(table.count) commands, shell \(shellVersion)")
        lines.append("")
        for group in groups {
            lines.append("  \(group.title)")
            lines.append(wrap(group.names, indent: "    "))
        }
        lines.append("")
        lines.append("  packages")
        lines.append(wrap(packageCommandNames, indent: "    "))
        lines.append("")
        lines.append("Operators:  |  >  >>  <  &&  ||  ;")
        lines.append("Substitution: $(command)  `command`   Variables: $VAR ${VAR} $? $# $1")
        lines.append("Scripts: if/elif/else, for, while, until, functions, # comments")
        return lines.joined(separator: "\n")
    }

    private static var groups: [(title: String, names: [String])] {
        [
            ("files", FileBuiltins.all.map(\.name)),
            ("text", TextBuiltins.all.map(\.name)),
            ("system", SystemBuiltins.all.map(\.name)),
            ("shell", engineCommands.map(\.name))
        ]
    }

    /// Wraps a command list to roughly 64 characters per line.
    private static func wrap(_ names: [String], indent: String) -> String {
        var lines: [String] = []
        var current = indent
        for (index, name) in names.enumerated() {
            let piece = index == names.count - 1 ? name : name + " "
            if current.count + piece.count > 68, current.count > indent.count {
                lines.append(current)
                current = indent
            }
            current += piece
        }
        if current.count > indent.count {
            lines.append(current)
        }
        return lines.joined(separator: "\n")
    }
}
