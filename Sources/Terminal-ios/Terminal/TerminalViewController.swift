// Copyright © 2026 Liu-bits. All rights reserved.

import UIKit

/// Dark phosphor-on-black terminal screen: scrollback, input line with a
/// blinking caret, and a mobile accessory key bar.
final class TerminalViewController: UIViewController {

    let engine = ShellEngine()

    private let scrollView = UIScrollView()
    let outputLabel = UILabel()
    private let promptLabel = UILabel()
    let inputField = UITextField()
    private let keyBar = UIStackView()
    private var outputLines: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()

        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor.black
        title = "Terminal-ios"

        setupOutput()
        setupPromptRow()
        setupKeyBar()
        setupConstraints()

        appendLine("Terminal-ios - offline shell. Type `help`.")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        inputField.becomeFirstResponder()
    }

    // MARK: - Setup

    private var promptRow: UIStackView?

    private func setupOutput() {
        outputLabel.numberOfLines = 0
        outputLabel.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        outputLabel.textColor = UIColor(red: 0.2, green: 1.0, blue: 0.35, alpha: 1.0)
        outputLabel.adjustsFontForContentSizeCategory = true
        outputLabel.translatesAutoresizingMaskIntoConstraints = false
        outputLabel.accessibilityIdentifier = "terminalOutput"

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(outputLabel)
        view.addSubview(scrollView)
    }

    private func setupPromptRow() {
        promptLabel.text = "$"
        promptLabel.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        promptLabel.textColor = outputLabel.textColor
        promptLabel.setContentHuggingPriority(.required, for: .horizontal)
        promptLabel.translatesAutoresizingMaskIntoConstraints = false

        inputField.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        inputField.textColor = UIColor.white
        inputField.tintColor = outputLabel.textColor
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

        let row = UIStackView(arrangedSubviews: [promptLabel, inputField])
        row.axis = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        promptRow = row
        view.addSubview(row)
    }

    private func setupKeyBar() {
        keyBar.axis = .horizontal
        keyBar.distribution = .fillEqually
        keyBar.spacing = 6
        for title in ["Tab", "Esc", "|", "/", "~", "-", "Ctrl+C"] {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .bold)
            button.setTitleColor(UIColor.black, for: .normal)
            button.backgroundColor = UIColor(white: 0.85, alpha: 1.0)
            button.layer.cornerRadius = 6
            button.accessibilityIdentifier = "key-\(title)"
            button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
            keyBar.addArrangedSubview(button)
        }
        inputField.inputAccessoryView = keyBar
    }

    private func setupConstraints() {
        guard let row = promptRow else {
            return
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -8),

            outputLabel.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            outputLabel.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            outputLabel.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            outputLabel.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            row.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
    }

    // MARK: - Execution

    @objc func keyTapped(_ sender: UIButton) {
        guard let key = sender.title(for: .normal) else {
            return
        }
        handleKey(key)
    }

    func handleKey(_ key: String) {
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

    func submit(_ line: String) {
        appendLine("$ \(line)")
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "help" {
            // Rendered from the live command table so the list cannot drift.
            appendLine(ShellBuiltins.helpText())
            return
        }
        if trimmed.isEmpty {
            return
        }
        let result = engine.run(line)
        if result.clearScreen {
            outputLines = []
            outputLabel.text = ""
            outputLabel.accessibilityValue = ""
            return
        }
        if !result.output.isEmpty {
            appendLine(result.output)
        }
        if result.exitCode != 0 {
            appendLine("[exit \(result.exitCode)]")
        }
    }

    private func appendLine(_ text: String) {
        outputLines.append(text)
        if outputLines.count > 500 {
            outputLines.removeFirst(outputLines.count - 500)
        }
        outputLabel.text = outputLines.joined(separator: "\n")
        // VoiceOver reads new output as it arrives.
        outputLabel.accessibilityValue = text
        UIAccessibility.post(notification: .announcement, argument: text)
        view.layoutIfNeeded()
        let bottom = CGPoint(x: 0, y: max(0, scrollView.contentSize.height - scrollView.bounds.height))
        scrollView.setContentOffset(bottom, animated: true)
    }
}

extension TerminalViewController: UITextFieldDelegate {

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit(textField.text ?? "")
        textField.text = ""
        return false
    }
}

#Preview {
    TerminalViewController()
}
