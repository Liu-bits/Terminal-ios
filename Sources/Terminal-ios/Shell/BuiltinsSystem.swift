// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// System, integrity and package commands.
///
/// Everything here reports the sandbox truthfully: there is one process (the
/// app), one file system (the container) and no network. Commands that would
/// need a real kernel keep the POSIX surface but answer from the sandbox.
enum SystemBuiltins {

    /// Start time of the app, used by `uptime` and `ps`.
    private static let started = Date()

    static let all: [ShellBuiltin] = [
        // Identity and platform
        ShellBuiltin("whoami", "print the current user name", whoami),
        ShellBuiltin("id", "print user and group identity", id),
        ShellBuiltin("uname", "print system information", uname),
        ShellBuiltin("hostname", "print the sandbox host name", hostname),
        ShellBuiltin("arch", "print the machine architecture", arch),
        ShellBuiltin("nproc", "print the number of CPUs", nproc),
        ShellBuiltin("date", "print or format the date", date),
        ShellBuiltin("uptime", "show how long the shell has been up", uptime),
        ShellBuiltin("sleep", "pause for a number of seconds", sleep),
        ShellBuiltin("tty", "print the terminal name", tty),
        ShellBuiltin("ps", "report running processes", ps),
        ShellBuiltin("kill", "send a signal (no real processes exist)", kill),
        ShellBuiltin("free", "show memory usage", free),

        // Environment
        ShellBuiltin("env", "print the environment", env),
        ShellBuiltin("printenv", "print environment variables", printenv),
        ShellBuiltin("unset", "remove environment variables", unset),
        ShellBuiltin("set", "print shell variables", set),
        ShellBuiltin("export", "set environment variables", export),
        ShellBuiltin("read", "read a line into a variable", read),

        // Shell plumbing
        ShellBuiltin("true", "do nothing, successfully", trueCommand),
        ShellBuiltin("false", "do nothing, unsuccessfully", falseCommand),
        ShellBuiltin("test", "evaluate a conditional expression", test),
        ShellBuiltin("[", "evaluate a conditional expression", bracket),
        ShellBuiltin("expr", "evaluate an integer expression", expr),
        ShellBuiltin("eval", "evaluate a string as shell input", eval),
        ShellBuiltin("sh", "run a shell script", sh),
        ShellBuiltin("source", "run a script in the current shell", source),
        ShellBuiltin(".", "run a script in the current shell", source),
        ShellBuiltin("which", "locate a command", which),
        ShellBuiltin("type", "describe how a name would be interpreted", type),
        ShellBuiltin("command", "run or inspect a command", command),
        ShellBuiltin("help", "list the built-in commands", help),
        ShellBuiltin("man", "show a built-in command summary", man),
        ShellBuiltin("version", "print the shell version", version),

        // Package managers (offline catalogs)
        ShellBuiltin("apt", "offline package manager (apt UX)", apt),
        ShellBuiltin("apt-get", "offline package manager (apt UX)", apt),
        ShellBuiltin("apk", "offline package manager (Alpine apk UX)", apk),
        ShellBuiltin("pip", "offline Python package installer (pip UX)", pip),
        ShellBuiltin("pip3", "offline Python package installer (pip UX)", pip),

        // Runtimes that arrive through the catalog
        ShellBuiltin("python3", "run a bundled Python runtime", python),
        ShellBuiltin("python", "run a bundled Python runtime", python),
        ShellBuiltin("py", "run a bundled Python runtime", python),
        ShellBuiltin("gcc", "compile with the bundled toolchain (WASM target)", toolchain),
        ShellBuiltin("cc", "compile with the bundled toolchain (WASM target)", toolchain),
        ShellBuiltin("clang", "compile with the bundled toolchain (WASM target)", toolchain),
        ShellBuiltin("make", "run make with the bundled toolchain", toolchain)
    ]

    // MARK: - Identity

    private static func whoami(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        .ok(context.environment.variables["USER"] ?? "user")
    }

    private static func id(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let user = context.environment.variables["USER"] ?? "user"
        return .ok("uid=501(\(user)) gid=20(staff) groups=20(staff)")
    }

    private static func uname(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        if parsed.has("a") {
            return .ok("Darwin Terminal-ios \(unameRelease) arm64 iOS sandbox")
        }
        if parsed.has("m") { return .ok("arm64") }
        if parsed.has("s") { return .ok("Darwin") }
        if parsed.has("r") { return .ok(unameRelease) }
        if parsed.has("n") { return hostname([], context) }
        return .ok("Darwin")
    }

