// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Mutable state handed to every built-in command.
///
/// Built-ins never touch UIKit or the network; everything they need is here.
/// The engine owns this object for the duration of one command stage and
/// discards it afterwards, so writing to it cannot leak between stages.
final class ShellRunContext {

    /// Working directory plus `$VAR` values.
    var environment: ShellEnvironment

    /// Input for this stage: piped output, or the contents of `< file`.
    var stdin: String?

    /// Offline package manager backing `apt` / `apk` / `pip`. Created lazily
    /// because most commands never touch it.
    private var packageManager: PackageManager?

    /// Runs another shell line through the owning engine. Used by `sh -c`,
    /// `eval` and `$(...)` command substitution.
    let evaluate: (String) -> ShellResult

    /// Runs a script body: `(source, displayName, positionalArguments, stdin)`.
    /// Installed by the engine, which owns the script interpreter and the
    /// function table.
    var runScript: ((String, String, [String], String?) -> ShellResult)?

    /// Resolves a command name to a path or an explanation. Installed by the
    /// engine so `which`, `type` and `command -v` can see scripts on disk and
    /// commands provided by installed packages.
    var commandResolver: ((String) -> String?)?

    /// The owning session, so commands such as `read` can consume script input.
    var session: ShellSession?

    /// Snapshots of past runs. The engine replaces this with the persistent
    /// store; the in-memory default keeps a context usable on its own.
    var snapshots: HistoryStore = MemoryHistoryStore()

    /// True when this command may take the screen and wait for keys.
    ///
    /// Off by default: only `ShellEngine.runInteractive` turns it on, and only
    /// for a lone command with no pipe or redirection. Everything else (scripts,
    /// functions, pipelines, the tests) sees the same value as before.
    var interactive = false

    /// Screen size for commands that need one, from `$LINES` / `$COLUMNS`.
    var terminalRows: Int {
        Int(environment.variables["LINES"] ?? "") ?? 24
    }

    var terminalColumns: Int {
        Int(environment.variables["COLUMNS"] ?? "") ?? 80
    }

    /// Whether commands should emit ANSI colour.
    ///
    /// Off by default, so pipes, tests and captured output compare plain text.
    /// The engine turns it on from the environment (`CLICOLOR`), which is the
    /// switch GNU tools already read - the terminal sets it, `cron` does not.
    var colorizeOutput = false

    /// Wraps `text` in `style` when colour is on, otherwise returns it as is.
    func color(_ style: TerminalStyle, _ text: String) -> String {
        colorizeOutput ? text.styled(style) : text
    }

    /// Wraps `text` in `style` when `policy` resolves to enabled.
    func color(_ style: TerminalStyle, _ text: String, policy: ColorPolicy) -> String {
        policy.isEnabled(self) ? text.styled(style) : text
    }

    init(
        environment: ShellEnvironment,
        stdin: String?,
        evaluate: @escaping (String) -> ShellResult
    ) {
        self.environment = environment
        self.stdin = stdin
        self.evaluate = evaluate
    }

    /// The package manager, bound to the sandbox root so installed state stays
    /// inside the app container.
    func packages() -> PackageManager {
        if let packageManager {
            return packageManager
        }
        let manager = PackageManager(stateDirectory: environment.root)
        packageManager = manager
        return manager
    }
}

/// A single built-in command.
struct ShellBuiltin {
    let name: String
    let summary: String
    let run: ([String], ShellRunContext) -> ShellResult

    init(_ name: String, _ summary: String, _ run: @escaping ([String], ShellRunContext) -> ShellResult) {
        self.name = name
        self.summary = summary
        self.run = run
    }
}

/// Result helpers shared by the built-ins.
extension ShellResult {

    /// Success with output.
    static func ok(_ output: String = "") -> ShellResult {
        ShellResult(output: output, exitCode: 0, clearScreen: false)
    }

    /// Failure with a message on stdout (the terminal renders one stream).
    static func fail(_ message: String, code: Int = 1) -> ShellResult {
        ShellResult(output: message, exitCode: code, clearScreen: false)
    }
}

// MARK: - Argument parsing

/// Parsed command line: short flags (`-la`, `-n5`), long flags (`--all`),
/// flags that take a value, and the remaining operands.
struct ShellArgs {
    var flags: Set<Character> = []
    var values: [Character: String] = [:]
    var longFlags: Set<String> = []
    var longValues: [String: String] = [:]
    var operands: [String] = []

    /// Short flag test (`-l`).
    ///
    /// There is deliberately no `has(_ flag: String)` overload: with one, a
    /// literal like `"l"` binds to the String version, every short flag looks
    /// absent, and commands silently ignore their options. Long flags have
    /// separate, explicitly named accessors for the same reason.
    func has(_ flag: Character) -> Bool { flags.contains(flag) }

    /// Long flag test (`--all`).
    func hasLong(_ name: String) -> Bool { longFlags.contains(name) }

