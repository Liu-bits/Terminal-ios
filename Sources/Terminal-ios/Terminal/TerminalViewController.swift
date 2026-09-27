// Copyright © 2026 Liu-bits. All rights reserved.

import UIKit

/// Dark phosphor-on-black terminal: a screen view, a prompt row, and a key bar
/// above the keyboard.
///
/// This controller is behaviour only - commands, sessions, key routing - after
/// the split: `TerminalTextView` owns the scrollback and its colours,
/// `AccessoryKeyBar` owns the keys, and `TerminalOutput` owns the grid. Anything
/// that can be tested without UIKit lives in `Shell/`, the model half of
/// `Terminal/`, or `History/`.
final class TerminalViewController: UIViewController {

    let engine = ShellEngine()

    /// Scrollback, grid and cursor. The screen model is what makes progress
    /// bars, cursor addressing and colour behave like a real terminal.
    private(set) var output = TerminalOutput()

    private let terminalView = TerminalTextView()
    private let promptLabel = UILabel()
    let inputField = UITextField()
    private let keyBar = AccessoryKeyBar()

    /// The command currently owning the screen (`less`, `ed`, `top`), if any.
    private var interactiveSession: InteractiveSession?

    /// True while a command owns the screen. Keystrokes go to it instead of the
    /// shell until it finishes.
    var isShowingPager: Bool { interactiveSession != nil }

    /// The label the screen draws into, so tests and the UI test target keep
    /// reading the text the way they always have.
    var outputLabel: UILabel { terminalView.label }

    override func viewDidLoad() {
        super.viewDidLoad()

        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor.black
        title = "Terminal-ios"

        // Tell the shell it is talking to a terminal. GNU tools read CLICOLOR,
        // so `ls` and `grep` colour their output here while `> file` stays
        // plain - the same rule as on a desktop.
        engine.environment.variables["CLICOLOR"] = "1"
        engine.environment.variables["TERM"] = "xterm-256color"
        engine.environment.variables["COLUMNS"] = "80"

        setupViews()
        setupInput()
        appendLine("Terminal-ios - offline shell. Type `help`.")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        inputField.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncScreenSize()
    }

    // MARK: - Layout

