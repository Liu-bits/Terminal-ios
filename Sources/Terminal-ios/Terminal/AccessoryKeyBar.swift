// Copyright © 2026 Liu-bits. All rights reserved.

import UIKit

/// Tells the owner which key the user pressed above the keyboard.
protocol AccessoryKeyBarDelegate: AnyObject {
    func keyBar(_ bar: AccessoryKeyBar, didSelect key: String)
}

/// The row of keys above the keyboard.
///
/// A phone keyboard has no Tab, Esc or Ctrl, and no arrow keys, so a shell needs
/// its own. The bar is deliberately dumb: it reports the key it was given and
/// lets the controller decide whether to type it, send it to a session, or quit.
final class AccessoryKeyBar: UIView {

    weak var delegate: AccessoryKeyBarDelegate?

    /// The default keys: the punctuation a shell wants, plus Tab, Esc and Ctrl-C.
    static let defaultKeys = ["Tab", "Esc", "|", "/", "~", "-", "Ctrl+C"]

    private(set) var keys: [String]
    private let stack = UIStackView()

    init(keys: [String] = AccessoryKeyBar.defaultKeys) {
        self.keys = keys
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AccessoryKeyBar is built in code")
    }

    private func setup() {
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        rebuild()
    }

    /// Replaces the keys, for a session that wants different ones.
    func setKeys(_ newKeys: [String]) {
        keys = newKeys
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for title in keys {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .bold)
            button.setTitleColor(UIColor.black, for: .normal)
            button.backgroundColor = UIColor(white: 0.85, alpha: 1.0)
            button.layer.cornerRadius = 6
            button.accessibilityIdentifier = "key-\(title)"
            button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
    }

    @objc private func tapped(_ sender: UIButton) {
        guard let key = sender.title(for: .normal) else {
            return
        }
        delegate?.keyBar(self, didSelect: key)
    }
}
