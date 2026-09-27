// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Foundation
import Testing

/// `tar` model and command.
@Suite("tar")
struct TarTests {

    /// A fresh engine rooted in a scratch directory, so filesystem work does not
    /// touch the real home directory.
    private func makeEngine() -> (ShellEngine, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tar-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment = ShellEnvironment(root: root)
        let engine = ShellEngine(environment: environment)
        return (engine, root)
    }

    @Test("creation, listing and a round trip")
    func roundTrip() throws {
        let (engine, root) = makeEngine()
        engine.run("mkdir -p tdir/nested")
        engine.run("printf 'hello tar\\n' > tdir/a.txt")
        engine.run("printf 'nested\\n' > tdir/nested/b.txt")

        #expect(engine.run("tar cf cross.tar tdir").exitCode == 0)

        let listing = engine.run("tar tf cross.tar")
        #expect(listing.output.contains("tdir/a.txt"))
        #expect(listing.output.contains("tdir/nested/b.txt"))

        let verbose = engine.run("tar tf -v cross.tar")
        // `a.txt` holds "hello tar\n", which is 10 bytes.
        #expect(verbose.output.contains("10"))

        #expect(engine.run("mkdir -p out; tar xf cross.tar -C out").exitCode == 0)
        #expect(engine.run("cat out/tdir/a.txt").output == "hello tar")
        #expect(engine.run("cat out/tdir/nested/b.txt").output == "nested")
        _ = root
    }

    @Test("names are stored relative to the sandbox root, not with a ~ prefix")
    func relativeNames() {
        let (engine, _) = makeEngine()
        engine.run("mkdir -p sub; printf 'x\\n' > sub/f.txt")
        engine.run("tar cf rel.tar sub")
        let listing = engine.run("tar tf rel.tar").output
        #expect(listing.contains("sub/f.txt"))
        #expect(listing.contains("~") == false)
    }

    @Test("extraction refuses paths that would escape the target directory")
    func refusesEscape() throws {
        let (engine, root) = makeEngine()
        engine.run("mkdir -p safe")
        let entry = TarArchive.Entry(
            name: "../evil", mode: 0o644, modificationTime: 0, kind: .file, linkTarget: "", data: Data("x".utf8)
        )
        let data = TarArchive.serialize([entry])
        try data.write(to: root.appendingPathComponent("escape.tar"))
        let result = engine.run("tar xf escape.tar -C safe")
        #expect(result.exitCode != 0)
        #expect(result.output.contains("refuses") || result.output.contains("outside"))
    }

    @Test("compression flags are refused with a message")
    func refusesCompression() {
        let (engine, _) = makeEngine()
        engine.run("mkdir -p tdir")
        let result = engine.run("tar czf x.tar tdir")
        #expect(result.exitCode == 2)
        #expect(result.output.contains("-z") || result.output.contains("gzip"))
    }

    @Test("checksum verification catches a corrupted header")
    func corruptedChecksum() throws {
        let (engine, root) = makeEngine()
        engine.run("printf 'data\\n' > f.txt")
        engine.run("tar cf ok.tar f.txt")

        let real = try Data(contentsOf: root.appendingPathComponent("ok.tar"))
        var bytes = [UInt8](real)
        if bytes.count > 10 { bytes[10] ^= 0xFF }
        try Data(bytes).write(to: root.appendingPathComponent("corrupt.tar"))

        let result = engine.run("tar tf corrupt.tar")
        #expect(result.exitCode != 0)
        #expect(result.output.contains("checksum"))
    }

    @Test("a missing archive and a non-tar file both fail cleanly")
    func missingArchive() {
        let (engine, _) = makeEngine()
        #expect(engine.run("tar tf nope.tar").exitCode == 1)
        engine.run("printf 'not a tar\\n' > plain.txt")
        #expect(engine.run("tar tf plain.txt").exitCode != 0)
    }
}
