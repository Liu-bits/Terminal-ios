// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Shared state for one terminal session: variables, shell functions and the
/// pending `exit` request all live here so they survive across command lines.
final class ShellSession {

    var environment: ShellEnvironment
    /// Shell functions defined so far, by name.
    var functions: [String: [ShellScriptNode]] = [:]
    /// Set by `exit`; the script runner and the engine stop when it is set.
    var exitStatus: Int?
    /// Nesting depth of script execution, so `exit` inside a function still
    /// unwinds only as far as it should.
    var scriptDepth = 0

    /// Lines still available to `read` inside the running script. A pipeline
    /// that feeds a script (`cat nums.txt | sum`) fills this queue.
    private var inputQueue: [String] = []

    /// True while a script with a defined stdin is running, so `read` can tell
    /// "no more input" (exit 1, ends a `while read` loop) from "not a script".
    private(set) var inputActive = false

    init(environment: ShellEnvironment) {
        self.environment = environment
    }

    /// Saved script-input state, so nested runs can be unwound exactly.
    struct InputState {
        var queue: [String]
        var active: Bool
    }

    /// Replaces the script input queue, returning the previous state so callers
    /// can restore it after a nested run.
    func setInput(_ text: String?) -> InputState {
        let previous = InputState(queue: inputQueue, active: inputActive)
        inputQueue = text.map(Self.splitLines) ?? []
        inputActive = text != nil
        return previous
    }

    /// Pops the next input line, or `nil` at end of input.
    func takeInputLine() -> String? {
        guard !inputQueue.isEmpty else { return nil }
        return inputQueue.removeFirst()
    }

    /// Puts a saved state back after a nested run finishes.
    func restoreInput(_ state: InputState) {
        inputQueue = state.queue
        inputActive = state.active
    }

    private static func splitLines(_ text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" {
            parts.removeLast()
        }
        return parts
    }

    /// Records the status of the last command so `$?` works.
    func record(status: Int) {
        environment.variables["?"] = "\(status)"
    }

    /// Sets a positional parameter list (`$1`, `$2`, ... and `$#`).
    func setPositional(_ values: [String]) {
        for index in 1...9 {
            environment.variables["\(index)"] = index <= values.count ? values[index - 1] : ""
        }
        environment.variables["#"] = "\(values.count)"
        environment.variables["@"] = values.joined(separator: " ")
    }
}

/// Statement tree produced by the script parser.
indirect enum ShellScriptNode: Equatable {
    /// One shell line, run through the normal tokenizer/parser/engine path.
    case command(String)
    /// `if cond; then ...; elif cond; then ...; else ...; fi`
    case ifChain(branches: [ShellBranch], elseBody: [ShellScriptNode])
    /// `for name in words; do ...; done`
    case forLoop(variable: String, words: [String], body: [ShellScriptNode])
    /// `while cond; do ...; done` (and `until`)
    case whileLoop(condition: String, body: [ShellScriptNode], until: Bool)
    /// `name() { ... }`
    case function(name: String, body: [ShellScriptNode])
}

struct ShellBranch: Equatable {
    var condition: String
    var body: [ShellScriptNode]
}

/// Parses shell source into `ShellScriptNode`s.
///
/// The parser is deliberately line-and-segment oriented rather than a full
/// POSIX grammar: it understands comments, backslash continuations, `;`
/// separated lists, `if`/`elif`/`else`, `for`, `while`/`until` and function
/// definitions, and hands every remaining segment to the ordinary command
/// parser. That covers the scripts people actually write on a phone terminal
/// without pretending to be `bash -n`.
enum ShellScriptParser {

    // MARK: - Lexing into items

    enum Item: Equatable {
        case keyword(String)
        case command(String)
    }

    /// Keywords that stand alone as items.
    private static let blockKeywords: Set<String> = [
        "then", "do", "done", "fi", "else", "{", "}"
    ]

    static func items(from source: String) -> [Item] {
        var items: [Item] = []
        for line in logicalLines(source) {
            let stripped = stripComment(line)
            guard !stripped.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            for segment in splitSegments(stripped) {
                items.append(contentsOf: classify(segment))
            }
        }
        return items
    }

    /// Joins backslash continuations and normalises line endings.
    private static func logicalLines(_ source: String) -> [String] {
        let normalised = source.replacingOccurrences(of: "\r\n", with: "\n")
        var result: [String] = []
        var pending = ""
        for line in normalised.components(separatedBy: "\n") {
            if line.hasSuffix("\\") {
                pending += String(line.dropLast()) + " "
                continue
            }
            result.append(pending + line)
            pending = ""
        }
        if !pending.isEmpty {
            result.append(pending)
        }
        return result
    }

