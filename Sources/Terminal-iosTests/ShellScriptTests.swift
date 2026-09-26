// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Foundation
import Testing

/// Covers the script interpreter: control flow, functions, assignments,
/// comments, `exit` and running scripts from a file.
struct ShellScriptTests {

    private func makeEngine() -> (ShellEngine, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ShellEngine(environment: ShellEnvironment(root: root)), root)
    }

    @Test("if/elif/else picks the right branch")
    func ifChains() throws {
        let (engine, _) = makeEngine()
        let script = """
        if [ -f missing.txt ]; then
          echo first
        elif test -d .; then
          echo second
        else
          echo third
        fi
        """
        #expect(engine.runScript(script).output == "second")
        #expect(engine.runScript("if false; then echo yes; else echo no; fi").output == "no")
        #expect(engine.runScript("mkdir -p tag; if [ -d tag ]; then echo dir; fi").output == "dir")
    }

    @Test("for loops walk a word list and positional parameters")
    func forLoops() throws {
        let (engine, _) = makeEngine()
        #expect(engine.runScript("for f in a b c; do echo item-$f; done").output == "item-a\nitem-b\nitem-c")
        let counted = """
        for f in x y; do
          echo "[$f]"
        done
        """
        #expect(engine.runScript(counted).output == "[x]\n[y]")
    }

    @Test("while loops consume script input and stop at EOF")
    func whileLoops() throws {
        let (engine, _) = makeEngine()
        let script = """
        total=0
        while read n; do
          total=$(expr $total + $n)
        done
        echo "sum=$total"
        """
        let result = engine.runScript(script, stdin: "1\n2\n3\n")
        #expect(result.output == "sum=6")
        #expect(result.exitCode == 0)
        #expect(engine.runScript("n=0\nwhile [ $n -lt 3 ]; do n=$(expr $n + 1); done\necho $n").output == "3")
        #expect(engine.runScript("n=0\nuntil [ $n -ge 2 ]; do n=$(expr $n + 1); done\necho $n").output == "2")
    }

    @Test("functions are defined and called with arguments")
    func functions() throws {
        let (engine, _) = makeEngine()
        let script = """
        greet() {
          echo "hello, $1"
        }
        greet world
        """
        #expect(engine.runScript(script).output == "hello, world")
        #expect(engine.functions.keys.contains("greet"))
        #expect(engine.run("greet again").output == "hello, again")
    }

    @Test("comments and backslash continuations are handled")
    func commentsAndContinuations() throws {
        let (engine, _) = makeEngine()
        let script = """
        # leading comment
        echo one \\
          two
        echo 'hash # inside quotes'
        """
        #expect(engine.runScript(script).output == "one two\nhash # inside quotes")
    }

    @Test("exit stops the script with its status")
    func exitStatus() throws {
        let (engine, _) = makeEngine()
        let script = """
        echo before
        exit 3
        echo after
        """
        let result = engine.runScript(script)
        #expect(result.output == "before")
        #expect(result.exitCode == 3)
    }

    @Test("scripts run from a file through sh and by path")
    func scriptFiles() throws {
        let (engine, _) = makeEngine()
        #expect(engine.run("printf 'echo from-file\\n' > run.sh").exitCode == 0)
        #expect(engine.run("sh run.sh").output == "from-file")
        #expect(engine.run("mkdir -p bin; printf 'echo from-dir\\n' > bin/tool.sh").exitCode == 0)
        #expect(engine.run("sh bin/tool.sh").output == "from-dir")
        #expect(engine.run("chmod +x bin/tool.sh").exitCode == 0)
        #expect(engine.run("bin/tool.sh").output == "from-dir")
        #expect(engine.run("sh -c 'echo inline'").output == "inline")
        #expect(engine.run("sh missing.sh").exitCode == 127)
    }

    @Test("assignments and positional parameters expand")
    func variables() throws {
        let (engine, _) = makeEngine()
        let script = """
        name=world
        echo "hi $name"
        echo "$# args: $1"
        """
        #expect(engine.runScript(script, name: "t.sh", args: ["first"]).output == "hi world\n1 args: first")
        #expect(engine.run("count=3; echo $count").output == "3")
    }
}
