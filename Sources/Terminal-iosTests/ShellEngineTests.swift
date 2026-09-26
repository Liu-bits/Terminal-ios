// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Foundation
import Testing

struct ShellEngineTests {

    private func makeEngine() -> (ShellEngine, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var environment = ShellEnvironment(root: root)
        environment.variables = ["NAME": "world"]
        let engine = ShellEngine(environment: environment)
        return (engine, root)
    }

    @Test("Expands variables and pipes output")
    func expandsVariablesAndPipes() throws {
        let (engine, _) = makeEngine()
        let result = engine.run("echo hello $NAME | cat")
        #expect(result.exitCode == 0)
        #expect(result.output == "hello world")
        #expect(engine.run("echo ${NAME}!").output == "world!")
        #expect(engine.run("echo $MISSING!").output == "!")
        #expect(engine.run("echo 'a|b'").output == "a|b")
    }

    @Test("Supports redirection round-trip")
    func supportsRedirection() throws {
        let (engine, root) = makeEngine()
        #expect(engine.run("echo abc > out.txt").exitCode == 0)
        #expect(engine.run("cat out.txt").output == "abc")
        #expect(engine.run("echo def >> out.txt").exitCode == 0)
        #expect(engine.run("cat < out.txt").output == "abc\ndef")
        #expect(engine.run("echo tail >> out.txt; cat out.txt").output == "abc\ndef\ntail")
        #expect(engine.run("cat < missing.txt").exitCode == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("out.txt").path))
    }

    @Test("Supports boolean chaining and sequences")
    func supportsChaining() throws {
        let (engine, _) = makeEngine()
        #expect(engine.run("echo a && echo b").output == "a\nb")
        #expect(engine.run("nosuchcmd || echo rescued").output == "rescued")
        #expect(engine.run("nosuchcmd; echo after").output == "after")
        #expect(engine.run("nosuchcmd").exitCode == 127)
    }

    @Test("Confines file access to the sandbox root")
    func confinesSandbox() throws {
        let (engine, root) = makeEngine()
        #expect(engine.run("cd /").exitCode == 0)
        #expect(engine.environment.currentDirectory.path == root.path)
        #expect(engine.run("cd ..").exitCode == 0)
        #expect(engine.environment.currentDirectory.path == root.path)
        #expect(engine.run("cat /etc/passwd").exitCode == 1)
        #expect(engine.run("echo x > ../escape.txt").output == "")
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("escape.txt").path
        ))
    }

    @Test("Reports clear screen and history")
    func reportsClearAndHistory() throws {
        let (engine, _) = makeEngine()
        _ = engine.run("echo one")
        #expect(engine.run("history").output.contains("echo one"))
        // Empty and whitespace-only lines are not recorded.
        let count = engine.history.count
        _ = engine.run("   ")
        #expect(engine.history.count == count)
        let cleared = engine.run("clear")
        #expect(cleared.clearScreen)
    }

    @Test("Rejects invalid syntax")
    func rejectsInvalidSyntax() throws {
        let (engine, _) = makeEngine()
        #expect(engine.run("echo 'oops").exitCode == 2)
        #expect(engine.run("echo hi |").exitCode == 2)
        #expect(engine.run("nosuchcmd < missing.txt").exitCode == 1)
        // Bare redirection still creates the file, like an empty command.
        #expect(engine.run("> blank.txt").exitCode == 0)
        #expect(engine.run("cat blank.txt").output == "")
    }
}
