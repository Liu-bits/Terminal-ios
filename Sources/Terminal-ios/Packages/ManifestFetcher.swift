// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// How bytes are fetched from a mirror.
///
/// The shell is synchronous, so the protocol is synchronous as well; the real
/// implementation bridges `URLSession` with a semaphore and a timeout. Tests
/// inject a stub, which is what keeps the unit tests offline.
protocol ManifestTransport {
    /// Downloads a manifest or payload. Implementations must refuse anything
    /// that is not `https` on an allow-listed host.
    func fetch(_ url: URL, byteLimit: Int) -> FetchResult<Data>
}

/// A transport backed by a table of canned responses. Used by the tests and by
/// `support/local_check.py`, so no network is ever required to verify the
/// mirror logic.
final class StubTransport: ManifestTransport {

    private var responses: [String: Data] = [:]
    private(set) var requested: [String] = []

    init(responses: [String: String] = [:]) {
        for (url, body) in responses {
            self.responses[url] = Data(body.utf8)
        }
    }

    func put(_ url: String, _ body: String) {
        responses[url] = Data(body.utf8)
    }

    func fetch(_ url: URL, byteLimit: Int) -> FetchResult<Data> {
        requested.append(url.absoluteString)
        if case .failure(let reason) = MirrorPolicy.validate(urlString: url.absoluteString) {
            return .failure(reason)
        }
        guard let data = responses[url.absoluteString] else {
            return .failure("no response configured for \(url.absoluteString)")
        }
        guard data.count <= byteLimit else {
            return .failure("response exceeds \(byteLimit) bytes")
        }
        return .success(data)
    }
}

/// The transport the app uses, injected once at launch.
///
/// It is a variable so the tests and `support/local_check.py` can install a
/// stub and stay offline; the app sets it to `URLSessionTransport` from
/// `AppDelegate`.
enum ManifestTransportFactory {
    static var shared: ManifestTransport?
}

/// Fetches a parsed catalog for a source, verifying what the policy requires.
enum CatalogFetcher {

    /// Downloads and decodes the manifest of a remote source.
    static func load(
        source: CatalogSource,
        transport: ManifestTransport
    ) -> FetchResult<Catalog> {
        guard !source.isBundled else {
            return .success(BundledCatalog.catalog)
        }
        guard let urlString = source.url else {
            return .failure("\(source.id): source has no manifest URL")
        }
        let url: URL
        switch MirrorPolicy.validate(urlString: urlString) {
        case .failure(let reason):
            return .failure("\(source.id): \(reason)")
        case .success(let parsed):
            url = parsed
        }
        switch transport.fetch(url, byteLimit: MirrorPolicy.manifestByteLimit) {
        case .failure(let reason):
            return .failure("\(source.id): \(reason)")
        case .success(let data):
            guard let text = String(data: data, encoding: .utf8),
                  let catalog = Catalog.decode(text) else {
                return .failure("\(source.id): manifest is not a catalog")
            }
            guard catalog.schema == BundledCatalog.catalog.schema else {
                return .failure("\(source.id): unsupported catalog schema \(catalog.schema)")
            }
            return .success(catalog)
        }
    }

    /// Downloads one payload and verifies its digest before it is handed on.
    static func payload(
        entry: CatalogEntry,
        source: CatalogSource,
        transport: ManifestTransport
    ) -> FetchResult<String> {
        if case .failure(let reason) = MirrorPolicy.validate(entry: entry, source: source) {
            return .failure(reason)
        }
        let url: URL
        switch MirrorPolicy.payloadURL(for: entry, source: source) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let parsed):
            url = parsed
        }
        switch transport.fetch(url, byteLimit: MirrorPolicy.payloadByteLimit) {
        case .failure(let reason):
            return .failure("\(entry.name): \(reason)")
        case .success(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure("\(entry.name): payload is not UTF-8 text")
            }
            if let expected = entry.sha256, !expected.isEmpty {
                let actual = PayloadStore.sha256Hex(text)
                guard actual == expected else {
                    return .failure("\(entry.name): digest mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)")
                }
            }
            return .success(text)
        }
    }
}
