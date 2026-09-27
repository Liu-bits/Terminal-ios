// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// How many columns a character occupies.
///
/// This matters as soon as the output contains Chinese: a cell grid that gives
/// every scalar one column misaligns `ls -l` and every table a tool prints. The
/// tables are the standard East Asian Width ones, trimmed to the ranges that
/// actually appear in shell output.
enum TerminalWidth {

    /// Columns taken by one scalar: 0, 1 or 2.
    static func of(_ scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if isZeroWidth(value) {
            return 0
        }
        if isWide(value) {
            return 2
        }
        return 1
    }

    /// Columns taken by a string.
    static func of(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + of($1) }
    }

    /// Columns taken by a string, ignoring ANSI escapes.
    static func visible(of text: String) -> Int {
        ANSIParser.strip(text).unicodeScalars.reduce(0) { $0 + of($1) }
    }

    static func isZeroWidth(_ value: UInt32) -> Bool {
        switch value {
        case 0x0300...0x036F,       // combining diacritics
             0x0483...0x0489,       // Cyrillic combining
             0x0591...0x05BD,       // Hebrew points
             0x0610...0x061A,       // Arabic marks
             0x064B...0x065F,
             0x0E31...0x0E3A,       // Thai marks
             0x0E47...0x0E4E,
             0x1AB0...0x1AFF,       // combining diacritics extended
             0x1DC0...0x1DFF,
             0x200B...0x200F,       // zero-width space/joiners, RTL marks
             0x2028...0x202E,       // line/paragraph separators, bidi overrides
             0x20D0...0x20F0,       // combining marks for symbols
             0xFE00...0xFE0F,       // variation selectors
             0xFE20...0xFE2F,       // combining half marks
             0xFEFF,                // BOM / zero-width no-break space
             0xE0100...0xE01EF:     // variation selectors supplement
            return true
        default:
            return false
        }
    }

    static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F,       // Hangul Jamo initial consonants
             0x2E80...0x303E,       // CJK radicals, Kangxi, CJK symbols
             0x3041...0x33FF,       // Hiragana, Katakana, Bopomofo, compat
             0x3400...0x4DBF,       // CJK unified ideographs extension A
             0x4E00...0x9FFF,       // CJK unified ideographs
             0xA000...0xA4CF,       // Yi syllables
             0xA960...0xA97F,       // Hangul Jamo extended A
             0xAC00...0xD7A3,       // Hangul syllables
             0xF900...0xFAFF,       // CJK compatibility ideographs
             0xFE10...0xFE19,       // vertical forms
             0xFE30...0xFE6F,       // CJK compatibility forms
             0xFF00...0xFF60,       // fullwidth forms
             0xFFE0...0xFFE6,       // fullwidth signs
             0x1F300...0x1F64F,     // emoji
             0x1F900...0x1F9FF,
             0x20000...0x2FFFD,     // CJK extensions B-F
             0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
