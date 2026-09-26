// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Executes a parsed script body against a live shell session.
///
/// Commands are handed back to the engine through `evaluate`, so a script uses
/// exactly the same built-ins, pipes and redirections as an interactive line.
final class ShellScriptRunner {

    private let session: ShellSession
    private let evaluate: (String) -> ShellResult
    private var lastStatus = 0

    init(session: ShellSession, evaluate: @escaping (String) -> ShellResult) {
        self.session = session
        self.evaluate = evaluate
    }

    /// Runs a script body. `name` and `positional` become `$0`-style context
    /// for the duration of the run.
    func run(_ nodes: [ShellScriptNode], name: String, positional: [String]) -> ShellResult {
        let savedPositional = [
            session.environment.variables["#"],
            session.environment.variables["@"],
            session.environment.variables["0"]
        ]
        session.setPositional(positional)
        session.environment.variables["0"] = name
        session.scriptDepth += 1

        var output: [String] = []
        execute(nodes, output: &output)

        session.scriptDepth -= 1
        session.setPositional(positional)
        session.environment.variables["#"] = savedPositional[0] ?? "0"
        session.environment.variables["@"] = savedPositional[1] ?? ""
        session.environment.variables["0"] = savedPositional[2] ?? "sh"

        return ShellResult(output: output.joined(separator: "\n"), exitCode: lastStatus, clearScreen: false)
    }

    private func execute(_ nodes: [ShellScriptNode], output: inout [String]) {
        for node in nodes {
            if session.exitStatus != nil {
                return
            }
            run(node, output: &output)
        }
    }

    private func run(_ node: ShellScriptNode, output: inout [String]) {
        switch node {
        case .command(let line):
            let result = evaluate(line)
            lastStatus = result.exitCode
            session.record(status: result.exitCode)
            let text = result.output.trimmingTrailingNewlines()
            if !text.isEmpty {
                output.append(text)
            }

        case .ifChain(let branches, let elseBody):
            for branch in branches {
                let condition = evaluate(branch.condition)
                session.record(status: condition.exitCode)
                if condition.exitCode == 0 {
                    execute(branch.body, output: &output)
                    return
                }
            }
            execute(elseBody, output: &output)

        case .forLoop(let variable, let words, let body):
            let values = words.isEmpty ? expandedPositional() : words.map { session.environment.expand($0) }
            for value in values {
                if session.exitStatus != nil { return }
                session.environment.variables[variable] = value
                execute(body, output: &output)
            }

        case .whileLoop(let condition, let body, let until):
            var guardCount = 0
            while true {
                if session.exitStatus != nil { return }
                let result = evaluate(condition)
                session.record(status: result.exitCode)
                let truth = until ? result.exitCode != 0 : result.exitCode == 0
                if !truth { break }
                execute(body, output: &output)
                guardCount += 1
                if guardCount > 10_000 {
                    output.append("sh: warning: loop stopped after 10000 iterations")
                    break
                }
            }

        case .function(let name, let body):
            session.functions[name] = body
        }
    }

    /// `for x; do ...` with no `in` list walks the positional parameters.
    private func expandedPositional() -> [String] {
        let joined = session.environment.variables["@"] ?? ""
        return joined.split(separator: " ").map(String.init)
    }
}
