// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Foundation
import Testing

/// The interactive channel and the pager built on it.
///
/// A session is driven by a script of keys, so the pager is testable without a
/// simulator; `TerminalViewControllerTests` covers the wiring that turns real
/// keystrokes into those calls.
struct PagerTests {

    private func makeEngine(lines: String, rows: Int = 4, columns: Int = 40) -> ShellEngine {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pager-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = ShellEngine(environment: ShellEnvironment(root: root))
        engine.environment.variables["LINES"] = "\(rows)"
        engine.environment.variables["COLUMNS"] = "\(columns)"
        engine.run("printf '\(lines.replacingOccurrences(of: "\n", with: "\\n"))\\n' > big.txt")
        return engine
    }

    private func opened(_ engine: ShellEngine, _ command: String = "less big.txt") -> InteractiveSession? {
        if case .interactive(let session) = engine.runInteractive(command) {
            return session
        }
        return nil
    }

    private func text(_ step: InteractiveStep) -> String {
        switch step {
        case .frame(let text), .finished(let text, _):
            return text
        }
    }

    @Test("A pager takes the screen at the top level and shows a page")
    func opensOnTheAlternateScreen() throws {
        let engine = makeEngine(lines: "l1\nl2\nl3\nl4\nl5\nl6")
        let session = try #require(opened(engine))
        #expect(session.initialFrame.contains("\u{1B}[?1049h"))
        #expect(session.initialFrame.contains("l1"))
        // Three text rows plus the status row: LINES is 4.
        #expect(session.initialFrame.contains("l3"))
        #expect(session.initialFrame.contains("l4") == false)
        #expect(session.initialFrame.contains("big.txt"))
        #expect(session.initialFrame.contains("1-3/6"))
        #expect(session.initialFrame.contains("\u{1B}[7m"))
        // 40 columns is too narrow for the long hint, so the short one shows.
        #expect(session.initialFrame.contains("spc/b/j/k/G/q"))
    }

    @Test("Keys move through the file and quit restores the screen")
    func navigation() throws {
        let engine = makeEngine(lines: "l1\nl2\nl3\nl4\nl5\nl6")
        let session = try #require(opened(engine))
        #expect(text(session.handle(key: " ")).contains("l4"))
        #expect(text(session.handle(key: "b")).contains("l1"))
        #expect(text(session.handle(key: "j")).contains("l2"))
        #expect(text(session.handle(key: "k")).contains("l1"))
        #expect(text(session.handle(key: "G")).contains("l6"))
        #expect(text(session.handle(key: "g")).contains("l1"))
        #expect(text(session.handle(key: InteractiveKey.down)).contains("l2"))
        // Clamping: the pager never scrolls past either end.
        #expect(text(session.handle(key: "k")).contains("l1"))
        let quit = session.handle(key: "q")
        #expect(text(quit).contains("\u{1B}[?1049l"))
        if case .finished(_, let code) = quit {
            #expect(code == 0)
        } else {
            Issue.record("q must finish the session")
        }
        // Esc and Ctrl-C quit too, for a phone keyboard without a `q` key.
        let second = try #require(opened(engine))
        if case .finished = second.handle(key: InteractiveKey.escape) {
            #expect(true)
        } else {
            Issue.record("Esc must finish the session")
        }
    }

    @Test("Search types, highlights and repeats")
    func search() throws {
        let engine = makeEngine(lines: "alpha\nbravo\ncharlie\ndelta\necho")
        let session = try #require(opened(engine))
        session.handle(key: "/")
        #expect(text(session.handle(key: "c")).contains("/c"))
        let typed = session.handle(key: "h")
        #expect(text(typed).contains("/ch"))
        // Backspace edits the draft rather than the screen.
        let erased = session.handle(key: InteractiveKey.backspace)
        #expect(text(erased).contains("/c"))
        session.handle(key: "h")
        let found = session.handle(key: InteractiveKey.enter)
        #expect(text(found).contains("\u{1B}[7mcharlie"))
        #expect(text(found).contains("not found") == false)
        // `n` finds the next match, and wraps with a note when there is none.
        session.handle(key: "g")
        #expect(text(session.handle(key: "n")).contains("charlie"))
        let wrapped = session.handle(key: "n")
        #expect(text(wrapped).contains("charlie"))
        // A pattern that is nowhere says so instead of pretending.
        session.handle(key: "/")
        session.handle(key: "z")
        session.handle(key: "z")
        #expect(text(session.handle(key: InteractiveKey.enter)).contains("not found"))
    }

    @Test("more walks a line per Enter and prompts the classic way")
    func more() throws {
        let engine = makeEngine(lines: "l1\nl2\nl3\nl4\nl5")
        let session = try #require(opened(engine, "more big.txt"))
        #expect(session.initialFrame.contains("--More--"))
        #expect(text(session.handle(key: InteractiveKey.enter)).contains("l4"))
    }

    @Test("A pager without a screen copies its input instead")
    func noScreenNoSession() {
        let engine = makeEngine(lines: "l1\nl2\nl3")
        // A pipe is not a terminal, which is exactly the real `less` rule.
        #expect(engine.run("cat big.txt | less").session == nil)
        #expect(engine.run("cat big.txt | less").output.contains("l1"))
        // Nor does a script get the screen.
        engine.run("printf 'less big.txt\\n' > pager.sh")
        if case .finished(let result) = engine.runInteractive("sh pager.sh") {
            #expect(result.session == nil)
            #expect(result.output.contains("l1"))
        } else {
            Issue.record("a script must not hand the screen to a command")
        }
        // And a missing file is still an error.
        #expect(engine.run("less nope.txt").exitCode == 1)
    }

    @Test("The outcome carries both the frame and the session")
    func outcomeShape() throws {
        let engine = makeEngine(lines: "l1\nl2\nl3")
        let outcome = engine.runInteractive("less big.txt")
        #expect(outcome.result.session != nil)
        #expect(outcome.result.output.contains("l1"))
        let plain = engine.runInteractive("echo hi")
        #expect(plain.result.session == nil)
        #expect(plain.result.output == "hi")
    }
}
