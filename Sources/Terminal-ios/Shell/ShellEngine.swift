// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Result of running one command line.
struct ShellResult {
    var output: String
    var exitCode: Int
    var clearScreen: Bool

    static func output(_ text: String, exitCode: Int = 0) -> ShellResult {
        ShellResult(output: text, exitCode: exitCode, clearScreen: false)
    }
}

/// Executes shell lines against a sandboxed file system.
///
/// Pure Swift: no UIKit, no processes, no network. The command table lives in
/// `ShellBuiltins`; this type owns the session (variables, functions, exit
/// state), the pipeline/redirection machinery, `$(...)` substitution and the
/// script interpreter.
final class ShellEngine {

    let session: ShellSession
    private(set) var history: [String]

    /// Working directory plus `$VAR` values. Mutating this writes through to
    /// the session so every command sees the same environment.
    var environment: ShellEnvironment {
        get { session.environment }
        set { session.environment = newValue }
    }

    /// Shell functions defined in this session.
    var functions: [String: [ShellScriptNode]] {
        session.functions
    }

    init(environment: ShellEnvironment = ShellEnvironment(), history: [String] = []) {
        self.session = ShellSession(environment: environment)
        self.history = history
        bootstrapEnvironment()
    }

    /// Seeds the handful of variables scripts expect to exist.
    private func bootstrapEnvironment() {
        var variables = session.environment.variables
        variables["SHELL"] = "/bin/sh"
        variables["0"] = "sh"
        if variables["USER"] == nil { variables["USER"] = "user" }
        if variables["HOME"] == nil { variables["HOME"] = "~" }
        if variables["PATH"] == nil { variables["PATH"] = "/usr/bin:/bin:~/.packages/bin" }
        if variables["TERM"] == nil { variables["TERM"] = "xterm-256color" }
        if variables["?"] == nil { variables["?"] = "0" }
        if variables["#"] == nil { variables["#"] = "0" }
        if variables["@"] == nil { variables["@"] = "" }
        session.environment.variables = variables
        syncWorkingDirectory()
    }

    /// Keeps `$PWD` in step with the real working directory.
    private func syncWorkingDirectory() {
        session.environment.variables["PWD"] = session.environment.displayPath(
            session.environment.currentDirectory
        )
    }

    // MARK: - Entry points

