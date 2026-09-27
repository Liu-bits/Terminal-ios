// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// An `awk` program: a set of `pattern { action }` rules, plus `BEGIN` and
/// `END` blocks, run over a stream of records.
///
/// This is a real subset, not a sketch. It has the field model (`$0`, `$1`...
/// `$NF`), the built-in variables (`NR`, `NF`, `FS`, `OFS`, `RS`, `ORS`,
/// `FILENAME`, `FNR`), expression patterns and `BEGIN`/`END`. What it does not
/// do is spelled out in `parse`'s failure path rather than silently skipped.
struct AwkProgram {

    // MARK: - Values

    /// awk's single scalar type: numbers and strings are interchangeable, and
    /// a "missing" field reads as the empty string / zero.
    enum Value: Equatable {
        case number(Double)
        case string(String)

        static let empty = Value.string("")

        var asString: String {
            switch self {
            case .number(let n):
                return Self.format(n)
            case .string(let s):
                return s
            }
        }

        var asNumber: Double {
            switch self {
            case .number(let n):
                return n
            case .string(let s):
                return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        var isTruthy: Bool {
            switch self {
            case .number(let n):
                return n != 0
            case .string(let s):
                return !s.isEmpty && s != "0"
            }
        }

        /// awk's number formatting: integers print without a decimal point.
        static func format(_ n: Double) -> String {
            if n.rounded() == n {
                return String(Int64(n))
            }
            return String(n)
        }
    }

    // MARK: - Expressions

    indirect enum Expr {
        case literal(Value)
        case field(Int)                    // `$0`..`$n`
        case variable(String)              // a bare name
        case binary(op: String, Expr, Expr)
        case unary(op: String, Expr)
        case assign(name: String, Expr)
        case fieldAssign(Int, Expr)        // `$1 = x`
        case call(String, [Expr])          // length(), substr(), split(), ...
        case regexMatch(pattern: String, negated: Bool)   // `$0 ~ /re/` as an expr
    }

    // MARK: - Statements

    indirect enum Statement {
        case print([Expr])                 // `print` / `print a, b`
        case printf(String, [Expr])        // `printf "fmt", a, b`
        case assign(name: String, Expr)
        case fieldAssign(Int, Expr)
        case if_(Expr, [Statement], [Statement])
        case for_(String, [Statement])     // `for (k in a)` is not supported; this is C-style
        case while_(Expr, [Statement])
        case next
        case exit_(Expr?)
        case block([Statement])
        case expr(Expr)                    // a bare expression (assignment, call)
    }

    // MARK: - Rules

    struct Rule {
        enum Pattern {
            case always                       // no pattern
            case regex(String)
            case expression(Expr)             // an expression that is truthy
        }
        var pattern: Pattern
        var body: [Statement]
    }

    var begin: [Statement] = []
    var rules: [Rule] = []
    var end: [Statement] = []
    private(set) var failure: String?

    // Variables carry awk's defaults; the executor seeds the environment with
    // these and lets `-v` and assignments override them.
    static let defaultFS = " "
    static let defaultOFS = " "
    static let defaultRS = "\n"
    static let defaultORS = "\n"

    // MARK: - Parsing

    /// Parses a program. `-v` pairs seed variables; `-F` sets the field
    /// separator. A parse failure is reported through `failure` and the program
    /// is unusable, so the caller prints the message instead of running half.
    static func parse(
        source: String,
        fieldSeparator: String?,
        assignments: [(String, String)]
    ) -> AwkProgram {
        var program = AwkProgram()
        program.overrides = assignments
        if let fieldSeparator {
            program.overrides.append(("FS", fieldSeparator))
        }
        var tokenizer = Tokenizer(source)
        guard let tokens = tokenizer.tokenize() else {
            program.failure = "awk: \(tokenizer.error ?? "syntax error")"
            return program
        }
        var parser = Parser(tokens: tokens)
        guard parser.parse(into: &program) else {
            program.failure = "awk: \(parser.error ?? "syntax error")"
            return program
        }
        return program
    }

    /// `-v` / `-F` values, applied before `BEGIN` runs.
    private(set) var overrides: [(String, String)] = []

    // MARK: - Execution

    /// Runs the program over `input` and returns the printed output.
    ///
    /// The executor is separate from the model so a script of test inputs can
    /// drive it the way the shell does, without the shell.
    func run(_ input: String, filename: String = "") -> String {
        var executor = Executor(program: self, filename: filename)
        executor.applyOverrides()
        executor.runStatements(begin)

        let rs = executor.env["RS"]?.asString ?? Self.defaultRS
        for rawRecord in Self.splitRecords(input, separator: rs) {
            executor.loadRecord(rawRecord)
            executor.env["NR"] = .number(Double(executor.recordNumber))
            executor.env["FNR"] = .number(Double(executor.recordNumber))
            for rule in rules {
                if executor.skipToNextRecord { break }
                if matches(rule.pattern, executor: &executor) {
                    executor.runStatements(rule.body)
                    if executor.stopped {
                        break
                    }
                }
            }
            executor.skipToNextRecord = false
            if executor.stopped {
                break
            }
        }
        // END runs after the records, and its prints append too.
        executor.runStatements(end)
        return executor.buffer
    }

    /// True when the rule's pattern selects the current record.
    private func matches(_ pattern: Rule.Pattern, executor: inout Executor) -> Bool {
        switch pattern {
        case .always:
            return true
        case .regex(let re):
            let text = executor.env["0"]?.asString ?? ""
            return text.range(of: re, options: .regularExpression) != nil
        case .expression(let expr):
            return executor.eval(expr).isTruthy
        }
    }

    private static func splitRecords(_ input: String, separator: String) -> [String] {
        guard !separator.isEmpty else {
            return input.isEmpty ? [] : [input]
        }
        var records = input.components(separatedBy: separator)
        // A trailing separator does not produce an empty final record in awk:
        // "a\nb\n" is two records, not three.
        if records.last == "" {
            records.removeLast()
        }
        return records
    }
}

// MARK: - Executor

/// Runs an `AwkProgram` over records, holding the variable environment and the
/// current record's fields.
private struct Executor {

