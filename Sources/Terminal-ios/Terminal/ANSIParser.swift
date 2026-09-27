// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// A stretch of text sharing one style.
struct ANSISegment: Equatable {
    var text: String
    var style: TerminalStyle

    init(_ text: String, _ style: TerminalStyle = .plain) {
        self.text = text
        self.style = style
    }
}

/// Reads the escape sequences a Unix tool writes into its output.
///
/// Two jobs, one scanner: `segments` splits inline text into styled runs (what
/// the UI draws), and `strip` removes the sequences entirely (what VoiceOver
/// reads aloud and what tests compare against).
enum ANSIParser {

    /// Splits `input` into styled runs.
    ///
    /// SGR (`ESC [ … m`) changes the running style. Every other escape sequence
    /// - cursor movement, erasing, OSC titles - contributes no text, so it is
    /// consumed and dropped here; `TerminalScreen` is what acts on it, because
    /// acting on it needs a grid.
    static func segments(_ input: String) -> [ANSISegment] {
        var result: [ANSISegment] = []
        var style = TerminalStyle.plain
        var buffer = ""
        var scanner = Scanner(text: input)

        func flush() {
            guard !buffer.isEmpty else {
                return
            }
            result.append(ANSISegment(buffer, style))
            buffer = ""
        }

        while let step = scanner.next() {
            switch step {
            case .character(let character):
                buffer.append(character)
            case .sgr(let parameters):
                flush()
                style = style.applying(sgr: parameters)
            case .control, .ignored:
                continue
            }
        }
        flush()
        return result
    }

    /// The text with every escape sequence removed.
    static func strip(_ input: String) -> String {
        var output = ""
        var scanner = Scanner(text: input)
        while let step = scanner.next() {
            if case .character(let character) = step {
                output.append(character)
            }
        }
        return output
    }

    /// How many columns the visible text occupies.
    ///
    /// Escape sequences take none, which is the whole point of knowing this:
    /// alignment code that counts `String.count` gets it wrong.
    static func visibleWidth(_ input: String) -> Int {
        strip(input).count
    }

    /// True when the text carries at least one escape sequence.
    static func containsEscapes(_ input: String) -> Bool {
        input.unicodeScalars.contains { $0.value == 0x1B }
    }

    // MARK: - Scanner

    enum Step {
        case character(Character)
        case sgr([Int])
        /// A control sequence: cursor movement, erasing, modes.
        case control(CSI)
        /// A sequence that produced nothing usable (OSC, DCS, two-char escapes).
        case ignored
    }

    /// A parsed Control Sequence Introducer.
    struct CSI: Equatable {
        var isPrivate = false
        var parameters: [Int] = []
        var intermediate: Character?
        var final: Character = " "

        /// `nil` when the parameter was omitted, so `ESC [ H` and `ESC [ 1 ; 1 H`
        /// can be told apart - the first means "home", not "row 1 column 1 of
        /// an empty list".
        func parameter(_ index: Int) -> Int? {
            guard index < parameters.count else {
                return nil
            }
            return parameters[index]
        }

        /// The parameter or its SGR default.
        func parameter(_ index: Int, default fallback: Int) -> Int {
            parameter(index) ?? fallback
        }
    }

    /// A single-pass scanner over the escape grammar.
    ///
    /// Kept as a struct with an index rather than a `String.Index` walk so the
    /// same code can be reused by `TerminalScreen` without duplicating the
    /// subtle parts (OSC terminators, private-parameter prefixes).
    struct Scanner {
        private let characters: [Character]
        private var index = 0

        init(text: String) {
            characters = Array(text)
        }

        var isAtEnd: Bool { index >= characters.count }

        mutating func next() -> Step? {
            guard index < characters.count else {
                return nil
            }
            let character = characters[index]
            guard character == "\u{1B}" else {
                index += 1
                return .character(character)
            }
            index += 1
            guard index < characters.count else {
                return .ignored
            }
            switch characters[index] {
            case "[":
                index += 1
                return consumeCSI()
            case "]":
                // OSC: runs until BEL or ST (ESC \).
                index += 1
                consumeOSC()
                return .ignored
            case "P", "^", "_":
                // DCS / PM / APC: also terminated by ST.
                index += 1
                consumeString()
                return .ignored
            case "(":
                // Charset designation: ESC ( B
                index += 1
                if index < characters.count {
                    index += 1
                }
                return .ignored
            default:
                let final = characters[index]
                index += 1
                // Two-character escapes the shell uses for colour aliases.
                if final == "c" {
                    return .sgr([])
                }
                return .ignored
            }
        }

        private mutating func consumeCSI() -> Step {
            // Private markers (`?`, `>`, `<`, `=`) come before the parameters.
            var isPrivate = false
            if index < characters.count, "?><=".contains(characters[index]) {
                isPrivate = true
                index += 1
            }
            var digits = ""
            var parameters: [Int] = []
            var intermediate: Character?
            var final: Character?
            while index < characters.count {
                let character = characters[index]
                if character.isNumber {
                    digits.append(character)
                    index += 1
                    continue
                }
                if character == ";" {
                    parameters.append(Int(digits) ?? 0)
                    digits = ""
                    index += 1
                    continue
                }
                if character == ":" {
                    // Sub-parameters (`38:5:196`) are not something our SGR
                    // subset emits; treat the whole sequence as opaque.
                    digits = ""
                    index += 1
                    continue
                }
                if character.asciiValue.map({ $0 >= 0x20 && $0 <= 0x2F }) == true {
                    // Intermediate byte, e.g. the `!p` of DECSTR.
                    intermediate = character
                    index += 1
                    continue
                }
                // Final byte.
                index += 1
                final = character
                if !digits.isEmpty || !parameters.isEmpty {
                    parameters.append(Int(digits) ?? 0)
                    digits = ""
                }
                break
            }
            if final == "m", !isPrivate {
                return .sgr(parameters)
            }
            guard let final else {
                return .ignored
            }
            return .control(CSI(
                isPrivate: isPrivate,
                parameters: parameters,
                intermediate: intermediate,
                final: final
            ))
        }

        private mutating func consumeOSC() {
            while index < characters.count {
                if characters[index] == "\u{07}" {
                    index += 1
                    return
                }
                if characters[index] == "\u{1B}",
                   index + 1 < characters.count,
                   characters[index + 1] == "\\" {
                    index += 2
                    return
                }
                index += 1
            }
        }

        private mutating func consumeString() {
            while index < characters.count {
                if characters[index] == "\u{1B}",
                   index + 1 < characters.count,
                   characters[index + 1] == "\\" {
                    index += 2
                    return
                }
                index += 1
            }
        }
    }
}

extension String {
    /// This string with ANSI escapes removed.
    var strippingANSI: String { ANSIParser.strip(self) }

    /// This string wrapped in `style`, reset afterwards.
    func styled(_ style: TerminalStyle) -> String {
        style.isPlain ? self : style.sgr + self + TerminalStyle.plain.sgr
    }
}
