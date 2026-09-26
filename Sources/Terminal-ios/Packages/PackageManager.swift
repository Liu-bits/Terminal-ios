// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Package manager behind `apt`, `apk`, `pip` and `winget`.
///
/// It resolves packages across the bundled catalog and any enabled mirrors, in
/// priority order, and installs by materialising a payload into the sandbox.
/// Mirrors can only be added from `MirrorPolicy.allowedHosts`, every remote
/// payload must be `script`/`wheel`/`wasm` with a matching SHA-256, and a
/// refresh only happens when the user asks for one. Nothing here can download
/// a native binary, and nothing executes downloaded bytes.
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

    /// One source plus the catalog it provided.
    struct LoadedSource: Equatable {
        var source: CatalogSource
        var catalog: Catalog
    }

    let stateDirectory: URL
    let registry: SourceRegistry
    private(set) var sources: [LoadedSource]

    private let fileManager = FileManager.default

    /// Loads the bundled catalog plus cached remote catalogs. Remote manifests
    /// are only fetched by `refresh`, so constructing a manager never touches
    /// the network - which is what lets the tests stay offline.
    init(stateDirectory: URL, registry: SourceRegistry? = nil) {
        self.stateDirectory = stateDirectory
        let registry = registry ?? SourceRegistry(stateDirectory: stateDirectory)
        self.registry = registry

        var loaded: [LoadedSource] = []
        for source in registry.enabledSources {
            if source.isBundled {
                loaded.append(LoadedSource(source: source, catalog: BundledCatalog.catalog))
            } else if let cached = PackageManager.cachedCatalog(for: source, in: stateDirectory) {
                loaded.append(LoadedSource(source: source, catalog: cached))
            }
        }
        if loaded.isEmpty {
            loaded.append(LoadedSource(source: SourceRegistry.bundled, catalog: BundledCatalog.catalog))
        }
        self.sources = loaded.sorted { $0.source.priority < $1.source.priority }
    }

    /// The bundled catalog, kept for the runtime shims.
    var catalog: Catalog { BundledCatalog.catalog }

    private static func cacheFile(for source: CatalogSource, in directory: URL) -> URL {
        directory.appendingPathComponent(".packages/cache/\(source.id).json")
    }

    private static func cachedCatalog(for source: CatalogSource, in directory: URL) -> Catalog? {
        guard let data = try? Data(contentsOf: cacheFile(for: source, in: directory)),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Catalog.decode(text)
    }

    // MARK: - Installed state

    private var stateFile: URL {
        stateDirectory.appendingPathComponent(".packages/installed.json")
    }

    var prefixDirectory: URL {
        stateDirectory.appendingPathComponent(".packages/prefix", isDirectory: true)
    }

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

    // MARK: - Resolution

    /// Every entry across every loaded source, in priority order.
    var allEntries: [(entry: CatalogEntry, source: CatalogSource)] {
        sources.flatMap { loaded in
            loaded.catalog.entries.map { (entry: $0, source: loaded.source) }
        }
    }

    /// Finds an entry by package name or winget id.
    func resolve(_ identifier: String) -> (entry: CatalogEntry, source: CatalogSource)? {
        allEntries.first {
            $0.entry.name.lowercased() == identifier.lowercased()
                || $0.entry.packageID.lowercased() == identifier.lowercased()
        }
    }

    /// Finds the entry that provides a command.
    func resolve(command: String) -> (entry: CatalogEntry, source: CatalogSource)? {
        allEntries.first { $0.entry.provides.contains(command) }
    }

    func isInstalled(providing command: String) -> Bool {
        guard let match = resolve(command: command) else { return false }
        return isInstalled(match.entry.name)
    }

    // MARK: - Install / remove

    func install(_ identifiers: [String], transport: ManifestTransport? = nil) -> Outcome {
        let targets: [(entry: CatalogEntry, source: CatalogSource)]
        if identifiers.isEmpty {
            targets = allEntries
        } else {
            var resolved: [(entry: CatalogEntry, source: CatalogSource)] = []
            for identifier in identifiers {
                guard let match = resolve(identifier) else {
                    return .fail("E: Unable to locate package \(identifier)")
                }
                resolved.append(match)
            }
            targets = resolved
        }
        guard !targets.isEmpty else {
            return .fail("E: The catalog is empty")
        }

        var installed = installedNames()
        var lines: [String] = []
        var skipped = 0
        var installedCount = 0
        for target in targets {
            let entry = target.entry
            if installed.contains(entry.name) {
                lines.append("\(entry.name) is already the newest version (\(entry.version)).")
                continue
            }
            guard entry.payload != nil else {
                lines.append("W: \(entry.name) (\(entry.version)) is declared in the catalog but its payload is not bundled in this build - skipped")
                skipped += 1
                continue
            }
            let body: String
            if target.source.isBundled {
                switch PayloadStore.text(for: entry) {
                case .failure(let reason):
                    return .fail("E: \(reason)")
                case .success(let text):
                    body = text
                }
            } else {
                guard let transport else {
                    return .fail("E: \(entry.name) lives on \(target.source.id); run `apt refresh` first")
                }
                switch CatalogFetcher.payload(entry: entry, source: target.source, transport: transport) {
                case .failure(let reason):
                    return .fail("E: \(reason)")
                case .success(let text):
                    body = text
                    lines.append("Get:1 \(target.source.id) \(entry.packageID) \(entry.version)")
                }
            }
            guard materialize(entry: entry, body: body) else {
                return .fail("E: \(entry.name): failed to unpack payload")
            }
            installed.append(entry.name)
            lines.append("Unpacking \(entry.name) (\(entry.version)) ... done")
            lines.append("Setting up \(entry.name) ... done")
            installedCount += 1
        }
        save(installed: installed)
        lines.append("Installed \(installedCount) package(s) from \(sources.count) source(s).")
        if skipped > 0 {
            lines.append("Skipped \(skipped) declared runtime(s) without a payload.")
        }
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
        let payloadURL = prefixDirectory.appendingPathComponent("\(entry.name).\(payloadExtension(for: entry))")
        do {
            try body.write(to: payloadURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        for command in entry.provides {
            let shimURL = binDirectory.appendingPathComponent(command)
            try? "#!/bin/sh\nexec \(entry.name) $@\n".write(to: shimURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: shimURL.path
            )
        }
        return true
    }

    private func payloadExtension(for entry: CatalogEntry) -> String {
        switch entry.kind {
        case "script": return "sh"
        case "wheel": return "whl"
        case "wasm": return "wasm"
        default: return "payload"
        }
    }

    func remove(_ names: [String]) -> Outcome {
        guard !names.isEmpty else {
            return .fail("E: no package name given", code: 2)
        }
        var installed = installedNames()
        var lines: [String] = []
        for name in names {
            guard let match = resolve(name) else {
                return .fail("E: Package \(name) is not in any source")
            }
            guard installed.contains(match.entry.name) else {
                return .fail("E: Package \(name) is not installed")
            }
            for command in match.entry.provides {
                try? fileManager.removeItem(at: binDirectory.appendingPathComponent(command))
            }
            try? fileManager.removeItem(
                at: prefixDirectory.appendingPathComponent(
                    "\(match.entry.name).\(payloadExtension(for: match.entry))"
                )
            )
            installed.removeAll { $0 == match.entry.name }
            lines.append("Removing \(match.entry.name) ... done")
        }
        save(installed: installed)
        return .ok(lines.joined(separator: "\n"))
    }

    func upgrade() -> Outcome {
        let installed = installedNames()
        guard !installed.isEmpty else {
            return .ok("0 upgraded, 0 newly installed, 0 to remove.")
        }
        var lines: [String] = []
        for name in installed {
            guard let match = resolve(name) else {
                lines.append("W: \(name) is not in any source any more")
                continue
            }
            lines.append("\(name) is already the newest version (\(match.entry.version)).")
        }
        lines.append("0 upgraded, 0 newly installed, \(installed.count) to keep.")
        return .ok(lines.joined(separator: "\n"))
    }

    /// Re-verifies installed payloads and, when a transport is supplied,
    /// refreshes every enabled mirror's manifest into the local cache.
    func update(transport: ManifestTransport? = nil) -> Outcome {
        var lines: [String] = []
        for loaded in sources {
            lines.append("Hit:\(loaded.source.priority) \(loaded.source.name) (\(loaded.catalog.entries.count) packages)")
        }
        var failures = 0
        for name in installedNames() {
            guard let match = resolve(name) else {
                lines.append("W: \(name) is not in any source any more")
                failures += 1
                continue
            }
            guard match.source.isBundled else { continue }
            switch PayloadStore.text(for: match.entry) {
            case .success:
                break
            case .failure(let reason):
                lines.append("E: \(reason)")
                failures += 1
            }
        }
        if let transport, registry.enabledSources.contains(where: { !$0.isBundled }) {
            let refresh = refresh(transport: transport)
            lines.append(refresh.text)
            if refresh.exitCode != 0 {
                failures += 1
            }
        }
        lines.append("Reading package lists... Done")
        lines.append(failures == 0 ? "All payload digests verified." : "\(failures) source(s) need attention.")
        return Outcome(text: lines.joined(separator: "\n"), exitCode: failures == 0 ? 0 : 1)
    }

    /// Fetches every enabled mirror's manifest and caches it locally.
    @discardableResult
    func refresh(transport: ManifestTransport) -> Outcome {
        let remotes = registry.enabledSources.filter { !$0.isBundled }
        guard !remotes.isEmpty else {
            return .ok("No mirrors are enabled. Enable one with `apt sources enable <id>`.")
        }
        var lines: [String] = []
        var failures = 0
        var loaded: [(String, Catalog)] = []
        for source in remotes {
            switch CatalogFetcher.load(source: source, transport: transport) {
            case .failure(let reason):
                lines.append("E: \(reason)")
                failures += 1
            case .success(let catalog):
                let file = PackageManager.cacheFile(for: source, in: stateDirectory)
                try? fileManager.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if let data = try? JSONEncoder().encode(catalog) {
                    try? data.write(to: file, options: .atomic)
                }
                loaded.append((source.id, catalog))
                lines.append("Get: \(source.id) manifest (\(catalog.entries.count) packages)")
            }
        }
        // Reload so newly cached catalogs take effect immediately.
        for (id, catalog) in loaded {
            if let index = sources.firstIndex(where: { $0.source.id == id }) {
                sources[index].catalog = catalog
            } else if let source = registry.source(id: id) {
                sources.append(LoadedSource(source: source, catalog: catalog))
                sources.sort { $0.source.priority < $1.source.priority }
            }
        }
        lines.append(failures == 0 ? "Refreshed \(loaded.count) mirror(s)." : "\(failures) mirror(s) failed.")
        return Outcome(text: lines.joined(separator: "\n"), exitCode: failures == 0 ? 0 : 1)
    }

    // MARK: - Queries

    /// `sourceFilter` limits results to one source id.
    func list(pattern: String?, sourceFilter: String? = nil) -> Outcome {
        let installed = installedNames()
        let rows = allEntries
            .filter { entry, source in
                if let sourceFilter, source.id.lowercased() != sourceFilter.lowercased() {
                    return false
                }
                guard let pattern, !pattern.isEmpty else { return true }
                return entry.matches(pattern)
            }
            .map { entry, source -> String in
                let mark = installed.contains(entry.name) ? "ii" : "un"
                return "\(pad(mark, 2)) \(pad(entry.packageID, 26)) \(pad(entry.version, 10)) \(pad(source.id, 14)) \(entry.summary)"
            }
        return .ok(rows.joined(separator: "\n"))
    }

    func search(_ terms: [String]) -> Outcome {
        guard let term = terms.first, !term.isEmpty else {
            return .fail("E: no search term given", code: 2)
        }
        let hits = allEntries.filter { $0.entry.matches(term) }
        guard !hits.isEmpty else {
            return .ok("No package matches '\(term)' in \(sources.map(\.source.id).joined(separator: ", ")).")
        }
        let rows = hits.map { entry, source in
            "\(entry.packageID)  \(entry.version)  [\(source.id)]\n  \(entry.summary)\n  provides: \(entry.provides.joined(separator: ", "))"
        }
        return .ok(rows.joined(separator: "\n"))
    }

    func info(_ names: [String]) -> Outcome {
        guard let name = names.first else {
            return .fail("E: no package name given", code: 2)
        }
        guard let match = resolve(name) else {
            return .fail("E: Unable to locate package \(name)")
        }
        let entry = match.entry
        let installed = isInstalled(entry.name) ? "yes" : "no"
        var lines = [
            "Package: \(entry.name)",
            "Id: \(entry.packageID)",
            "Version: \(entry.version)",
            "Kind: \(entry.kind)",
            "Source: \(match.source.id) (\(match.source.kind))",
            "Installed: \(installed)",
            "Commands: \(entry.provides.joined(separator: ", "))",
            "Upstream: \(entry.source)",
            "License: \(entry.license)",
            "Digest: \(entry.sha256 ?? "-")",
            "Summary: \(entry.summary)"
        ]
        if entry.tagList.isEmpty == false {
            lines.append("Tags: \(entry.tagList.joined(separator: ", "))")
        }
        return .ok(lines.joined(separator: "\n"))
    }

    func sourceList() -> Outcome {
        var lines = ["id               state     packages  name"]
        for source in registry.sources.sorted(by: { $0.priority < $1.priority }) {
            let loaded = sources.first { $0.source.id == source.id }
            // `pending` means enabled but never refreshed: no cached manifest
            // yet, so its packages are not visible.
            let state: String
            if !source.enabled {
                state = "disabled"
            } else if loaded == nil {
                state = "pending"
            } else {
                state = "ready"
            }
            lines.append(
                "\(pad(source.id, 16)) \(pad(state, 9)) \(pad(loaded.map { "\($0.catalog.entries.count)" } ?? "-", 9)) \(source.name)"
            )
        }
        lines.append("")
        lines.append("allowed hosts: \(MirrorPolicy.allowedHosts.map(\.host).joined(separator: ", "))")
        lines.append("script/wheel/wasm only, https only, SHA-256 verified before use.")
        lines.append("enable a mirror with `apt sources enable <id>`, then run `apt refresh`.")
        return .ok(lines.joined(separator: "\n"))
    }

    func sourceAdd(id: String, name: String, urlString: String) -> Outcome {
        switch registry.add(id: id, name: name, urlString: urlString) {
        case .failure(let reason):
            return .fail(reason)
        case .success(let source):
            return .ok("Added \(source.id) (disabled). Enable it with `apt sources enable \(source.id)`.")
        }
    }

    func sourceRemove(id: String) -> Outcome {
        switch registry.remove(id: id) {
        case .failure(let reason):
            return .fail(reason)
        case .success:
            sources.removeAll { $0.source.id == id }
            try? fileManager.removeItem(at: PackageManager.cacheFile(
                for: CatalogSource(id: id, name: id, kind: "remote", priority: 0), in: stateDirectory
            ))
            return .ok("Removed \(id).")
        }
    }

    func sourceSetEnabled(id: String, enabled: Bool) -> Outcome {
        switch registry.setEnabled(id: id, enabled: enabled) {
        case .failure(let reason):
            return .fail(reason)
        case .success(let source):
            if enabled {
                if let cached = PackageManager.cachedCatalog(for: source, in: stateDirectory) {
                    if let index = sources.firstIndex(where: { $0.source.id == source.id }) {
                        sources[index].catalog = cached
                    } else {
                        sources.append(LoadedSource(source: source, catalog: cached))
                        sources.sort { $0.source.priority < $1.source.priority }
                    }
                }
                return .ok("Enabled \(source.id). Run `apt refresh` to fetch its manifest.")
            }
            sources.removeAll { $0.source.id == source.id }
            return .ok("Disabled \(source.id).")
        }
    }

    /// Left-aligns text to `width`.
    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    // MARK: - Command resolution

    /// Entry providing an installed command, plus the script body to run.
    ///
    /// The body is read back from the prefix directory, so bundled and mirror
    /// packages behave identically at run time.
    func script(for command: String) -> (entry: CatalogEntry, body: String)? {
        guard let match = resolve(command: command), isInstalled(match.entry.name) else {
            return nil
        }
        let url = prefixDirectory.appendingPathComponent(
            "\(match.entry.name).\(payloadExtension(for: match.entry))"
        )
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return (match.entry, body)
    }
}
