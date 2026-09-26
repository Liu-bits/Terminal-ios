// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// PowerShell-style parameter parsing: `-Path`, `-Path value`, `-Path:value`,
/// switch parameters, plus positional arguments.
///
/// POSIX parsing (`ShellArgs`) cannot be reused: PowerShell parameters are
/// single-dash and PascalCase, so `-Recurse` would look like the five short
/// flags `R e c u r s e`. Callers pass the switch names they know so the parser
/// can tell `-Recurse` (no value) from `-Path x` (value follows).
struct PSArgs {
    var named: [String: String] = [:]
    var switches: Set<String> = []
    var positional: [String] = []

    init(_ args: [String], switchNames: Set<String> = []) {
        let loweredSwitches = Set(switchNames.map { $0.lowercased() })
        var index = 0
        var positionalOnly = false
        while index < args.count {
            let arg = args[index]
            index += 1
            if positionalOnly || !arg.hasPrefix("-") || arg == "-" || arg == "--" {
                if arg == "--" {
                    positionalOnly = true
                    continue
                }
                positional.append(arg)
                continue
            }
            var name = String(arg.drop(while: { $0 == "-" }))
            var inlineValue: String?
            if let colon = name.firstIndex(of: ":") {
                inlineValue = String(name[name.index(after: colon)...])
                name = String(name[..<colon])
            }
            let key = name.lowercased()
            if let inlineValue {
                named[key] = inlineValue
                continue
            }
            if loweredSwitches.contains(key) {
                switches.insert(key)
                continue
            }
            // A value parameter consumes the next token when it is not a
            // parameter itself.
            if index < args.count, !args[index].hasPrefix("-") {
                named[key] = args[index]
                index += 1
            } else {
                switches.insert(key)
            }
        }
    }

    func value(_ name: String) -> String? { named[name.lowercased()] }
    func has(_ name: String) -> Bool { switches.contains(name.lowercased()) || named[name.lowercased()] != nil }

    /// The target path: `-Path` / `-LiteralPath`, else the first positional.
    var path: String? {
        value("path") ?? value("literalpath") ?? positional.first
    }

    /// Remaining positionals after the path (used by cmdlets that take two).
    var restPositional: [String] {
        if value("path") != nil || value("literalpath") != nil {
            return positional
        }
        return Array(positional.dropFirst())
    }

    /// `-Value a b c` is rare; PowerShell sends an array, so join what we get.
    var values: [String] {
        var result: [String] = []
        if let single = value("value") { result.append(single) }
        result.append(contentsOf: restPositional)
        return result
    }
}

/// PowerShell-flavoured cmdlets.
///
/// Where POSIX has one tool per job, PowerShell has verb-noun cmdlets with
/// PascalCase parameters. Both live side by side here: `Get-ChildItem` and `ls`
/// are different command names over the same sandbox helpers.
enum PowerShellBuiltins {

    static let all: [ShellBuiltin] = [
        ShellBuiltin("Get-Location", "print the current location", getLocation),
        ShellBuiltin("Set-Location", "change the current location", setLocation),
        ShellBuiltin("Get-ChildItem", "list child items", getChildItem),
        ShellBuiltin("Get-Item", "describe an item", getItem),
        ShellBuiltin("Get-Content", "read the content of a file", getContent),
        ShellBuiltin("Set-Content", "write content to a file", setContent),
        ShellBuiltin("Add-Content", "append content to a file", addContent),
        ShellBuiltin("New-Item", "create a file or directory", newItem),
        ShellBuiltin("Remove-Item", "delete items", removeItem),
        ShellBuiltin("Copy-Item", "copy items", copyItem),
        ShellBuiltin("Move-Item", "move items", moveItem),
        ShellBuiltin("Rename-Item", "rename an item", renameItem),
        ShellBuiltin("Test-Path", "test whether a path exists", testPath),
        ShellBuiltin("Get-PSDrive", "list the available drives", getPSDrive),
        ShellBuiltin("Get-Process", "list running processes", getProcess),
        ShellBuiltin("Get-Command", "list available commands", getCommand),
        ShellBuiltin("Get-Help", "show help for a command", getHelp),
        ShellBuiltin("Select-String", "search for text", selectString),
        ShellBuiltin("Measure-Object", "count lines, words or characters", measureObject),
        ShellBuiltin("Sort-Object", "sort input lines", sortObject),
        ShellBuiltin("Select-Object", "pick lines by position", selectObject),
        ShellBuiltin("Where-Object", "filter lines", whereObject),
        ShellBuiltin("Write-Output", "write to the pipeline", writeOutput),
        ShellBuiltin("Write-Host", "write to the host", writeOutput),
        ShellBuiltin("Clear-Host", "clear the screen", clearHost),
        ShellBuiltin("Get-Date", "print the current date", getDate),
        ShellBuiltin("Start-Sleep", "pause for a number of seconds", startSleep)
    ]

