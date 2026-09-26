// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Offline package manager behind `apt`, `apk` and `pip`.
///
/// There is no download path anywhere in this type: installing resolves the
/// package in the bundled catalog, verifies its payload digest, and unpacks it
/// into the sandbox. `update` re-verifies what is already installed rather
/// than reaching for a network, which is what keeps the app compliant with
/// App Store Review Guideline 2.5.2 while still behaving like a package
/// manager from the terminal's point of view.
final class PackageManager {

    struct Outcome {
        var text: String
        var exitCode: Int

        static func ok(_ text: String = "") -> Outcome {
            Outcome(text: text, exitCode: 0)
        }

        static func fail(_ text: String, code: Int = 1) -> Outcome {
            Outcome(text: text, exitCode: code)
        }
    }

    /// Where the sandbox keeps installed packages and command shims.
    let stateDirectory: URL
    let catalog: Catalog

    private let fileManager = FileManager.default

    init(stateDirectory: URL, catalog: Catalog = .bundled()) {
        self.stateDirectory = stateDirectory
        self.catalog = catalog
    }

    // MARK: - Installed state

    private var stateFile: URL {
        stateDirectory.appendingPathComponent(".packages/installed.json")
    }

    /// Directory holding the materialised payloads.
    var prefixDirectory: URL {
        stateDirectory.appendingPathComponent(".packages/prefix", isDirectory: true)
    }

    /// Directory holding one executable shim per provided command.
    var binDirectory: URL {
        stateDirectory.appendingPathComponent(".packages/bin", isDirectory: true)
    }

    func installedNames() -> [String] {
        guard let data = try? Data(contentsOf: stateFile),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return names.sorted()
    }

    func isInstalled(_ name: String) -> Bool {
        installedNames().contains(name)
    }

