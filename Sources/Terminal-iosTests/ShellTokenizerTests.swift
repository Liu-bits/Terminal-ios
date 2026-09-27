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
        // Single quotes are kept in the word on purpose: expansion needs to know
        // which characters are literal. Double quotes are stripped, because
        // nothing inside them is protected from expansion.
        #expect(ShellTokenizer.tokenize("echo 'a b' \"c d\" e\\ f") == [
            .word("echo"), .word("'a b'"), .word("c d"), .word("e f"),
        ])
        #expect(ShellTokenizer.tokenize("echo \"a\\\"b\" 'c\\d'") == [
            .word("echo"), .word("a\"b"), .word("'c\\d'"),
        ])
    }

    @Test("Quotes protect their contents from expansion")
    func quotesProtectExpansion() {
        let environment = ShellEnvironment(
            root: FileManager.default.temporaryDirectory,
            variables: ["HOME": "/home/liu", "p": ""]
        )
        #expect(environment.expand("$HOME") == "/home/liu")
        #expect(environment.expand("'$HOME'") == "$HOME")
        #expect(environment.expand("pre'$HOME'post") == "pre$HOMEpost")
        // An apostrophe with no partner (it can only come from inside double
        // quotes) stays literal instead of swallowing the rest of the word.
        #expect(environment.expand("it's") == "it's")
        // Two quoted runs in one word, and an empty pair.
        #expect(environment.expand("'a'$p'b'") == "ab")
        #expect(environment.expand("''") == "")
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
