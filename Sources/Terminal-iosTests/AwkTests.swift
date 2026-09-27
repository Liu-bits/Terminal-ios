// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Foundation
import Testing

/// The `awk` interpreter, checked against the semantics of a real awk.
@Suite("awk")
struct AwkTests {

    private func makeEngine() -> ShellEngine {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("awk-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ShellEngine(environment: ShellEnvironment(root: root))
    }

    @Test("fields, NF, NR and the last field")
    func fields() {
        let engine = makeEngine()
        engine.run("printf 'one two three\\ntwo two four\\nfive six seven\\n' > aw.txt")
        #expect(engine.run("awk '{ print $1 }' aw.txt").output == "one\ntwo\nfive")
        #expect(engine.run("awk '{ print NF }' aw.txt").output == "3\n3\n3")
        #expect(engine.run("awk '{ print NR }' aw.txt").output == "1\n2\n3")
        #expect(engine.run("awk '{ print $NF }' aw.txt").output == "three\nfour\nseven")
    }

    @Test("BEGIN and END blocks run once each")
    func beginEnd() {
        let engine = makeEngine()
        engine.run("printf 'a\\nb\\n' > f.txt")
        #expect(
            engine.run("awk 'BEGIN { print \"start\" } { print $1 } END { print \"end\" }' f.txt").output
            == "start\na\nb\nend"
        )
    }

    @Test("a trailing newline does not produce an empty record")
    func trailingNewline() {
        let engine = makeEngine()
        engine.run("printf 'a\\nb\\n' > f.txt")
        #expect(engine.run("awk '{ print NR }' f.txt").output == "1\n2")
    }

    @Test("field assignment rejoins with OFS")
    func fieldAssignment() {
        let engine = makeEngine()
        #expect(
            engine.run("printf 'a b\\n' | awk 'BEGIN { OFS = \"-\" } { $1 = \"x\"; $2 = \"y\"; print }'").output
            == "x-y"
        )
    }

    @Test("accumulation with += and END")
    func accumulation() {
        let engine = makeEngine()
        #expect(engine.run("printf '1\\n2\\n3\\n' | awk '{ s += $1 } END { print s }'").output == "6")
    }

    @Test("printf with a zero-padded width")
    func printfWidth() {
        let engine = makeEngine()
        #expect(engine.run("printf '2\\n' | awk '{ printf \"%02d\", $1 }'").output == "02")
    }

    @Test("built-in functions length, substr, toupper, tolower, int")
    func functions() {
        let engine = makeEngine()
        #expect(engine.run("printf 'abc\\n' | awk '{ print length($0) }'").output == "3")
        #expect(engine.run("printf 'abc\\n' | awk '{ print substr($0, 2, 2) }'").output == "bc")
        #expect(engine.run("printf 'abc\\n' | awk '{ print toupper($0) }'").output == "ABC")
        #expect(engine.run("printf 'ABC\\n' | awk '{ print tolower($0) }'").output == "abc")
        #expect(engine.run("printf '3.9\\n' | awk '{ print int($1) }'").output == "3")
    }

    @Test("a bare pattern prints the whole record, and a missing field is empty")
    func defaultActionAndMissingField() {
        let engine = makeEngine()
        engine.run("printf 'one two\\nthree four\\n' > f.txt")
        #expect(engine.run("awk '/four/' f.txt").output == "three four")
        #expect(engine.run("printf 'a\\n' | awk '{ print $5 }'").output == "")
    }

    @Test("if/else and next")
    func controlFlow() {
        let engine = makeEngine()
        #expect(engine.run("printf '10\\n' | awk '{ if ($1 > 5) print \"big\"; else print \"small\" }'").output == "big")
        #expect(engine.run("printf '1\\n2\\n3\\n' | awk 'NR == 1 { next } { print $1 }'").output == "2\n3")
    }

    @Test("a parse error is reported, not half-run")
    func parseError() {
        let engine = makeEngine()
        #expect(engine.run("awk '{ print'").exitCode != 0)
    }
}
