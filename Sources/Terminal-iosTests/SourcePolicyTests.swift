// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Foundation
import Testing

/// Covers the mirror rules: only allow-listed HTTPS hosts, only interpreted
/// payload kinds, mandatory digests, and an explicit opt-in before anything is
/// fetched. Everything runs against a stub transport, so no network is used.
@Suite(.serialized)
struct SourcePolicyTests {

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeEngine(_ root: URL) -> ShellEngine {
        ShellEngine(environment: ShellEnvironment(root: root))
    }

    // MARK: - Policy

    @Test("only https URLs on allow-listed hosts are accepted")
    func allowList() throws {
        if case .failure(let reason) = MirrorPolicy.validate(
            urlString: "https://raw.githubusercontent.com/Liu-bits/terminal-ios-catalog/main/catalog.json"
        ) {
            Issue.record("allow-listed mirror rejected: \(reason)")
        }
        #expect(isRejected("http://raw.githubusercontent.com/Liu-bits/terminal-ios-catalog/main/catalog.json"))
        #expect(isRejected("https://evil.example.com/catalog.json"))
        #expect(isRejected("https://raw.githubusercontent.com/someone-else/catalog/main/catalog.json"))
        #expect(isRejected("ftp://raw.githubusercontent.com/Liu-bits/terminal-ios-catalog/x"))
        #expect(isRejected("not a url"))
    }

    private func isRejected(_ url: String) -> Bool {
        if case .failure = MirrorPolicy.validate(urlString: url) { return true }
        return false
    }

    @Test("remote entries must be interpreted payloads with a digest")
    func entryRules() throws {
        let remote = CatalogSource(id: "m", name: "m", kind: "remote", priority: 20)
        let good = CatalogEntry(
            name: "a", version: "1", kind: "script", summary: "", provides: ["a"],
            payload: "payloads/a.sh", sha256: String(repeating: "a", count: 64),
            source: "s", license: "MIT"
        )
        if case .failure(let reason) = MirrorPolicy.validate(entry: good, source: remote) {
            Issue.record("valid remote entry refused: \(reason)")
        }
        var native = good
        native.kind = "native"
        #expect(entryRefused(native, remote))
        var noDigest = good
        noDigest.sha256 = nil
        #expect(entryRefused(noDigest, remote))
        var harness = good
        harness.payload = nil
        #expect(entryRefused(harness, remote))
    }

    private func entryRefused(_ entry: CatalogEntry, _ source: CatalogSource) -> Bool {
        if case .failure = MirrorPolicy.validate(entry: entry, source: source) { return true }
        return false
    }

    @Test("mirrors ship disabled and can only be switched on explicitly")
    func mirrorLifecycle() throws {
        let root = makeRoot()
        let engine = makeEngine(root)
        #expect(engine.run("apt sources").output.contains("bundled"))
        #expect(engine.run("apt sources").output.contains("disabled"))

        #expect(engine.run("apt sources enable mirror-primary").exitCode == 0)
        #expect(engine.run("apt sources").output.contains("mirror-primary"))
        #expect(engine.run("apt sources disable mirror-primary").exitCode == 0)
        #expect(engine.run("apt sources disable bundled").exitCode == 1)
        #expect(engine.run("apt sources remove bundled").exitCode == 1)
        #expect(engine.run("apt sources add evil https://evil.example.com/x.json").exitCode == 1)
        #expect(engine.run("apt sources add mine https://raw.githubusercontent.com/Liu-bits/terminal-ios-catalog/main/other.json").exitCode == 0)
        #expect(engine.run("apt sources remove mine").exitCode == 0)
    }

    // MARK: - Refresh and install from a mirror

