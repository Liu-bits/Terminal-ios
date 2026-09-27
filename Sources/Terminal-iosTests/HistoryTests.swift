// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Foundation
import Testing

/// Phase 1: the snapshot store, the search over it, and the `tm` command.
struct HistoryTests {

    private func makeEngine() -> (ShellEngine, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = ShellEngine(environment: ShellEnvironment(root: root))
        engine.environment.variables["LINES"] = "6"
        engine.environment.variables["COLUMNS"] = "40"
        return (engine, root)
    }

    /// Text carried by an interactive step, whichever kind it is.
    private func text(_ step: InteractiveStep) -> String {
        switch step {
        case .frame(let text), .append(let text), .finished(let text, _):
            return text
        }
    }

    /// The text as a reader sees it: escapes removed, which matters because the
    /// browser's status line is drawn in reverse video.
    private func plain(_ step: InteractiveStep) -> String {
        ANSIParser.strip(text(step))
    }

    // MARK: - Recording

    @Test("Every top-level line becomes a snapshot")
    func recording() throws {
        let (engine, _) = makeEngine()
        var observed: [HistoryEntry] = []
        engine.onExecute = { observed.append($0) }

        #expect(engine.run("echo hello").exitCode == 0)
        engine.run("nosuchcmd")

        // The engine stores it itself; `onExecute` is only an observer.
        #expect(engine.snapshots.entries().count == 2)
        #expect(observed.count == 2)
        let entry = try #require(observed.first)
        #expect(entry.command == "echo hello")
        #expect(entry.argv == ["echo", "hello"])
        #expect(entry.stdout == "hello")
        #expect(entry.exitCode == 0)
        #expect(entry.duration >= 0)
        #expect(entry.directory.hasPrefix("~"))
        // Bookkeeping variables would drown the useful ones.
        #expect(entry.environment["?"] == nil)
        #expect(entry.environment["#"] == nil)
        #expect(entry.environment["HOME"] != nil)
        #expect(observed.last?.exitCode == 127)
        #expect(observed.last?.succeeded == false)
    }

    @Test("A snapshot of an interactive command stores no screen escapes")
    func interactiveSnapshots() throws {
        let (engine, _) = makeEngine()
        engine.run("printf 'a\\nb\\nc\\nd\\ne\\nf\\ng\\n' > page.txt")
        var observed: [HistoryEntry] = []
        engine.onExecute = { observed.append($0) }
        _ = engine.runInteractive("less page.txt")
        let entry = try #require(observed.last)
        #expect(entry.command == "less page.txt")
        #expect(entry.stdout.isEmpty)
    }

    @Test("Variables are recorded as written, not as expanded")
    func argvIsAsWritten() throws {
        let (engine, _) = makeEngine()
        var observed: [HistoryEntry] = []
        engine.onExecute = { observed.append($0) }
        engine.run("export NAME=world; echo $NAME")
        // The leftmost branch of a chain is what gets recorded, and the words are
        // the ones the user typed.
        #expect(observed.first?.argv == ["export", "NAME=world"])
    }

    // MARK: - The store

    @Test("The in-memory store keeps its shape")
    func memoryStore() {
        let store = MemoryHistoryStore(limit: 3)
        for index in 1...5 {
            store.append(HistoryEntry(command: "cmd\(index)", directory: "~"))
        }
        #expect(store.entries().count == 3)
        #expect(store.entries().first?.command == "cmd5")
        #expect(store.recent(2).map(\.command) == ["cmd5", "cmd4"])

        guard let first = store.entries().first else {
            Issue.record("the store should hold three entries")
            return
        }
        #expect(store.find(id: first.shortID) != nil)
        store.update(HistoryEntry(id: first.id, command: "renamed", directory: "~", pinned: true))
        #expect(store.entries().first?.pinned == true)
        store.delete(id: first.shortID)
        #expect(store.entries().count == 2)
        store.clear()
        #expect(store.entries().isEmpty)
    }

    @Test("The JSON store survives a reload and caps output")
    func jsonStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = JSONHistoryStore(directory: root, limit: 5)
        store.append(HistoryEntry(command: "echo persisted", directory: "~", stdout: "yes"))

        let reloaded = JSONHistoryStore(directory: root, limit: 5)
        #expect(reloaded.entries().first?.command == "echo persisted")
        #expect(reloaded.entries().first?.stdout == "yes")

        // A snapshot is a convenience: a huge output must not be stored whole.
        let huge = HistoryEntry(
            command: "cat big",
            directory: "~",
            stdout: String(repeating: "x", count: HistoryEntry.outputLimit + 500)
        )
        #expect(huge.stdout.contains("output truncated"))
        #expect(huge.stdout.utf8.count < HistoryEntry.outputLimit + 100)

