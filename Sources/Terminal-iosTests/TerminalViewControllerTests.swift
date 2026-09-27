// Copyright © 2026 Liu-bits. All rights reserved.

@testable import Terminal_ios
import Testing
import UIKit

@MainActor
struct TerminalViewControllerTests {

    @Test("Boots with welcome line and focused input")
    func bootsWithWelcomeLine() {
        let controller = TerminalViewController()
        controller.loadViewIfNeeded()
        #expect(controller.outputLabel.text?.contains("Type `help`") == true)
        #expect(controller.inputField.delegate != nil)
    }

    @Test("Runs commands and prints exit codes")
    func runsCommands() {
        let controller = TerminalViewController()
        controller.loadViewIfNeeded()
        controller.submit("echo hi")
        #expect(controller.outputLabel.text?.contains("$ echo hi") == true)
        #expect(controller.outputLabel.text?.hasSuffix("\nhi") == true)
        controller.submit("nosuchcmd")
        #expect(controller.outputLabel.text?.contains("[exit 127]") == true)
    }

    @Test("Clears the screen on clear")
    func clearsScreen() {
        let controller = TerminalViewController()
        controller.loadViewIfNeeded()
        controller.submit("echo hi")
        controller.submit("clear")
        #expect(controller.outputLabel.text == "")
    }

    @Test("Shows help without touching history")
    func showsHelp() {
        let controller = TerminalViewController()
        controller.loadViewIfNeeded()
        controller.submit("help")
        #expect(controller.outputLabel.text?.contains("Built-ins:") == true)
        #expect(controller.engine.history.isEmpty)
    }

    @Test("Accessory keys edit the input")
    func accessoryKeysEditInput() {
        let controller = TerminalViewController()
        controller.loadViewIfNeeded()
        controller.handleKey("|")
        controller.handleKey("~")
        #expect(controller.inputField.text == "|~")
        controller.handleKey("Ctrl+C")
        #expect(controller.inputField.text == "")
        #expect(controller.outputLabel.text?.contains("$ ^C") == true)
    }

    @Test("A pager takes the screen and gives it back")
    func pagerWiring() {
        let controller = TerminalViewController()
        controller.loadViewIfNeeded()
        // Escapes are stripped for the assertions: the pager draws in reverse
        // video, and an escape in the middle of the text would hide it.
        let screen = { ANSIParser.strip(controller.outputLabel.text ?? "") }

        controller.submit("printf 'a\\nb\\nc\\nd\\ne\\nf\\ng\\n' > pager.txt")
        controller.submit("less pager.txt")
        #expect(controller.isShowingPager, "the pager did not take the screen; screen=\(screen())")
        // The status line is what proves the screen belongs to the pager now.
        #expect(screen().contains("1-7/7"), "screen=\(screen())")
        #expect(screen().contains("q:quit"), "screen=\(screen())")

        // Keys from the accessory bar reach the pager instead of the shell.
        controller.handleKey(" ")
        #expect(controller.isShowingPager)
        controller.handleKey("q")
        #expect(controller.isShowingPager == false)

        // And the shell is usable again, with the main screen intact.
        controller.submit("echo after")
        #expect(screen().hasSuffix("after"), "screen=\(screen())")
        #expect(screen().contains("$ less pager.txt"), "screen=\(screen())")
    }
}
