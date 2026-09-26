// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Testing

struct ShellParserTests {

    @Test("Parses a pipeline with redirection")
    func parsesPipelineWithRedirection() {
        let tokens: [ShellToken] = [
            .word("cat"), .word("a.txt"), .pipe, .word("cat"),
            .redirectOut(append: false), .word("b.txt"),
        ]
        #expect(ShellParser.parse(tokens) == .pipeline([
            ShellCommand(argv: ["cat", "a.txt"], stdinFile: nil, stdoutFile: nil, stdoutAppend: false),
            ShellCommand(argv: ["cat"], stdinFile: nil, stdoutFile: "b.txt", stdoutAppend: false),
        ]))
    }

    @Test("Parses boolean chains with precedence")
    func parsesBooleanChains() {
        let tokens: [ShellToken] = [
            .word("a"), .and, .word("b"), .or, .word("c"), .sequence, .word("d"),
        ]
        #expect(ShellParser.parse(tokens) == .sequence(
            .or(.and(.pipeline([ShellCommand(argv: ["a"], stdinFile: nil, stdoutFile: nil, stdoutAppend: false)]),
                      .pipeline([ShellCommand(argv: ["b"], stdinFile: nil, stdoutFile: nil, stdoutAppend: false)])),
                .pipeline([ShellCommand(argv: ["c"], stdinFile: nil, stdoutFile: nil, stdoutAppend: false)])),
            .pipeline([ShellCommand(argv: ["d"], stdinFile: nil, stdoutFile: nil, stdoutAppend: false)])
        ))
    }

    @Test("Rejects dangling operators")
    func rejectsDanglingOperators() {
        #expect(ShellParser.parse([.word("a"), .pipe]) == nil)
        #expect(ShellParser.parse([.word("a"), .redirectOut(append: false)]) == nil)
        #expect(ShellParser.parse([.and, .word("a")]) == nil)
    }

    @Test("Parses redirection-only stages")
    func parsesRedirectionOnlyStages() {
        #expect(ShellParser.parse([.redirectOut(append: false), .word("f")]) == .pipeline([
            ShellCommand(argv: [], stdinFile: nil, stdoutFile: "f", stdoutAppend: false),
        ]))
        #expect(ShellParser.parse([.redirectIn, .word("f")]) == .pipeline([
            ShellCommand(argv: [], stdinFile: "f", stdoutFile: nil, stdoutAppend: false),
        ]))
    }
}
