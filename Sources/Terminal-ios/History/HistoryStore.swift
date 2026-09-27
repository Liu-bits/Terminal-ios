// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Where snapshots live.
///
/// The protocol exists so the app can move to SQLite without touching the shell
/// or the search code, and so tests can use the in-memory implementation. The
/// bundled implementation writes one JSON file per store: a few thousand
/// snapshots is well inside what the IPA budget can carry, and it keeps the
/// local checker able to compile and exercise everything on Windows, where the
/// SQLite module is not available.
protocol HistoryStore: AnyObject {
    func entries() -> [HistoryEntry]
    func append(_ entry: HistoryEntry)
    func update(_ entry: HistoryEntry)
    func delete(id: String)
    func clear()
    func find(id: String) -> HistoryEntry?
}

extension HistoryStore {
    /// Newest first, which is the order every caller wants.
    func recent(_ count: Int) -> [HistoryEntry] {
        Array(entries().prefix(max(0, count)))
    }

    /// Accepts a full id or the eight-character prefix `tm` prints.
    func find(id: String) -> HistoryEntry? {
        entries().first { $0.id == id || $0.shortID == id }
    }

    func search(_ filter: HistoryFilter) -> [HistoryMatch] {
        HistorySearch.search(entries(), filter: filter)
    }
}

/// Snapshots held in memory. Used by the tests and by `tm` when a caller asked
/// for a scratch store.
final class MemoryHistoryStore: HistoryStore {

    private var storage: [HistoryEntry]
    /// Keeps a long session from growing without bound.
    let limit: Int

    init(entries: [HistoryEntry] = [], limit: Int = 2000) {
        self.storage = Array(entries.suffix(max(0, limit)).reversed())
        self.limit = max(1, limit)
    }

    func entries() -> [HistoryEntry] { storage }

    func append(_ entry: HistoryEntry) {
        storage.insert(entry, at: 0)
        if storage.count > limit {
            storage.removeLast(storage.count - limit)
        }
    }

    func update(_ entry: HistoryEntry) {
        guard let index = storage.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        storage[index] = entry
    }

    func delete(id: String) {
        storage.removeAll { $0.id == id || $0.shortID == id }
    }

    func clear() {
        storage = []
    }

    func find(id: String) -> HistoryEntry? {
        storage.first { $0.id == id || $0.shortID == id }
    }
}

/// Snapshots in one JSON file under the sandbox root.
///
/// Every operation loads, mutates and writes, so two instances pointing at the
/// same directory (the engine's recorder and a `tm` call, say) cannot disagree.
/// A shell writes a handful of snapshots per second at most, so the read cost
/// is not worth a cache that could go stale.
final class JSONHistoryStore: HistoryStore {

    let fileURL: URL
    let limit: Int

    init(directory: URL, fileName: String = "history.json", limit: Int = 2000) {
        self.fileURL = directory.appendingPathComponent(fileName)
        self.limit = max(1, limit)
    }

    private func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save(_ entries: [HistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    func entries() -> [HistoryEntry] { load() }

    func append(_ entry: HistoryEntry) {
        var list = load()
        list.insert(entry, at: 0)
        if list.count > limit {
            list.removeLast(list.count - limit)
        }
        save(list)
    }

    func update(_ entry: HistoryEntry) {
        var list = load()
        guard let index = list.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        list[index] = entry
        save(list)
    }

    func delete(id: String) {
        var list = load()
        list.removeAll { $0.id == id || $0.shortID == id }
        save(list)
    }

    func clear() {
        save([])
    }
}
