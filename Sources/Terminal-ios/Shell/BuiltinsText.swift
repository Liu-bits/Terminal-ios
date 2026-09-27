// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation
import CryptoKit

/// Text filters and generators: the coreutils text surface.
///
/// Filter commands read `stdin` (or the files named as operands) and print to
/// stdout, so they compose with pipes exactly like their POSIX namesakes.
enum TextBuiltins {

    static let all: [ShellBuiltin] = [
        ShellBuiltin("echo", "print its arguments", echo),
        ShellBuiltin("printf", "format and print data", printf),
        ShellBuiltin("head", "print the first lines", head),
        ShellBuiltin("tail", "print the last lines", tail),
        ShellBuiltin("wc", "count lines, words and bytes", wc),
        ShellBuiltin("grep", "print matching lines", grep),
        ShellBuiltin("sed", "stream editor (s///, -n p, d)", sed),
        ShellBuiltin("sort", "sort lines", sort),
        ShellBuiltin("uniq", "filter adjacent duplicate lines", uniq),
        ShellBuiltin("cut", "select fields or columns", cut),
        ShellBuiltin("tr", "translate or delete characters", tr),
        ShellBuiltin("tee", "write input to files and stdout", tee),
        ShellBuiltin("nl", "number lines", nl),
        ShellBuiltin("rev", "reverse each line", rev),
        ShellBuiltin("tac", "print lines in reverse order", tac),
        ShellBuiltin("seq", "print a sequence of numbers", seq),
        ShellBuiltin("yes", "print a string forever (bounded here)", yes),
        ShellBuiltin("base64", "encode or decode base64", base64),
        ShellBuiltin("sha256sum", "print SHA-256 checksums", sha256sum),
        ShellBuiltin("sha1sum", "print SHA-1 checksums", sha1sum),
        ShellBuiltin("md5sum", "print MD5 checksums", md5sum),
        ShellBuiltin("cksum", "print a simple checksum", cksum),
        ShellBuiltin("diff", "compare two files line by line", diff),
        ShellBuiltin("strings", "print printable runs in a file", strings)
    ]

    // MARK: - echo / printf

