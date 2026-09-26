// Copyright © 2026 Liu-bits. All rights reserved.

import XCTest

class AppUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false
        // UI tests must launch the application that they test. Doing this in setup will make sure it happens for each test method.
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
    }

    func testLaunchesToTerminal() {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let output = app.staticTexts["terminalOutput"]
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        let input = app.textFields["terminalInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
    }
}