    /// Value of a short flag that takes one (`-n 5` / `-n5`).
    func value(_ flag: Character) -> String? { values[flag] }

    /// Value of a long flag that takes one (`--max=3`).
    func longValue(_ name: String) -> String? { longValues[name] }

    /// Splits `args` into flags and operands.
    ///
    /// - Parameters:
    ///   - valueFlags: short flags that consume a value (`-n 5` or `-n5`).
    ///   - longValueFlags: long flags that consume a value (`--max=3`).
    ///   - stopAtFirstOperand: when true, the first non-flag ends parsing
    ///     (used by commands where flags must come first).
    static func parse(
        _ args: [String],
        valueFlags: Set<Character> = [],
        longValueFlags: Set<String> = [],
        stopAtFirstOperand: Bool = false
    ) -> ShellArgs {
        var parsed = ShellArgs()
        var index = 0
        var optionsDone = false
        while index < args.count {
            let arg = args[index]
            index += 1
            if optionsDone || arg == "-" || !arg.hasPrefix("-") {
                parsed.operands.append(arg)
                if stopAtFirstOperand {
                    optionsDone = true
                }
                continue
            }
            if arg == "--" {
                optionsDone = true
                continue
            }
            if arg.hasPrefix("--") {
                let body = String(arg.dropFirst(2))
                let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                if parts.count == 2 {
                    parsed.longValues[name] = String(parts[1])
                } else if longValueFlags.contains(name), index < args.count {
                    parsed.longValues[name] = args[index]
                    index += 1
                } else {
                    parsed.longFlags.insert(name)
                }
                continue
            }
            let body = Array(arg.dropFirst())
            var position = 0
            while position < body.count {
                let flag = body[position]
                position += 1
                if valueFlags.contains(flag) {
                    let rest = String(body[position...])
                    if !rest.isEmpty {
                        parsed.values[flag] = rest
                    } else if index < args.count {
                        parsed.values[flag] = args[index]
                        index += 1
                    }
                    break
                }
                parsed.flags.insert(flag)
            }
        }
        return parsed
    }
}

// MARK: - Shared file helpers

extension String {
    /// Drops trailing newlines. Built-ins return POSIX-shaped output (with a
    /// trailing newline); joining two of those needs the newlines removed first
    /// or every chained command grows a blank line.
    func trimmingTrailingNewlines() -> String {
        var text = self
        while text.hasSuffix("\n") {
            text.removeLast()
        }
        return text
    }
}

extension ShellRunContext {

    var fileManager: FileManager { FileManager.default }

    /// Resolves a path inside the sandbox, or `nil` when it would escape.
    func url(for path: String) -> URL? {
        environment.resolve(path)
    }

    /// Reads a UTF-8 file, or `nil` when it is missing or not text.
    func readText(_ path: String) -> String? {
        guard let url = url(for: path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Reads binary content (used by `base64`, `sha256sum`).
    func readData(_ path: String) -> Data? {
        guard let url = url(for: path) else { return nil }
        return try? Data(contentsOf: url)
    }

    func isDirectory(_ path: String) -> Bool {
        guard let url = url(for: path) else { return false }
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    func exists(_ path: String) -> Bool {
        guard let url = url(for: path) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    /// Writes text, creating parent directories, and appending when asked.
    @discardableResult
    func writeText(_ text: String, to path: String, append: Bool) -> Bool {
        guard let url = url(for: path) else { return false }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if append, let existing = try? String(contentsOf: url, encoding: .utf8) {
            return (try? (existing + text).write(to: url, atomically: true, encoding: .utf8)) != nil
        }
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    /// Writes bytes, creating parent directories, and appending when asked.
    ///
    /// Mirrors `writeText` because archives and compressed files are binary; the
    /// same sandbox resolution applies, so nothing can write outside the root.
    @discardableResult
    func writeData(_ data: Data, to path: String, append: Bool = false) -> Bool {
        guard let url = url(for: path) else { return false }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if append, let existing = try? Data(contentsOf: url) {
            return (try? (existing + data).write(to: url, options: .atomic)) != nil
        }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Input for a filter command: piped text, or the files named as operands.
    /// Returns `nil` when a named file cannot be read (caller reports the error).
    func inputText(named files: [String], command: String) -> (text: String?, failure: ShellResult?) {
        if files.isEmpty {
            return (stdin ?? "", nil)
        }
        var parts: [String] = []
        for file in files {
            if file == "-" {
                parts.append(stdin ?? "")
                continue
            }
            guard let text = readText(file) else {
                return (nil, .fail("\(command): \(file): No such file or directory"))
            }
            parts.append(text)
        }
        return (parts.joined(separator: "\n"), nil)
    }

    /// Splits text into lines, dropping a single trailing empty element so
    /// `printf 'a\n' | wc -l` counts one line rather than two.
    func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" {
            parts.removeLast()
        }
        return parts
    }

    /// The short display name for a path, matching `basename` semantics.
    static func baseName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
