// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// The `winget` surface over the same catalogs the other package managers use.
///
/// winget adds identifiers (`Publisher.Package`), publishers, tags and named
/// sources to the model, which is why the catalog entries carry those fields.
/// Everything else - allow-listed mirrors, digest verification, interpreted
/// payloads only - is unchanged.
enum WingetBuiltin {

    static let version = "1.9.0-terminal-ios"

    static let all: [ShellBuiltin] = [
        ShellBuiltin("winget", "Windows Package Manager UX over the catalogs", winget)
    ]

    private struct Invocation {
        var verb: String
        var operands: [String]
        var flags: Set<String>
        var named: [String: String]

        /// Parses `winget <verb> <operands...> [--flag] [-n value]`.
        init(_ args: [String], valueFlags: Set<String> = []) {
            var verb = ""
            var operands: [String] = []
            var flags = Set<String>()
            var named: [String: String] = [:]
            var index = 0
            while index < args.count {
                let arg = args[index]
                index += 1
                if arg.hasPrefix("--") || arg.hasPrefix("-") {
                    let name = String(arg.drop(while: { $0 == "-" })).lowercased()
                    if valueFlags.contains(name), index < args.count {
                        named[name] = args[index]
                        index += 1
                    } else {
                        flags.insert(name)
                    }
                    continue
                }
                if verb.isEmpty {
                    verb = arg.lowercased()
                } else {
                    operands.append(arg)
                }
            }
            self.verb = verb
            self.operands = operands
            self.flags = flags
            self.named = named
        }

        func has(_ flag: String) -> Bool { flags.contains(flag.lowercased()) }
        func value(_ name: String) -> String? { named[name.lowercased()] }
    }

    private static func winget(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let manager = context.packages()
        let invocation = Invocation(args, valueFlags: ["source", "s", "n", "a", "id", "version"])
        if invocation.has("version") || invocation.verb == "-v" || invocation.verb == "--version" {
            return .ok("v\(version)")
        }
        switch invocation.verb {
        case "":
            return .ok(usage)
        case "search", "find":
            return search(invocation, manager)
        case "show", "view":
            return show(invocation, manager)
        case "install", "add":
            return install(invocation, manager)
        case "uninstall", "remove", "rm":
            return uninstall(invocation, manager)
        case "list", "ls":
            return list(invocation, manager)
        case "upgrade", "update":
            return upgrade(invocation, manager)
        case "source", "sources":
            return source(invocation, manager)
        default:
            return .fail("winget: unknown verb '\(invocation.verb)'\n\n\(usage)", code: 2)
        }
    }

    private static let usage = """
    Windows Package Manager (Terminal-ios)
    usage: winget <verb> [options]

      search <term>                 find packages
      show <id>                     details for a package
      install <id>                  install ([-s|--source <source-id>])
      uninstall <id>                remove an installed package
      list [term]                   list catalog / installed packages
      upgrade                       check installed packages
      source list                   show configured sources
      source add -n <id> -a <url>   register an allow-listed mirror
      source remove <id>            drop a mirror
      source enable|disable <id>    turn a mirror on or off
      source update                 refresh mirror manifests

    Mirrors are https-only, allow-listed in this build, and their payloads must
    be script/wheel/wasm with a matching SHA-256.
    """

    // MARK: - Verbs

    private static func search(_ invocation: Invocation, _ manager: PackageManager) -> ShellResult {
        guard let term = invocation.operands.first else {
            return .fail("winget: search needs a term", code: 2)
        }
        let outcome = manager.search([term])
        if outcome.exitCode != 0 {
            return toResult(outcome)
        }
        // `PackageManager.search` prints one summary line per hit plus indented
        // detail lines; winget only shows the summary columns.
        let summary = outcome.text
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("  ") }
            .joined(separator: "\n")
        return .ok("Id                          Version    Source\n" + summary)
    }

    private static func show(_ invocation: Invocation, _ manager: PackageManager) -> ShellResult {
        guard let identifier = invocation.operands.first else {
            return .fail("winget: show needs a package id", code: 2)
        }
        return toResult(manager.info([identifier]))
    }

    private static func install(_ invocation: Invocation, _ manager: PackageManager) -> ShellResult {
        guard let identifier = invocation.operands.first else {
            return .fail("winget: install needs a package id", code: 2)
        }
        guard let match = manager.resolve(identifier) else {
            return .fail("No package found matching input criteria: \(identifier)")
        }
        if let requested = invocation.value("source") ?? invocation.value("s"),
           requested.lowercased() != match.source.id.lowercased() {
            return .fail("No package found in source '\(requested)'. It lives in '\(match.source.id)'.")
        }
        let outcome = manager.install([identifier], transport: transport())
        if outcome.exitCode != 0 {
            return toResult(outcome)
        }
        return .ok(outcome.text + "\nSuccessfully installed \(match.entry.packageID) \(match.entry.version)")
    }

    private static func uninstall(_ invocation: Invocation, _ manager: PackageManager) -> ShellResult {
        guard let identifier = invocation.operands.first else {
            return .fail("winget: uninstall needs a package id", code: 2)
        }
        return toResult(manager.remove([identifier]))
    }

    private static func list(_ invocation: Invocation, _ manager: PackageManager) -> ShellResult {
        let outcome = manager.list(
            pattern: invocation.operands.first,
            sourceFilter: invocation.value("source") ?? invocation.value("s")
        )
        guard outcome.exitCode == 0 else {
            return toResult(outcome)
        }
        let header = "Name                  Id                          Version    Source"
        return .ok(outcome.text.isEmpty ? "No installed package found matching input criteria." : header + "\n" + outcome.text)
    }

    private static func upgrade(_ invocation: Invocation, _ manager: PackageManager) -> ShellResult {
        toResult(manager.upgrade())
    }

    private static func source(_ invocation: Invocation, _ manager: PackageManager) -> ShellResult {
        let verb = invocation.operands.first?.lowercased() ?? "list"
        let rest = Array(invocation.operands.dropFirst())
        switch verb {
        case "list", "ls":
            return toResult(manager.sourceList())
        case "add":
            let id = invocation.value("n") ?? rest.first
            let url = invocation.value("a") ?? rest.dropFirst().first
            guard let id, let url else {
                return .fail("winget: source add needs -n <id> and -a <url>", code: 2)
            }
            return toResult(manager.sourceAdd(id: id, name: id, urlString: url))
        case "remove", "rm":
            guard let id = invocation.value("n") ?? rest.first else {
                return .fail("winget: source remove needs an id", code: 2)
            }
            return toResult(manager.sourceRemove(id: id))
        case "enable", "disable":
            guard let id = rest.first else {
                return .fail("winget: source \(verb) needs an id", code: 2)
            }
            return toResult(manager.sourceSetEnabled(id: id, enabled: verb == "enable"))
        case "update", "refresh":
            guard let transport = transport() else {
                return .fail("winget: no network transport is available in this environment")
            }
            return toResult(manager.refresh(transport: transport))
        default:
            return .fail("winget: unknown source verb '\(verb)'", code: 2)
        }
    }

    // MARK: - Helpers

    private static func toResult(_ outcome: PackageManager.Outcome) -> ShellResult {
        ShellResult(output: outcome.text, exitCode: outcome.exitCode, clearScreen: false)
    }

    /// The transport installed by the app (nil in tests and in the local check
    /// runner, which inject their own).
    private static func transport() -> ManifestTransport? {
        ManifestTransportFactory.shared
    }
}