    private func installMirror(_ engine: ShellEngine, kind: String = "script") -> (transport: StubTransport, digest: String) {
        let payload = "echo mirror-payload\n"
        let digest = PayloadStore.sha256Hex(payload)
        let identifier = kind == "script" ? "" : ",\"id\":\"Terminal-ios.evil\""
        let manifest = """
        {"schema":1,"name":"mirror","generated":"2026-09-27","entries":[
          {"name":"hello-mirror","version":"1.0.0","kind":"\(kind)","summary":"from a mirror",
           "provides":["hello-mirror"],"payload":"payloads/hello-mirror.sh","sha256":"\(digest)",
           "source":"test","license":"MIT","id":"Terminal-ios.hello-mirror"\(identifier)}]}
        """
        let base = "https://raw.githubusercontent.com/Liu-bits/terminal-ios-catalog/main/"
        let transport = StubTransport()
        transport.put(base + "catalog.json", manifest)
        transport.put(base + "payloads/hello-mirror.sh", payload)
        ManifestTransportFactory.shared = transport
        return (transport, digest)
    }

    @Test("a mirror manifest installs after an explicit refresh")
    func refreshAndInstall() throws {
        let root = makeRoot()
        let engine = makeEngine(root)
        let (transport, _) = installMirror(engine)
        defer { ManifestTransportFactory.shared = nil }

        // No refresh yet: the mirror is enabled but has no cached manifest.
        #expect(engine.run("apt sources enable mirror-primary").exitCode == 0)
        #expect(engine.run("apt install hello-mirror").exitCode == 1)

        let refresh = engine.run("apt refresh")
        #expect(refresh.exitCode == 0)
        #expect(refresh.output.contains("Get: mirror-primary"))
        #expect(transport.requested.contains { $0.hasSuffix("catalog.json") })

        #expect(engine.run("apt search hello-mirror").output.contains("mirror-primary"))
        #expect(engine.run("apt install hello-mirror").exitCode == 0)
        #expect(engine.run("hello-mirror").output == "mirror-payload")
        #expect(engine.run("winget list mirror").output.contains("Terminal-ios.hello-mirror"))
        #expect(engine.run("apt sources disable mirror-primary").exitCode == 0)
    }

    @Test("a mirror cannot hand over a native payload")
    func nativePayloadRefused() throws {
        let root = makeRoot()
        let engine = makeEngine(root)
        _ = installMirror(engine, kind: "native")
        defer { ManifestTransportFactory.shared = nil }

        #expect(engine.run("apt sources enable mirror-primary").exitCode == 0)
        #expect(engine.run("apt refresh").exitCode == 0)
        let install = engine.run("apt install hello-mirror")
        #expect(install.exitCode == 1)
        #expect(install.output.contains("script/wheel/wasm"))
        #expect(engine.run("hello-mirror").exitCode == 127)
    }

    @Test("a mismatched digest is refused")
    func digestMismatchRefused() throws {
        let root = makeRoot()
        let engine = makeEngine(root)
        let payload = "echo tampered\n"
        let manifest = """
        {"schema":1,"name":"mirror","generated":"2026-09-27","entries":[
          {"name":"tampered","version":"1.0.0","kind":"script","summary":"x","provides":["tampered"],
           "payload":"payloads/tampered.sh","sha256":"\(String(repeating: "b", count: 64))",
           "source":"test","license":"MIT"}]}
        """
        let base = "https://raw.githubusercontent.com/Liu-bits/terminal-ios-catalog/main/"
        let transport = StubTransport()
        transport.put(base + "catalog.json", manifest)
        transport.put(base + "payloads/tampered.sh", payload)
        ManifestTransportFactory.shared = transport
        defer { ManifestTransportFactory.shared = nil }

        _ = engine.run("apt sources enable mirror-primary")
        #expect(engine.run("apt refresh").exitCode == 0)
        let install = engine.run("apt install tampered")
        #expect(install.exitCode == 1)
        #expect(install.output.contains("digest mismatch"))
    }

    @Test("with no transport, remote installs explain themselves")
    func noTransport() throws {
        let root = makeRoot()
        let engine = makeEngine(root)
        ManifestTransportFactory.shared = nil
        _ = engine.run("apt sources enable mirror-primary")
        let install = engine.run("apt install hello")
        // `hello` is bundled, so it still installs without any network.
        #expect(install.exitCode == 0)
        #expect(engine.run("apt refresh").output.contains("no network transport"))
    }
}