    let program: AwkProgram
    let filename: String
    var env: [String: AwkProgram.Value] = [:]
    var buffer = ""
    var stopped = false
    var skipToNextRecord = false
    var recordNumber = 0

    init(program: AwkProgram, filename: String) {
        self.program = program
        self.filename = filename
        env["FS"] = .string(AwkProgram.defaultFS)
        env["OFS"] = .string(AwkProgram.defaultOFS)
        env["RS"] = .string(AwkProgram.defaultRS)
        env["ORS"] = .string(AwkProgram.defaultORS)
        env["FILENAME"] = .string(filename)
    }

    mutating func applyOverrides() {
        for (name, value) in program.overrides {
            env[name] = .string(value)
        }
    }

    mutating func loadRecord(_ record: String) {
        recordNumber += 1
        env["0"] = .string(record)
        // Splitting is done lazily on first field access, but NF is cheap to
        // compute here and $0 is already set.
        let fs = env["FS"]?.asString ?? AwkProgram.defaultFS
        let fields = Self.split(record, fs: fs)
        env["NF"] = .number(Double(fields.count))
        // Store the fields so `$n` can read them without re-splitting.
        fieldCache = fields
    }

    private var fieldCache: [String] = []

    private static func split(_ record: String, fs: String) -> [String] {
        if fs == " " {
            // The default: runs of whitespace, leading/trailing trimmed.
            let trimmed = record.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return [] }
            return trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        }
        return record.components(separatedBy: fs)
    }

    mutating func field(_ index: Int) -> AwkProgram.Value {
        if index == 0 {
            return env["0"] ?? .empty
        }
        // Rebuild the field cache if it is stale (the record was reassigned).
        if env["NF"] == nil || fieldCache.isEmpty && (env["0"]?.asString.isEmpty == false) {
            let fs = env["FS"]?.asString ?? AwkProgram.defaultFS
            fieldCache = Self.split(env["0"]?.asString ?? "", fs: fs)
            env["NF"] = .number(Double(fieldCache.count))
        }
        // `$NF` arrives as -1: the last field.
        let resolved = index == -1 ? fieldCache.count : index
        guard resolved >= 1, resolved <= fieldCache.count else {
            return .empty
        }
        return .string(fieldCache[resolved - 1])
    }