    /// Removes a trailing `#` comment, respecting quotes.
    static func stripComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var result = ""
        var previousWasBlank = true
        for char in line {
            if char == "'", !inDouble {
                inSingle.toggle()
                result.append(char)
                previousWasBlank = false
                continue
            }
            if char == "\"", !inSingle {
                inDouble.toggle()
                result.append(char)
                previousWasBlank = false
                continue
            }
            if char == "#", !inSingle, !inDouble, previousWasBlank {
                break
            }
            previousWasBlank = char == " " || char == "\t" || char == ";"
            result.append(char)
        }
        return result
    }

    /// Splits a line on `;` and around block braces, ignoring separators that
    /// sit inside quotes.
    private static func splitSegments(_ line: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        for char in line {
            if char == "'", !inDouble {
                inSingle.toggle()
                current.append(char)
                continue
            }
            if char == "\"", !inSingle {
                inDouble.toggle()
                current.append(char)
                continue
            }
            if !inSingle, !inDouble, char == ";" {
                segments.append(current)
                current = ""
                continue
            }
            if !inSingle, !inDouble, char == "{" || char == "}" {
                segments.append(current)
                segments.append(String(char))
                current = ""
                continue
            }
            current.append(char)
        }
        segments.append(current)
        return segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Turns one segment into one or more items, pulling leading keywords out.
    private static func classify(_ segment: String) -> [Item] {
        let text = segment.trimmingCharacters(in: .whitespaces)
        if blockKeywords.contains(text) {
            return [.keyword(text)]
        }
        var items: [Item] = []
        // `if`, `elif`, `while`, `until`, `for` introduce a condition/header.
        for keyword in ["if", "elif", "while", "until", "for", "then", "else", "do", "fi", "done"] {
            guard text.hasPrefix(keyword + " ") || text == keyword else { continue }
            if text == keyword {
                items.append(.keyword(keyword))
            } else {
                items.append(.keyword(keyword))
                let remainder = String(text.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
                if !remainder.isEmpty {
                    items.append(.command(remainder))
                }
            }
            return items
        }
        // `name()` starts a function definition; the body brace is its own item.
        if text.hasSuffix("()") {
            let name = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), name.first?.isNumber == false {
                items.append(.keyword("function"))
                items.append(.command(name))
                return items
            }
        }
        return [.command(text)]
    }

    // MARK: - Parsing into a tree

    static func parse(_ source: String) -> [ShellScriptNode] {
        var parser = Parser(items: items(from: source))
        return parser.parseBlock(until: [])
    }

    private struct Parser {
        let items: [Item]
        var index = 0

        var isAtEnd: Bool { index >= items.count }

        mutating func peek() -> Item? {
            isAtEnd ? nil : items[index]
        }

        mutating func next() -> Item? {
            guard !isAtEnd else { return nil }
            let item = items[index]
            index += 1
            return item
        }

        /// Parses statements until one of `stops` is reached (it is consumed).
        /// The consumed terminator is recorded in `lastConsumedTerminator` so
        /// callers can tell `fi` from `elif`/`else`.
        mutating func parseBlock(until stops: Set<String>) -> [ShellScriptNode] {
            var nodes: [ShellScriptNode] = []
            lastConsumedTerminator = nil
            while let item = peek() {
                if case .keyword(let keyword) = item, stops.contains(keyword) {
                    lastConsumedTerminator = keyword
                    _ = next()
                    break
                }
                guard let node = parseStatement() else {
                    _ = next()
                    continue
                }
                nodes.append(node)
            }
            return nodes
        }

        mutating func parseStatement() -> ShellScriptNode? {
            guard let item = peek() else { return nil }
            switch item {
            case .command(let text):
                _ = next()
                return .command(text)
            case .keyword(let keyword):
                switch keyword {
                case "if": return parseIf()
                case "for": return parseFor()
                case "while": return parseWhile(until: false)
                case "until": return parseWhile(until: true)
                case "function": return parseFunction()
                default:
                    _ = next()
                    return nil
                }
            }
        }

        /// Reads the condition that follows `if` / `elif` / `while` / `until`.
        private mutating func parseCondition() -> String {
            var parts: [String] = []
            while let item = peek() {
                if case .keyword("then") = item { break }
                if case .keyword("do") = item { break }
                if case .command(let text) = item {
                    parts.append(text)
                    _ = next()
                    continue
                }
                break
            }
            return parts.joined(separator: " ")
        }

        /// Consumes the `then` / `do` keyword if present.
        private mutating func consume(_ keyword: String) {
            if case .keyword(let value) = peek(), value == keyword {
                _ = next()
            }
        }

        private mutating func parseIf() -> ShellScriptNode {
            consume("if")
            var branches: [ShellBranch] = []
            var elseBody: [ShellScriptNode] = []
            var condition = parseCondition()
            consume("then")
            while true {
                let body = parseBlock(until: ["elif", "else", "fi"])
                branches.append(ShellBranch(condition: condition, body: body))
                guard let item = lastConsumedTerminator else {
                    break
                }
                if item == "elif" {
                    condition = parseCondition()
                    consume("then")
                    continue
                }
                if item == "else" {
                    elseBody = parseBlock(until: ["fi"])
                    break
                }
                break
            }
            return .ifChain(branches: branches, elseBody: elseBody)
        }

        /// The terminator that ended the most recent `parseBlock` call.
        private var lastConsumedTerminator: String?

        private mutating func parseFor() -> ShellScriptNode {
            consume("for")
            var header = ""
            if case .command(let text) = peek() {
                header = text
                _ = next()
            }
            consume("do")
            let body = parseBlock(until: ["done"])
            let words = ShellTokenizer.tokenize(header) ?? []
            var name = ""
            var values: [String] = []
            var seenIn = false
            for token in words {
                guard case .word(let value) = token else { continue }
                if name.isEmpty {
                    name = value
                    continue
                }
                if value == "in", !seenIn {
                    seenIn = true
                    continue
                }
                if seenIn {
                    values.append(value)
                }
            }
            return .forLoop(variable: name.isEmpty ? "i" : name, words: values, body: body)
        }

        private mutating func parseWhile(until: Bool) -> ShellScriptNode {
            consume(until ? "until" : "while")
            let condition = parseCondition()
            consume("do")
            let body = parseBlock(until: ["done"])
            return .whileLoop(condition: condition, body: body, until: until)
        }

        private mutating func parseFunction() -> ShellScriptNode {
            consume("function")
            var name = ""
            if case .command(let text) = peek() {
                name = text
                _ = next()
            }
            consume("{")
            let body = parseBlock(until: ["}"])
            return .function(name: name, body: body)
        }
    }
}
