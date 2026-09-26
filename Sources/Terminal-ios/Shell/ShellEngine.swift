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

/// Executes parsed shell lines against a sandboxed file system.
///
/// Pure Swift, no UIKit, no processes, no network. Built-ins: `cd`, `ls`,
/// `pwd`, `cat`, `echo`, `env`, `export`, `clear`, `history`.
final class ShellEngine {

    var environment: ShellEnvironment
    private(set) var history: [String]

    init(environment: ShellEnvironment = ShellEnvironment(), history: [String] = []) {
        self.environment = environment
        self.history = history
    }

    /// Runs one line. Returns output text plus a clear-screen flag.
    @discardableResult
    func run(_ line: String) -> ShellResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .output("")
        }
        history.append(line)
        guard let tokens = ShellTokenizer.tokenize(trimmed) else {
            return .output("syntax error: unterminated quote", exitCode: 2)
        }
        guard !tokens.isEmpty, let ast = ShellParser.parse(tokens) else {
            return .output("syntax error: invalid command", exitCode: 2)
        }
        // Like shell command substitution: the final output never carries
        // trailing newlines, while pipeline stages and files keep theirs.
        var result = evaluate(ast)
        while result.output.hasSuffix("\n") {
            result.output.removeLast()
        }
        return result
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
        var combined = first.exitCode == 0 ? first.output : ""
        if !combined.isEmpty, !second.output.isEmpty {
            combined += "\n"
        }
        combined += second.output
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
    }

    private func runCommand(argv: [String], stdin: String?, stdinFile: String?) -> StepResult {
        let input: String?
        if let stdinFile {
            guard let url = environment.resolve(stdinFile),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return StepResult(output: "\(argv.first ?? "cat"): \(stdinFile): No such file", exitCode: 1, clearScreen: false)
            }
            input = text
        } else {
            input = stdin
        }
        guard let name = argv.first, !name.isEmpty else {
            return StepResult(output: input ?? "", exitCode: 0, clearScreen: false)
        }
        let args = Array(argv.dropFirst())
        switch name {
        case "cd":
            if args.count > 1 {
                return StepResult(output: "cd: too many arguments", exitCode: 1, clearScreen: false)
            }
            if environment.changeDirectory(args.first) == nil {
                return StepResult(output: "cd: \(args.first ?? ""): No such directory", exitCode: 1, clearScreen: false)
            }
            return StepResult(output: "", exitCode: 0, clearScreen: false)
        case "pwd":
            return StepResult(output: environment.displayPath(environment.currentDirectory), exitCode: 0, clearScreen: false)
        case "echo":
            return StepResult(output: args.joined(separator: " "), exitCode: 0, clearScreen: false)
        case "env":
            let lines = environment.variables.sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
            return StepResult(output: lines.joined(separator: "\n"), exitCode: 0, clearScreen: false)
        case "export":
            for assignment in args {
                if let equals = assignment.firstIndex(of: "=") {
                    let key = String(assignment[..<equals])
                    let value = String(assignment[assignment.index(after: equals)...])
                    if !key.isEmpty {
                        environment.variables[key] = value
                    }
                } else if !assignment.isEmpty {
                    environment.variables[assignment] = environment.variables[assignment] ?? ""
                }
            }
            return StepResult(output: "", exitCode: 0, clearScreen: false)
        case "clear":
            return StepResult(output: "", exitCode: 0, clearScreen: true)
        case "history":
            let lines = history.enumerated().map { "\($0.offset + 1)  \($0.element)" }
            return StepResult(output: lines.joined(separator: "\n"), exitCode: 0, clearScreen: false)
        case "ls":
            return runLs(args: args)
        case "cat":
            return runCat(args: args, stdin: input)
        default:
            return StepResult(output: "\(name): command not found", exitCode: 127, clearScreen: false)
        }
    }

    private func runLs(args: [String]) -> StepResult {
        let targets = args.isEmpty ? ["~"] : args
        var lines: [String] = []
        for target in targets {
            guard let url = environment.resolve(target) else {
                return StepResult(output: "ls: \(target): No such file or directory", exitCode: 1, clearScreen: false)
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                return StepResult(output: "ls: \(target): No such file or directory", exitCode: 1, clearScreen: false)
            }
            if isDir.boolValue {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted() ?? []
                if targets.count > 1 {
                    lines.append("\(target):")
                }
                lines.append(contentsOf: names)
            } else {
                lines.append(url.lastPathComponent)
            }
        }
        return StepResult(output: lines.joined(separator: "\n"), exitCode: 0, clearScreen: false)
    }

    private func runCat(args: [String], stdin: String?) -> StepResult {
        if args.isEmpty {
            return StepResult(output: stdin ?? "", exitCode: 0, clearScreen: false)
        }
        var parts: [String] = []
        for target in args {
            if target == "-" {
                parts.append(stdin ?? "")
                continue
            }
            guard let url = environment.resolve(target),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return StepResult(output: "cat: \(target): No such file", exitCode: 1, clearScreen: false)
            }
            parts.append(text)
        }
        return StepResult(output: parts.joined(separator: "\n"), exitCode: 0, clearScreen: false)
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
