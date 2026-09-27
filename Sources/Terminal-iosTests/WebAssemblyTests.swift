// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Foundation
import Testing

/// The WebAssembly interpreter.
///
/// Every fixture is hand-assembled by `support/wasm_fixtures.py` and was
/// validated with Node's WebAssembly implementation first; the expected values
/// here are exactly what Node produced, so a regression in the interpreter
/// cannot be mistaken for a bug in the fixture.
struct WebAssemblyTests {

    /// Small budgets so a runaway module fails fast instead of burning the
    /// default 20 million instructions.
    private let limits = WasmInstance.Limits(instructionBudget: 200_000, maxMemoryPages: 8, maxCallDepth: 64)

    private func instance(_ bytes: [UInt8]) throws -> WasmInstance {
        try WasmInstance(module: try WasmModule.parse(bytes), host: WASIHost(), limits: limits)
    }

    private func engine() -> (ShellEngine, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ShellEngine(environment: ShellEnvironment(root: root)), root)
    }

    // MARK: - Parsing

    @Test("rejects what is not a module")
    func parsing() throws {
        do {
            _ = try WasmModule.parse([0x00, 0x61, 0x73])
            Issue.record("a three-byte file should not parse")
        } catch let trap as WasmTrap {
            #expect(trap.message.contains("malformed"))
        }
        do {
            _ = try WasmModule.parse([0x00, 0x61, 0x73, 0x6D, 0x02, 0x00, 0x00, 0x00])
            Issue.record("an unknown version should not parse")
        } catch let trap as WasmTrap {
            #expect(trap.message.contains("version"))
        }
        let module = try WasmModule.parse(WasmFixtures.add)
        #expect(module.exportNames == ["add", "answer", "counter"])
        #expect(module.types.count == 1)
    }

    // MARK: - Execution

    @Test("arithmetic, globals and exports work")
    func arithmetic() throws {
        let instance = try instance(WasmFixtures.add)
        let sum = try instance.invoke(export: "add", arguments: [.i32(20), .i32(22)])
        #expect(sum.first?.description == "42")
        #expect(instance.globals.first?.description == "7")
        #expect(instance.executedSteps > 0)
        #expect(instance.growMemory(pages: 4) >= 0)
        #expect(instance.growMemory(pages: 100) == -1)      // capped
    }

    @Test("loops, blocks and br_table behave like V8")
    func controlFlow() throws {
        let instance = try instance(WasmFixtures.controlflow)
        #expect(try instance.invoke(export: "fib", arguments: [.i32(10)]).first?.description == "55")
        #expect(try instance.invoke(export: "fib", arguments: [.i32(20)]).first?.description == "6765")
        #expect(try instance.invoke(export: "classify", arguments: [.i32(0)]).first?.description == "10")
        #expect(try instance.invoke(export: "classify", arguments: [.i32(1)]).first?.description == "20")
        #expect(try instance.invoke(export: "classify", arguments: [.i32(9)]).first?.description == "30")
    }

    @Test("memory, data segments and load/store work")
    func memory() throws {
        let instance = try instance(WasmFixtures.memory)
        #expect(try instance.invoke(export: "roundtrip", arguments: [.i32(123_456)]).first?.description == "123456")
        #expect(try instance.invoke(export: "byte_at", arguments: [.i32(16)]).first?.description == "119")
        // `memory.size` and `memory.grow` each carry a reserved memory-index
        // immediate. Not consuming it made the interpreter run the immediate as
        // an `unreachable` instruction, so these two lines are the regression
        // guard for that.
        #expect(try instance.invoke(export: "pages").first?.description == "1")
        #expect(try instance.invoke(export: "grow").first?.description == "1")
        #expect(try instance.invoke(export: "pages").first?.description == "2")
        // The data segment landed where the fixture put it.
        #expect(String(decoding: try instance.readMemory(at: 16, count: 5), as: UTF8.self) == "wasm-")
        // `poke(addr, value)` really stores where it is told, so an
        // out-of-bounds address is expressible; `roundtrip` could not do this.
        #expect(try instance.invoke(export: "poke", arguments: [.i32(4), .i32(7)]).first?.description == "1")
        #expect(try instance.invoke(export: "byte_at", arguments: [.i32(4)]).first?.description == "7")
        // Out-of-bounds access traps instead of crashing.
        do {
            // Well past the two pages this test has grown to; 70_000 would
            // still be inside them and would not trap at all.
            _ = try instance.invoke(export: "poke", arguments: [.i32(999_999), .i32(1)])
            Issue.record("an out-of-bounds store should trap")
        } catch let trap as WasmTrap {
            #expect(trap.message.contains("out of bounds"))
        }
    }

    @Test("a module cannot run away or divide by zero silently")
    func trapsAndBudgets() throws {
        let divide = try instance(WasmFixtures.trap)
        do {
            _ = try divide.invoke(export: "divide", arguments: [.i32(0)])
            Issue.record("dividing by zero should trap")
        } catch let trap as WasmTrap {
            #expect(trap.message.contains("divide by zero"))
        }
        #expect(try divide.invoke(export: "divide", arguments: [.i32(4)]).first?.description == "50")

        let spin = try instance(WasmFixtures.spin)
        do {
            _ = try spin.invoke(export: "forever")
            Issue.record("an endless loop should hit the instruction budget")
        } catch let trap as WasmTrap {
            #expect(trap.message.contains("budget"))
        }
    }

    // MARK: - WASI

    @Test("a WASI module writes to stdout through fd_write")
    func wasiOutput() throws {
        let outcome = try WasmRuntime.run(
            WasmFixtures.wasihello,
            arguments: ["hello.wasm"],
            environment: ["TERM": "xterm"],
            stdin: "",
            limits: limits
        )
        #expect(outcome.stdout == "hello from wasm\n")
        #expect(outcome.exitCode == 0)

        // The same module also runs as a file in the sandbox.
        let (engine, root) = engine()
        try Data(WasmFixtures.wasihello).write(to: root.appendingPathComponent("hello.wasm"))
        #expect(engine.run("wasm run hello.wasm").output == "hello from wasm")
        #expect(engine.run("wasm info hello.wasm").output.contains("wasi_snapshot_preview1.fd_write"))
        #expect(engine.run("wasm run missing.wasm").exitCode == 1)
        #expect(engine.run("wasm --version").output.contains("interpreter"))
        #expect(engine.run("wasm nonsense").exitCode == 2)
    }

    // MARK: - The catalog package

    @Test("a wasm package from the catalog runs in the interpreter")
    func wasmPackage() throws {
        let (engine, _) = engine()
        #expect(engine.run("apt install hello-wasm").exitCode == 0)
        #expect(engine.run("hello-wasm").output == "hello from wasm")
        #expect(engine.run("winget list wasm").output.contains("Terminal-ios.hello-wasm"))
        #expect(engine.run("apt show hello-wasm").output.contains("Kind: wasm"))
        #expect(engine.run("apt remove hello-wasm").exitCode == 0)
        #expect(engine.run("hello-wasm").exitCode == 127)
    }

    @Test("every bundled payload verifies, binary ones included")
    func bundledPayloadsVerify() throws {
        let manager = PackageManager(stateDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        var sawBinary = false
        for entry in manager.catalog.entries where entry.payload != nil {
            switch PayloadStore.bytes(for: entry) {
            case .success(let data):
                #expect(data.isEmpty == false)
                if entry.encoding == "base64" {
                    sawBinary = true
                    // A wasm module starts with the magic number.
                    #expect(Array(data.prefix(4)) == WasmModule.magic)
                }
            case .failure(let reason):
                Issue.record("payload failed to verify: \(reason)")
            }
        }
        #expect(sawBinary)
    }
}