    private static func echo(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, stopAtFirstOperand: true)
        let noNewline = parsed.has("n")
        let interpretEscapes = parsed.has("e")
        var text = parsed.operands.joined(separator: " ")
        if interpretEscapes {
            text = unescape(text)
        }
        return .ok(noNewline ? text : text + "\n")
    }

    /// Handles the `\n`, `\t`, `\\` escapes `echo -e` understands.
    private static func unescape(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let char = iterator.next() {
            guard char == "\\" else {
                result.append(char)
                continue
            }
            guard let next = iterator.next() else {
                result.append("\\")
                break
            }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "\\": result.append("\\")
            default:
                result.append("\\")
                result.append(next)
            }
        }
        return result
    }

    private static func printf(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, stopAtFirstOperand: true)
        guard let rawFormat = parsed.operands.first else {
            return .fail("printf: usage: printf format [arguments]")
        }
        let values = Array(parsed.operands.dropFirst())
        var output = ""
        var valueIndex = 0
        let iterator = Array(unescape(rawFormat))
        var position = 0
        while position < iterator.count {
            let char = iterator[position]
            position += 1
            if char != "%" {
                output.append(char)
                continue
            }
            guard position < iterator.count else {
                output.append("%")
                break
            }
            let specifier = iterator[position]
            position += 1
            let raw = valueIndex < values.count ? values[valueIndex] : ""
            switch specifier {
            case "s":
                output += raw
                valueIndex += 1
            case "d", "i":
                output += String(Int(raw) ?? 0)
                valueIndex += 1
            case "f":
                output += String(Double(raw) ?? 0)
                valueIndex += 1
            case "x":
                output += String(Int(raw) ?? 0, radix: 16)
                valueIndex += 1
            case "c":
                output += raw.isEmpty ? "" : String(raw.first!)
                valueIndex += 1
            case "%":
                output.append("%")
            case "n":
                output.append("\n")
            default:
                output.append("%")
                output.append(specifier)
            }
        }
        return .ok(output)
    }

    // MARK: - head / tail / wc / nl / rev / tac

    private static func head(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, valueFlags: ["n"])
        let count = parsed.value("n").flatMap { Int($0) } ?? 10
        let input = context.inputText(named: parsed.operands, command: "head")
        if let failure = input.failure {
            return failure
        }
        let lines = context.lines(input.text ?? "")
        let selected = lines.prefix(max(0, count))
        return .ok(selected.joined(separator: "\n"))
    }

    private static func tail(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, valueFlags: ["n"])
        let count = parsed.value("n").flatMap { Int($0) } ?? 10
        let input = context.inputText(named: parsed.operands, command: "tail")
        if let failure = input.failure {
            return failure
        }
        let lines = context.lines(input.text ?? "")
        let selected = lines.suffix(max(0, count))
        return .ok(selected.joined(separator: "\n"))
    }

    private static func wc(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let input = context.inputText(named: parsed.operands, command: "wc")
        if let failure = input.failure {
            return failure
        }
        let text = input.text ?? ""
        let lines = context.lines(text).count
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        let bytes = text.utf8.count
        if parsed.has("l") { return .ok("\(lines)") }
        if parsed.has("w") { return .ok("\(words)") }
        if parsed.has("c") { return .ok("\(bytes)") }
        return .ok("\(lines) \(words) \(bytes)")
    }

    private static func nl(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let input = context.inputText(named: parsed.operands, command: "nl")
        if let failure = input.failure {
            return failure
        }
        let all = parsed.has("a") || parsed.has("b")
        var number = 0
        var output: [String] = []
        for line in context.lines(input.text ?? "") {
            if all || !line.isEmpty {
                number += 1
                output.append(String(format: "%6d\t%@", number, line))
            } else {
                output.append("")
            }
        }
        return .ok(output.joined(separator: "\n"))
    }

    private static func rev(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let input = context.inputText(named: parsed.operands, command: "rev")
        if let failure = input.failure {
            return failure
        }
        let reversed = context.lines(input.text ?? "").map { String($0.reversed()) }
        return .ok(reversed.joined(separator: "\n"))
    }

    private static func tac(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let input = context.inputText(named: parsed.operands, command: "tac")
        if let failure = input.failure {
            return failure
        }
        return .ok(context.lines(input.text ?? "").reversed().joined(separator: "\n"))
    }

    // MARK: - grep

    /// Wraps every match of `pattern` in `style`.
    ///
    /// Both grep modes go through `NSRegularExpression`: the plain mode escapes
    /// the pattern first. Using the template form keeps the original text
    /// intact, which matters under `-i` - the match is highlighted as written,
    /// not as spelled in the pattern.
    private static func highlight(
        _ line: String,
        pattern: String,
        ignoreCase: Bool,
        extended: Bool,
        style: TerminalStyle
    ) -> String {
        let source = extended ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        var options: NSRegularExpression.Options = []
        if ignoreCase {
            options.insert(.caseInsensitive)
        }
        guard let expression = try? NSRegularExpression(pattern: source, options: options) else {
            return line
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let template = style.sgr + "$0" + TerminalStyle.plain.sgr
        return expression.stringByReplacingMatches(
            in: line,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    private static func grep(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        guard let pattern = parsed.operands.first else {
            return .fail("grep: usage: grep [-ivnrl] pattern [file ...]", code: 2)
        }
        let files = Array(parsed.operands.dropFirst())
        let ignoreCase = parsed.has("i")
        let invert = parsed.has("v")
        let showNumbers = parsed.has("n")
        let countOnly = parsed.has("c")
        let filesOnly = parsed.has("l")
        let extended = parsed.has("E")
        let policy = ColorPolicy.from(parsed)
        let colour = policy.isEnabled(context)

        func matcher(_ line: String) -> Bool {
            let options: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
            if extended {
                return line.range(of: pattern, options: options.union(.regularExpression)) != nil
            }
            return line.range(of: pattern, options: options) != nil
        }

        /// The line with every match wrapped in the highlight style. Inverted
        /// output and non-matching lines come back untouched, because a
        /// highlight there would mark the wrong text.
        func highlighted(_ line: String) -> String {
            guard colour, !invert else { return line }
            return highlight(
                line,
                pattern: pattern,
                ignoreCase: ignoreCase,
                extended: extended,
                style: .matchHighlight
            )
        }

        /// Greps one text blob and returns the rendered lines.
        func scan(_ text: String) -> (lines: [String], matches: Int) {
            var results: [String] = []
            var matches = 0
            for (index, line) in context.lines(text).enumerated() {
                let hit = matcher(line)
                guard hit != invert else { continue }
                matches += 1
                if showNumbers && !countOnly && !filesOnly {
                    // GNU's `ln=` colour, and only the number is coloured so a
                    // copy/paste of the line still works.
                    let number = context.color(.lineNumber, "\(index + 1)", policy: policy)
                    results.append("\(number):\(highlighted(line))")
                } else if !countOnly && !filesOnly {
                    results.append(highlighted(line))
                }
            }
            return (results, matches)
        }

        if files.isEmpty {
            let outcome = scan(context.stdin ?? "")
            if countOnly { return .ok("\(outcome.matches)") }
            return ShellResult(output: outcome.lines.joined(separator: "\n"), exitCode: outcome.matches > 0 ? 0 : 1, clearScreen: false)
        }

        var output: [String] = []
        var totalMatches = 0
        for file in files {
            if parsed.has("r"), context.isDirectory(file) {
                guard let root = context.url(for: file) else { continue }
                let rootDisplay = context.environment.displayPath(root)
                walkFiles(root, display: rootDisplay) { url, display in
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                    let outcome = scan(text)
                    totalMatches += outcome.matches
                    if filesOnly {
                        if outcome.matches > 0 { output.append(display) }
                    } else if countOnly {
                        output.append("\(display):\(outcome.matches)")
                    } else {
                        let tag = context.color(.fileName, display, policy: policy)
                        output.append(contentsOf: outcome.lines.map { "\(tag):\($0)" })
                    }
                }
                continue
            }
            guard let text = context.readText(file) else {
                return .fail("grep: \(file): No such file or directory", code: 2)
            }
            let outcome = scan(text)
            totalMatches += outcome.matches
            if countOnly {
                // `grep -c` only prefixes the file name when several are given.
                output.append(files.count > 1 ? "\(file):\(outcome.matches)" : "\(outcome.matches)")
            } else if filesOnly {
                if outcome.matches > 0 { output.append(file) }
            } else if files.count > 1 {
                let tag = context.color(.fileName, file, policy: policy)
                output.append(contentsOf: outcome.lines.map { "\(tag):\($0)" })
            } else {
                output.append(contentsOf: outcome.lines)
            }
        }
        return ShellResult(output: output.joined(separator: "\n"), exitCode: totalMatches > 0 ? 0 : 1, clearScreen: false)
    }

    /// Recursively visits regular files under `root`.
    private static func walkFiles(_ root: URL, display: String, visit: (URL, String) -> Void) {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in children.sorted() {
            let child = root.appendingPathComponent(name)
            let childDisplay = display == "/" ? "/\(name)" : "\(display)/\(name)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                walkFiles(child, display: childDisplay, visit: visit)
            } else {
                visit(child, childDisplay)
            }
        }
    }

    // MARK: - sed

    /// Supports the two substitutions people actually type: `s/old/new/`,
    /// `s/old/new/g`, `-n` with a trailing `p`, and `Nd` line deletion.
    /// `sed`, backed by `SedProgram`.
    ///
    /// The argument scan is manual because `-e` may appear many times and
    /// `ShellArgs` keeps only the last value of a flag.
    private static func sed(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        var scripts: [String] = []
        var rest: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            switch arg {
            case "-e", "--expression":
                guard index < args.count else {
                    return .fail("sed: option -e requires an argument", code: 2)
                }
                scripts.append(args[index])
                index += 1
            case "-f", "--file":
                return .fail("sed: -f (script files) is not supported", code: 2)
            case "-i", "--in-place":
                return .fail("sed: -i is not supported; redirect to a file instead", code: 2)
            default:
                if arg.hasPrefix("--expression=") {
                    scripts.append(String(arg.dropFirst("--expression=".count)))
                } else if arg.hasPrefix("-e"), arg.count > 2 {
                    scripts.append(String(arg.dropFirst(2)))
                } else {
                    rest.append(arg)
                }
            }
        }

        let parsed = ShellArgs.parse(rest)
        let quiet = parsed.has("n")
        let extended = parsed.has("E") || parsed.has("r")
        var operands = parsed.operands
        if scripts.isEmpty {
            guard let first = operands.first else {
                return .fail("sed: usage: sed [-nE] 's/old/new/g' [file ...]", code: 2)
            }
            scripts = [first]
            operands = Array(operands.dropFirst())
        }

        let program = SedProgram.parse(scripts: scripts, quiet: quiet, extended: extended)
        if let failure = program.failure {
            return .fail(failure, code: 2)
        }
        let input = context.inputText(named: operands, command: "sed")
        if let failure = input.failure {
            return failure
        }
        let lines = context.lines(input.text ?? "")
        return .ok(program.run(lines).joined(separator: "\n"))
    }

    /// Splits `s/a/b/g` style bodies on an unescaped delimiter.
    // MARK: - sort / uniq / cut / tr / tee

    private static func sort(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let input = context.inputText(named: parsed.operands, command: "sort")
        if let failure = input.failure {
            return failure
        }
        var lines = context.lines(input.text ?? "")
        if parsed.has("n") {
            lines.sort { (Int($0) ?? 0) < (Int($1) ?? 0) }
        } else if parsed.has("f") {
            lines.sort { $0.lowercased() < $1.lowercased() }
        } else {
            lines.sort()
        }
        if parsed.has("r") {
            lines.reverse()
        }
        if parsed.has("u") {
            var seen = Set<String>()
            lines = lines.filter { seen.insert($0).inserted }
        }
        return .ok(lines.joined(separator: "\n"))
    }

    private static func uniq(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let input = context.inputText(named: parsed.operands, command: "uniq")
        if let failure = input.failure {
            return failure
        }
        var output: [String] = []
        var previous: String?
        var count = 0
        func flush() {
            guard let previous else { return }
            if parsed.has("d") && count < 2 { return }
            if parsed.has("u") && count > 1 { return }
            if parsed.has("c") {
                output.append(String(format: "%7d %@", count, previous))
            } else {
                output.append(previous)
            }
        }
        for line in context.lines(input.text ?? "") {
            if line == previous {
                count += 1
            } else {
                flush()
                previous = line
                count = 1
            }
        }
        flush()
        return .ok(output.joined(separator: "\n"))
    }

    private static func cut(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, valueFlags: ["d", "f", "c"])
        let input = context.inputText(named: parsed.operands, command: "cut")
        if let failure = input.failure {
            return failure
        }
        let lines = context.lines(input.text ?? "")
        if let columns = parsed.value("c") {
            let range = parseRange(columns)
            var selected: [String] = []
            for line in lines {
                var picked = ""
                for (index, char) in line.enumerated() where range.contains(index + 1) {
                    picked.append(char)
                }
                selected.append(picked)
            }
            return .ok(selected.joined(separator: "\n"))
        }
        guard let fieldSpec = parsed.value("f") else {
            return .fail("cut: you must specify -f or -c", code: 2)
        }
        let delimiter = parsed.value("d").flatMap { $0.first } ?? "\t"
        let fields = parseRange(fieldSpec)
        var output: [String] = []
        for line in lines {
            let parts = line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
            let selected = parts.enumerated()
                .filter { fields.contains($0.offset + 1) }
                .map { $0.element }
            output.append(selected.joined(separator: String(delimiter)))
        }
        return .ok(output.joined(separator: "\n"))
    }

    /// Parses `1`, `2-4`, or `1,3,5` into a set of 1-based indices.
    private static func parseRange(_ spec: String) -> Set<Int> {
        var result = Set<Int>()
        for chunk in spec.split(separator: ",") {
            let text = String(chunk)
            if text.contains("-") {
                let bounds = text.split(separator: "-").map { Int($0) ?? 0 }
                guard bounds.count == 2, bounds[0] <= bounds[1] else { continue }
                for value in bounds[0]...bounds[1] {
                    result.insert(value)
                }
            } else if let value = Int(text) {
                result.insert(value)
            }
        }
        return result
    }

    private static func tr(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let delete = parsed.has("d")
        let squeeze = parsed.has("s")
        guard let setSpec = parsed.operands.first else {
            return .fail("tr: missing operand", code: 2)
        }
        // `tr` reads stdin only: its operands are the character sets, never
        // input files, so treating extra operands as files would be wrong.
        let input = context.inputText(named: [], command: "tr")
        if let failure = input.failure {
            return failure
        }
        let source = expandSet(setSpec)
        if delete {
            let filtered = (input.text ?? "").filter { !source.contains($0) }
            return .ok(squeeze ? squeezeRepeats(filtered) : filtered)
        }
        guard parsed.operands.count >= 2 else {
            return .fail("tr: missing operand after '\(setSpec)'", code: 2)
        }
        let destination = expandSet(parsed.operands[1])
        var mapping: [Character: Character] = [:]
        for (index, char) in source.enumerated() {
            let replacement = index < destination.count
                ? destination[index]
                : destination.last ?? char
            mapping[char] = replacement
        }
        let translated = String((input.text ?? "").map { mapping[$0] ?? $0 })
        return .ok(parsed.has("s") ? squeezeRepeats(translated) : translated)
    }

    /// Expands `a-z` ranges and `\n`-style escapes into a character list.
    private static func expandSet(_ spec: String) -> [Character] {
        var result: [Character] = []
        let characters = Array(unescape(spec))
        var index = 0
        while index < characters.count {
            if index + 2 < characters.count, characters[index + 1] == "-" {
                let start = characters[index]
                let end = characters[index + 2]
                if let startValue = start.asciiValue, let endValue = end.asciiValue, startValue <= endValue {
                    for value in startValue...endValue {
                        result.append(Character(Unicode.Scalar(value)))
                    }
                    index += 3
                    continue
                }
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    private static func squeezeRepeats(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for char in text {
            if char == previous { continue }
            result.append(char)
            previous = char
        }
        return result
    }

    private static func tee(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let append = parsed.has("a")
        let text = context.stdin ?? ""
        for file in parsed.operands {
            var payload = text
            if !payload.isEmpty, !payload.hasSuffix("\n") {
                payload += "\n"
            }
            guard context.writeText(payload, to: file, append: append) else {
                return .fail("tee: \(file): cannot write")
            }
        }
        return .ok(text)
    }

    // MARK: - seq / yes

    private static func seq(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let numbers = parsed.operands.compactMap { Int($0) }
        let first: Int
        let step: Int
        let last: Int
        switch numbers.count {
        case 1:
            first = 1
            step = 1
            last = numbers[0]
        case 2:
            first = numbers[0]
            step = 1
            last = numbers[1]
        case 3:
            first = numbers[0]
            step = numbers[1]
            last = numbers[2]
        default:
            return .fail("seq: usage: seq [first [step]] last", code: 2)
        }
        guard step != 0 else {
            return .fail("seq: step cannot be zero", code: 2)
        }
        var output: [String] = []
        var value = first
        var guardCount = 0
        while step > 0 ? value <= last : value >= last {
            output.append("\(value)")
            value += step
            guardCount += 1
            if guardCount > 100_000 { break }
        }
        return .ok(output.joined(separator: "\n"))
    }

    /// Real `yes` never stops; a terminal app cannot afford that, so the
    /// output is capped and the command says so on stderr-like trailing note.
    private static func yes(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, stopAtFirstOperand: true)
        let text = parsed.operands.isEmpty ? "y" : parsed.operands.joined(separator: " ")
        let limit = 10_000
        return .ok(Array(repeating: text, count: limit).joined(separator: "\n"))
    }

    // MARK: - base64 and digests

    private static func base64(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let decode = parsed.has("d")
        let input = context.inputText(named: parsed.operands, command: "base64")
        if let failure = input.failure {
            return failure
        }
        let text = input.text ?? ""
        if decode {
            let cleaned = text.split(whereSeparator: { $0 == "\n" || $0 == " " }).joined()
            guard let data = Data(base64Encoded: cleaned),
                  let decoded = String(data: data, encoding: .utf8) else {
                return .fail("base64: invalid input")
            }
            return .ok(decoded)
        }
        guard let data = text.data(using: .utf8) else {
            return .fail("base64: invalid input")
        }
        return .ok(data.base64EncodedString())
    }

    private static func digest(
        _ args: [String],
        _ context: ShellRunContext,
        command: String,
        compute: (Data) -> String
    ) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        var output: [String] = []
        if parsed.operands.isEmpty {
            guard let data = (context.stdin ?? "").data(using: .utf8) else {
                return .fail("\(command): invalid input")
            }
            output.append("\(compute(data))  -")
        } else {
            for file in parsed.operands {
                guard let data = context.readData(file) else {
                    return .fail("\(command): \(file): No such file or directory")
                }
                output.append("\(compute(data))  \(file)")
            }
        }
        return .ok(output.joined(separator: "\n"))
    }

    private static func hex(_ digest: [UInt8]) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256sum(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        digest(args, context, command: "sha256sum") { hex(Array(SHA256.hash(data: $0))) }
    }

    private static func sha1sum(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        digest(args, context, command: "sha1sum") { hex(Array(Insecure.SHA1.hash(data: $0))) }
    }

    private static func md5sum(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        digest(args, context, command: "md5sum") { hex(Array(Insecure.MD5.hash(data: $0))) }
    }

    private static func cksum(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        digest(args, context, command: "cksum") { data in
            let sum = data.reduce(UInt32(0)) { partial, byte in
                partial &+ UInt32(byte)
            }
            return "\(sum) \(data.count)"
        }
    }

    // MARK: - diff / strings

    /// A plain line-by-line diff: enough to see what changed between two
    /// small files without pulling in a full Myers implementation.
    private static func diff(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        guard parsed.operands.count == 2 else {
            return .fail("diff: usage: diff file1 file2", code: 2)
        }
        guard let left = context.readText(parsed.operands[0]) else {
            return .fail("diff: \(parsed.operands[0]): No such file or directory", code: 2)
        }
        guard let right = context.readText(parsed.operands[1]) else {
            return .fail("diff: \(parsed.operands[1]): No such file or directory", code: 2)
        }
        if left == right {
            return .ok()
        }
        let leftLines = context.lines(left)
        let rightLines = context.lines(right)
        var output = ["--- \(parsed.operands[0])", "+++ \(parsed.operands[1])"]
        let limit = max(leftLines.count, rightLines.count)
        for index in 0..<limit {
            let leftLine = index < leftLines.count ? leftLines[index] : nil
            let rightLine = index < rightLines.count ? rightLines[index] : nil
            if leftLine == rightLine {
                continue
            }
            if let leftLine {
                output.append("-\(leftLine)")
            }
            if let rightLine {
                output.append("+\(rightLine)")
            }
        }
        return ShellResult(output: output.joined(separator: "\n"), exitCode: 1, clearScreen: false)
    }

    private static func strings(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, valueFlags: ["n"])
        let minimum = parsed.value("n").flatMap { Int($0) } ?? 4
        guard let file = parsed.operands.first else {
            return .fail("strings: usage: strings [-n length] file", code: 2)
        }
        guard let data = context.readData(file) else {
            return .fail("strings: \(file): No such file or directory", code: 1)
        }
        var output: [String] = []
        var current = ""
        for byte in data {
            // ASCII printable range only; `Unicode.Scalar(UInt8)` cannot fail.
            if byte >= 32 && byte < 127 {
                current.append(Character(Unicode.Scalar(byte)))
            } else {
                if current.count >= minimum {
                    output.append(current)
                }
                current = ""
            }
        }
        if current.count >= minimum {
            output.append(current)
        }
        return .ok(output.joined(separator: "\n"))
    }
}