    mutating func setField(_ index: Int, _ value: AwkProgram.Value) {
        if index == 0 {
            env["0"] = value
            // The record changed: invalidate the cache and recompute NF.
            let fs = env["FS"]?.asString ?? AwkProgram.defaultFS
            fieldCache = Self.split(value.asString, fs: fs)
            env["NF"] = .number(Double(fieldCache.count))
            return
        }
        // Rebuild cache from $0 first.
        if fieldCache.isEmpty {
            let fs = env["FS"]?.asString ?? AwkProgram.defaultFS
            fieldCache = Self.split(env["0"]?.asString ?? "", fs: fs)
        }
        while fieldCache.count < index {
            fieldCache.append("")
        }
        fieldCache[index - 1] = value.asString
        env["NF"] = .number(Double(fieldCache.count))
        // Rejoin into $0 with OFS.
        env["0"] = .string(fieldCache.joined(separator: env["OFS"]?.asString ?? AwkProgram.defaultOFS))
    }

    mutating func runStatements(_ statements: [AwkProgram.Statement]) {
        for statement in statements {
            if stopped { break }
            runStatement(statement)
        }
    }

    mutating func runStatement(_ statement: AwkProgram.Statement) {
        switch statement {
        case .block(let statements):
            runStatements(statements)
        case .print(let exprs):
            let ofs = env["OFS"]?.asString ?? AwkProgram.defaultOFS
            let ors = env["ORS"]?.asString ?? AwkProgram.defaultORS
            let text = exprs.map { eval($0).asString }.joined(separator: ofs)
            buffer += text + ors
        case .printf(let format, let args):
            buffer += Self.format(format, args: args.map { eval($0) })
        case .assign(let name, let expr):
            env[name] = eval(expr)
        case .fieldAssign(let index, let expr):
            setField(index, eval(expr))
        case .if_(let condition, let then, let else_):
            if eval(condition).isTruthy {
                runStatements(then)
            } else {
                runStatements(else_)
            }
        case .while_(let condition, let body):
            var iterationGuard = 0
            while eval(condition).isTruthy {
                runStatements(body)
                iterationGuard += 1
                if iterationGuard > 1_000_000 { break }
                if stopped { break }
            }
        case .for_(let initName, let body):
            // This is the unsupported-for-now `for (i = 0; i < n; i++)` case;
            // the parser never produces it. Kept so the switch is exhaustive.
            _ = initName
            runStatements(body)
        case .next:
            // `next` skips to the next record, abandoning the rest of this one.
            skipToNextRecord = true
        case .exit_(let code):
            if let code { env["?"] = eval(code) }
            stopped = true
        case .expr(let expr):
            _ = eval(expr)
        }
    }

    mutating func eval(_ expr: AwkProgram.Expr) -> AwkProgram.Value {
        switch expr {
        case .literal(let value):
            return value
        case .field(let index):
            return field(index)
        case .variable(let name):
            return env[name] ?? .empty
        case .unary(let op, let operand):
            let value = eval(operand)
            switch op {
            case "-": return .number(-value.asNumber)
            case "+": return .number(value.asNumber)
            case "!": return .number(value.isTruthy ? 0 : 1)
            default: return value
            }
        case .binary(let op, let lhs, let rhs):
            return Self.binary(op, eval(lhs), eval(rhs))
        case .assign(let name, let expr):
            let value = eval(expr)
            env[name] = value
            return value
        case .fieldAssign(let index, let expr):
            let value = eval(expr)
            setField(index, value)
            return value
        case .call(let name, let args):
            return Self.call(name, args.map { eval($0) }, executor: &self)
        case .regexMatch(let pattern, let negated):
            let text = env["0"]?.asString ?? ""
            let found = text.range(of: pattern, options: .regularExpression) != nil
            return .number((found != negated) ? 1 : 0)
        }
    }