    private static var unameRelease: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func hostname(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let environment = ProcessInfo.processInfo.environment
        if let name = environment["HOSTNAME"], !name.isEmpty {
            return .ok(name)
        }
        return .ok("localhost")
    }

    private static func arch(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        // The shell only ever runs on Apple silicon builds that are arm64 or
        // on the simulator, which reports the host architecture.
        .ok("arm64")
    }

    private static func nproc(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        .ok("\(ProcessInfo.processInfo.activeProcessorCount)")
    }

    // MARK: - Time and scheduling

    /// `date [+FORMAT]`, with the strftime specifiers people actually use.
    private static func date(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let now = Date()
        guard let format = parsed.operands.first, format.hasPrefix("+") else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE MMM dd HH:mm:ss zzz yyyy"
            return .ok(formatter.string(from: now))
        }
        return .ok(strftime(String(format.dropFirst()), date: now))
    }

    private static func strftime(_ format: String, date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday, .dayOfYear], from: date
        )
        let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        func number(_ value: Int, _ width: Int) -> String {
            let text = "\(value)"
            return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
        }
        var output = ""
        let characters = Array(format)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            index += 1
            guard char == "%", index < characters.count else {
                output.append(char)
                continue
            }
            let specifier = characters[index]
            index += 1
            switch specifier {
            case "Y": output += "\(components.year ?? 0)"
            case "y": output += number((components.year ?? 0) % 100, 2)
            case "m": output += number(components.month ?? 1, 2)
            case "d": output += number(components.day ?? 1, 2)
            case "e": output += "\(components.day ?? 1)"
            case "H": output += number(components.hour ?? 0, 2)
            case "M": output += number(components.minute ?? 0, 2)
            case "S": output += number(components.second ?? 0, 2)
            case "F":
                output += "\(components.year ?? 0)-\(number(components.month ?? 1, 2))-\(number(components.day ?? 1, 2))"
            case "T":
                output += "\(number(components.hour ?? 0, 2)):\(number(components.minute ?? 0, 2)):\(number(components.second ?? 0, 2))"
            case "j": output += number(components.dayOfYear ?? 1, 3)
            case "s": output += "\(Int(date.timeIntervalSince1970))"
            case "a": output += dayNames[max(0, min(6, (components.weekday ?? 1) - 1))]
            case "b": output += monthNames[max(0, min(11, (components.month ?? 1) - 1))]
            case "u": output += "\((components.weekday ?? 0) == 1 ? 7 : (components.weekday ?? 1) - 1)"
            case "Z": output += "UTC"
            case "z": output += "+0000"
            case "p": output += (components.hour ?? 0) < 12 ? "AM" : "PM"
            case "n": output += "\n"
            case "%": output += "%"
            default:
                output.append("%")
                output.append(specifier)
            }
        }
        return output
    }

    private static func uptime(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let seconds = Int(Date().timeIntervalSince(started))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return .ok("up \(hours)h \(minutes)m, 1 user, load averages: 0.00 0.00 0.00")
    }

    private static func sleep(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        guard let raw = args.first, let seconds = Double(raw) else {
            return .fail("sleep: usage: sleep seconds", code: 2)
        }
        // Capped so a stray `sleep 9999` cannot lock the UI thread.
        let capped = min(max(0, seconds), 5)
        Thread.sleep(forTimeInterval: capped)
        if capped < seconds {
            return .ok("")
        }
        return .ok("")
    }

    private static func tty(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        .ok("/dev/console")
    }

    /// One process exists: this app. Listing a full table would be a lie.
    private static func ps(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let seconds = Int(Date().timeIntervalSince(started))
        return .ok("""
          PID TTY           TIME CMD
            1 console   00:00:\(String(format: "%02d", seconds % 60)) Terminal-ios (in-process shell)
        """)
    }

    private static func kill(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        guard !args.isEmpty else {
            return .fail("kill: usage: kill pid", code: 2)
        }
        return .fail("kill: 1: no such process (all commands run in-process; there are no child processes)")
    }

    private static func free(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let total = Int(ProcessInfo.processInfo.physicalMemory / 1024)
        return .ok("""
                     total        used        free
        Mem:      \(total)       -           -
        """)
    }

    // MARK: - Environment

    private static func env(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let lines = context.environment.variables.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        return .ok(lines.joined(separator: "\n"))
    }

    private static func printenv(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        guard !args.isEmpty else {
            return env([], context)
        }
        var lines: [String] = []
        for name in args {
            if let value = context.environment.variables[name] {
                lines.append(value)
            }
        }
        return lines.isEmpty
            ? ShellResult(output: "", exitCode: 1, clearScreen: false)
            : .ok(lines.joined(separator: "\n"))
    }

    private static func unset(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        for name in args {
            context.environment.variables.removeValue(forKey: name)
        }
        return .ok()
    }

    private static func set(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        env([], context)
    }

    private static func export(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        for assignment in args {
            if let equals = assignment.firstIndex(of: "=") {
                let key = String(assignment[..<equals])
                let value = String(assignment[assignment.index(after: equals)...])
                if !key.isEmpty {
                    context.environment.variables[key] = value
                }
            } else if !assignment.isEmpty {
                context.environment.variables[assignment] = context.environment.variables[assignment] ?? ""
            }
        }
        return .ok()
    }

    private static func read(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        guard let name = parsed.operands.first else {
            return .fail("read: usage: read variable", code: 2)
        }
        // Inside a script the input queue advances line by line, so
        // `while read line; do ...; done` terminates at end of input.
        if let session = context.session, session.inputActive {
            guard let line = session.takeInputLine() else {
                return .exit(1)
            }
            context.environment.variables[name] = line
            return .exit(0)
        }
        let text = context.stdin ?? ""
        let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        guard !first.isEmpty else {
            return .exit(1)
        }
        context.environment.variables[name] = first
        return .exit(0)
    }

    // MARK: - Shell plumbing

    private static func trueCommand(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        .ok()
    }

    private static func falseCommand(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        ShellResult(output: "", exitCode: 1, clearScreen: false)
    }

    /// Evaluates `test` expressions: file predicates, string and integer tests.
    private static func evaluateTest(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        if args.isEmpty {
            return .exit(1)
        }
        if args[0] == "!" {
            let inner = evaluateTest(Array(args.dropFirst()), context)
            return .exit(inner.exitCode == 0 ? 1 : 0)
        }
        if args.count == 1 {
            return .exit(args[0].isEmpty ? 1 : 0)
        }
        if args.count == 2 {
            let operand = args[1]
            switch args[0] {
            case "-e": return .exit(context.exists(operand) ? 0 : 1)
            case "-f": return .exit(context.exists(operand) && !context.isDirectory(operand) ? 0 : 1)
            case "-d": return .exit(context.isDirectory(operand) ? 0 : 1)
            case "-z": return .exit(operand.isEmpty ? 0 : 1)
            case "-n": return .exit(operand.isEmpty ? 1 : 0)
            case "-r", "-w", "-x": return .exit(0)
            case "-s":
                let size = context.readData(operand)?.count ?? 0
                return .exit(size > 0 ? 0 : 1)
            default:
                return .fail("test: unknown operator: \(args[0])", code: 2)
            }
        }
        if args.count == 3 {
            let left = args[0]
            let op = args[1]
            let right = args[2]
            switch op {
            case "=", "==": return .exit(left == right ? 0 : 1)
            case "!=": return .exit(left != right ? 0 : 1)
            case "-eq": return .exit((Int(left) ?? 0) == (Int(right) ?? 0) ? 0 : 1)
            case "-ne": return .exit((Int(left) ?? 0) != (Int(right) ?? 0) ? 0 : 1)
            case "-lt": return .exit((Int(left) ?? 0) < (Int(right) ?? 0) ? 0 : 1)
            case "-le": return .exit((Int(left) ?? 0) <= (Int(right) ?? 0) ? 0 : 1)
            case "-gt": return .exit((Int(left) ?? 0) > (Int(right) ?? 0) ? 0 : 1)
            case "-ge": return .exit((Int(left) ?? 0) >= (Int(right) ?? 0) ? 0 : 1)
            default:
                return .fail("test: unknown operator: \(op)", code: 2)
            }
        }
        return .fail("test: too many arguments", code: 2)
    }

    private static func test(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        evaluateTest(args, context)
    }

    private static func bracket(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        guard args.last == "]" else {
            return .fail("[: missing ']'", code: 2)
        }
        return evaluateTest(Array(args.dropLast()), context)
    }

    private static func expr(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        guard args.count == 3 else {
            return .fail("expr: usage: expr left op right", code: 2)
        }
        guard let left = Int(args[0]), let right = Int(args[2]) else {
            return .fail("expr: non-integer argument", code: 2)
        }
        switch args[1] {
        case "+": return .ok("\(left + right)")
        case "-": return .ok("\(left - right)")
        case "*": return .ok("\(left * right)")
        case "/":
            guard right != 0 else { return .fail("expr: division by zero", code: 2) }
            return .ok("\(left / right)")
        case "%":
            guard right != 0 else { return .fail("expr: division by zero", code: 2) }
            return .ok("\(left % right)")
        case "=": return .ok(left == right ? "1" : "0")
        case "!=": return .ok(left != right ? "1" : "0")
        case "<": return .ok(left < right ? "1" : "0")
        case ">": return .ok(left > right ? "1" : "0")
        default: return .fail("expr: unknown operator: \(args[1])", code: 2)
        }
    }

    private static func eval(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        context.evaluate(args.joined(separator: " "))
    }

    /// `sh script.sh [args]` and `sh -c 'command'`.
    private static func sh(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, valueFlags: ["c"])
        if let inline = parsed.value("c") {
            return context.evaluate(inline)
        }
        guard let path = parsed.operands.first else {
            return .fail("sh: usage: sh script [arguments]", code: 2)
        }
        guard let runner = context.runScript else {
            return .fail("sh: \(path): script execution is unavailable")
        }
        guard let body = context.readText(path) else {
            return .fail("sh: \(path): No such file or directory", code: 127)
        }
        return runner(body, path, Array(parsed.operands.dropFirst()), context.stdin)
    }

    private static func source(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        guard let path = args.first else {
            return .fail("source: usage: source script", code: 2)
        }
        guard let runner = context.runScript, let body = context.readText(path) else {
            return .fail("source: \(path): No such file or directory")
        }
        return runner(body, path, [], context.stdin)
    }

    private static func which(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        guard !parsed.operands.isEmpty else {
            return .fail("which: usage: which command", code: 2)
        }
        var output: [String] = []
        var missing = false
        for name in parsed.operands {
            if let resolved = context.commandResolver?(name) {
                output.append(resolved)
            } else {
                missing = true
            }
        }
        return ShellResult(output: output.joined(separator: "\n"), exitCode: missing ? 1 : 0, clearScreen: false)
    }

    private static func type(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        guard !parsed.operands.isEmpty else {
            return .fail("type: usage: type name", code: 2)
        }
        var output: [String] = []
        var missing = false
        for name in parsed.operands {
            if let builtin = ShellBuiltins.table[name] {
                output.append("\(name) is a shell built-in (\(builtin.summary))")
            } else if let resolved = context.commandResolver?(name) {
                output.append("\(name) is \(resolved)")
            } else {
                output.append("type: \(name): not found")
                missing = true
            }
        }
        return ShellResult(output: output.joined(separator: "\n"), exitCode: missing ? 1 : 0, clearScreen: false)
    }

    private static func command(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        if parsed.has("v") {
            guard let name = parsed.operands.first else {
                return .fail("command: usage: command -v name", code: 2)
            }
            if let builtin = ShellBuiltins.table[name] {
                return .ok(builtin.name)
            }
            if let resolved = context.commandResolver?(name) {
                return .ok(resolved)
            }
            return ShellResult(output: "", exitCode: 1, clearScreen: false)
        }
        guard !parsed.operands.isEmpty else {
            return .fail("command: usage: command name [arguments]", code: 2)
        }
        return context.evaluate(parsed.operands.joined(separator: " "))
    }

    private static func help(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        ShellResult.ok(ShellBuiltins.helpText())
    }

    private static func man(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        guard let name = args.first else {
            return .fail("What manual page do you want?", code: 2)
        }
        guard let builtin = ShellBuiltins.table[name] else {
            return .fail("No manual entry for \(name)")
        }
        return .ok("\(builtin.name) - \(builtin.summary)")
    }

    private static func version(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        .ok("Terminal-ios shell \(ShellBuiltins.shellVersion) - \(ShellBuiltins.table.count) built-ins, \(ShellBuiltins.packageCommandNames.count) catalog commands")
    }

    // MARK: - Package managers

    private static func apt(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        packageCommand(args, context, label: "apt", supportsSearch: true)
    }

    private static func apk(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let manager = context.packages()
        // Alpine spells the same operations `apk add` / `apk del` / `apk info`.
        if parsed.operands.first == "add" {
            return describe(manager.install(Array(parsed.operands.dropFirst())), prefix: "apk")
        }
        if parsed.operands.first == "del" {
            return describe(manager.remove(Array(parsed.operands.dropFirst())), prefix: "apk")
        }
        if parsed.operands.first == "info" {
            return describe(manager.list(pattern: parsed.operands.count > 1 ? parsed.operands[1] : nil), prefix: "apk")
        }
        return packageCommand(args, context, label: "apk", supportsSearch: true)
    }

    private static func pip(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        packageCommand(args, context, label: "pip", supportsSearch: true)
    }

    /// Shared `install` / `remove` / `list` / `search` / `show` / `update` UX.
    private static func packageCommand(
        _ args: [String],
        _ context: ShellRunContext,
        label: String,
        supportsSearch: Bool
    ) -> ShellResult {
        let manager = context.packages()
        let parsed = ShellArgs.parse(args)
        guard let subcommand = parsed.operands.first else {
            return .ok("""
            \(label): offline package manager
            usage: \(label) install|remove|list|search|show|update|sources [name ...]
            source: \(manager.catalog.name) (bundled, \(manager.catalog.entries.count) packages)
            """)
        }
        let rest = Array(parsed.operands.dropFirst())
        switch subcommand {
        case "install", "add", "get":
            return describe(manager.install(rest), prefix: label)
        case "remove", "rm", "uninstall", "delete", "del":
            return describe(manager.remove(rest), prefix: label)
        case "list", "ls":
            return describe(manager.list(pattern: rest.first), prefix: label)
        case "search":
            return supportsSearch
                ? describe(manager.search(rest), prefix: label)
                : .fail("\(label): search is not supported")
        case "show", "info":
            return describe(manager.info(rest), prefix: label)
        case "update":
            return describe(manager.update(), prefix: label)
        case "upgrade":
            return describe(manager.upgrade(), prefix: label)
        case "sources":
            return describe(manager.sources(), prefix: label)
        default:
            return .fail("\(label): unknown subcommand '\(subcommand)'", code: 2)
        }
    }

    private static func describe(_ outcome: PackageManager.Outcome, prefix: String) -> ShellResult {
        ShellResult(output: outcome.text, exitCode: outcome.exitCode, clearScreen: false)
    }

    // MARK: - Runtimes from the catalog

    /// Runs a bundled Python package if the catalog provides one, otherwise
    /// explains exactly what to install.
    private static func python(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let manager = context.packages()
        guard let entry = manager.catalog.entry(providing: "python3") else {
            return .fail("python3: no runtime in \(manager.catalog.name). Add a `python` entry to the catalog.")
        }
        guard entry.payload != nil else {
            return .fail("python3: \(entry.name) \(entry.version) is declared in the catalog, but its WASM payload is not bundled in this build yet.")
        }
        guard manager.isInstalled(entry.name) else {
            return .fail("python3: runtime \(entry.name) \(entry.version) is not installed. Run: apt install \(entry.name)")
        }
        return .fail("python3: \(entry.name) is installed, but the WASM runtime is not wired up yet.")
    }

    private static func toolchain(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let command = args.first ?? "cc"
        let manager = context.packages()
        guard let entry = manager.catalog.entry(providing: "gcc") ?? manager.catalog.entry(providing: command) else {
            return .fail("\(command): no toolchain in \(manager.catalog.name). MinGW builds are shipped as WASM payloads.")
        }
        guard entry.payload != nil else {
            return .fail("\(command): \(entry.name) \(entry.version) is declared in the catalog, but its WASM payload is not bundled in this build yet.")
        }
        guard manager.isInstalled(entry.name) else {
            return .fail("\(command): toolchain \(entry.name) \(entry.version) is not installed. Run: apt install \(entry.name)")
        }
        return .fail("\(command): \(entry.name) is installed, but the WASM runtime is not wired up yet.")
    }
}

extension ShellResult {
    /// A silent result with the given exit code - used by `test`, `[` and
    /// `read`, which communicate only through the exit status.
    static func exit(_ code: Int) -> ShellResult {
        ShellResult(output: "", exitCode: code, clearScreen: false)
    }
}