    /// Short aliases PowerShell users type.
    static let aliases: [String: String] = [
        "gci": "Get-ChildItem",
        "gc": "Get-Content",
        "sc": "Set-Content",
        "ac": "Add-Content",
        "gl": "Get-Location",
        "sl": "Set-Location",
        "ni": "New-Item",
        "ri": "Remove-Item",
        "ci": "Copy-Item",
        "mi": "Move-Item",
        "rn": "Rename-Item",
        "si": "Set-Content",
        "gps": "Get-Process",
        "gm": "Get-Command",
        "ft": "Select-Object",
        "cls": "Clear-Host",
        "echo": "Write-Output"
    ]

    // MARK: - Location

    private static func getLocation(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        .ok(context.environment.displayPath(context.environment.currentDirectory))
    }

    private static func setLocation(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: [])
        let target = parsed.path ?? "~"
        guard context.environment.changeDirectory(target) != nil else {
            return .fail("Set-Location: Cannot find path '\(target)' because it does not exist.")
        }
        return .ok()
    }

    private static func getPSDrive(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let root = context.environment.displayPath(context.environment.root)
        return .ok("""
        Name           Used (GB)     Free (GB) Provider      Root
        ----           ---------     --------- --------      ----
        Sandbox                 0             0 FileSystem    \(root)
        """)
    }

    // MARK: - Items

    private static func itemLines(
        _ context: ShellRunContext,
        path: String,
        filter: String?,
        recurse: Bool,
        force: Bool
    ) -> [String] {
        guard let url = context.url(for: path) else { return [] }
        var isDir: ObjCBool = false
        guard context.fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return []
        }
        let display = context.environment.displayPath(url)
        if !isDir.boolValue {
            return [display]
        }
        var lines: [String] = []
        func visit(_ directory: URL, _ displayPath: String, _ depth: Int) {
            let children = (try? context.fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in children.sorted() {
                if !force, name.hasPrefix(".") { continue }
                if let filter, !filter.isEmpty, !matchesFilter(name, filter) { continue }
                let child = directory.appendingPathComponent(name)
                lines.append(displayPath == "~" ? "~\\\(name)" : "\(displayPath)\\\(name)")
                var childIsDir: ObjCBool = false
                if recurse,
                   context.fileManager.fileExists(atPath: child.path, isDirectory: &childIsDir),
                   childIsDir.boolValue {
                    visit(child, displayPath == "~" ? "~\\\(name)" : "\(displayPath)\\\(name)", depth + 1)
                }
            }
        }
        visit(url, display, 1)
        return lines
    }

    /// PowerShell wildcard match, limited to `*` and `?`.
    private static func matchesFilter(_ name: String, _ filter: String) -> Bool {
        let pattern = "^" + filter
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".") + "$"
        return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func getChildItem(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: ["recurse", "force"])
        let lines = itemLines(
            context,
            path: parsed.path ?? ".",
            filter: parsed.value("filter"),
            recurse: parsed.has("recurse"),
            force: parsed.has("force")
        )
        if lines.isEmpty, let path = parsed.path, !context.exists(path) {
            return .fail("Get-ChildItem: Cannot find path '\(path)' because it does not exist.")
        }
        return .ok(lines.joined(separator: "\n"))
    }

    private static func getItem(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: ["force"])
        let target = parsed.path ?? "."
        guard let url = context.url(for: target), context.exists(target) else {
            return .fail("Get-Item: Cannot find path '\(target)' because it does not exist.")
        }
        var isDir: ObjCBool = false
        _ = context.fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
        let size = context.readData(target)?.count ?? 0
        let kind = isDir.boolValue ? "Directory" : "File"
        return .ok("""
            Directory: \(context.environment.displayPath(url.deletingLastPathComponent()))

        Mode          Length Name
        ----          ------ ----
        \(isDir.boolValue ? "d----" : "-a---")       \(String(format: "%6d", size)) \(url.lastPathComponent)
        Type: \(kind)
        """)
    }

    private static func newItem(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: ["force"])
        guard let target = parsed.path else {
            return .fail("New-Item: missing -Path")
        }
        let type = (parsed.value("itemtype") ?? "file").lowercased()
        guard let url = context.url(for: target) else {
            return .fail("New-Item: Cannot create '\(target)'.")
        }
        if context.exists(target), !parsed.has("force") {
            return .fail("New-Item: The file '\(target)' already exists.")
        }
        if type == "directory" || type == "dir" {
            do {
                try context.fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                return .fail("New-Item: Cannot create directory '\(target)'.")
            }
        } else {
            do {
                try context.fileManager.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
            } catch {
                return .fail("New-Item: Cannot create '\(target)'.")
            }
            guard context.fileManager.createFile(atPath: url.path, contents: Data()) else {
                return .fail("New-Item: Cannot create file '\(target)'.")
            }
        }
        return .ok("""
            Directory: \(context.environment.displayPath(url.deletingLastPathComponent()))

        Mode          Length Name
        ----          ------ ----
        \(type == "file" ? "-a---" : "d----")             0 \(url.lastPathComponent)
        """)
    }

    private static func removeItem(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: ["recurse", "force"])
        var targets: [String] = []
        if let path = parsed.value("path") { targets.append(path) }
        targets.append(contentsOf: parsed.positional)
        guard !targets.isEmpty else {
            return .fail("Remove-Item: missing -Path", code: 2)
        }
        var forward: [String] = []
        if parsed.has("recurse") { forward.append("-r") }
        if parsed.has("force") { forward.append("-f") }
        forward.append(contentsOf: targets)
        return FileBuiltins.run("rm", forward, context)
    }

    private static func copyItem(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: ["recurse", "force"])
        guard let source = parsed.path ?? parsed.positional.first,
              let destination = parsed.value("destination") ?? parsed.positional.dropFirst().first else {
            return .fail("Copy-Item: needs -Path and -Destination", code: 2)
        }
        var forward: [String] = []
        if parsed.has("recurse") { forward.append("-r") }
        if parsed.has("force") { forward.append("-f") }
        forward.append(source)
        forward.append(destination)
        return FileBuiltins.run("cp", forward, context)
    }

    private static func moveItem(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: ["force"])
        guard let source = parsed.path ?? parsed.positional.first,
              let destination = parsed.value("destination") ?? parsed.positional.dropFirst().first else {
            return .fail("Move-Item: needs -Path and -Destination", code: 2)
        }
        return FileBuiltins.run("mv", [source, destination], context)
    }

    private static func renameItem(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: [])
        guard let target = parsed.path,
              let newName = parsed.value("newname") ?? parsed.restPositional.first else {
            return .fail("Rename-Item: needs -Path and -NewName", code: 2)
        }
        guard let url = context.url(for: target) else {
            return .fail("Rename-Item: Cannot find path '\(target)'.")
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try context.fileManager.moveItem(at: url, to: destination)
        } catch {
            return .fail("Rename-Item: Cannot rename '\(target)'.")
        }
        return .ok()
    }

    private static func testPath(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: ["pathonly"])
        guard let target = parsed.path else {
            return .fail("Test-Path: missing -Path", code: 2)
        }
        let exists = context.exists(target)
        return .ok(exists ? "True" : "False")
    }

    // MARK: - Content

    private static func getContent(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: [])
        let text: String
        if let path = parsed.path {
            guard let body = context.readText(path) else {
                return .fail("Get-Content: Cannot find path '\(path)' because it does not exist.")
            }
            text = body
        } else {
            text = context.stdin ?? ""
        }
        var lines = context.lines(text)
        if let head = parsed.value("head").flatMap({ Int($0) }) ?? parsed.value("totalcount").flatMap({ Int($0) }) {
            lines = Array(lines.prefix(max(0, head)))
        } else if let tail = parsed.value("tail").flatMap({ Int($0) }) {
            lines = Array(lines.suffix(max(0, tail)))
        }
        return ShellResult(output: lines.joined(separator: "\n"), exitCode: 0, clearScreen: false)
    }

    private static func setContent(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: [])
        guard let path = parsed.path else {
            return .fail("Set-Content: missing -Path", code: 2)
        }
        let payload = parsed.values.isEmpty ? [context.stdin ?? ""] : parsed.values
        // PowerShell writes line-terminated records, so the file ends with a
        // newline and a later `-Tail 1` sees the last line, not the last blob.
        guard context.writeText(lineTerminated(payload), to: path, append: false) else {
            return .fail("Set-Content: Cannot write '\(path)'.")
        }
        return .ok()
    }

    private static func addContent(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: [])
        guard let path = parsed.path else {
            return .fail("Add-Content: missing -Path", code: 2)
        }
        let payload = parsed.values.isEmpty ? [context.stdin ?? ""] : parsed.values
        guard context.writeText(lineTerminated(payload), to: path, append: true) else {
            return .fail("Add-Content: Cannot write '\(path)'.")
        }
        return .ok()
    }

    /// Joins values into line-terminated text.
    private static func lineTerminated(_ values: [String]) -> String {
        var text = values.joined(separator: "\n")
        if !text.isEmpty, !text.hasSuffix("\n") {
            text += "\n"
        }
        return text
    }

    // MARK: - Pipelines

    private static func selectString(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: ["casesensitive", "notmatch", "simplematch"])
        guard let pattern = parsed.value("pattern") ?? parsed.positional.first else {
            return .fail("Select-String: missing -Pattern", code: 2)
        }
        let text: String
        if let path = parsed.value("path") {
            guard let body = context.readText(path) else {
                return .fail("Select-String: Cannot find path '\(path)'.")
            }
            text = body
        } else {
            text = context.stdin ?? ""
        }
        let options: String.CompareOptions = parsed.has("casesensitive") ? [] : [.caseInsensitive]
        var output: [String] = []
        for (index, line) in context.lines(text).enumerated() {
            let hit = line.range(of: pattern, options: options) != nil
            if hit != parsed.has("notmatch") {
                output.append("\(index + 1):\(line)")
            }
        }
        return .ok(output.joined(separator: "\n"))
    }

    private static func measureObject(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: ["line", "word", "character", "allstats"])
        let text: String
        if let path = parsed.path {
            guard let body = context.readText(path) else {
                return .fail("Measure-Object: Cannot find path '\(path)'.")
            }
            text = body
        } else {
            text = context.stdin ?? ""
        }
        let lines = context.lines(text).count
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        let characters = text.count
        var rows: [String] = []
        if parsed.has("word") { rows.append("Words          : \(words)") }
        if parsed.has("character") { rows.append("Characters     : \(characters)") }
        if rows.isEmpty || parsed.has("line") { rows.insert("Lines          : \(lines)", at: 0) }
        return .ok("""
        Count    : \(rows.count)
        \(rows.joined(separator: "\n"))
        """)
    }

    private static func sortObject(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: ["descending", "unique"])
        let text = parsed.path.flatMap { context.readText($0) } ?? (context.stdin ?? "")
        var lines = context.lines(text).sorted()
        if parsed.has("unique") {
            var seen = Set<String>()
            lines = lines.filter { seen.insert($0).inserted }
        }
        if parsed.has("descending") {
            lines.reverse()
        }
        return .ok(lines.joined(separator: "\n"))
    }

    private static func selectObject(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        // `-First` / `-Last` / `-Skip` take values, so only `-Unique` is a switch.
        let parsed = PSArgs(args, switchNames: ["unique"])
        let text = parsed.path.flatMap { context.readText($0) } ?? (context.stdin ?? "")
        var lines = context.lines(text)
        if parsed.has("unique") {
            var seen = Set<String>()
            lines = lines.filter { seen.insert($0).inserted }
        }
        if let skip = parsed.value("skip").flatMap({ Int($0) }) {
            lines = Array(lines.dropFirst(max(0, skip)))
        }
        if let first = parsed.value("first").flatMap({ Int($0) }) {
            lines = Array(lines.prefix(max(0, first)))
        }
        if let last = parsed.value("last").flatMap({ Int($0) }) {
            lines = Array(lines.suffix(max(0, last)))
        }
        return .ok(lines.joined(separator: "\n"))
    }

    private static func whereObject(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: ["notmatch"])
        guard let pattern = parsed.value("match") ?? parsed.value("like") else {
            return .fail("Where-Object: this shell supports -Match <pattern> only (script blocks are not interpreted)", code: 2)
        }
        let text = context.stdin ?? ""
        let output = context.lines(text).filter { line in
            let hit = line.range(of: pattern, options: [.caseInsensitive]) != nil
            return hit != parsed.has("notmatch")
        }
        return .ok(output.joined(separator: "\n"))
    }

    private static func writeOutput(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: ["nonewline"])
        var values: [String] = []
        if let object = parsed.value("inputobject") {
            values.append(object)
        }
        values.append(contentsOf: parsed.positional)
        guard !values.isEmpty else {
            return .ok(context.stdin ?? "")
        }
        return .ok(values.joined(separator: " "))
    }

    private static func clearHost(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        ShellResult(output: "", exitCode: 0, clearScreen: true)
    }

    private static func getDate(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        ShellResult.ok(ShellDate.describe(Date()))
    }

    private static func startSleep(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: [])
        let seconds = parsed.value("seconds").flatMap { Double($0) }
            ?? parsed.positional.first.flatMap { Double($0) }
            ?? 1
        Thread.sleep(forTimeInterval: min(max(0, seconds), 5))
        return .ok()
    }

    private static func getProcess(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        .ok("""
           Id ProcessName
           -- -----------
            1 Terminal-ios
        """)
    }

    private static func getCommand(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: [])
        let names = ShellBuiltins.names
        let term = parsed.path?.lowercased()
        let filtered = term.map { needle in names.filter { $0.lowercased().contains(needle) } } ?? names
        guard !filtered.isEmpty else {
            return .fail("Get-Command: no command matches '\(term ?? "")'")
        }
        return .ok(filtered.joined(separator: "\n"))
    }

    private static func getHelp(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = PSArgs(args, switchNames: [])
        guard let name = parsed.path else {
            return .ok(ShellBuiltins.helpText())
        }
        guard let builtin = ShellBuiltins.lookup(name) else {
            return .fail("Get-Help: no help for '\(name)'")
        }
        return .ok("""
        NAME
            \(builtin.name)

        SYNOPSIS
            \(builtin.summary)
        """)
    }
}

/// Date formatting shared by `date` and `Get-Date`.
enum ShellDate {
    static func describe(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy h:mm:ss a"
        return formatter.string(from: date)
    }
}