        // Dates survive the ISO-8601 round trip.
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        store.append(HistoryEntry(date: date, command: "dated", directory: "~"))
        let after = JSONHistoryStore(directory: root, limit: 5)
        let stored = try #require(after.entries().first { $0.command == "dated" })
        #expect(abs(stored.date.timeIntervalSince(date)) < 1)
    }

    // MARK: - Search

    @Test("Command matches outrank output matches, and only real hits rank")
    func searchRanking() {
        let store = MemoryHistoryStore(entries: [
            HistoryEntry(command: "grep needle log.txt", directory: "~", stdout: "nothing here", pinned: true, title: "logs"),
            HistoryEntry(command: "cat log.txt", directory: "~", stdout: "needle here", exitCode: 1),
        ])
        let ranked = store.search(HistoryFilter(text: "needle"))
        #expect(ranked.count == 2)
        #expect(ranked.first?.entry.command == "grep needle log.txt")
        #expect(ranked.first?.matchedCommand == true)
        #expect(ranked.last?.matchedCommand == false)
        #expect(ranked.last?.outputLines.first?.contains("needle") == true)

        // A run that failed must not match a query it does not contain: the
        // "failed runs are interesting" bonus is a tie-breaker, not a match.
        #expect(store.search(HistoryFilter(text: "zzzz")).isEmpty)

        #expect(store.search(HistoryFilter(text: "needle", failedOnly: true)).count == 1)
        #expect(store.search(HistoryFilter(text: "needle", pinnedOnly: true)).count == 1)
        #expect(store.search(HistoryFilter(text: "logs")).count == 1)   // the pinned title
        #expect(store.search(HistoryFilter(text: "needle", limit: 1)).count == 1)
        #expect(store.search(HistoryFilter()).count == 2)
        #expect(store.search(HistoryFilter(text: "cat", directory: "~")).count == 1)
        #expect(store.search(HistoryFilter(text: "cat", directory: "/elsewhere")).isEmpty)
    }

    @Test("Export is plain text with the command and the output")
    func export() {
        let store = MemoryHistoryStore(entries: [
            HistoryEntry(command: "echo hi", directory: "~", stdout: "hi", duration: 0.25)
        ])
        let text = HistorySearch.export(store.entries())
        #expect(text.contains("$ echo hi"))
        #expect(text.contains("| hi"))
        #expect(text.contains("exit 0"))
    }

    // MARK: - The tm command

    @Test("tm lists, shows, searches and pins")
    func tmSubcommands() throws {
        let (engine, _) = makeEngine()
        engine.run("echo hello")
        engine.run("nosuchcmd")
        // Stop the tm calls below from showing up in their own results.
        let identifier = try #require(engine.snapshots.entries().first).shortID

        let list = engine.run("tm list").output
        #expect(list.contains("nosuchcmd"))
        #expect(list.contains("fail"))

        #expect(engine.run("tm search hello").output.contains("$ "))
        #expect(engine.run("tm search --failed nosuchcmd").output.contains("nosuchcmd"))
        #expect(engine.run("tm search zzzz").output.contains("No snapshot matches"))

        let show = engine.run("tm show \(identifier)").output
        #expect(show.contains("nosuchcmd"))
        #expect(show.contains("directory"))
        #expect(engine.run("tm show zzzzzzzz").exitCode == 1)

        #expect(engine.run("tm pin \(identifier) deploy").output.contains("Pinned"))
        #expect(engine.run("tm search --pinned nosuchcmd").output.contains("nosuchcmd"))
        #expect(engine.run("tm unpin \(identifier)").output.contains("Unpinned"))

        #expect(engine.run("tm export").output.contains("$ nosuchcmd"))
        #expect(engine.run("tm export dump.txt").exitCode == 0)
        #expect(engine.run("cat dump.txt").output.contains("nosuchcmd"))

        #expect(engine.run("tm nonsense").exitCode == 2)
        #expect(engine.run("tm").output.contains("usage"))
    }

    @Test("tm replays a snapshot, and pages one")
    func tmReplayAndPage() throws {
        let (engine, _) = makeEngine()
        engine.run("echo replayable")
        let entry = try #require(engine.snapshots.entries().first { $0.command == "echo replayable" })
        #expect(engine.run("tm replay \(entry.shortID)").output == "replayable")

        // Without a screen it prints; the engine only hands over a session when
        // the command is alone at the top level.
        #expect(engine.run("tm page \(entry.shortID)").output.contains("replayable"))
        if case .interactive(let session) = engine.runInteractive("tm page \(entry.shortID)") {
            #expect(session.initialFrame.contains("snapshot"))
            #expect(session.initialFrame.contains("echo replayable"))
            if case .finished = session.handle(key: "q") {
                #expect(true)
            } else {
                Issue.record("tm page must quit on q")
            }
        } else {
            Issue.record("tm page should take the screen at the top level")
        }
    }

    @Test("tm browse lists, opens, searches, pins and deletes")
    func tmBrowse() throws {
        let (engine, _) = makeEngine()
        engine.run("echo alpha")
        engine.run("nosuchcmd")

        #expect(engine.run("tm browse").output.contains("echo alpha"))

        guard case .interactive(let session) = engine.runInteractive("tm browse") else {
            Issue.record("tm browse should take the screen")
            return
        }
        #expect(session.inputMode == .key)
        #expect(session.initialFrame.contains("tm browse"))

        // Enter opens a snapshot; Esc goes back to the list.
        #expect(plain(session.handle(key: InteractiveKey.enter)).contains("exit"))
        #expect(plain(session.handle(key: InteractiveKey.escape)).contains("snapshot"))

        // Search, then a pin toggle.
        session.handle(key: "/")
        session.handle(key: "a")
        #expect(plain(session.handle(key: InteractiveKey.enter)).contains("match"))
        #expect(plain(session.handle(key: "p")).contains("Pinned"))

        // Delete asks first, `n` cancels, `y` removes it.
        #expect(plain(session.handle(key: "x")).contains("delete"))
        #expect(plain(session.handle(key: "n")).contains("cancelled"))
        session.handle(key: "x")
        #expect(plain(session.handle(key: "y")).contains("Deleted"))

        guard case .finished(_, let code) = session.handle(key: "q") else {
            Issue.record("q should quit the browser")
            return
        }
        #expect(code == 0)
    }

    @Test("tm clear drops the old snapshots and records itself")
    func tmClear() throws {
        let (engine, _) = makeEngine()
        engine.run("echo before")
        #expect(engine.run("tm clear").output.contains("Cleared"))
        let list = engine.run("tm list").output
        #expect(list.contains("echo before") == false)
        // Every run is recorded, this one included: a clear that silently wrote
        // nothing would be a surprise, so the message says so.
        #expect(list.contains("tm clear"))
    }
}
