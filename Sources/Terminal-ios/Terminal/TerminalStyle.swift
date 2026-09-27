// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// A colour the terminal can render.
///
/// Three shapes cover everything SGR can ask for: the terminal default, one of
/// the 256 xterm palette indices, and a direct 24-bit colour.
enum TerminalColor: Equatable, Hashable {
    case `default`
    case palette(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    /// RGB triple, resolved through the xterm palette.
    ///
    /// The palette layout is the standard one: 0-15 are the named ANSI colours,
    /// 16-231 a 6x6x6 cube, 232-255 a 24-step greyscale ramp.
    var rgb: (r: UInt8, g: UInt8, b: UInt8) {
        switch self {
        case .rgb(let r, let g, let b):
            return (r, g, b)
        case .default:
            return Self.named[7]
        case .palette(let index):
            if index < 16 {
                return Self.named[Int(index)]
            }
            if index < 232 {
                let offset = Int(index) - 16
                let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
                return (
                    steps[(offset / 36) % 6],
                    steps[(offset / 6) % 6],
                    steps[offset % 6]
                )
            }
            let level = UInt8(8 + (Int(index) - 232) * 10)
            return (level, level, level)
        }
    }

    /// True for the 16 named colours, which the UI can darken on a dark theme.
    var isNamed: Bool {
        if case .palette(let index) = self {
            return index < 16
        }
        return false
    }

    /// The `38;…` / `48;…` parameter list for this colour.
    var sgrParameters: [Int] {
        switch self {
        case .default:
            return []
        case .palette(let index):
            return [5, Int(index)]
        case .rgb(let r, let g, let b):
            return [2, Int(r), Int(g), Int(b)]
        }
    }

    /// xterm's values for indices 0-15.
    static let named: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (0x00, 0x00, 0x00),     // 0  black
        (0xCD, 0x00, 0x00),     // 1  red
        (0x00, 0xCD, 0x00),     // 2  green
        (0xCD, 0xCD, 0x00),     // 3  yellow
        (0x00, 0x00, 0xEE),     // 4  blue
        (0xCD, 0x00, 0xCD),     // 5  magenta
        (0x00, 0xCD, 0xCD),     // 6  cyan
        (0xE5, 0xE5, 0xE5),     // 7  white
        (0x7F, 0x7F, 0x7F),     // 8  bright black
        (0xFF, 0x00, 0x00),     // 9  bright red
        (0x00, 0xFF, 0x00),     // 10 bright green
        (0xFF, 0xFF, 0x00),     // 11 bright yellow
        (0x5C, 0x5C, 0xFF),     // 12 bright blue
        (0xFF, 0x00, 0xFF),     // 13 bright magenta
        (0x00, 0xFF, 0xFF),     // 14 bright cyan
        (0xFF, 0xFF, 0xFF)      // 15 bright white
    ]
}

/// The attributes that apply to a run of text.
struct TerminalStyle: Equatable, Hashable {
    var foreground: TerminalColor = .default
    var background: TerminalColor = .default
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var blink = false
    var reverse = false
    var hidden = false
    var strikethrough = false

    static let plain = TerminalStyle()

    var isPlain: Bool { self == .plain }

    /// Applies one SGR parameter list (the numbers between `ESC [` and `m`).
    ///
    /// An empty list means `0`, which is why `ESC [ m` resets: that is what
    /// every shell in the wild relies on.
    func applying(sgr parameters: [Int]) -> TerminalStyle {
        var style = self
        var values = parameters.isEmpty ? [0] : parameters
        var index = 0
        while index < values.count {
            let code = values[index]
            index += 1
            switch code {
            case 0:
                style = .plain
            case 1:
                style.bold = true
            case 2:
                style.dim = true
            case 3:
                style.italic = true
            case 4:
                style.underline = true
            case 5, 6:
                style.blink = true
            case 7:
                style.reverse = true
            case 8:
                style.hidden = true
            case 9:
                style.strikethrough = true
            case 21, 22:
                style.bold = false
                style.dim = false
            case 23:
                style.italic = false
            case 24:
                style.underline = false
            case 25:
                style.blink = false
            case 27:
                style.reverse = false
            case 28:
                style.hidden = false
            case 29:
                style.strikethrough = false
            case 30...37:
                style.foreground = .palette(UInt8(code - 30))
            case 39:
                style.foreground = .default
            case 40...47:
                style.background = .palette(UInt8(code - 40))
            case 49:
                style.background = .default
            case 90...97:
                style.foreground = .palette(UInt8(code - 90 + 8))
            case 100...107:
                style.background = .palette(UInt8(code - 100 + 8))
            case 38, 48:
                guard index < values.count else {
                    break
                }
                let target = code == 38
                let mode = values[index]
                index += 1
                if mode == 5, index < values.count {
                    let colour = TerminalColor.palette(UInt8(clamping: values[index]))
                    index += 1
                    if target { style.foreground = colour } else { style.background = colour }
                } else if mode == 2, index + 2 < values.count {
                    let colour = TerminalColor.rgb(
                        UInt8(clamping: values[index]),
                        UInt8(clamping: values[index + 1]),
                        UInt8(clamping: values[index + 2])
                    )
                    index += 3
                    if target { style.foreground = colour } else { style.background = colour }
                }
            default:
                // Unknown parameters are ignored, like every real terminal does.
                break
            }
        }
        return style
    }

    /// Escape sequence that turns a reset terminal into this style.
    ///
    /// This is what lets the `ls --color` path and the tests share one
    /// definition of "what red looks like".
    var sgr: String {
        if isPlain {
            return "\u{1B}[0m"
        }
        var parameters: [Int] = []
        if bold { parameters.append(1) }
        if dim { parameters.append(2) }
        if italic { parameters.append(3) }
        if underline { parameters.append(4) }
        if blink { parameters.append(5) }
        if reverse { parameters.append(7) }
        if hidden { parameters.append(8) }
        if strikethrough { parameters.append(9) }
        if foreground != .default {
            parameters.append(38)
            parameters.append(contentsOf: foreground.sgrParameters)
        }
        if background != .default {
            parameters.append(48)
            parameters.append(contentsOf: background.sgrParameters)
        }
        return "\u{1B}[" + parameters.map(String.init).joined(separator: ";") + "m"
    }

    // MARK: - Named styles the shell uses

    static let directory = TerminalStyle(foreground: .palette(12), bold: true)
    static let executable = TerminalStyle(foreground: .palette(10), bold: true)
    static let symlink = TerminalStyle(foreground: .palette(14))
    static let archive = TerminalStyle(foreground: .palette(9))
    static let image = TerminalStyle(foreground: .palette(13))
    static let warning = TerminalStyle(foreground: .palette(11))
    static let error = TerminalStyle(foreground: .palette(9), bold: true)

    /// GNU's defaults for `grep --color`: `ms=` (matched text, bold red),
    /// `fn=` (file name, magenta), `ln=` (line number, green).
    static let matchHighlight = TerminalStyle(foreground: .palette(9), bold: true)
    static let fileName = TerminalStyle(foreground: .palette(13))
    static let lineNumber = TerminalStyle(foreground: .palette(10))
}
