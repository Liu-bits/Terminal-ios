// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Foundation
import Testing

/// Covers the offline catalog and the `apt` / `apk` / `pip` surface.
///
/// The digest assertions are the real check on `support/generate_catalog.py`:
/// installing only succeeds when the payload compiled into the binary hashes
/// to the value recorded in the manifest.
struct PackageManagerTests {

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeManager(_ root: URL) -> PackageManager {
        PackageManager(stateDirectory: root)
    }

    @Test("the bundled catalog loads and every payload digest verifies")
    func catalogIntegrity() throws {
        let manager = makeManager(makeRoot())
        #expect(manager.catalog.schema == 1)
        #expect(manager.catalog.entries.count >= 5)
        #expect(manager.catalog.providedCommands.contains("hello"))
        for entry in manager.catalog.entries where entry.payload != nil {
            switch PayloadStore.text(for: entry) {
            case .success(let body):
                #expect(body.isEmpty == false)
                #expect(entry.sha256?.isEmpty == false)
            case .failure(let reason):
                Issue.record("payload failed to verify: \(reason)")
            }
        }
    }

    @Test("installing a script package writes a shim and marks it installed")
    func installScriptPackage() throws {
        let root = makeRoot()
        let manager = makeManager(root)
        #expect(manager.installedNames().isEmpty)

        let outcome = manager.install(["hello"])
        #expect(outcome.exitCode == 0)
        #expect(outcome.text.contains("Setting up hello"))
        #expect(manager.isInstalled("hello"))
        #expect(manager.script(for: "hello")?.body.contains("hello, $name") == true)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".packages/bin/hello").path
        ))

        // Installing again is a no-op, removing clears the shim.
        #expect(manager.install(["hello"]).text.contains("already the newest version"))
        #expect(manager.remove(["hello"]).exitCode == 0)
        #expect(manager.isInstalled("hello") == false)
    }

    @Test("declared runtimes are skipped instead of pretending to install")
    func declaredRuntimeWithoutPayload() throws {
        let manager = makeManager(makeRoot())
        let outcome = manager.install(["python-runtime"])
        #expect(outcome.text.contains("payload is not bundled"))
        #expect(manager.isInstalled("python-runtime") == false)
        let toolchain = manager.install(["mingw-toolchain"])
        #expect(toolchain.text.contains("payload is not bundled"))
    }

    @Test("apt, apk and pip drive the same catalog")
    func packageCommands() throws {
        let root = makeRoot()
        let engine = ShellEngine(environment: ShellEnvironment(root: root))

        #expect(engine.run("apt list").output.contains("hello"))
        #expect(engine.run("apt install hello").exitCode == 0)
        #expect(engine.run("hello swift").output == "hello, swift")
        #expect(engine.run("hello").output == "hello, world")
        #expect(engine.run("apt show hello").output.contains("Digest:"))
        #expect(engine.run("apt show hello").output.contains("License: MIT"))
        #expect(engine.run("apt install nosuchpkg").exitCode == 1)
        #expect(engine.run("apt sources").output.contains("bundled"))
        #expect(engine.run("apt update").exitCode == 0)
        #expect(engine.run("pip search hello").output.contains("hello"))

        // apk spells the same operations differently.
        #expect(engine.run("apk add sum").exitCode == 0)
        #expect(engine.run("printf '2\\n3\\n' | sum").output == "total: 5")
        #expect(engine.run("apk info").output.contains("sum"))
        #expect(engine.run("which sum").output.contains(".packages/bin/sum"))
        #expect(engine.run("apk del sum").exitCode == 0)
        #expect(engine.run("sum").exitCode == 127)

        // Runtime shims explain themselves instead of crashing.
        #expect(engine.run("python3").output.contains("not bundled"))
        #expect(engine.run("gcc").output.contains("not bundled"))
    }

    @Test("installed packages survive a new engine on the same sandbox")
    func statePersists() throws {
        let root = makeRoot()
        let first = ShellEngine(environment: ShellEnvironment(root: root))
        #expect(first.run("apt install mkproject").exitCode == 0)
        let second = ShellEngine(environment: ShellEnvironment(root: root))
        #expect(second.run("mkproject demo").output.contains("created demo/"))
        #expect(second.run("ls demo").output == "README.md\nsrc\ntests")
        #expect(second.run("cat demo/README.md").output == "# demo")
    }
}
