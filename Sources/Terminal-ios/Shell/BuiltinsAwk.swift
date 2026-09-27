// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// `awk` - a pattern-action text processor.
///
/// The interpreter lives in `TextAwk`; this is the thin built-in that parses
/// the command line (`-F`, `-v`, the program and any files) and feeds input
/// through the program.
enum AwkBuiltin {

    static let all: [ShellBuiltin] = [
        ShellBuiltin("awk", "awk: pattern-action text processing") { args, context in
            run(args, context)
        }
    ]

    private static let usage = """
    awk: pattern-action text processing
    usage:
      awk [-F sep] [-v var=value] 'program' [file ...]
      awk [-F sep] [-v var=value] -f program.awk [file ...]
    """

    private static func run(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        var fieldSeparator: String?
        var assignments: [(String, String)] = []
        var programText: String?
        var programFile: String?
        var files: [String] = []

        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            switch arg {
            case "-F":
                guard index < args.count else {
                    return .fail("awk: -F needs a separator")
                }
                fieldSeparator = args[index]
                index += 1
            case "-v":
                guard index < args.count else {
                    return .fail("awk: -v needs a var=value pair")
                }
                let pair = args[index]
                index += 1
                if let eq = pair.firstIndex(of: "=") {
                    let name = String(pair[..<eq])
                    let value = String(pair[pair.index(after: eq)...])
                    assignments.append((name, value))
                }
            case "-f":
                guard index < args.count else {
                    return .fail("awk: -f needs a file")
                }
                programFile = args[index]
                index += 1
            default:
                if arg.hasPrefix("-F"), arg.count > 2 {
                    fieldSeparator = String(arg.dropFirst(2))
                } else if programText == nil && programFile == nil {
                    programText = arg
                } else {
                    files.append(arg)
                }
            }
        }

        // Resolve the program text from -f or the positional argument.
        if let programFile {
            let read = context.inputText(named: [programFile], command: "awk")
            guard let text = read.text, read.failure == nil else {
                return .fail("awk: \(programFile): No such file or directory")
            }
            programText = text
        }
        guard let programText else {
            return .ok(usage)
        }

        let program = AwkProgram.parse(
            source: programText,
            fieldSeparator: fieldSeparator,
            assignments: assignments
        )
        if let failure = program.failure {
            return .fail(failure, code: 2)
        }

        // Read the input: named files concatenated, or stdin.
        let input: String
        if files.isEmpty {
            input = context.stdin ?? ""
        } else {
            var parts: [String] = []
            for file in files {
                let read = context.inputText(named: [file], command: "awk")
                guard let text = read.text, read.failure == nil else {
                    return .fail("awk: \(file): No such file or directory")
                }
                parts.append(text)
            }
            input = parts.joined(separator: "\n")
        }

        let output = program.run(input)
        return .ok(output)
    }
}
