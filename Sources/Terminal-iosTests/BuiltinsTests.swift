// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Foundation
import Testing

/// Exercises the coreutils-style built-ins through the engine, so both the
/// command table and the pipeline machinery are covered.
struct BuiltinsTests {

    private func makeEngine() -> (ShellEngine, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ShellEngine(environment: ShellEnvironment(root: root)), root)
    }

    @Test("file commands create, list and remove a tree")
    func fileCommands() throws {
        let (engine, root) = makeEngine()
        #expect(engine.run("mkdir -p a/b/c").exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/b/c").path))
        #expect(engine.run("touch a/b/c/note.txt").exitCode == 0)
        #expect(engine.run("ls a/b/c").output == "note.txt")
        #expect(engine.run("ls -a a/b/c").output.contains("note.txt"))
        #expect(engine.run("cp a/b/c/note.txt a/b/copy.txt").exitCode == 0)
        #expect(engine.run("ls a/b/c | sort").output == "copy.txt\nnote.txt")
        #expect(engine.run("mv a/b/c/copy.txt a/b/moved.txt").exitCode == 0)
        #expect(engine.run("ls a/b").output == "c\nmoved.txt")
        #expect(engine.run("rm a/b/moved.txt").exitCode == 0)
        #expect(engine.run("rm a/b/c").exitCode == 1)
        #expect(engine.run("rm -r a/b/c").exitCode == 0)
        #expect(engine.run("rmdir a/b").exitCode == 0)
    }

    @Test("path helpers answer like their POSIX namesakes")
    func pathHelpers() throws {
        let (engine, _) = makeEngine()
        #expect(engine.run("basename /tmp/a/report.txt").output == "report.txt")
        #expect(engine.run("basename report.txt .txt").output == "report")
        #expect(engine.run("dirname /tmp/a/report.txt").output == "/tmp/a")
        #expect(engine.run("dirname report.txt").output == ".")
        #expect(engine.run("mkdir -p deep/tree; realpath deep/tree").output.hasPrefix("~"))
        #expect(engine.run("find . -name '*.txt'").exitCode == 0)
        #expect(engine.run("du -s .").exitCode == 0)
        #expect(engine.run("df -h").exitCode == 0)
    }

    @Test("text filters compose through pipes")
    func textFilters() throws {
        let (engine, _) = makeEngine()
        #expect(engine.run("printf 'b\\na\\nc\\na\\n' > list.txt").exitCode == 0)
        #expect(engine.run("sort list.txt").output == "a\na\nb\nc")
        #expect(engine.run("sort -u list.txt").output == "a\nb\nc")
        #expect(engine.run("sort list.txt | uniq").output == "a\nb\nc")
        #expect(engine.run("head -n 2 list.txt").output == "b\na")
        #expect(engine.run("tail -n 1 list.txt").output == "a")
        #expect(engine.run("wc -l list.txt").output == "4")
        #expect(engine.run("grep a list.txt").output == "a\na")
        #expect(engine.run("grep -c a list.txt").output == "2")
        #expect(engine.run("grep -v a list.txt").output == "b\nc")
        #expect(engine.run("grep a list.txt").exitCode == 0)
        #expect(engine.run("grep zzz list.txt").exitCode == 1)
        #expect(engine.run("cat list.txt | tr a-z A-Z").output == "B\nA\nC\nA")
        #expect(engine.run("cut -d, -f2 csv.txt").exitCode != 0)
        #expect(engine.run("printf 'a,b,c\\n' > csv.txt; cut -d, -f2 csv.txt").output == "b")
        #expect(engine.run("nl list.txt").output.hasPrefix("     1\tb"))
        #expect(engine.run("tac list.txt").output == "a\nc\na\nb")
        #expect(engine.run("rev list.txt").output == "b\na\nc\na")
    }

    @Test("sed, tee, seq and printf do their jobs")
    func editing() throws {
        let (engine, _) = makeEngine()
        #expect(engine.run("seq 1 3").output == "1\n2\n3")
        #expect(engine.run("seq 1 2 5").output == "1\n3\n5")
        #expect(engine.run("printf '%s-%d' ab 7").output == "ab-7")
        #expect(engine.run("echo -n hi").output == "hi")
        #expect(engine.run("echo -e 'a\\tb'").output == "a\tb")
        #expect(engine.run("printf 'x\\ny\\n' > two.txt; sed 's/x/X/' two.txt").output == "X\ny")
        #expect(engine.run("printf 'p\\nq\\n' | tee saved.txt").output == "p\nq")
        #expect(engine.run("cat saved.txt").output == "p\nq")
        #expect(engine.run("mkdir -p d2; echo one > d2/f.txt; grep -r one d2").output.contains("one"))
    }

    @Test("digests and base64 match the platform implementations")
    func digests() throws {
        let (engine, _) = makeEngine()
        #expect(engine.run("printf '' > empty.txt").exitCode == 0)
        let sha = engine.run("echo -n abc | sha256sum")
        #expect(sha.output.hasPrefix("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        let md5 = engine.run("echo -n abc | md5sum")
        #expect(md5.output.hasPrefix("900150983cd24fb0d6963f7d28e17f72"))
        #expect(engine.run("echo -n hello | base64").output == "aGVsbG8=")
        #expect(engine.run("echo -n aGVsbG8= | base64 -d").output == "hello")
    }

    @Test("system commands describe the sandbox honestly")
    func systemCommands() throws {
        let (engine, _) = makeEngine()
        #expect(engine.run("whoami").output == "user")
        #expect(engine.run("uname -s").output == "Darwin")
        #expect(engine.run("nproc").output.isEmpty == false)
        #expect(engine.run("date +%Y").output.count == 4)
        #expect(engine.run("ps").output.contains("Terminal-ios"))
        #expect(engine.run("free").output.contains("Mem:"))
        #expect(engine.run("uptime").output.hasPrefix("up "))
        #expect(engine.run("true").exitCode == 0)
        #expect(engine.run("false").exitCode == 1)
        #expect(engine.run("which ls").exitCode == 1)
        #expect(engine.run("type ls").output.contains("shell built-in"))
        #expect(engine.run("version").output.contains("built-ins"))
        #expect(engine.run("help").output.contains("Built-ins:"))
        #expect(engine.run("man ls").output == "ls - list directory contents")
    }

    @Test("conditionals and arithmetic work as commands")
    func conditionals() throws {
        let (engine, _) = makeEngine()
        #expect(engine.run("test -d .").exitCode == 0)
        #expect(engine.run("[ -f nope.txt ]").exitCode == 1)
        #expect(engine.run("mkdir -p here; [ -d here ]").exitCode == 0)
        #expect(engine.run("test 3 -gt 2").exitCode == 0)
        #expect(engine.run("test abc = abc").exitCode == 0)
        #expect(engine.run("expr 2 + 3").output == "5")
        #expect(engine.run("expr 7 / 0").exitCode == 2)
        #expect(engine.run("echo $?").output == "0")
        #expect(engine.run("false; echo $?").output == "1")
    }

    @Test("command substitution and special variables expand")
    func substitution() throws {
        let (engine, _) = makeEngine()
        #expect(engine.run("echo $(echo nested)").output == "nested")
        #expect(engine.run("echo `echo backtick`").output == "backtick")
        #expect(engine.run("echo $(echo a)$(echo b)").output == "ab")
        #expect(engine.run("echo 'no $(sub)'").output == "no $(sub)")
        #expect(engine.run("echo \"yes $(echo sub)\"").output == "yes sub")
        #expect(engine.run("echo $(uname -s)").output == "Darwin")
    }
}
