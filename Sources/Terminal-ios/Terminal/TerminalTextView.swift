// Copyright © 2026 Liu-bits. All rights reserved.

import UIKit

/// The screen: scrollback, colour, and the measurements commands ask for.
///
/// Everything here is presentation. It owns the scroll view and the label, turns
/// the screen model in `Terminal/` into an attributed string, and reports how
/// many characters fit - which is how `$LINES`/`$COLUMNS` get their values. The
/// view controller keeps behaviour: commands, sessions and key routing.
final class TerminalTextView: UIView {

    /// Read by tests and by the UI test target through `terminalOutput`.
    let label = UILabel()

    private let scroller = UIScrollView()

    /// Phosphor green: the colour of everything a program left unstyled.
    private let baseColor = UIColor(red: 0.2, green: 1.0, blue: 0.35, alpha: 1.0)

    var monospaceFont: UIFont {
        UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    private var font: UIFont {
        label.font ?? monospaceFont
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black
        label.numberOfLines = 0
        label.font = monospaceFont
        label.textColor = baseColor
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = "terminalOutput"
        label.translatesAutoresizingMaskIntoConstraints = false
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(label)
        addSubview(scroller)
        NSLayoutConstraint.activate([
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),

            label.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            label.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            label.widthAnchor.constraint(equalTo: scroller.frameLayoutGuide.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalTextView is built in code")
    }

    // MARK: - Rendering

    /// Draws the whole screen model.
    func render(_ screen: TerminalOutput) {
        label.attributedText = attributed(screen.renderedLines)
        scrollToBottom()
    }

    /// Draws the model and reports the plain text VoiceOver should announce.
    ///
    /// `announcement` is what was just added, not the whole screen: reading a
    /// thousand lines every time a command runs would be unusable.
    func render(_ screen: TerminalOutput, announcing announcement: String? = nil) {
        render(screen)
        let spoken = announcement.map { ANSIParser.strip($0) } ?? screen.plainText
        label.accessibilityValue = spoken
        if let announcement {
            UIAccessibility.post(notification: .announcement, argument: spoken)
        }
        layoutIfNeeded()
        scrollToBottom()
    }

    private func scrollToBottom() {
        let bottom = CGPoint(x: 0, y: max(0, scroller.contentSize.height - scroller.bounds.height))
        scroller.setContentOffset(bottom, animated: true)
    }

    // MARK: - Measurements

    /// Character columns that fit, which is what `$COLUMNS` should be.
    var columnCount: Int {
        let width = scroller.bounds.width
        guard width > 0 else {
            return 0
        }
        let characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        guard characterWidth > 0 else {
            return 0
        }
        return max(20, Int(width / characterWidth))
    }

    /// Character rows that fit, which is what `$LINES` should be.
    var rowCount: Int {
        let height = scroller.bounds.height
        guard height > 0 else {
            return 0
        }
        return max(6, Int(height / max(1, font.lineHeight)))
    }

    // MARK: - Styled runs to attributed text

    private func attributed(_ lines: [[ANSISegment]]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let newline = NSAttributedString(
            string: "\n",
            attributes: [.font: font, .foregroundColor: baseColor]
        )
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result.append(newline)
            }
            for segment in line {
                result.append(
                    NSAttributedString(string: segment.text, attributes: attributes(for: segment.style))
                )
            }
        }
        return result
    }

    private func attributes(for style: TerminalStyle) -> [NSAttributedString.Key: Any] {
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
            // The monospaced system font has no italic face, so lean it.
            attributes[.obliqueness] = 0.18
        }
        return attributes
    }

    /// Maps a terminal colour onto a `UIColor`.
    ///
    /// Two adjustments keep output readable on black: palette 0 and 8 (black and
    /// bright black) would be invisible, so they become greys.
    private func color(for terminalColor: TerminalColor, fallback: UIColor?) -> UIColor {
        switch terminalColor {
        case .default:
            return fallback ?? baseColor
        case .palette(0):
            return UIColor(white: 0.25, alpha: 1.0)
        case .palette(8):
            return UIColor(white: 0.55, alpha: 1.0)
        default:
            let rgb = terminalColor.rgb
            return UIColor(
                red: CGFloat(rgb.r) / 255,
                green: CGFloat(rgb.g) / 255,
                blue: CGFloat(rgb.b) / 255,
                alpha: 1.0
            )
        }
    }
}
