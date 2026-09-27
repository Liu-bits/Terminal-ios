// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Foundation
import Testing

/// `ed` and `top`: one is a line editor that wants whole lines, the other a
/// viewer that wants single keys. Both are driven by scripts here, so neither
/// needs a simulator.
struct EditorTests {

    private func makeEngine() -> (ShellEngine, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = ShellEngine(environment: ShellEnvironment(root: root))
        engine.environment.variables["LINES"] = "8"
        engine.environment.variables["COLUMNS"] = "60"
        return (engine, root)
    }

    private func text(_ step: InteractiveStep) -> String {
        switch step {
        case .frame(let text), .append(let text), .finished(let text, _):
            return text
        }
    }

    // MARK: - ed on a pipe

    @Test("ed reads its commands from standard input when there is no screen")
    func edOnAPipe() {
        let (engine, _) = makeEngine()
        engine.run("printf 'alpha\\nbravo\\ncharlie\\n' > notes.txt")

        #expect(engine.run("printf '1,$p\\nq\\n' | ed notes.txt").output == "alpha\nbravo\ncharlie")
        #expect(engine.run("printf '2p\\nq\\n' | ed notes.txt").output == "bravo")
        #expect(engine.run("printf '$p\\nq\\n' | ed notes.txt").output == "charlie")
        #expect(engine.run("printf '.p\\nq\\n' | ed notes.txt").output == "charlie")
        #expect(engine.run("printf '2n\\nq\\n' | ed notes.txt").output == "2\tbravo")
        #expect(engine.run("printf '$=\\nq\\n' | ed notes.txt").output == "3")
        // One address is one line: this was wrong once, and `1d` deleted the
        // whole buffer because of it.
        #expect(engine.run("printf '1,2p\\nq\\n' | ed notes.txt").output == "alpha\nbravo")
    }

    @Test("ed edits and writes through the shell's file layer")
    func edEditing() {
        let (engine, _) = makeEngine()
        engine.run("printf 'alpha\\nbravo\\ncharlie\\n' > notes.txt")

        // Substituting marks the buffer modified, so `q` refuses and `Q` leaves.
        #expect(engine.run("printf '2s/ra/X/\\np\\nq\\n' | ed notes.txt").output.contains("bXvo"))
        #expect(engine.run("printf '2s/ra/X/\\nq\\n' | ed notes.txt").output.contains("modified"))
        #expect(engine.run("printf '2s/ra/X/\\nQ\\n' | ed notes.txt").output.contains("modified") == false)
        #expect(engine.run("cat notes.txt").output == "alpha\nbravo\ncharlie")

        engine.run("printf 'a\\ndelta\\n.\\nw\\nq\\n' | ed notes.txt")
        #expect(engine.run("cat notes.txt").output == "alpha\nbravo\ncharlie\ndelta")
        engine.run("printf '1d\\nw\\nq\\n' | ed notes.txt")
        #expect(engine.run("cat notes.txt").output == "bravo\ncharlie\ndelta")
        engine.run("printf '1c\\nX\\n.\\nw\\nq\\n' | ed notes.txt")
        #expect(engine.run("cat notes.txt").output == "X\ncharlie\ndelta")
        engine.run("printf '2i\\ninserted\\n.\\nw\\nq\\n' | ed notes.txt")
        #expect(engine.run("cat notes.txt").output == "X\ninserted\ncharlie\ndelta")
    }

    @Test("ed writes a file that did not exist")
    func edCreatesFiles() {
        let (engine, _) = makeEngine()
        #expect(engine.run("printf 'a\\nfresh\\n.\\nw other.txt\\nq\\n' | ed scratch.txt").output.contains("bytes written"))
        #expect(engine.run("cat other.txt").output == "fresh")
        // With no name at all it has to say so rather than invent one.
        #expect(engine.run("printf 'a\\nx\\n.\\nw\\nQ\\n' | ed").output.contains("no file name"))
    }

    // MARK: - ed as a session

    @Test("ed is a line-mode session with a visible, editable line")
    func edSession() throws {
        let (engine, _) = makeEngine()
        engine.run("printf 'X\\ncharlie\\ndelta\\n' > notes.txt")
        guard case .interactive(let session) = engine.runInteractive("ed notes.txt") else {
            Issue.record("ed should take the screen at the top level")
            return
        }
        #expect(session.inputMode == .line)
        #expect(session.initialFrame.contains("notes.txt"))
        #expect(text(session.handle(line: "1,2p")).contains("X"))
        #expect(text(session.handle(line: "h")).contains("append"))
        #expect(text(session.handle(line: "zz")).contains("unknown command"))
        #expect(text(session.handle(line: "u")).contains("undo"))
        #expect(text(session.handle(line: "w")).contains("bytes written"))
        #expect(text(session.handle(line: "q")).isEmpty)

        // Esc abandons the buffer, and says it did.
        guard case .finished(let note, let code) = session.handle(key: InteractiveKey.escape) else {
            Issue.record("Esc should end an ed session")
            return
        }
        #expect(code == 0)
        #expect(note.isEmpty)
    }

    // MARK: - top

    @Test("top reports real state without a screen")
    func topReport() {
        let (engine, _) = makeEngine()
        engine.run("echo one")
        engine.run("nosuchcmd")
        let report = engine.run("top").output
        #expect(report.contains("TimeShell top"))
        #expect(report.contains("echo one"))
        #expect(report.contains("fail"))
        #expect(report.contains("~"))
    }

    @Test("top filters, sorts and opens a run")
    func topSession() throws {
        let (engine, _) = makeEngine()
        engine.run("echo one")
        engine.run("nosuchcmd")
        guard case .interactive(let session) = engine.runInteractive("top") else {
            Issue.record("top should take the screen at the top level")
            return
        }
        let top = try #require(session as? TopSession)
        #expect(session.inputMode == .key)
        #expect(session.initialFrame.contains("TimeShell top"))
        #expect(top.visible.contains { $0.command == "echo one" })

        // f narrows to failures, and the hint says the filter is on.
        let filtered = session.handle(key: "f")
        #expect(top.visible.allSatisfy { $0.succeeded == false })
        #expect(top.visible.isEmpty == false)
        #expect(!(top.visible.contains { $0.command == "echo one" }))
        #expect(text(filtered).contains("f:all"))

        _ = session.handle(key: "f")
        _ = session.handle(key: "s")
        #expect(zip(top.visible, top.visible.dropFirst()).allSatisfy { $0.duration >= $1.duration })

        _ = session.handle(key: "j")
        #expect(top.selectedIndex == 1)
        _ = session.handle(key: "g")
        #expect(top.selectedIndex == 0)

        #expect(text(session.handle(key: InteractiveKey.enter)).contains("esc:back"))
        _ = session.handle(key: InteractiveKey.escape)
        // Back on the list: an unbound key only redraws.
        #expect(text(session.handle(key: "x")).contains("TimeShell top"))
        guard case .finished(_, let code) = session.handle(key: "q") else {
            Issue.record("q should quit top")
            return
        }
        #expect(code == 0)
    }
}