    /// Runs one interactive line. Returns output text plus a clear-screen flag.
    @discardableResult
    func run(_ line: String) -> ShellResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .output("")
        }
        history.append(line)
        session.exitStatus = nil
        var result = executeLine(trimmed)
        session.record(status: result.exitCode)
        // Like command substitution: the final output never carries trailing
        // newlines, while pipeline stages and files keep theirs.
        while result.output.hasSuffix("\n") {
            result.output.removeLast()
        }
        return result
    }

    /// Runs a script body (used by `sh file.sh`, `source`, functions and the
    /// tests). `name` becomes `$0`, `args` becomes `$1`, `$2`, ... and `stdin`
    /// fills the input queue that `read` consumes.
    func runScript(
        _ source: String,
        name: String = "sh",
        args: [String] = [],
        stdin: String? = nil
    ) -> ShellResult {
        let nodes = ShellScriptParser.parse(source)
        var result = runNodes(nodes, name: name, args: args, stdin: stdin)
        session.exitStatus = nil
        session.record(status: result.exitCode)
        while result.output.hasSuffix("\n") {
            result.output.removeLast()
        }
        return result
    }

    /// Shared script execution path: saves the input queue, runs the runner and
    /// restores the queue so nested scripts cannot steal each other's input.
    private func runNodes(
        _ nodes: [ShellScriptNode],
        name: String,
        args: [String],
        stdin: String?
    ) -> ShellResult {
        let savedInput = session.setInput(stdin)
        let runner = ShellScriptRunner(session: session) { [weak self] line in
            self?.executeLine(line) ?? .output("")
        }
        let result = runner.run(nodes, name: name, positional: args)
        session.restoreInput(savedInput)
        return result
    }

    // MARK: - Line execution

    private func executeLine(_ line: String) -> ShellResult {
        let interpolated = interpolate(line)
        guard let tokens = ShellTokenizer.tokenize(interpolated) else {
            return .output("syntax error: unterminated quote", exitCode: 2)
        }
        guard !tokens.isEmpty, let ast = ShellParser.parse(tokens) else {
            return .output("syntax error: invalid command", exitCode: 2)
        }
        return evaluate(ast)
    }

    /// Expands `$(command)` and `` `command` `` before parsing.
    ///
    /// Single quotes suppress substitution, double quotes allow it, and nested
    /// `$(...)` is handled by counting parentheses.
    private func interpolate(_ line: String) -> String {
        var result = ""
        let characters = Array(line)
        var index = 0
        var inSingle = false
        var inDouble = false
        while index < characters.count {
            let char = characters[index]
            if char == "'", !inDouble {
                inSingle.toggle()
                result.append(char)
                index += 1
                continue
            }
            if char == "\"", !inSingle {
                inDouble.toggle()
                result.append(char)
                index += 1
                continue
            }
            if !inSingle, char == "$", index + 1 < characters.count, characters[index + 1] == "(" {
                if let (body, next) = captureBalanced(characters, from: index + 2) {
                    result += substitute(body)
                    index = next
                    continue
                }
            }
            if !inSingle, char == "`" {
                var body = ""
                var cursor = index + 1
                var closed = false
                while cursor < characters.count {
                    if characters[cursor] == "`" {
                        closed = true
                        cursor += 1
                        break
                    }
                    body.append(characters[cursor])
                    cursor += 1
                }
                if closed {
                    result += substitute(body)
                    index = cursor
                    continue
                }
            }
            result.append(char)
            index += 1
        }
        return result
    }

    /// Reads a balanced `$( ... )` body. Returns the body and the index just
    /// past the closing parenthesis.
    private func captureBalanced(_ characters: [Character], from start: Int) -> (String, Int)? {
        var depth = 1
        var index = start
        var body = ""
        while index < characters.count {
            let char = characters[index]
            if char == "(" {
                depth += 1
            } else if char == ")" {
                depth -= 1
                if depth == 0 {
                    return (body, index + 1)
                }
            }
            body.append(char)
            index += 1
        }
        return nil
    }

    /// Runs the body of a substitution and trims the trailing newlines, the
    /// way a real shell does. An `exit` inside a substitution must not end the
    /// surrounding script, so the exit state is restored afterwards.
    private func substitute(_ body: String) -> String {
        let savedExit = session.exitStatus
        var result = executeLine(body.trimmingCharacters(in: .whitespaces))
        session.exitStatus = savedExit
        while result.output.hasSuffix("\n") {
            result.output.removeLast()
        }
        return result.output
    }

    // MARK: - Evaluation

    private func evaluate(_ node: ShellAST) -> ShellResult {
        switch node {
        case .empty:
            return .output("")
        case .pipeline(let commands):
            return evaluatePipeline(commands)
        case .and(let left, let right):
            let first = evaluate(left)
            if first.clearScreen {
                return first
            }
            guard first.exitCode == 0 else {
                return first
            }
            return combine(first, evaluate(right))
        case .or(let left, let right):
            let first = evaluate(left)
            if first.clearScreen {
                return first
            }
            guard first.exitCode != 0 else {
                return first
            }
            return combine(first, evaluate(right))
        case .sequence(let left, let right):
            let first = evaluate(left)
            if first.clearScreen {
                return first
            }
            return combine(first, evaluate(right))
        }
    }

    /// Merges two evaluated results: outputs concatenate, the right side's
    /// exit state wins (the right side is the last command that ran). The left
    /// side's output is dropped when it failed — its message would just be
    /// noise before whatever `||`/`;` ran next, and the exit status carries
    /// the failure instead.
    private func combine(_ first: ShellResult, _ second: ShellResult) -> ShellResult {
        var combined = first.exitCode == 0 ? first.output.trimmingTrailingNewlines() : ""
        let tail = second.output.trimmingTrailingNewlines()
        if !combined.isEmpty, !tail.isEmpty {
            combined += "\n"
        }
        combined += tail
        return ShellResult(
            output: combined,
            exitCode: second.exitCode,
            clearScreen: second.clearScreen
        )
    }

    private func evaluatePipeline(_ commands: [ShellCommand]) -> ShellResult {
        var stdin: String?
        var lastExit = 0
        var output = ""
        for command in commands {
            let expanded = command.argv.map { environment.expand($0) }
            // A stage is runnable when it has argv, `< file`, or both; a bare
            // `> file` with no command still creates/truncates the file.
            guard !expanded.isEmpty || command.stdinFile != nil || command.stdoutFile != nil else {
                continue
            }
            let step = runCommand(
                argv: expanded,
                stdin: stdin,
                stdinFile: command.stdinFile.map { environment.expand($0) }
            )
            lastExit = step.exitCode
            // Record after every stage so `$?` reflects the command that ran
            // last inside `a; b` and `a && b`, not just the whole line.
            session.record(status: step.exitCode)
            if step.clearScreen {
                return ShellResult(
                    output: step.output,
                    exitCode: step.exitCode,
                    clearScreen: true
                )
            }
            // Redirection wins over the pipe for that stage; the next stage
            // then reads empty input. Matches the documented simplification.
            if let file = command.stdoutFile.map({ environment.expand($0) }) {
                writeOutput(step.output, to: file, append: command.stdoutAppend)
                stdin = ""
                output = ""
            } else {
                stdin = step.output
                output = step.output
            }
        }
        return ShellResult(output: output, exitCode: lastExit, clearScreen: false)
    }

    // MARK: - Commands

    private struct StepResult {
        var output: String
        var exitCode: Int
        var clearScreen: Bool

        init(_ result: ShellResult) {
            output = result.output
            exitCode = result.exitCode
            clearScreen = result.clearScreen
        }

        init(output: String, exitCode: Int, clearScreen: Bool) {
            self.output = output
            self.exitCode = exitCode
            self.clearScreen = clearScreen
        }
    }

    private func runCommand(argv: [String], stdin: String?, stdinFile: String?) -> StepResult {
        let input: String?
        if let stdinFile {
            guard let url = environment.resolve(stdinFile),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return StepResult(
                    output: "\(argv.first ?? "cat"): \(stdinFile): No such file",
                    exitCode: 1,
                    clearScreen: false
                )
            }
            input = text
        } else {
            input = stdin
        }
        guard let name = argv.first, !name.isEmpty else {
            return StepResult(output: input ?? "", exitCode: 0, clearScreen: false)
        }
        let args = Array(argv.dropFirst())

        // A bare assignment (`total=0`) sets a variable, like every shell.
        if args.isEmpty, let equals = name.firstIndex(of: "="), equals != name.startIndex {
            let key = String(name[..<equals])
            let isIdentifier = !key.isEmpty
                && !(key.first?.isNumber ?? true)
                && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            if isIdentifier {
                environment.variables[key] = String(name[name.index(after: equals)...])
                return StepResult(output: "", exitCode: 0, clearScreen: false)
            }
        }

        switch name {
        case "cd":
            if args.count > 1 {
                return StepResult(output: "cd: too many arguments", exitCode: 1, clearScreen: false)
            }
            if environment.changeDirectory(args.first) == nil {
                return StepResult(
                    output: "cd: \(args.first ?? ""): No such directory",
                    exitCode: 1,
                    clearScreen: false
                )
            }
            syncWorkingDirectory()
            return StepResult(output: "", exitCode: 0, clearScreen: false)
        case "pwd":
            return StepResult(
                output: environment.displayPath(environment.currentDirectory),
                exitCode: 0,
                clearScreen: false
            )
        case "clear":
            return StepResult(output: "", exitCode: 0, clearScreen: true)
        case "history":
            let lines = history.enumerated().map { "\($0.offset + 1)  \($0.element)" }
            return StepResult(output: lines.joined(separator: "\n"), exitCode: 0, clearScreen: false)
        case "exit":
            let status = args.first.flatMap { Int($0) } ?? 0
            session.exitStatus = status
            return StepResult(output: "", exitCode: status, clearScreen: false)
        default:
            break
        }

        if let body = session.functions[name] {
            // An `exit` inside the function sets `session.exitStatus`, which the
            // runner turns into an early return and which the caller sees.
            return StepResult(runNodes(body, name: name, args: args, stdin: input))
        }

        let context = makeContext(stdin: input)
        if let builtin = ShellBuiltins.table[name] {
            let result = builtin.run(args, context)
            // Built-ins may mutate variables (`export`, `unset`, `read`).
            session.environment = context.environment
            return StepResult(result)
        }

        // A package installed from the catalog can provide this command.
        let manager = context.packages()
        if let script = manager.script(for: name) {
            return StepResult(runScript(script.body, name: name, args: args, stdin: input))
        }

        // Or the command is a script file on disk (`./build.sh`, `tools/run`).
        if let url = environment.resolve(name),
           FileManager.default.fileExists(atPath: url.path),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return StepResult(runScript(text, name: name, args: args, stdin: input))
        }

        return StepResult(output: "\(name): command not found", exitCode: 127, clearScreen: false)
    }

    /// Builds the context handed to a built-in, wiring the engine hooks.
    private func makeContext(stdin: String?) -> ShellRunContext {
        let context = ShellRunContext(environment: session.environment, stdin: stdin) { [weak self] line in
            self?.executeLine(line) ?? .output("")
        }
        context.runScript = { [weak self] body, name, positional, nestedInput in
            self?.runScript(body, name: name, args: positional, stdin: nestedInput)
                ?? .fail("sh: script execution unavailable")
        }
        context.commandResolver = { [weak self] command in
            self?.resolveCommand(command)
        }
        context.session = session
        return context
    }

    /// Human-readable resolution of a command name, for `which` and `type`.
    private func resolveCommand(_ name: String) -> String? {
        if session.functions[name] != nil {
            return "a shell function"
        }
        let manager = PackageManager(stateDirectory: environment.root)
        if let entry = manager.catalog.entry(providing: name), manager.isInstalled(entry.name) {
            return manager.binDirectory.appendingPathComponent(name).path
        }
        if let url = environment.resolve(name), FileManager.default.fileExists(atPath: url.path) {
            let display = environment.displayPath(url)
            return display == name ? "./\(display)" : display
        }
        return nil
    }

    private func writeOutput(_ text: String, to file: String, append: Bool) {
        guard let url = environment.resolve(file) else {
            return
        }
        // Files are line-oriented: anything written gets its trailing newline,
        // so later `>>` appends start on a fresh line.
        var payload = text
        if !payload.isEmpty, !payload.hasSuffix("\n") {
            payload += "\n"
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if append, let existing = try? String(contentsOf: url, encoding: .utf8) {
            try? (existing + payload).write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? payload.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
