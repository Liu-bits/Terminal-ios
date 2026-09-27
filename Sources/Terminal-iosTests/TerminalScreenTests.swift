// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Foundation
import Testing

/// Covers the ANSI layer: style parsing, escape scanning, character widths, the
/// screen grid, and the colour switches `ls`/`grep` use.
///
/// The same ground is covered by `support/local_check.py`, which runs without a
/// simulator; these tests are the version CI runs on macOS, where the execute
/// bit of a file is real and `chmod +x` actually does something.
struct TerminalScreenTests {

    // MARK: - Styles

    @Test("SGR parameters build the expected style")
    func styleParsing() {
        #expect(TerminalStyle.plain.applying(sgr: [31]).foreground == .palette(1))
        #expect(TerminalStyle.plain.applying(sgr: [97]).foreground == .palette(15))
        #expect(TerminalStyle.plain.applying(sgr: [7]).reverse)
        #expect(TerminalStyle.plain.applying(sgr: [4]).underline)
        #expect(TerminalStyle.plain.applying(sgr: []).isPlain)
        #expect(
            TerminalStyle.plain.applying(sgr: [1, 4, 32, 44])
                == TerminalStyle(foreground: .palette(2), background: .palette(4), bold: true, underline: true)
        )
        // 22 clears both weight attributes, 24 the underline.
        #expect(TerminalStyle.plain.applying(sgr: [1, 2, 22]).isPlain)
        #expect(TerminalStyle.plain.applying(sgr: [4, 24]).isPlain)
        // 39/49 go back to the terminal default without touching the rest.
        let partial = TerminalStyle.plain.applying(sgr: [31, 44, 39, 49])
        #expect(partial.foreground == .default && partial.background == .default)
    }

    @Test("Extended colour forms are understood")
    func extendedColours() {
        #expect(TerminalStyle.plain.applying(sgr: [38, 5, 196]).foreground == .palette(196))
        #expect(TerminalStyle.plain.applying(sgr: [48, 5, 21]).background == .palette(21))
        #expect(TerminalStyle.plain.applying(sgr: [38, 2, 10, 20, 30]).foreground == .rgb(10, 20, 30))
        // A truncated sequence must not eat the following parameters.
        #expect(TerminalStyle.plain.applying(sgr: [38]).isPlain)
    }

    @Test("The xterm palette resolves to RGB")
    func palette() {
        #expect(TerminalColor.palette(0).rgb == (0x00, 0x00, 0x00))
        #expect(TerminalColor.palette(1).rgb == (0xCD, 0x00, 0x00))
        #expect(TerminalColor.palette(196).rgb == (255, 0, 0))       // top of the cube
        #expect(TerminalColor.palette(232).rgb == (8, 8, 8))         // first grey
        #expect(TerminalColor.palette(255).rgb == (238, 238, 238))   // last grey
        #expect(TerminalColor.rgb(1, 2, 3).rgb == (1, 2, 3))
        #expect(TerminalColor.palette(12).isNamed)
        #expect(TerminalColor.palette(120).isNamed == false)
    }

    @Test("A style round-trips through its escape sequence")
    func styleRoundTrip() {
        let style = TerminalStyle(foreground: .palette(9), background: .rgb(1, 2, 3), bold: true)
        let text = style.sgr + "x" + TerminalStyle.plain.sgr
        let runs = ANSIParser.segments(text)
        #expect(runs.count == 1)
        #expect(runs[0].text == "x")
        #expect(runs[0].style == style)
    }

    // MARK: - Scanning

    @Test("Segments carry their own style and stripping removes escapes")
    func segmentsAndStripping() {
        let text = "a\u{1B}[31mRED\u{1B}[0mb"
        let runs = ANSIParser.segments(text)
        #expect(runs.map(\.text) == ["a", "RED", "b"])
        #expect(runs[1].style.foreground == .palette(1))
        #expect(runs[2].style.isPlain)
        #expect(ANSIParser.strip(text) == "aREDb")
        #expect(ANSIParser.visibleWidth(text) == 5)
        #expect(ANSIParser.containsEscapes(text))
    }

    @Test("Non-SGR sequences produce no text")
    func controlSequencesAreNotText() {
        #expect(ANSIParser.strip("a\u{1B}[2Cb") == "ab")            // cursor forward
        #expect(ANSIParser.strip("a\u{1B}[Hb") == "ab")             // cursor home
        #expect(ANSIParser.strip("a\u{1B}]0;window title\u{07}b") == "ab")   // OSC
        #expect(ANSIParser.strip("a\u{1B}]8;;https://x\u{1B}\\b") == "ab")   // OSC 8 hyperlink
        #expect(ANSIParser.strip("a\u{1B}(Bb") == "ab")             // charset selection
        #expect(ANSIParser.strip("a\u{1B}[?25lb") == "ab")          // private mode
    }

    @Test("Character widths follow East Asian rules")
    func characterWidth() {
        #expect(TerminalWidth.of("a") == 1)
        #expect(TerminalWidth.of("好") == 2)
        #expect(TerminalWidth.of("あ") == 2)
        #expect(TerminalWidth.of("한") == 2)
        #expect(TerminalWidth.of("\u{0301}") == 0)
        #expect(TerminalWidth.of("ab好") == 4)
        #expect(TerminalWidth.visible(of: "\u{1B}[31mab好\u{1B}[0m") == 4)
    }

    // MARK: - Grid

    @Test("Control characters drive the cursor instead of becoming cells")
    func controlCharacters() {
        var screen = TerminalScreen(columns: 10, rows: 3, scrollbackLimit: 4)
        screen.write("hello")
        #expect(screen.plainText == "hello")
        screen.write("\rbye")
        #expect(screen.plainText == "byelo")
        screen.write("\u{1B}[K")
        #expect(screen.plainText == "bye")
        screen.write("\u{8}")
        #expect(screen.cursorColumn == 2)
        screen.write("\t")
        #expect(screen.cursorColumn == 8)
        screen.write("\n")
        #expect(screen.cursorRow == 1 && screen.cursorColumn == 0)
    }

    @Test("Cursor addressing and erasing work")
    func cursorAndErase() {
        var screen = TerminalScreen(columns: 10, rows: 3, scrollbackLimit: 4)
        screen.write("bye\u{1B}[1;6H!")
        #expect(screen.plainText == "bye  !")
        #expect(screen.cursorRow == 0 && screen.cursorColumn == 6)
        screen.write("\u{1B}[2J")
        #expect(screen.plainText.isEmpty)
        screen.write("one\ntwo\nthree")
        screen.write("\u{1B}[2;1H\u{1B}[K")
        #expect(screen.plainText == "one\n\nthree")
        // Save/restore, and cursor visibility for full-screen tools.
        screen.write("\u{1B}[s\u{1B}[1;1HX\u{1B}[u")
        #expect(screen.cursorRow == 1)
        screen.write("\u{1B}[?25l")
        #expect(screen.cursorVisible == false)
        screen.write("\u{1B}[?25h")
        #expect(screen.cursorVisible)
    }

    @Test("Long lines wrap and completed rows scroll into history")
    func wrappingAndScrollback() {
        var wrapper = TerminalScreen(columns: 5, rows: 4, scrollbackLimit: 4)
        wrapper.write("abcdefgh")
        #expect(wrapper.plainText == "abcde\nfgh")

        var scroller = TerminalScreen(columns: 20, rows: 2, scrollbackLimit: 10)
        scroller.write("one\ntwo\nthree\nfour")
        #expect(scroller.scrollback.count == 2)
        #expect(scroller.plainText == "one\ntwo\nthree\nfour")
        // History is capped, so a long session cannot grow without bound.
        var capped = TerminalScreen(columns: 10, rows: 1, scrollbackLimit: 2)
        capped.write("a\nb\nc\nd\n")
        #expect(capped.scrollback.count == 2)
        #expect(capped.plainText == "c\nd")
    }

    @Test("Wide characters take two cells and render once")
    func wideCharacters() {
        var screen = TerminalScreen(columns: 6, rows: 2, scrollbackLimit: 4)
        screen.write("好a")
        #expect(screen.cursorColumn == 3)
        #expect(screen.plainText == "好a")
        let rendered = screen.renderedLines[0]
        #expect(rendered.reduce(0) { $0 + $1.text.count } == 2)
        #expect(rendered.map(\.text).joined() == "好a")
    }

    @Test("Styled runs survive into the rendered model")
    func renderedRuns() {
        var screen = TerminalScreen(columns: 40, rows: 4, scrollbackLimit: 4)
        screen.write("\u{1B}[34mdir\u{1B}[0m file")
        let runs = screen.renderedLines[0]
        #expect(runs.count == 2)
        #expect(runs[0].style.foreground == .palette(4))
        #expect(runs[1].style.isPlain)
        #expect(screen.plainText == "dir file")
    }

    @Test("The scrolling region holds everything outside it still")
    func scrollingRegion() {
        var screen = TerminalScreen(columns: 10, rows: 4, scrollbackLimit: 8)
        screen.write("top\n")
        screen.write("\u{1B}[2;3r\u{1B}[2;1H")
        #expect(screen.scrollTop == 1 && screen.scrollBottom == 2)
        screen.write("x\ny\nz")
        // Row 0 was outside the region, so it must not have moved, and a band
        // scroll must not invent scrollback entries.
        #expect(screen.plainText == "top\ny\nz")
        #expect(screen.scrollback.isEmpty)

        // `CSI r` with no parameters goes back to the whole screen.
        screen.write("\u{1B}[r")
        #expect(screen.scrollTop == 0 && screen.scrollBottom == 3)
    }

    @Test("Origin mode addresses rows relative to the region")
    func originMode() {
        var screen = TerminalScreen(columns: 10, rows: 5, scrollbackLimit: 4)
        screen.write("a\nb\nc\nd\ne")
        screen.write("\u{1B}[3;5r\u{1B}[?6h")
        #expect(screen.originMode && screen.cursorRow == 2)
        screen.write("\u{1B}[1;1HX")
        #expect(screen.plainText == "a\nb\nX\nd\ne")
        // Row parameters are clamped to the region while origin mode is on.
        screen.write("\u{1B}[9;1HY")
        #expect(screen.plainText == "a\nb\nX\nd\nY")
        screen.write("\u{1B}[?6l")
        #expect(screen.originMode == false && screen.cursorRow == 0)
    }

    @Test("The alternate screen gives the main one back untouched")
    func alternateScreen() {
        var screen = TerminalScreen(columns: 20, rows: 3, scrollbackLimit: 8)
        screen.write("main one\nmain two")
        screen.write("\u{1B}[?1049h")
        #expect(screen.isAlternateScreen)
        #expect(screen.plainText.isEmpty)
        screen.write("full screen app")
        #expect(screen.plainText == "full screen app")
        screen.write("\u{1B}[?1049l")
        #expect(screen.isAlternateScreen == false)
        #expect(screen.plainText == "main one\nmain two")
        // ?47 is the older spelling of the same switch.
        screen.write("\u{1B}[?47h")
        #expect(screen.isAlternateScreen)
        screen.write("\u{1B}[?47l")
        #expect(screen.plainText == "main one\nmain two")
    }

    @Test("Sequences we do not implement are recorded, not swallowed")
    func unsupportedSequences() {
        var screen = TerminalScreen(columns: 20, rows: 4, scrollbackLimit: 4)
        screen.write("\u{1B}[?5h")        // DECSCNM: reverse video
        screen.write("\u{1B}[?1004h")     // focus reporting
        #expect(screen.unsupported.contains { $0.contains("private mode") })
        // The region and the alternate buffer are implemented, so they must not
        // show up here any more.
        screen.write("\u{1B}[1;5r")
        screen.write("\u{1B}[?1049h")
        #expect(screen.unsupported.contains { $0.contains("scrolling region") } == false)
        #expect(screen.unsupported.contains { $0.contains("alternate screen") } == false)
    }

    @Test("TerminalOutput keeps the view state together")
    func terminalOutput() {
        var output = TerminalOutput(columns: 20, rows: 4, scrollbackLimit: 4)
        output.appendLine("$ ls")
        output.append("a.txt\n")
        #expect(output.plainText == "$ ls\na.txt")
        #expect(output.plainLines.count == 2)
        // Resizing re-wraps rather than dropping content.
        output.resize(columns: 4)
        #expect(output.screen.columns == 4)
        #expect(output.plainText.contains("a.tx"))
        output.clear()
        #expect(output.plainText.isEmpty)
        // Go back to a readable width before asserting the text: at four columns
        // this line wraps, which is correct but is not what is under test here.
        output.resize(columns: 20)
        output.appendLine("after clear")
        #expect(output.plainText == "after clear")
        output.reset()
        #expect(output.plainText.isEmpty && output.screen.scrollback.isEmpty)
    }

    // MARK: - The shell's colour switch

    @Test("ls colours by file type only when asked")
    func lsColours() throws {
        let (engine, root) = makeEngine()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        try Data().write(to: root.appendingPathComponent("photo.png"))
        try Data().write(to: root.appendingPathComponent("pack.zip"))

        #expect(engine.run("ls").output.contains("\u{1B}") == false)
        #expect(engine.run("ls --color=never").output.contains("\u{1B}") == false)

        let coloured = engine.run("ls --color=always").output
        #expect(coloured.contains("\u{1B}[1;38;5;12msub"))          // directory: blue
        #expect(coloured.contains("\u{1B}[38;5;13mphoto.png"))     // image: magenta
        #expect(coloured.contains("\u{1B}[38;5;9mpack.zip"))       // archive: red
        // The mode/size/date columns stay uncoloured so they keep their width.
        let long = engine.run("ls --color=always -l pack.zip").output
        #expect(long.hasPrefix("-rw"))
        #expect(long.contains("\u{1B}[38;5;9mpack.zip"))

        // An executable is green; this needs a filesystem with a real execute bit.
        #expect(engine.run("printf '#!/bin/sh\\necho hi\\n' > run.sh; chmod +x run.sh").exitCode == 0)
        #expect(engine.run("ls --color=always run.sh").output.contains("\u{1B}[1;38;5;10mrun.sh"))
    }

    @Test("CLICOLOR switches auto colour on and NO_COLOR overrides it")
    func colourEnvironment() {
        let (engine, _) = makeEngine()
        engine.run("mkdir sub; printf 'x\\n' > f.txt")
        #expect(engine.environment.colorEnabled == false)
        #expect(engine.run("ls --color=auto").output.contains("\u{1B}") == false)

        engine.run("export CLICOLOR=1")
        #expect(engine.environment.colorEnabled)
        // `auto` now colours a directory, because the session environment says so.
        #expect(engine.run("ls --color=auto").output.contains("\u{1B}[1;38;5;12msub"))

        // NO_COLOR wins over CLICOLOR, which is the convention tools follow.
        engine.environment.variables["NO_COLOR"] = "1"
        #expect(engine.environment.colorEnabled == false)
        #expect(engine.run("ls --color=auto").output.contains("\u{1B}") == false)
        // An explicit request still wins over the environment.
        #expect(engine.run("ls --color=always").output.contains("\u{1B}[1;38;5;12msub"))
    }

    @Test("grep highlights matches but not inverted output")
    func grepColours() {
        let (engine, _) = makeEngine()
        engine.run("printf 'alpha\\nbeta\\nALPHA\\n' > g.txt")
        #expect(engine.run("grep alpha g.txt").output == "alpha")
        let hit = engine.run("grep --color=always alpha g.txt").output
        #expect(hit.contains("\u{1B}[1;38;5;9malpha"))
        // -i highlights the text as written, not as spelled in the pattern.
        let insensitive = engine.run("grep --color=always -i alpha g.txt").output
        #expect(insensitive.contains("\u{1B}[1;38;5;9mALPHA"))
        // -v prints every line that does not match, and ALPHA does not match
        // the lowercase pattern.
        #expect(engine.run("grep --color=always -v alpha g.txt").output == "beta\nALPHA")
        #expect(engine.run("grep --color=always -n alpha g.txt").output.contains("\u{1B}[38;5;10m1"))
        // A regex pattern must still work when colour is on.
        #expect(engine.run("grep --color=always -E 'a.*a' g.txt").output.contains("alpha"))
    }

    private func makeEngine() -> (ShellEngine, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ShellEngine(environment: ShellEnvironment(root: root)), root)
    }
}
