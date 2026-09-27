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
        let groups = FileBuiltins.all + TextBuiltins.all + SystemBuiltins.all
            + PowerShellBuiltins.all + WingetBuiltin.all + WasmBuiltin.all
            + PagerBuiltins.all + TimeMachineBuiltin.all
        for builtin in groups {
            result[builtin.name] = builtin
        }
        return result
    }()

    /// Lower-cased name to built-in, so `get-childitem` and `Get-ChildItem`
    /// both resolve the way PowerShell resolves them.
    private static let caseInsensitiveIndex: [String: ShellBuiltin] = {
        var result: [String: ShellBuiltin] = [:]
        for builtin in table.values where builtin.name.contains("-") {
            result[builtin.name.lowercased()] = builtin
        }
        return result
    }()

    /// PowerShell aliases (`gci`, `gc`, `sl`, ...).
    private static let aliasIndex: [String: ShellBuiltin] = {
        var result: [String: ShellBuiltin] = [:]
        for (alias, target) in PowerShellBuiltins.aliases {
            if let builtin = table[target] {
                result[alias] = builtin
            }
        }
        return result
    }()

    /// Resolves a command name: exact, then alias, then case-insensitive
    /// (cmdlets only, which is where PowerShell's case-insensitivity applies).
    static func lookup(_ name: String) -> ShellBuiltin? {
        if let builtin = table[name] {
            return builtin
        }
        let lowered = name.lowercased()
        if let builtin = aliasIndex[lowered] {
            return builtin
        }
        return caseInsensitiveIndex[lowered]
    }

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
        lines.append("PowerShell cmdlets work too (Get-ChildItem, Select-String, ...), with aliases like gci/gc/sl")
        return lines.joined(separator: "\n")
    }

    private static var groups: [(title: String, names: [String])] {
        [
            ("files", FileBuiltins.all.map(\.name)),
            ("text", TextBuiltins.all.map(\.name)),
            ("system", SystemBuiltins.all.map(\.name)),
            ("packages", WingetBuiltin.all.map(\.name)),
            ("runtimes", WasmBuiltin.all.map(\.name)),
            ("pager", PagerBuiltins.all.map(\.name)),
            ("history", TimeMachineBuiltin.all.map(\.name)),
            ("powershell", PowerShellBuiltins.all.map(\.name)),
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