    private func save(installed names: [String]) {
        try? fileManager.createDirectory(
            at: stateFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(names.sorted()) else { return }
        try? data.write(to: stateFile, options: .atomic)
    }

    // MARK: - Install / remove

    /// Installs the named packages, or everything in the catalog when empty.
    func install(_ names: [String]) -> Outcome {
        let targets: [CatalogEntry]
        if names.isEmpty {
            targets = catalog.entries
        } else {
            var resolved: [CatalogEntry] = []
            for name in names {
                guard let entry = catalog.entry(named: name) else {
                    return .fail("E: Unable to locate package \(name)")
                }
                resolved.append(entry)
            }
            targets = resolved
        }
        guard !targets.isEmpty else {
            return .fail("E: The catalog is empty")
        }

        var installed = installedNames()
        var lines: [String] = []
        var skipped = 0
        for entry in targets {
            if installed.contains(entry.name) {
                lines.append("\(entry.name) is already the newest version (\(entry.version)).")
                continue
            }
            guard entry.payload != nil else {
                lines.append("W: \(entry.name) (\(entry.version)) is declared in the catalog but its payload is not bundled in this build - skipped")
                skipped += 1
                continue
            }
            let payload = PayloadStore.text(for: entry)
            switch payload {
            case .failure(let reason):
                return .fail("E: \(reason)")
            case .success(let body):
                guard materialize(entry: entry, body: body) else {
                    return .fail("E: \(entry.name): failed to unpack payload")
                }
            }
            installed.append(entry.name)
            lines.append("Unpacking \(entry.name) (\(entry.version)) ... done")
            lines.append("Setting up \(entry.name) ... done")
        }
        save(installed: installed)
        let installedCount = targets.count - skipped
        lines.append("Installed \(installedCount) package(s) from \(catalog.name).")
        return .ok(lines.joined(separator: "\n"))
    }

    /// Writes the payload into the prefix and creates one shim per command.
    private func materialize(entry: CatalogEntry, body: String) -> Bool {
        do {
            try fileManager.createDirectory(at: prefixDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let extensionName = entry.kind == "script" ? "sh" : "payload"
        let payloadURL = prefixDirectory.appendingPathComponent("\(entry.name).\(extensionName)")
        do {
            try body.write(to: payloadURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        let shim = "#!/bin/sh\nexec \(entry.name) $@\n"
        for command in entry.provides {
            let shimURL = binDirectory.appendingPathComponent(command)
            try? shim.write(to: shimURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: shimURL.path
            )
        }
        return true
    }

    func remove(_ names: [String]) -> Outcome {
        guard !names.isEmpty else {
            return .fail("E: no package name given", code: 2)
        }
        var installed = installedNames()
        var lines: [String] = []
        for name in names {
            guard installed.contains(name) else {
                return .fail("E: Package \(name) is not installed")
            }
            guard let entry = catalog.entry(named: name) else {
                return .fail("E: Package \(name) is not in the catalog")
            }
            for command in entry.provides {
                let shim = binDirectory.appendingPathComponent(command)
                try? fileManager.removeItem(at: shim)
            }
            let payloadExtension = entry.kind == "script" ? "sh" : "payload"
            try? fileManager.removeItem(
                at: prefixDirectory.appendingPathComponent("\(name).\(payloadExtension)")
            )
            installed.removeAll { $0 == name }
            lines.append("Removing \(name) ... done")
        }
        save(installed: installed)
        return .ok(lines.joined(separator: "\n"))
    }

    func upgrade() -> Outcome {
        let installed = installedNames()
        guard !installed.isEmpty else {
            return .ok("0 upgraded, 0 newly installed, 0 to remove.")
        }
        return .ok("0 upgraded, 0 newly installed, 0 to remove.\nAll \(installed.count) installed package(s) match \(catalog.name).")
    }

    /// Offline equivalent of `apt update`: re-verify the installed payloads
    /// against the catalog digests and report any mismatch. When the network
    /// fetcher lands (see AGENTS.md) this is also where a remote index would be
    /// refreshed, behind the user's explicit consent.
    func update() -> Outcome {
        var lines = ["Hit:1 \(catalog.name) (bundled, read-only)"]
        var failures = 0
        for name in installedNames() {
            guard let entry = catalog.entry(named: name) else {
                lines.append("W: \(name) is not in the catalog any more")
                failures += 1
                continue
            }
            switch PayloadStore.text(for: entry) {
            case .success:
                break
            case .failure(let reason):
                lines.append("E: \(reason)")
                failures += 1
            }
        }
        lines.append("Reading package lists... Done")
        lines.append(failures == 0 ? "All payload digests verified." : "\(failures) package(s) need attention.")
        return Outcome(text: lines.joined(separator: "\n"), exitCode: failures == 0 ? 0 : 1)
    }

    // MARK: - Queries

    func list(pattern: String?) -> Outcome {
        let installed = installedNames()
        let rows = catalog.entries
            .filter { entry in
                guard let pattern, !pattern.isEmpty else { return true }
                return entry.name.contains(pattern)
            }
            .map { entry -> String in
                let mark = installed.contains(entry.name) ? "ii" : "un"
                return "\(pad(mark, 2)) \(pad(entry.name, 24)) \(pad(entry.version, 10)) \(entry.summary)"
            }
        guard !rows.isEmpty else {
            return .ok("")
        }
        return .ok(rows.joined(separator: "\n"))
    }

    /// Left-aligns text to `width` (a tiny stand-in for `String(format:)`'s
    /// field widths, which are unreliable for `%@`).
    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    func search(_ terms: [String]) -> Outcome {
        guard let term = terms.first, !term.isEmpty else {
            return .fail("E: no search term given", code: 2)
        }
        let hits = catalog.entries.filter {
            $0.name.contains(term) || $0.summary.lowercased().contains(term.lowercased())
        }
        guard !hits.isEmpty else {
            return .ok("No package matches '\(term)' in \(catalog.name).")
        }
        let rows = hits.map { entry in
            "\(entry.name)/\(entry.version)  \(entry.summary)\n  provides: \(entry.provides.joined(separator: ", "))"
        }
        return .ok(rows.joined(separator: "\n"))
    }

    func info(_ names: [String]) -> Outcome {
        guard let name = names.first else {
            return .fail("E: no package name given", code: 2)
        }
        guard let entry = catalog.entry(named: name) else {
            return .fail("E: Unable to locate package \(name)")
        }
        let installed = isInstalled(name) ? "yes" : "no"
        return .ok(
            """
            Package: \(entry.name)
            Version: \(entry.version)
            Kind: \(entry.kind)
            Installed: \(installed)
            Commands: \(entry.provides.joined(separator: ", "))
            Source: \(entry.source)
            License: \(entry.license)
            Digest: \(entry.sha256 ?? "-")
            Summary: \(entry.summary)
            """
        )
    }

    func sources() -> Outcome {
        .ok(
            """
            \(catalog.name) [bundled] schema=\(catalog.schema) generated=\(catalog.generated)
            \(catalog.entries.count) package(s); no network source is configured by design.
            """
        )
    }

    // MARK: - Command resolution

    /// Entry providing a command, and the script body to run for it.
    func script(for command: String) -> (entry: CatalogEntry, body: String)? {
        guard let entry = catalog.entry(providing: command),
              isInstalled(entry.name),
              case .success(let body) = PayloadStore.text(for: entry) else {
            return nil
        }
        return (entry, body)
    }
}