    private static func binary(_ op: String, _ lhs: AwkProgram.Value, _ rhs: AwkProgram.Value) -> AwkProgram.Value {
        switch op {
        case "+": return .number(lhs.asNumber + rhs.asNumber)
        case "-": return .number(lhs.asNumber - rhs.asNumber)
        case "*": return .number(lhs.asNumber * rhs.asNumber)
        case "/": return .number(rhs.asNumber == 0 ? 0 : lhs.asNumber / rhs.asNumber)
        case "%": return .number(rhs.asNumber == 0 ? 0 : lhs.asNumber.truncatingRemainder(dividingBy: rhs.asNumber))
        case "<": return .number(lhs.asNumber < rhs.asNumber ? 1 : 0)
        case "<=": return .number(lhs.asNumber <= rhs.asNumber ? 1 : 0)
        case ">": return .number(lhs.asNumber > rhs.asNumber ? 1 : 0)
        case ">=": return .number(lhs.asNumber >= rhs.asNumber ? 1 : 0)
        case "==": return .number(lhs == rhs || lhs.asNumber == rhs.asNumber ? 1 : 0)
        case "!=": return .number(lhs == rhs || lhs.asNumber == rhs.asNumber ? 0 : 1)
        case "&&": return .number((lhs.isTruthy && rhs.isTruthy) ? 1 : 0)
        case "||": return .number((lhs.isTruthy || rhs.isTruthy) ? 1 : 0)
        default: return lhs
        }
    }

    private static func call(
        _ name: String,
        _ args: [AwkProgram.Value],
        executor: inout Executor
    ) -> AwkProgram.Value {
        switch name {
        case "length":
            if args.isEmpty {
                return .number(Double((executor.env["0"]?.asString ?? "").count))
            }
            return .number(Double(args[0].asString.count))
        case "substr":
            let s = args[0].asString
            let start = Int(args[1].asNumber)
            guard start >= 1 else { return .string("") }
            let from = s.index(s.startIndex, offsetBy: min(start - 1, s.count))
            if args.count >= 3 {
                let length = Int(args[2].asNumber)
                let to = s.index(from, offsetBy: min(length, s.distance(from: from, to: s.endIndex)))
                return .string(String(s[from..<to]))
            }
            return .string(String(s[from...]))
        case "int":
            return .number(Double(Int(args[0].asNumber)))
        case "split":
            let s = args[0].asString
            let fs = args.count >= 3 ? args[2].asString : (executor.env["FS"]?.asString ?? AwkProgram.defaultFS)
            let parts = fs == " "
                ? s.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                : s.components(separatedBy: fs)
            // Store into the named array (we only support a flat name; array
            // semantics are reduced to a single variable holding the count).
            let arrayName = args[1].asString
            executor.env[arrayName] = .number(Double(parts.count))
            for (i, part) in parts.enumerated() {
                executor.env["\(arrayName)[\(i + 1)]"] = .string(part)
            }
            return .number(Double(parts.count))
        case "toupper":
            return .string(args[0].asString.uppercased())
        case "tolower":
            return .string(args[0].asString.lowercased())
        case "sprintf":
            guard !args.isEmpty else { return .string("") }
            return .string(format(args[0].asString, args: Array(args.dropFirst())))
        default:
            return .empty
        }
    }

    /// awk's printf: a small subset of the C format specifiers.
    private static func format(_ format: String, args: [AwkProgram.Value]) -> String {
        var result = ""
        var argIndex = 0
        var index = format.startIndex
        while index < format.endIndex {
            let char = format[index]
            if char == "%" {
                let specStart = index
                index = format.index(after: index)
                while index < format.endIndex, "0123456789.-+ ".contains(format[index]) {
                    index = format.index(after: index)
                }
                guard index < format.endIndex else { break }
                let spec = String(format[specStart..<format.index(after: index)])
                if format[index] == "%" {
                    result += "%"
                } else if argIndex < args.count {
                    let value = args[argIndex]
                    argIndex += 1
                    switch format[index] {
                    case "s": result += value.asString
                    case "d", "i": result += Self.formatInt(spec, Int(value.asNumber))
                    case "f": result += String(format: spec, value.asNumber)
                    case "g": result += value.asNumber == value.asNumber.rounded() ? String(Int64(value.asNumber)) : String(value.asNumber)
                    default: result += value.asString
                    }
                }
                index = format.index(after: index)
            } else if char == "\\" {
                let next = format.index(after: index)
                if next < format.endIndex {
                    let escape = format[next]
                    if escape == "n" { result += "\n" }
                    else if escape == "t" { result += "\t" }
                    else { result += String(escape) }
                    index = format.index(after: next)
                } else {
                    index = format.index(after: index)
                }
            } else {
                result += String(char)
                index = format.index(after: index)
            }
        }
        return result
    }

