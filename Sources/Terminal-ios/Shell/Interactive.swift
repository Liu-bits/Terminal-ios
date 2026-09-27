// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// One step of a command that keeps running while the user presses keys.
enum InteractiveStep: Equatable {
    /// Draw this (escape sequences included) and wait for another key.
    case frame(String)
    /// Leave interactive mode: write this on the main screen and finish.
    case finished(String, Int)

    static func done(code: Int = 0) -> InteractiveStep { .finished("", code) }
}

/// A command that owns the screen until it is done.
///
/// The engine is synchronous, so a command cannot block waiting for stdin.
/// Instead it hands back a session: the UI draws `initialFrame`, routes every
/// keystroke to `handle(key:)` and gets either the next frame or the end. The
/// tests drive the very same session with a script of keys, which is why the
/// pager can be tested without a simulator.
///
/// Keys arrive as strings. Printable keys are one character; named keys are
/// `Enter`, `Backspace`, `Escape`, `Up`, `Down`, `PageUp`, `PageDown`, `Space`
/// and `Ctrl-C`. A session accepts the spellings that make sense to it and
/// ignores the rest.
protocol InteractiveSession: AnyObject {
    /// Escape sequences and text that put the screen into the command's view.
    var initialFrame: String { get }
    /// Consumes one key and produces the next frame, or finishes.
    func handle(key: String) -> InteractiveStep
}

/// Shared spellings for keys the UI can send.
enum InteractiveKey {
    static let enter = "Enter"
    static let backspace = "Backspace"
    static let escape = "Escape"
    static let up = "Up"
    static let down = "Down"
    static let pageUp = "PageUp"
    static let pageDown = "PageDown"
    static let space = "Space"
    static let interrupt = "Ctrl-C"

    /// True for a key that stands for a single printable character.
    ///
    /// Non-ASCII characters count as printable, which is what makes a Chinese
    /// search term typeable.
    static func printable(_ key: String) -> Character? {
        guard key.count == 1, let character = key.first else {
            return nil
        }
        guard let value = character.asciiValue else {
            return character
        }
        return value >= 0x20 && value != 0x7F ? character : nil
    }
}
