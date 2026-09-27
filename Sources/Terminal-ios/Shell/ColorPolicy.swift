// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// `--color[=auto|always|never]`, shared by `ls`, `grep` and `find`.
///
/// The default is `auto`, and `auto` follows the same environment convention
/// the GNU tools use: `CLICOLOR` switches colour on, `NO_COLOR` wins over it.
/// Tests and pipelines therefore stay plain unless they ask otherwise.
enum ColorPolicy: String {
    case auto
    case always
    case never

    func isEnabled(_ context: ShellRunContext) -> Bool {
        switch self {
        case .always:
            return true
        case .never:
            return false
        case .auto:
            return context.colorizeOutput
        }
    }

    /// Reads the option from parsed arguments. A bare `--color` means
    /// `always`, which is what busybox and BSD do.
    static func from(_ parsed: ShellArgs) -> ColorPolicy {
        if let value = parsed.longValue("color") {
            return ColorPolicy(rawValue: value.lowercased()) ?? .auto
        }
        return parsed.hasLong("color") ? .always : .auto
    }
}