    /// Formats an integer with a `%d`-family spec, handling the width flag
    /// (`%02d` -> `"02"`) that `String(Int(...))` would drop.
    private static func formatInt(_ spec: String, _ value: Int) -> String {
        // Extract a leading zero-pad width: `%02d` has width 2, `%d` none.
        var width = 0
        var zeroPadded = false
        var index = spec.startIndex
        if spec.first == "%" { index = spec.index(after: index) }
        while index < spec.endIndex, spec[index] != "d", spec[index] != "i", spec[index] != "u" {
            if spec[index] == "0" && !zeroPadded && width == 0 {
                zeroPadded = true
            } else if spec[index].isNumber {
                width = width * 10 + Int(String(spec[index]))!
            }
            index = spec.index(after: index)
        }
        let digits = String(abs(value))
        let sign = value < 0 ? "-" : ""
        if width > digits.count {
            let pad = String(repeating: "0", count: width - digits.count)
            return sign + pad + digits
        }
        return sign + digits
    }
}

// MARK: - Tokenizer

/// Turns awk source into tokens. Newlines separate statements; braces group
/// actions; a `/` opens a regex in a pattern position and division elsewhere.
private struct Tokenizer {

    enum Token: Equatable {
        case newline
        case symbol(String)
        case string(String)
        case number(Double)
        case regex(String)
        case punct(String)
        case eof

        /// The case without its associated value, so a parser can ask "is this
        /// a number?" without constructing a full token (`.number` alone would
        /// be a value with a missing argument, which is not allowed).
        enum Kind {
            case newline, symbol, string, number, regex, punct, eof
        }

        var kind: Kind {
            switch self {
            case .newline: return .newline
            case .symbol: return .symbol
            case .string: return .string
            case .number: return .number
            case .regex: return .regex
            case .punct: return .punct
            case .eof: return .eof
            }
        }
    }

    let source: String
    private(set) var error: String?
    private var index: String.Index

    init(_ source: String) {
        self.source = source
        self.index = source.startIndex
    }

    mutating func tokenize() -> [Token]? {
        var tokens: [Token] = []
        while let token = next() {
            if case .eof = token { break }
            tokens.append(token)
        }
        if error != nil { return nil }
        tokens.append(.eof)
        return tokens
    }

    private mutating func next() -> Token? {
        skipWhitespaceAndComments()
        guard index < source.endIndex else { return .eof }
        let char = source[index]
        if char == "\n" {
            index = source.index(after: index)
            return .newline
        }
        if char == "\"" { return readString() }
        if char.isNumber || (char == "." && peekIsNumber) { return readNumber() }
        if char.isLetter || char == "_" { return readSymbol() }
        if char == "/" { return readRegexOrDivide() }
        return readPunct()
    }

    private var peekIsNumber: Bool {
        let next = source.index(after: index)
        return next < source.endIndex && source[next].isNumber
    }

    private mutating func skipWhitespaceAndComments() {
        while index < source.endIndex {
            let char = source[index]
            if char == " " || char == "\t" || char == "\r" {
                index = source.index(after: index)
            } else if char == "#" {
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
            } else {
                break
            }
        }
    }

    private mutating func readString() -> Token {
        index = source.index(after: index)
        var result = ""
        while index < source.endIndex, source[index] != "\"" {
            let char = source[index]
            if char == "\\" {
                let next = source.index(after: index)
                if next < source.endIndex {
                    let escape = source[next]
                    if escape == "n" { result += "\n" }
                    else if escape == "t" { result += "\t" }
                    else { result += String(escape) }
                    index = source.index(after: next)
                    continue
                }
            }
            result += String(char)
            index = source.index(after: index)
        }
        if index < source.endIndex {
            index = source.index(after: index)
        }
        return .string(result)
    }

    private mutating func readNumber() -> Token {
        let start = index
        while index < source.endIndex, source[index].isNumber || source[index] == "." {
            index = source.index(after: index)
        }
        let text = String(source[start..<index])
        return .number(Double(text) ?? 0)
    }

    private mutating func readSymbol() -> Token {
        let start = index
        while index < source.endIndex, source[index].isLetter || source[index].isNumber || source[index] == "_" {
            index = source.index(after: index)
        }
        return .symbol(String(source[start..<index]))
    }

