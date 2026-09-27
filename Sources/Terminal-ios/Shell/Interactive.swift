// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// One step of a command that keeps running while the user presses keys.
enum InteractiveStep: Equatable {
    /// Replace the screen with this frame (escape sequences included).
    ///
    /// Full-screen commands use this: the frame homes the cursor and erases, and
    /// the grid in `Terminal/` does the drawing.
    case frame(String)
    /// Add this to the scrollback instead of redrawing the screen.
    ///
    /// Line-oriented commands use this: `ed` prints `wrote 12 lines` where it
    /// happens, the way the real one does, instead of clearing the screen for a
    /// single line of output.
    case append(String)
    /// Leave interactive mode: write this on the main screen and finish.
    case finished(String, Int)

    static func done(code: Int = 0) -> InteractiveStep { .finished("", code) }
}

/// How a session wants its input.
enum InteractiveInputMode {
    /// Single keystrokes: a pager, a viewer.
    case key
    /// Whole lines, edited in the input field and handed over on Return: a line
    /// editor, a REPL. The view keeps the text visible while it is typed, which
    /// per-character routing cannot do.
    case line
}

/// A command that owns the screen until it is done.
///
/// The engine is synchronous, so a command cannot block waiting for stdin.
/// Instead it hands back a session: the UI draws `initialFrame`, routes input to
/// the session and follows the steps it gets back. The tests drive the very same
/// session with a script of keys, which is why every interactive command can be
/// tested without a simulator.
///
/// Keys arrive as strings. Printable keys are one character; named keys are
/// `Enter`, `Backspace`, `Escape`, `Up`, `Down`, `PageUp`, `PageDown`, `Space`
/// and `Ctrl-C`. A session accepts the spellings that make sense to it.
protocol InteractiveSession: AnyObject {
    /// What to draw before the first input.
    var initialFrame: String { get }
    /// Single keys, or whole lines.
    var inputMode: InteractiveInputMode { get }
    /// Consumes one key and produces the next step.
    func handle(key: String) -> InteractiveStep
    /// Consumes a completed line in `.line` mode. Not called in `.key` mode.
    func handle(line: String) -> InteractiveStep
}

extension InteractiveSession {
    /// Keystrokes by default; line-oriented sessions override this.
    var inputMode: InteractiveInputMode { .key }

    /// A session that only reads keys ignores completed lines.
    func handle(line: String) -> InteractiveStep {
        handle(key: InteractiveKey.enter)
    }
}

/// Shared spellings for input the UI can send.
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
    /// search term or file name typeable.
    static func printable(_ key: String) -> Character? {
        guard key.count == 1, let character = key.first else {
            return nil
        }
        guard let value = character.asciiValue else {
            return character
        }
        return value >= 0x20 && value != 0x7F ? character : nil
    }

    /// True for the keys every session treats as "stop".
    static func isQuit(_ key: String) -> Bool {
        key == escape || key == interrupt
    }
}
