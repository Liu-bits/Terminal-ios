// Copyright © 2026 Liu-bits. All rights reserved.

import UIKit

/// Dark phosphor-on-black terminal screen: ANSI-coloured scrollback, an input
/// line with a blinking caret, and a mobile accessory key bar.
///
/// The view is deliberately thin. Everything that can be tested without a
/// simulator lives elsewhere: the shell in `Shell/`, the escape-sequence and
/// grid handling in `Terminal/`. This file only turns styled runs into an
/// attributed string and forwards input to the engine.
final class TerminalViewController: UIViewController {

    let engine = ShellEngine()

    /// Scrollback, grid and cursor. The screen model is what makes progress
    /// bars, cursor addressing and colour behave like a real terminal.
    private(set) var output = TerminalOutput()

    private let scrollView = UIScrollView()
    let outputLabel = UILabel()
    private let promptLabel = UILabel()
    let inputField = UITextField()
    private let keyBar = UIStackView()

    /// The default foreground: phosphor green, used wherever a program leaves
    /// the colour alone.
    private let baseColor = UIColor(red: 0.2, green: 1.0, blue: 0.35, alpha: 1.0)
    private var outputFont: UIFont {
        UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncColumnsToWidth()
    }

    // MARK: - Setup

    private var promptRow: UIStackView?

    private func setupOutput() {
        outputLabel.numberOfLines = 0
        outputLabel.font = outputFont
        outputLabel.textColor = baseColor
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
        promptLabel.textColor = baseColor
        promptLabel.setContentHuggingPriority(.required, for: .horizontal)
        promptLabel.translatesAutoresizingMaskIntoConstraints = false

        inputField.font = outputFont
        inputField.textColor = UIColor.white
        inputField.tintColor = baseColor
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
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        appendLine("$ \(line)")
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
            output.reset()
            render()
            return
        }
        if !result.output.isEmpty {
            appendLine(result.output)
        }
        if result.exitCode != 0 {
            appendLine("[exit \(result.exitCode)]")
        }
    }

    // MARK: - Rendering

    private func appendLine(_ text: String) {
        output.appendLine(text)
        render(announcing: text)
    }

    private func render(announcing announcement: String? = nil) {
        outputLabel.attributedText = attributedOutput()
        // VoiceOver must not read escape sequences aloud, and it should hear the
        // new chunk rather than the whole scrollback.
        if let announcement {
            let spoken = ANSIParser.strip(announcement)
            outputLabel.accessibilityValue = spoken
            UIAccessibility.post(notification: .announcement, argument: spoken)
        } else {
            outputLabel.accessibilityValue = output.plainText
        }
        view.layoutIfNeeded()
        let bottom = CGPoint(x: 0, y: max(0, scrollView.contentSize.height - scrollView.bounds.height))
        scrollView.setContentOffset(bottom, animated: true)
    }

    private func attributedOutput() -> NSAttributedString {
        let font = outputFont
        let attributed = NSMutableAttributedString()
        let newline = NSAttributedString(
            string: "\n",
            attributes: [.font: font, .foregroundColor: baseColor]
        )
        for (index, line) in output.renderedLines.enumerated() {
            if index > 0 {
                attributed.append(newline)
            }
            for segment in line {
                attributed.append(
                    NSAttributedString(
                        string: segment.text,
                        attributes: attributes(for: segment.style, font: font)
                    )
                )
            }
        }
        return attributed
    }

    private func attributes(
        for style: TerminalStyle,
        font: UIFont
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        attributes[.font] = style.bold
            ? UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
            : font

        var foreground = color(for: style.foreground, fallback: baseColor)
        var background: UIColor? = style.background == .default
            ? nil
            : color(for: style.background, fallback: nil)
        if style.reverse {
            let swapped = foreground
            foreground = background ?? UIColor.black
            background = swapped
        }
        if style.dim {
            foreground = foreground.withAlphaComponent(0.6)
        }
        if style.hidden {
            foreground = UIColor.clear
        }
        attributes[.foregroundColor] = foreground
        if let background {
            attributes[.backgroundColor] = background
        }
        if style.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = foreground
        }
        if style.italic {
            // The monospaced system font ships no italic face, so lean it.
            attributes[.obliqueness] = 0.18
        }
        return attributes
    }

    /// Maps a terminal colour onto a `UIColor`.
    ///
    /// Two adjustments keep the output readable on a black background: the
    /// palette's black and bright-black entries would be invisible, so they
    /// become greys.
    private func color(for terminalColor: TerminalColor, fallback: UIColor?) -> UIColor {
        switch terminalColor {
        case .default:
            return fallback ?? baseColor
        case .palette(let index):
            if index == 0 {
                return UIColor(white: 0.25, alpha: 1.0)
            }
            if index == 8 {
                return UIColor(white: 0.55, alpha: 1.0)
            }
            let rgb = terminalColor.rgb
            return UIColor(
                red: CGFloat(rgb.r) / 255,
                green: CGFloat(rgb.g) / 255,
                blue: CGFloat(rgb.b) / 255,
                alpha: 1.0
            )
        case .rgb:
            let rgb = terminalColor.rgb
            return UIColor(
                red: CGFloat(rgb.r) / 255,
                green: CGFloat(rgb.g) / 255,
                blue: CGFloat(rgb.b) / 255,
                alpha: 1.0
            )
        }
    }

    /// Feeds the measured width back to the screen so wrapping matches the view.
    private func syncColumnsToWidth() {
        let available = scrollView.bounds.width
        guard available > 0 else {
            return
        }
        let characterWidth = ("0" as NSString)
            .size(withAttributes: [.font: outputFont])
            .width
        guard characterWidth > 0 else {
            return
        }
        let columns = max(20, Int(available / characterWidth))
        guard columns != output.screen.columns else {
            return
        }
        output.resize(columns: columns)
        engine.environment.variables["COLUMNS"] = "\(columns)"
        render()
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
