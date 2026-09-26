// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Where a catalog comes from.
///
/// `bundled` sources are compiled into the app and always available. `remote`
/// sources are mirrors: they may only point at hosts from `MirrorPolicy`, and
/// installing from them still requires a verified SHA-256 and an interpreted
/// payload kind. Adding a mirror therefore means shipping a new binary rather
/// than fetching a configuration - that is the compliance argument, not a
/// limitation to work around.
struct CatalogSource: Codable, Equatable {
    var id: String
    var name: String
    /// `bundled` or `remote`.
    var kind: String
    /// Manifest URL (remote sources only).
    var url: String?
    /// Prefix prepended to relative payload paths (remote sources only).
    var payloadBase: String?
    /// Lower priority is consulted first.
    var priority: Int
    var enabled: Bool
    /// Mirrors stay disabled until the user turns them on explicitly.
    var enabledByDefault: Bool

    var isBundled: Bool { kind == "bundled" }

    init(
        id: String,
        name: String,
        kind: String,
        url: String? = nil,
        payloadBase: String? = nil,
        priority: Int,
        enabled: Bool = false,
        enabledByDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.payloadBase = payloadBase
        self.priority = priority
        self.enabled = enabled
        self.enabledByDefault = enabledByDefault
    }
}

/// The mirrors shipped with this build, and the rules they must satisfy.
///
/// Everything here is compiled in: the app can only ever talk to these hosts,
/// over HTTPS, under these path prefixes, and only when the user has enabled
/// the source and asked for a refresh.
enum MirrorPolicy {

    /// Hosts this build is allowed to contact, with the path prefixes that are
    /// acceptable. A wildcard would undo the point of the list.
    struct AllowedHost: Equatable {
        var host: String
        var pathPrefixes: [String]
    }

    static let allowedHosts: [AllowedHost] = [
        AllowedHost(
            host: "raw.githubusercontent.com",
            pathPrefixes: ["/Liu-bits/terminal-ios-catalog/"]
        ),
        AllowedHost(
            host: "terminal-ios-catalog.pages.dev",
            pathPrefixes: ["/"]
        ),
        AllowedHost(
            host: "cdn.jsdelivr.net",
            pathPrefixes: ["/gh/Liu-bits/terminal-ios-catalog@"]
        )
    ]

    /// Maximum manifest size (manifest only; payloads have their own cap).
    static let manifestByteLimit = 2 * 1024 * 1024
    /// Maximum payload size. Keeps a mirror from filling the container.
    static let payloadByteLimit = 32 * 1024 * 1024

    /// Payload kinds that may be fetched and executed. Anything else - most
    /// importantly native binaries - is refused before a byte is downloaded.
    static let fetchableKinds: Set<String> = ["script", "wheel", "wasm"]

    /// Mirrors offered for the same catalog on three continents. All disabled
    /// until the user opts in.
    static let shippedMirrors: [CatalogSource] = [
        CatalogSource(
            id: "mirror-global",
            name: "terminal-ios-catalog (global, jsDelivr)",
            kind: "remote",
            url: "https://cdn.jsdelivr.net/gh/Liu-bits/terminal-ios-catalog@main/catalog.json",
            payloadBase: "https://cdn.jsdelivr.net/gh/Liu-bits/terminal-ios-catalog@main/",
            priority: 20
        ),
        CatalogSource(
            id: "mirror-primary",
            name: "terminal-ios-catalog (GitHub raw)",
            kind: "remote",
            url: "https://raw.githubusercontent.com/Liu-bits/terminal-ios-catalog/main/catalog.json",
            payloadBase: "https://raw.githubusercontent.com/Liu-bits/terminal-ios-catalog/main/",
            priority: 30
        ),
        CatalogSource(
            id: "mirror-pages",
            name: "terminal-ios-catalog (project pages)",
            kind: "remote",
            url: "https://terminal-ios-catalog.pages.dev/catalog.json",
            payloadBase: "https://terminal-ios-catalog.pages.dev/",
            priority: 40
        )
    ]

