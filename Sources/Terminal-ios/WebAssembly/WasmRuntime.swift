// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Runs a WebAssembly module the way a shell command needs it: parse, verify the
/// entry point, execute in-process, and hand back text plus an exit code.
///
/// This is the layer the package manager and the `wasm` command both use. It
/// never downloads anything, never spawns a process and never allocates
/// executable memory - execution happens inside this interpreter.
enum WasmRuntime {

    struct Outcome {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        /// Instructions actually executed, useful for diagnosing slow modules.
        var steps: Int
    }

    /// Entry points looked for, in order. WASI command modules export
    /// `_start`; some toolchains export `main` instead.
    static let entryPoints = ["_start", "main"]

    /// Parses and validates a module without running it.
    static func inspect(_ bytes: [UInt8]) throws -> WasmModule {
        try WasmModule.parse(bytes)
    }

    /// Runs a module. Returns stdout/stderr and the exit status, or throws a
    /// `WasmTrap` describing why it could not run.
    static func run(
        _ bytes: [UInt8],
        arguments: [String] = [],
        environment: [String: String] = [:],
        stdin: String = "",
        limits: WasmInstance.Limits = WasmInstance.Limits()
    ) throws -> Outcome {
        let module = try WasmModule.parse(bytes)
        let host = WASIHost(arguments: arguments, environment: environment, stdin: stdin)
        let instance = try WasmInstance(module: module, host: host, limits: limits)

        var exitCode: Int32 = 0
        let entry = entryPoints.first { name in
            if let exported = module.export(named: name) {
                return exported.kind == 0
            }
            return false
        }
        if let entry {
            do {
                _ = try instance.invoke(export: entry)
            } catch let signal as WasmExitSignal {
                exitCode = signal.code
            }
        } else if module.startFunction == nil {
            throw WasmTrap.runtime(
                "module exports no entry point (looked for \(entryPoints.joined(separator: ", ")); exports: \(module.exportNames.joined(separator: ", ")))"
            )
        }

        if let hostExit = host.exitCode {
            exitCode = hostExit
        }
        return Outcome(
            exitCode: exitCode,
            stdout: host.stdoutText,
            stderr: host.stderrText,
            steps: instance.executedSteps
        )
    }

    /// A one-line summary used by `wasm info`.
    static func describe(_ bytes: [UInt8]) throws -> String {
        let module = try WasmModule.parse(bytes)
        var lines: [String] = []
        let defined = module.functions.count - module.importedFunctionCount
        lines.append("size:        \(bytes.count) bytes")
        lines.append("functions:   \(defined) defined, \(module.importedFunctionCount) imported")
        lines.append("memory:      \(module.memoryPageCount) pages (\(module.memoryPageCount * 64) KiB)")
        if let table = module.tableLimits {
            lines.append("table:       \(table.minimum) entries")
        }
        lines.append("globals:     \(module.globals.count)")
        lines.append("data:        \(module.dataSegments.count) segment(s)")
        if let start = module.startFunction {
            lines.append("start:       function #\(start)")
        }
        if !module.imports.isEmpty {
            let names = module.imports.map { "\($0.module).\($0.field)" }
            lines.append("imports:     \(names.joined(separator: ", "))")
        }
        lines.append("exports:     \(module.exportNames.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }
}
