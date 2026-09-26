// Copyright © 2026 Liu-bits. All rights reserved.

/// AST for one parsed command line.
indirect enum ShellAST: Equatable {
    case empty
    case pipeline([ShellCommand])
    case and(ShellAST, ShellAST)
    case or(ShellAST, ShellAST)
    case sequence(ShellAST, ShellAST)
}

/// One simple command: argv plus optional redirections.
struct ShellCommand: Equatable {
    var argv: [String]
    var stdinFile: String?
    var stdoutFile: String?
    var stdoutAppend: Bool
}

/// Parses tokenizer output into an AST.
///
/// Grammar: `sequence := or (`;` or)*`, `or := and (`||` and)*`,
/// `and := pipeline (`&&` pipeline)*`, `pipeline := command (`|` command)*`.
/// A redirection token consumes the word token after it; anything else is a
/// syntax error and parsing returns `nil`.
enum ShellParser {

    static func parse(_ tokens: [ShellToken]) -> ShellAST? {
        var parser = Parser(tokens: tokens)
        guard let ast = parser.parseSequence(), parser.isAtEnd else {
            return nil
        }
        return ast
    }

    private struct Parser {
        let tokens: [ShellToken]
        var index: Int = 0

        var isAtEnd: Bool { index >= tokens.count }

        mutating func parseSequence() -> ShellAST? {
            guard var node = parseOr() else {
                return nil
            }
            while match(.sequence) {
                guard let next = parseOr() else {
                    return nil
                }
                node = .sequence(node, next)
            }
            return node
        }

        mutating func parseOr() -> ShellAST? {
            guard var node = parseAnd() else {
                return nil
            }
            while match(.or) {
                guard let next = parseAnd() else {
                    return nil
                }
                node = .or(node, next)
            }
            return node
        }

        mutating func parseAnd() -> ShellAST? {
            guard var node = parsePipeline() else {
                return nil
            }
            while match(.and) {
                guard let next = parsePipeline() else {
                    return nil
                }
                node = .and(node, next)
            }
            return node
        }

        mutating func parsePipeline() -> ShellAST? {
            var commands: [ShellCommand] = []
            guard let first = parseCommand() else {
                return nil
            }
            commands.append(first)
            while match(.pipe) {
                guard let next = parseCommand(),
                      next.argv.isEmpty == false || next.stdinFile != nil || next.stdoutFile != nil else {
                    // `a |` leaves an empty stage; `a | | b` never reaches
                    // here because the second parseCommand rejects the pipe.
                    return nil
                }
                commands.append(next)
            }
            if commands.count == 1, commands[0].argv.isEmpty,
               commands[0].stdinFile == nil, commands[0].stdoutFile == nil {
                return .empty
            }
            return .pipeline(commands)
        }

        mutating func parseCommand() -> ShellCommand? {
            var argv: [String] = []
            var stdinFile: String?
            var stdoutFile: String?
            var stdoutAppend = false
            while !isAtEnd {
                switch tokens[index] {
                case .word(let value):
                    argv.append(value)
                    index += 1
                case .redirectOut(let append):
                    index += 1
                    guard !isAtEnd, case .word(let value) = tokens[index] else {
                        return nil
                    }
                    stdoutFile = value
                    stdoutAppend = append
                    index += 1
                case .redirectIn:
                    index += 1
                    guard !isAtEnd, case .word(let value) = tokens[index] else {
                        return nil
                    }
                    stdinFile = value
                    index += 1
                default:
                    // An operator cannot start a command: `&& a`, `| b`, ...
                    guard !argv.isEmpty || stdinFile != nil || stdoutFile != nil else {
                        return nil
                    }
                    return ShellCommand(
                        argv: argv,
                        stdinFile: stdinFile,
                        stdoutFile: stdoutFile,
                        stdoutAppend: stdoutAppend
                    )
                }
            }
            return ShellCommand(
                argv: argv,
                stdinFile: stdinFile,
                stdoutFile: stdoutFile,
                stdoutAppend: stdoutAppend
            )
        }

        mutating func match(_ token: ShellToken) -> Bool {
            guard !isAtEnd, tokens[index] == token else {
                return false
            }
            index += 1
            return true
        }
    }
}