    /// Checks a remote source against every rule. Returns a reason on failure.
    static func validate(urlString: String) -> FetchResult<URL> {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            return .failure("not a valid URL")
        }
        guard scheme == "https" else {
            return .failure("only https sources are allowed (got \(scheme))")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return .failure("source has no host")
        }
        guard let allowed = allowedHosts.first(where: { $0.host == host }) else {
            return .failure("host \(host) is not in this build's mirror allow-list")
        }
        let path = url.path.isEmpty ? "/" : url.path
        let permitted = allowed.pathPrefixes.contains { path.hasPrefix($0) }
        guard permitted else {
            return .failure("path \(path) is outside the allowed prefixes for \(host)")
        }
        return .success(url)
    }

    /// Whether a remote entry may be downloaded and run at all.
    static func validate(entry: CatalogEntry, source: CatalogSource) -> FetchResult<Void> {
        if source.isBundled {
            return .success(())
        }
        guard fetchableKinds.contains(entry.kind) else {
            return .failure("\(entry.name): remote payloads must be script/wheel/wasm, not '\(entry.kind)'")
        }
        guard let digest = entry.sha256, digest.count == 64 else {
            return .failure("\(entry.name): remote entries must carry a SHA-256 digest")
        }
        guard let relative = entry.payload, !relative.isEmpty else {
            return .failure("\(entry.name): remote entry has no payload path")
        }
        return .success(())
    }

    /// Absolute payload URL for an entry, honouring the source base.
    static func payloadURL(for entry: CatalogEntry, source: CatalogSource) -> FetchResult<URL> {
        guard let relative = entry.payload else {
            return .failure("\(entry.name): entry has no payload")
        }
        if let base = source.payloadBase, source.isBundled == false {
            guard let url = URL(string: base + relative) else {
                return .failure("\(entry.name): cannot build payload URL")
            }
            if case .failure(let reason) = validate(urlString: url.absoluteString) {
                return .failure(reason)
            }
            return .success(url)
        }
        guard let url = URL(string: relative) else {
            return .failure("\(entry.name): payload path is not a URL")
        }
        return .success(url)
    }
}

/// Ordered, persisted set of sources: the bundled catalog plus any mirrors the
/// user switched on.
final class SourceRegistry {

    private let stateDirectory: URL
    private let fileManager = FileManager.default
    private(set) var sources: [CatalogSource]

    /// The bundled source is always present and always enabled.
    static let bundled = CatalogSource(
        id: "bundled",
        name: "Terminal-ios bundled catalog",
        kind: "bundled",
        priority: 10,
        enabled: true,
        enabledByDefault: true
    )

    init(stateDirectory: URL) {
        self.stateDirectory = stateDirectory
        self.sources = SourceRegistry.load(from: stateDirectory)
    }

    private var stateFile: URL {
        stateDirectory.appendingPathComponent(".packages/sources.json")
    }

    private static func load(from directory: URL) -> [CatalogSource] {
        let file = directory.appendingPathComponent(".packages/sources.json")
        var result: [CatalogSource] = [bundled]
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([CatalogSource].self, from: data) {
            // Keep whichever stored entry we know about, refresh the rest from
            // the shipped list so a new build can update mirror URLs.
            for shipped in MirrorPolicy.shippedMirrors {
                if let match = stored.first(where: { $0.id == shipped.id }) {
                    var merged = shipped
                    merged.enabled = match.enabled
                    result.append(merged)
                } else {
                    result.append(shipped)
                }
            }
            for extra in stored
            where extra.isBundled == false && MirrorPolicy.shippedMirrors.contains(where: { $0.id == extra.id }) == false {
                result.append(extra)
            }
        } else {
            result.append(contentsOf: MirrorPolicy.shippedMirrors)
        }
        return result.sorted { $0.priority < $1.priority }
    }

    private func save() {
        try? fileManager.createDirectory(
            at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(sources) else { return }
        try? data.write(to: stateFile, options: .atomic)
    }

    var enabledSources: [CatalogSource] {
        sources.filter { $0.enabled }.sorted { $0.priority < $1.priority }
    }

    func source(id: String) -> CatalogSource? {
        sources.first { $0.id.lowercased() == id.lowercased() }
    }

    /// Registers a mirror. Only allow-listed hosts are accepted.
    func add(id: String, name: String, urlString: String) -> FetchResult<CatalogSource> {
        switch MirrorPolicy.validate(urlString: urlString) {
        case .failure(let reason):
            return .failure("E: \(reason)")
        case .success(let url):
            guard source(id: id) == nil else {
                return .failure("E: source '\(id)' already exists")
            }
            let source = CatalogSource(
                id: id,
                name: name,
                kind: "remote",
                url: url.absoluteString,
                payloadBase: url.deletingLastPathComponent().absoluteString,
                priority: 50,
                enabled: false
            )
            sources.append(source)
            sources.sort { $0.priority < $1.priority }
            save()
            return .success(source)
        }
    }

    func remove(id: String) -> FetchResult<Void> {
        guard let match = source(id: id) else {
            return .failure("E: no such source '\(id)'")
        }
        guard !match.isBundled else {
            return .failure("E: the bundled catalog cannot be removed")
        }
        sources.removeAll { $0.id == match.id }
        save()
        return .success(())
    }

    func setEnabled(id: String, enabled: Bool) -> FetchResult<CatalogSource> {
        guard let index = sources.firstIndex(where: { $0.id.lowercased() == id.lowercased() }) else {
            return .failure("E: no such source '\(id)'")
        }
        guard !sources[index].isBundled else {
            return .failure("E: the bundled catalog is always enabled")
        }
        sources[index].enabled = enabled
        save()
        return .success(sources[index])
    }
}