    private func setupViews() {
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        promptLabel.text = "$"
        promptLabel.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        promptLabel.textColor = UIColor(red: 0.2, green: 1.0, blue: 0.35, alpha: 1.0)
        promptLabel.setContentHuggingPriority(.required, for: .horizontal)
        promptLabel.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [promptLabel, inputField])
        row.axis = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            terminalView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            terminalView.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -8),

            row.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
    }

    private func setupInput() {
        inputField.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        inputField.textColor = UIColor.white
        inputField.tintColor = UIColor(red: 0.2, green: 1.0, blue: 0.35, alpha: 1.0)
        inputField.autocapitalizationType = .none
        inputField.autocorrectionType = .no
        inputField.spellCheckingType = .no
        inputField.smartQuotesType = .no
        inputField.smartDashesType = .no
        inputField.returnKeyType = .go
        inputField.accessibilityIdentifier = "terminalInput"
        inputField.accessibilityLabel = "Command input"
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false

        keyBar.delegate = self
        inputField.inputAccessoryView = keyBar
    }

    /// Feeds the measured screen size back to commands that ask for one, and
    /// keeps the grid's wrapping in step with the view.
    private func syncScreenSize() {
        let rows = terminalView.rowCount
        if rows > 0 {
            engine.environment.variables["LINES"] = "\(rows)"
        }
        let columns = terminalView.columnCount
        guard columns > 0, columns != output.screen.columns else {
            return
        }
        output.resize(columns: columns)
        engine.environment.variables["COLUMNS"] = "\(columns)"
        terminalView.render(output)
    }

    // MARK: - Execution

    func submit(_ line: String) {
        appendLine("$ \(line)")
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "help" {
            // Rendered from the live command table so the list cannot drift.
            appendLine(ShellBuiltins.helpText())
            return
        }
        guard !trimmed.isEmpty else {
            return
        }
        // A command may take the screen instead of returning output; that is what
        // turns `less` into a real pager rather than a cat.
        switch engine.runInteractive(line) {
        case .interactive(let session):
            interactiveSession = session
            updatePromptForSession()
            output.append(session.initialFrame)
            terminalView.render(output, announcing: session.initialFrame)
        case .finished(let result):
            if result.clearScreen {
                output.reset()
                terminalView.render(output)
                return
            }
            if !result.output.isEmpty {
                appendLine(result.output)
            }
            if result.exitCode != 0 {
                appendLine("[exit \(result.exitCode)]")
            }
        }
    }

    private func appendLine(_ text: String) {
        output.appendLine(text)
        terminalView.render(output, announcing: text)
    }

    // MARK: - Interactive commands

    /// Routes one keystroke to the command that owns the screen.
    func send(key: String) {
        guard let session = interactiveSession else {
            return
        }
        apply(session.handle(key: key))
    }

    /// Routes a completed line, for sessions that read whole lines.
    func send(line: String) {
        guard let session = interactiveSession else {
            return
        }
        apply(session.handle(line: line))
    }

    /// Draws whatever the session returned.
    ///
    /// `.frame` and `.append` are handled the same way on purpose: a frame is
    /// just text that happens to begin with "home and erase", and the grid in
    /// `Terminal/` is what acts on that. The difference is the command's choice,
    /// not something the view has to know about.
    private func apply(_ step: InteractiveStep) {
        switch step {
        case .frame(let text), .append(let text):
            output.append(text)
            terminalView.render(output, announcing: text)
        case .finished(let text, let code):
            interactiveSession = nil
            output.append(text)
            terminalView.render(output)
            updatePromptForSession()
            inputField.text = ""
            if code != 0 {
                appendLine("[exit \(code)]")
            }
        }
    }

    /// The prompt row says which mode the terminal is in, and what the session
    /// expects: single keys, or whole lines typed into the field.
    private func updatePromptForSession() {
        guard let session = interactiveSession else {
            promptLabel.text = "$"
            inputField.placeholder = nil
            return
        }
        let isLine = session.inputMode == .line
        promptLabel.text = isLine ? ":" : "⌨"
        inputField.placeholder = isLine
            ? "type a line, Return to send"
            : "space / b / j / k / G / q / …"
    }

    // MARK: - Keys

    func handleKey(_ key: String) {
        if let session = interactiveSession {
            if session.inputMode == .line {
                // A line-oriented session keeps the field visible and editable;
                // only the "stop" keys go to it directly.
                switch key {
                case "Esc":
                    send(key: InteractiveKey.escape)
                case "Ctrl+C":
                    send(key: InteractiveKey.interrupt)
                case "Tab":
                    inputField.insertText("\t")
                default:
                    inputField.insertText(key)
                }
                return
            }
            // A key-oriented session (a pager) takes every key: space to page,
            // `q` (or Esc / Ctrl+C) to quit.
            switch key {
            case "Tab":
                send(key: " ")
            case "Esc":
                send(key: InteractiveKey.escape)
            case "Ctrl+C":
                send(key: InteractiveKey.interrupt)
            default:
                send(key: key)
            }
            return
        }
        switch key {
        case "Ctrl+C":
            inputField.text = ""
            appendLine("$ ^C")
        case "Tab":
            inputField.insertText("\t")
        case "Esc":
            inputField.resignFirstResponder()
            inputField.becomeFirstResponder()
        default:
            inputField.insertText(key)
        }
    }
}

extension TerminalViewController: AccessoryKeyBarDelegate {

    func keyBar(_ bar: AccessoryKeyBar, didSelect key: String) {
        handleKey(key)
    }
}

extension TerminalViewController: UITextFieldDelegate {

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let session = interactiveSession {
            if session.inputMode == .line {
                send(line: textField.text ?? "")
                textField.text = ""
            } else {
                send(key: InteractiveKey.enter)
            }
            return false
        }
        submit(textField.text ?? "")
        textField.text = ""
        return false
    }

    /// While a key-oriented command owns the screen, typed characters are keys
    /// for it - they must not end up in the shell's input line.
    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        guard let session = interactiveSession else {
            return true
        }
        // A line-oriented session needs the text to stay in the field so the
        // user can see and edit it.
        guard session.inputMode == .key else {
            return true
        }
        for character in string {
            send(key: String(character))
        }
        return false
    }
}

#Preview {
    TerminalViewController()
}
