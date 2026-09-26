// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Testing

struct ShellTokenizerTests {

    @Test("Splits plain words")
    func splitsPlainWords() {
        #expect(ShellTokenizer.tokenize("ls -la /tmp") == [
            .word("ls"), .word("-la"), .word("/tmp"),
        ])
    }

    @Test("Handles quotes and escapes")
    func handlesQuotesAndEscapes() {
        #expect(ShellTokenizer.tokenize("echo 'a b' \"c d\" e\\ f") == [
            .word("echo"), .word("a b"), .word("c d"), .word("e f"),
        ])
        #expect(ShellTokenizer.tokenize("echo \"a\\\"b\" 'c\\d'") == [
            .word("echo"), .word("a\"b"), .word("c\\d"),
        ])
    }

    @Test("Splits operators")
    func splitsOperators() {
        #expect(ShellTokenizer.tokenize("a|b||c&&d;e>f>>g<h") == [
            .word("a"), .pipe, .word("b"), .or, .word("c"), .and,
            .word("d"), .sequence, .word("e"), .redirectOut(append: false),
            .word("f"), .redirectOut(append: true), .word("g"),
            .redirectIn, .word("h"),
        ])
    }

    @Test("Rejects unterminated quotes")
    func rejectsUnterminatedQuotes() {
        #expect(ShellTokenizer.tokenize("echo 'abc") == nil)
        #expect(ShellTokenizer.tokenize("echo \"abc") == nil)
    }
}
