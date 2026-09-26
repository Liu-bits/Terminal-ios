// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation
import CryptoKit

/// One package in the offline catalog.
///
/// `kind` decides how a payload is executed once installed:
/// - `script`  - a shell script materialised into the sandbox and run by `sh`
/// - `wasm`    - a `.wasm` module for the bundled interpreter (no JIT)
/// - `wheel`   - a pure-Python wheel unpacked into the Python prefix
/// - `toolchain` - a compiler/runtime bundle exposed as several commands
struct CatalogEntry: Codable, Equatable {
    var name: String
    var version: String
    var kind: String
    var summary: String
    /// Command names this package adds to `PATH`.
    var provides: [String]
    /// Bundle-relative payload path, e.g. `payloads/hello.sh`.
    var payload: String?
    /// Lower-case hex SHA-256 of the payload, verified before use.
    var sha256: String?
    /// Upstream project this payload was built from (informational).
    var source: String
    var license: String
    /// winget-style identifier, e.g. `Terminal-ios.hello`. Optional so older
    /// manifests still decode.
    var id: String?
    var publisher: String?
    var tags: [String]?

    /// Identifier shown by `winget list` / `winget search`.
    var packageID: String {
        id ?? "\(publisher ?? "Terminal-ios").\(name)"
    }

    var tagList: [String] {
        tags ?? []
    }

    /// Whether a search term matches this entry (name, id, summary or tags).
    func matches(_ term: String) -> Bool {
        let needle = term.lowercased()
        if needle.isEmpty { return true }
        if name.lowercased().contains(needle) { return true }
        if packageID.lowercased().contains(needle) { return true }
        if summary.lowercased().contains(needle) { return true }
        return tagList.contains { $0.lowercased().contains(needle) }
    }
}

/// The bundled catalog: the single, frozen package source.
///
/// It ships inside the app bundle and is never fetched. `sources` reports the
/// catalog identity so the origin of every package is auditable.
struct Catalog: Codable, Equatable {
    var schema: Int
    var name: String
    var generated: String
    var entries: [CatalogEntry]

    static func decode(_ json: String) -> Catalog? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }

    /// The catalog compiled into this build.
    static func bundled() -> Catalog {
        decode(BundledCatalog.json) ?? Catalog(schema: 1, name: "unavailable", generated: "", entries: [])
    }

    /// All command names any entry would provide.
    var providedCommands: [String] {
        entries.flatMap { $0.provides }.sorted()
    }

    func entry(named name: String) -> CatalogEntry? {
        entries.first { $0.name == name }
    }

    /// Entry providing a command name, used to resolve `python`, `gcc`, ...
    func entry(providing command: String) -> CatalogEntry? {
        entries.first { $0.provides.contains(command) }
    }

    /// Lookup by package name or winget id, case-insensitively.
    func entry(identifier: String) -> CatalogEntry? {
        entries.first {
            $0.name.lowercased() == identifier.lowercased()
                || $0.packageID.lowercased() == identifier.lowercased()
        }
    }
}

extension BundledCatalog {
    /// The parsed bundled manifest, decoded once per process.
    static let catalog: Catalog = Catalog.bundled()
}

/// Outcome of a lookup or a download: the value, or why it is unavailable.
///
/// `Result<Value, String>` is not an option because its failure type must
/// conform to `Error`; this keeps the reason a readable string.
enum FetchResult<Value> {
    case success(Value)
    case failure(String)
}

/// Payload lookups read better with their own name.
typealias PayloadLookup = FetchResult<String>

/// Payload storage: bundle text first, then the literals compiled into
/// `BundledCatalog`. Both paths verify the SHA-256 recorded in the catalog, so
/// a tampered payload is refused instead of executed.
enum PayloadStore {

    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the payload text for an entry, or a failure reason.
    static func text(for entry: CatalogEntry) -> PayloadLookup {
        guard let path = entry.payload else {
            return .failure("\(entry.name): catalog entry has no payload")
        }
        guard let body = BundledCatalog.payloads[path] ?? BundledCatalog.payloads[ShellRunContext.baseName(path)] else {
            return .failure("\(entry.name): payload \(path) is missing from the bundle")
        }
        if let expected = entry.sha256, !expected.isEmpty {
            let actual = sha256Hex(body)
            guard actual == expected else {
                return .failure("\(entry.name): payload digest mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)")
            }
        }
        return .success(body)
    }
}
