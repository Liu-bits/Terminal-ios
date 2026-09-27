// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// The `wasm` command: run and inspect WebAssembly modules that live in the
/// sandbox, plus the version of the engine.
///
/// This is how a packaged tool actually executes: `apt install hello-wasm`
/// materialises a module, and the shim ends up here. Execution is in-process
/// (interpreter mode, no JIT), the module gets no file-system access and an
/// instruction budget, so a bad module traps instead of hanging the terminal.
enum WasmBuiltin {

    static let engineVersion = "terminal-wasm 0.1.0 (interpreter, no JIT)"

    static let all: [ShellBuiltin] = [
        ShellBuiltin("wasm", "run or inspect a WebAssembly module", wasm)
    ]

    private static func wasm(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, valueFlags: ["e"])
        // `--version` / `-v` are options, so they never reach the operands.
        if parsed.hasLong("version") || parsed.hasLong("help") || parsed.has("v") || parsed.has("h") {
            return parsed.hasLong("help") || parsed.has("h") ? .ok(usage) : .ok(engineVersion)
        }
        let operands = parsed.operands
        guard let verb = operands.first else {
            return .ok(usage)
        }
        switch verb {
        case "--version", "-v", "version":
            return .ok(engineVersion)
        case "run":
            let rest = Array(operands.dropFirst())
            guard let path = rest.first else {
                return .fail("wasm run: needs a module path", code: 2)
            }
            return run(path: path, arguments: Array(rest.dropFirst()), context)
        case "info", "inspect":
            guard let path = operands.dropFirst().first else {
                return .fail("wasm info: needs a module path", code: 2)
            }
            return info(path: path, context)
        default:
            return .fail("wasm: unknown verb '\(verb)'\n\n\(usage)", code: 2)
        }
    }

    private static let usage = """
    usage: wasm <verb>

      run <module.wasm> [args...]   execute a module (WASI subset, no JIT)
      info <module.wasm>            print sections, imports and exports
      version                       print the engine version

    Modules run inside this process: no file access, no sockets, no processes.
    """

    static func run(path: String, arguments: [String], _ context: ShellRunContext) -> ShellResult {
        guard let bytes = context.readData(path) else {
            return .fail("wasm: \(path): No such file or directory", code: 1)
        }
        let outcome = execute([UInt8](bytes), name: path, arguments: [path] + arguments, context)
        // Errors from `execute` are already prefixed; the happy path is not.
        return outcome
    }

    /// Runs module bytes as a command. Used by `wasm run` and by the engine
    /// when a catalog package provides a wasm-backed command.
    static func execute(
        _ bytes: [UInt8],
        name: String,
        arguments: [String],
        _ context: ShellRunContext
    ) -> ShellResult {
        do {
            let outcome = try WasmRuntime.run(
                bytes,
                arguments: arguments,
                environment: context.environment.variables,
                stdin: context.stdin ?? ""
            )
            var text = outcome.stdout
            if !outcome.stderr.isEmpty {
                if !text.isEmpty, !text.hasSuffix("\n") {
                    text += "\n"
                }
                text += outcome.stderr
            }
            return ShellResult(output: text, exitCode: Int(outcome.exitCode), clearScreen: false)
        } catch let trap as WasmTrap {
            return .fail("\(name): \(trap.message)", code: 1)
        } catch {
            return .fail("\(name): \(error)", code: 1)
        }
    }

    private static func info(path: String, _ context: ShellRunContext) -> ShellResult {
        guard let bytes = context.readData(path) else {
            return .fail("wasm: \(path): No such file or directory", code: 1)
        }
        do {
            return .ok(try WasmRuntime.describe([UInt8](bytes)))
        } catch let trap as WasmTrap {
            return .fail("wasm: \(path): \(trap.message)", code: 1)
        } catch {
            return .fail("wasm: \(path): \(error)", code: 1)
        }
    }
}