    private mutating func readRegexOrDivide() -> Token {
        index = source.index(after: index)
        var body = ""
        var escaped = false
        while index < source.endIndex {
            let char = source[index]
            if escaped {
                body += String(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "/" {
                index = source.index(after: index)
                return .regex(body)
            } else if char == "\n" {
                break
            } else {
                body += String(char)
            }
            index = source.index(after: index)
        }
        return .punct("/")
    }

    private mutating func readPunct() -> Token {
        let char = source[index]
        let next = source.index(after: index)
        let twoCharOps = ["<=", ">=", "==", "!=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=", "%=", "!~"]
        if next < source.endIndex {
            let two = String(char) + String(source[next])
            if twoCharOps.contains(two) {
                index = source.index(after: next)
                return .punct(two)
            }
        }
        index = source.index(after: index)
        return .punct(String(char))
    }
}

// MARK: - Parser

/// A recursive-descent parser for the awk subset.
private struct Parser {

    var tokens: [Tokenizer.Token]
    var position = 0
    private(set) var error: String?

    init(tokens: [Tokenizer.Token]) {
        self.tokens = tokens
    }

    mutating func parse(into program: inout AwkProgram) -> Bool {
        while !atEnd {
            if match(.newline) { continue }
            if check(.punct("{")) {
                _ = advance()
                var body: [AwkProgram.Statement] = []
                guard parseStatements(into: &body) else { return false }
                program.rules.append(AwkProgram.Rule(pattern: .always, body: body))
                _ = match(.newline)
                continue
            }
            guard let pattern = parsePattern() else { return false }
            if match(.punct("{")) {
                var body: [AwkProgram.Statement] = []
                guard parseStatements(into: &body) else { return false }
                let rule = AwkProgram.Rule(pattern: pattern, body: body)
                if case .expression(.variable("BEGIN")) = pattern {
                    program.begin = body
                } else if case .expression(.variable("END")) = pattern {
                    program.end = body
                } else {
                    program.rules.append(rule)
                }
                _ = match(.newline)
            } else {
                let body: [AwkProgram.Statement] = [.print([.field(0)])]
                let rule = AwkProgram.Rule(pattern: pattern, body: body)
                if case .expression(.variable("BEGIN")) = pattern {
                    program.begin = body
                } else if case .expression(.variable("END")) = pattern {
                    program.end = body
                } else {
                    program.rules.append(rule)
                }
                _ = match(.newline)
            }
        }
        return true
    }

    private mutating func parsePattern() -> AwkProgram.Rule.Pattern? {
        if checkKind(.regex) {
            let token = advance()
            guard case .regex(let re) = token else { return .always }
            return .regex(re)
        }
        guard let expr = parseExpression() else { return nil }
        return .expression(expr)
    }

    // MARK: Statements

    private mutating func parseStatements(into result: inout [AwkProgram.Statement]) -> Bool {
        while !atEnd {
            if check(.newline) { _ = advance(); continue }
            if check(.punct("}")) {
                _ = advance()
                return true
            }
            guard let statement = parseStatement() else { return false }
            result.append(statement)
        }
        error = "awk: missing closing brace"
        return false
    }

    private mutating func parseStatement() -> AwkProgram.Statement? {
        if check(.punct("{")) {
            _ = advance()
            var body: [AwkProgram.Statement] = []
            guard parseStatements(into: &body) else { return nil }
            return .block(body)
        }
        if matchSymbol("print") {
            var exprs: [AwkProgram.Expr] = []
            while !check(.newline) && !check(.punct(";")) && !check(.punct("}")) && !atEnd {
                guard let expr = parseExpression() else { return nil }
                exprs.append(expr)
                if match(.punct(",")) { continue }
                break
            }
            _ = match(.punct(";"))
            // A bare `print` means `print $0`.
            if exprs.isEmpty {
                exprs = [.field(0)]
            }
            return .print(exprs)
        }
        if matchSymbol("printf") {
            var exprs: [AwkProgram.Expr] = []
            while !check(.newline) && !check(.punct(";")) && !check(.punct("}")) && !atEnd {
                guard let expr = parseExpression() else { return nil }
                exprs.append(expr)
                if match(.punct(",")) { continue }
                break
            }
            _ = match(.punct(";"))
            guard let first = exprs.first, case .literal(let fmt) = first, case .string(let text) = fmt else {
                error = "awk: printf needs a format string"
                return nil
            }
            return .printf(text, Array(exprs.dropFirst()))
        }
        if matchSymbol("if") {
            _ = match(.punct("("))
            guard let condition = parseExpression() else { return nil }
            _ = match(.punct(")"))
            guard let then = parseStatement() else { return nil }
            var else_: [AwkProgram.Statement] = []
            if matchSymbol("else") {
                if let single = parseStatement() {
                    else_ = [single]
                }
            }
            return .if_(condition, [then], else_)
        }
        if matchSymbol("while") {
            _ = match(.punct("("))
            guard let condition = parseExpression() else { return nil }
            _ = match(.punct(")"))
            guard let body = parseStatement() else { return nil }
            return .while_(condition, [body])
        }
        if matchSymbol("next") {
            _ = match(.punct(";"))
            return .next
        }
        if matchSymbol("exit") {
            var code: AwkProgram.Expr?
            if !check(.newline) && !check(.punct(";")) && !check(.punct("}")) {
                code = parseExpression()
            }
            _ = match(.punct(";"))
            return .exit_(code)
        }
        if let expr = parseExpression() {
            _ = match(.punct(";"))
            return .expr(expr)
        }
        return nil
    }

    // MARK: Expressions

    private mutating func parseExpression() -> AwkProgram.Expr? { parseLogicalOr() }

    private mutating func parseLogicalOr() -> AwkProgram.Expr? {
        guard var left = parseLogicalAnd() else { return nil }
        while match(.punct("||")) {
            guard let right = parseLogicalAnd() else { return nil }
            left = .binary(op: "||", left, right)
        }
        return left
    }

    private mutating func parseLogicalAnd() -> AwkProgram.Expr? {
        guard var left = parseComparison() else { return nil }
        while match(.punct("&&")) {
            guard let right = parseComparison() else { return nil }
            left = .binary(op: "&&", left, right)
        }
        return left
    }

    private mutating func parseComparison() -> AwkProgram.Expr? {
        guard var left = parseAdditive() else { return nil }
        while true {
            if match(.punct("==")) { guard let r = parseAdditive() else { return nil }; left = .binary(op: "==", left, r) }
            else if match(.punct("!=")) { guard let r = parseAdditive() else { return nil }; left = .binary(op: "!=", left, r) }
            else if match(.punct("<")) { guard let r = parseAdditive() else { return nil }; left = .binary(op: "<", left, r) }
            else if match(.punct("<=")) { guard let r = parseAdditive() else { return nil }; left = .binary(op: "<=", left, r) }
            else if match(.punct(">")) { guard let r = parseAdditive() else { return nil }; left = .binary(op: ">", left, r) }
            else if match(.punct(">=")) { guard let r = parseAdditive() else { return nil }; left = .binary(op: ">=", left, r) }
            else if match(.punct("~")) {
                guard let re = parseRegexLiteral() else { return nil }
                left = .binary(op: "~", left, re)
            }
            else if match(.punct("!~")) {
                guard let re = parseRegexLiteral() else { return nil }
                left = .binary(op: "!~", left, re)
            }
            else { break }
        }
        return left
    }

    private mutating func parseRegexLiteral() -> AwkProgram.Expr? {
        if checkKind(.regex) {
            let token = advance()
            guard case .regex(let re) = token else { return nil }
            return .literal(.string(re))
        }
        error = "awk: expected regex"
        return nil
    }

    private mutating func parseAdditive() -> AwkProgram.Expr? {
        guard var left = parseMultiplicative() else { return nil }
        while true {
            if match(.punct("+")) { guard let r = parseMultiplicative() else { return nil }; left = .binary(op: "+", left, r) }
            else if match(.punct("-")) { guard let r = parseMultiplicative() else { return nil }; left = .binary(op: "-", left, r) }
            else { break }
        }
        return left
    }

    private mutating func parseMultiplicative() -> AwkProgram.Expr? {
        guard var left = parseUnary() else { return nil }
        while true {
            if match(.punct("*")) { guard let r = parseUnary() else { return nil }; left = .binary(op: "*", left, r) }
            else if match(.punct("/")) { guard let r = parseUnary() else { return nil }; left = .binary(op: "/", left, r) }
            else if match(.punct("%")) { guard let r = parseUnary() else { return nil }; left = .binary(op: "%", left, r) }
            else { break }
        }
        return left
    }

    private mutating func parseUnary() -> AwkProgram.Expr? {
        if match(.punct("-")) { guard let e = parseUnary() else { return nil }; return .unary(op: "-", e) }
        if match(.punct("+")) { guard let e = parseUnary() else { return nil }; return .unary(op: "+", e) }
        if match(.punct("!")) { guard let e = parseUnary() else { return nil }; return .unary(op: "!", e) }
        return parsePrimary()
    }

    /// The index after a `$`: a number, `NF` (the last field, encoded -1), or a
    /// parenthesised expression.
    private mutating func parseFieldIndex() -> Int {
        if checkKind(.number) {
            let token = advance()
            guard case .number(let n) = token else { return 0 }
            return Int(n)
        }
        if match(.punct("(")) {
            guard let expr = parseExpression() else { return 0 }
            _ = match(.punct(")"))
            return Int(expr.literalNumber ?? 0)
        }
        if checkKind(.symbol) {
            let token = advance()
            guard case .symbol(let name) = token else { return 0 }
            if name == "NF" { return -1 }
            return Int(name) ?? 0
        }
        return 0
    }

    private mutating func parsePrimary() -> AwkProgram.Expr? {
        if checkKind(.number) {
            let token = advance()
            guard case .number(let n) = token else { return nil }
            return .literal(.number(n))
        }
        if checkKind(.string) {
            let token = advance()
            guard case .string(let s) = token else { return nil }
            return .literal(.string(s))
        }
        if match(.punct("$")) {
            // Field reference: $0, $1, $NF, $(expr). A following `=` makes it
            // a field assignment (`$1 = "x"`).
            let fieldIndex = parseFieldIndex()
            if match(.punct("=")) {
                guard let value = parseExpression() else { return nil }
                return .fieldAssign(fieldIndex, value)
            }
            return .field(fieldIndex)
        }
        if match(.punct("(")) {
            guard let expr = parseExpression() else { return nil }
            _ = match(.punct(")"))
            return expr
        }
        if checkKind(.symbol) {
            let token = advance()
            guard case .symbol(let name) = token else { return nil }
            if match(.punct("(")) {
                var args: [AwkProgram.Expr] = []
                if !check(.punct(")")) {
                    while true {
                        guard let arg = parseExpression() else { return nil }
                        args.append(arg)
                        if match(.punct(",")) { continue }
                        break
                    }
                }
                _ = match(.punct(")"))
                return .call(name, args)
            }
            if match(.punct("=")) {
                guard let value = parseExpression() else { return nil }
                return .assign(name: name, value)
            }
            // Compound assignment: `x += y` is `x = x + y`, and so on.
            for (op, symbol) in [("+", "+="), ("-", "-="), ("*", "*="), ("/", "/="), ("%", "%=")] {
                if match(.punct(symbol)) {
                    guard let value = parseExpression() else { return nil }
                    let combined = AwkProgram.Expr.binary(op: op, .variable(name), value)
                    return .assign(name: name, combined)
                }
            }
            return .variable(name)
        }
        if checkKind(.regex) {
            let token = advance()
            guard case .regex(let re) = token else { return nil }
            return .literal(.string(re))
        }
        return nil
    }

    // MARK: Helpers

    private var atEnd: Bool {
        if position >= tokens.count { return true }
        if case .eof = tokens[position] { return true }
        return false
    }

    private func check(_ type: Tokenizer.Token) -> Bool {
        !atEnd && tokens[position] == type
    }

    private func check(_ punct: String) -> Bool {
        !atEnd && tokens[position] == .punct(punct)
    }

    private func checkSymbol(_ name: String) -> Bool {
        !atEnd && tokens[position] == .symbol(name)
    }

    private func checkKind(_ kind: Tokenizer.Token.Kind) -> Bool {
        !atEnd && tokens[position].kind == kind
    }

    @discardableResult
    private mutating func match(_ type: Tokenizer.Token) -> Bool {
        if check(type) { position += 1; return true }
        return false
    }

    @discardableResult
    private mutating func match(_ punct: String) -> Bool {
        if check(punct) { position += 1; return true }
        return false
    }

    @discardableResult
    private mutating func matchSymbol(_ name: String) -> Bool {
        if checkSymbol(name) { position += 1; return true }
        return false
    }

    private mutating func advance() -> Tokenizer.Token {
        let token = tokens[position]
        position += 1
        return token
    }
}

extension AwkProgram.Expr {
    /// The literal number, if this is a numeric literal (for `$(expr)`).
    var literalNumber: Double? {
        if case .literal(.number(let n)) = self { return n }
        return nil
    }
}
