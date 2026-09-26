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
}
