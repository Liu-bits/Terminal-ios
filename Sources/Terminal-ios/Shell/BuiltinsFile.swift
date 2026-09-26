// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// File-system commands: listing, reading, moving, metadata.
///
/// Everything resolves through `ShellRunContext.url(for:)`, so a command can
/// never touch anything outside the app sandbox.
enum FileBuiltins {

    static let all: [ShellBuiltin] = [
        ShellBuiltin("ls", "list directory contents", ls),
        ShellBuiltin("cat", "concatenate and print files", cat),
        ShellBuiltin("mkdir", "create directories", mkdir),
        ShellBuiltin("rmdir", "remove empty directories", rmdir),
        ShellBuiltin("rm", "remove files and directories", rm),
        ShellBuiltin("cp", "copy files and directories", cp),
        ShellBuiltin("mv", "move or rename files", mv),
        ShellBuiltin("touch", "create empty files or update timestamps", touch),
        ShellBuiltin("stat", "display file metadata", stat),
        ShellBuiltin("ln", "create links", ln),
        ShellBuiltin("basename", "strip directory from a path", basename),
        ShellBuiltin("dirname", "strip the last path component", dirname),
        ShellBuiltin("realpath", "print the resolved path", realpath),
        ShellBuiltin("find", "walk a tree looking for files", find),
        ShellBuiltin("tree", "print a directory tree", tree),
        ShellBuiltin("du", "estimate file space usage", du),
        ShellBuiltin("df", "report file-system space", df),
        ShellBuiltin("chmod", "change file mode bits", chmod),
        ShellBuiltin("file", "classify a file", file),
        ShellBuiltin("mktemp", "create a temporary file", mktemp)
    ]

    // MARK: - ls

    /// Permissions string such as `drwxr-xr-x`.
    private static func modeString(permissions: Int, isDirectory: Bool) -> String {
        let chars = Array("rwxrwxrwx")
        var out = isDirectory ? "d" : "-"
        for index in 0..<9 {
            let bit = (permissions >> (8 - index)) & 1
            out.append(bit == 1 ? chars[index] : "-")
        }
        return out
    }

    private static func humanSize(_ bytes: Int) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 {
            return "\(bytes)"
        }
        return String(format: "%.1f%@", value, units[unit])
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd HH:mm"
        return formatter.string(from: date)
    }

    private static func longLine(for url: URL, name: String) -> String {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let modes = modeString(permissions: permissions, isDirectory: isDir.boolValue)
        var sizeText = humanSize(size)
        if sizeText.count < 8 {
            sizeText = String(repeating: " ", count: 8 - sizeText.count) + sizeText
        }
        return "\(modes) \(sizeText) \(timestamp(modified)) \(name)"
    }

    private static func ls(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let showAll = parsed.has("a")
        let long = parsed.has("l")
        let directoriesOnly = parsed.has("d")
        let targets = parsed.operands.isEmpty ? ["~"] : parsed.operands
        var lines: [String] = []

        for target in targets {
            guard let url = context.url(for: target) else {
                return .fail("ls: \(target): No such file or directory")
            }
            var isDir: ObjCBool = false
            guard context.fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
                return .fail("ls: \(target): No such file or directory")
            }
            if isDir.boolValue && !directoriesOnly {
                var names = (try? context.fileManager.contentsOfDirectory(atPath: url.path)) ?? []
                if !showAll {
                    names = names.filter { !$0.hasPrefix(".") }
                }
                names.sort()
                if targets.count > 1 {
                    if !lines.isEmpty { lines.append("") }
                    lines.append("\(target):")
                }
                for name in names {
                    if long {
                        lines.append(longLine(for: url.appendingPathComponent(name), name: name))
                    } else {
                        lines.append(name)
                    }
                }
            } else if long {
                lines.append(longLine(for: url, name: url.lastPathComponent))
            } else {
                lines.append(url.lastPathComponent)
            }
        }
        return .ok(lines.joined(separator: "\n"))
    }

    // MARK: - cat

    private static func cat(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, valueFlags: [])
        let number = parsed.has("n")
        let files = parsed.operands
        let input = context.inputText(named: files, command: "cat")
        if let failure = input.failure {
            return failure
        }
        guard let text = input.text else {
            return .ok("")
        }
        guard number else {
            return .ok(text)
        }
        let lines = context.lines(text)
        let numbered = lines.enumerated().map { String(format: "%6d\t%@", $0.offset + 1, $0.element) }
        return .ok(numbered.joined(separator: "\n"))
    }

    // MARK: - Directory creation and removal

    private static func mkdir(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let parents = parsed.has("p")
        guard !parsed.operands.isEmpty else {
            return .fail("mkdir: missing operand")
        }
        for target in parsed.operands {
            guard let url = context.url(for: target) else {
                return .fail("mkdir: \(target): Permission denied")
            }
            if context.fileManager.fileExists(atPath: url.path) {
                if parents {
                    continue
                }
                return .fail("mkdir: \(target): File exists")
            }
            do {
                try context.fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: parents
                )
            } catch {
                return .fail("mkdir: \(target): \(parents ? "cannot create directory" : "No such file or directory")")
            }
        }
        return .ok()
    }

    private static func rmdir(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        guard !parsed.operands.isEmpty else {
            return .fail("rmdir: missing operand")
        }
        for target in parsed.operands {
            guard let url = context.url(for: target) else {
                return .fail("rmdir: \(target): Permission denied")
            }
            var isDir: ObjCBool = false
            guard context.fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return .fail("rmdir: \(target): Not a directory")
            }
            let contents = (try? context.fileManager.contentsOfDirectory(atPath: url.path)) ?? []
            guard contents.isEmpty else {
                return .fail("rmdir: \(target): Directory not empty")
            }
            do {
                try context.fileManager.removeItem(at: url)
            } catch {
                return .fail("rmdir: \(target): Operation not permitted")
            }
        }
        return .ok()
    }

    private static func rm(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let recursive = parsed.has("r") || parsed.has("R")
        let force = parsed.has("f")
        guard !parsed.operands.isEmpty else {
            return force ? .ok() : .fail("rm: missing operand")
        }
        for target in parsed.operands {
            guard let url = context.url(for: target) else {
                return .fail("rm: \(target): Permission denied")
            }
            var isDir: ObjCBool = false
            let exists = context.fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            guard exists else {
                if force { continue }
                return .fail("rm: \(target): No such file or directory")
            }
            if isDir.boolValue && !recursive {
                return .fail("rm: \(target): is a directory")
            }
            do {
                try context.fileManager.removeItem(at: url)
            } catch {
                return .fail("rm: \(target): Operation not permitted")
            }
        }
        return .ok()
    }

    // MARK: - Copy and move

    private static func cp(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let recursive = parsed.has("r") || parsed.has("R")
        let force = parsed.has("f")
        guard parsed.operands.count >= 2 else {
            return .fail("cp: missing destination file operand")
        }
        let sources = Array(parsed.operands.dropLast())
        let destination = parsed.operands[parsed.operands.count - 1]
        guard let destinationURL = context.url(for: destination) else {
            return .fail("cp: \(destination): Permission denied")
        }
        var isDir: ObjCBool = false
        let destinationIsDirectory = context.fileManager.fileExists(
            atPath: destinationURL.path, isDirectory: &isDir
        ) && isDir.boolValue
        if sources.count > 1 && !destinationIsDirectory {
            return .fail("cp: target \(destination) is not a directory")
        }
        for source in sources {
            guard let sourceURL = context.url(for: source) else {
                return .fail("cp: \(source): Permission denied")
            }
            var sourceIsDir: ObjCBool = false
            let exists = context.fileManager.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDir)
            guard exists else {
                return .fail("cp: \(source): No such file or directory")
            }
            if sourceIsDir.boolValue && !recursive {
                return .fail("cp: \(source): is a directory (use -r)")
            }
            let targetURL = destinationIsDirectory
                ? destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
                : destinationURL
            if context.fileManager.fileExists(atPath: targetURL.path), !force {
                return .fail("cp: \(targetURL.lastPathComponent): File exists")
            }
            if context.fileManager.fileExists(atPath: targetURL.path) {
                try? context.fileManager.removeItem(at: targetURL)
            }
            do {
                try context.fileManager.copyItem(at: sourceURL, to: targetURL)
            } catch {
                try? context.fileManager.createDirectory(
                    at: targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                do {
                    try context.fileManager.copyItem(at: sourceURL, to: targetURL)
                } catch {
                    return .fail("cp: \(source): cannot copy")
                }
            }
        }
        return .ok()
    }

    private static func mv(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        guard parsed.operands.count >= 2 else {
            return .fail("mv: missing destination file operand")
        }
        let sources = Array(parsed.operands.dropLast())
        let destination = parsed.operands[parsed.operands.count - 1]
        guard let destinationURL = context.url(for: destination) else {
            return .fail("mv: \(destination): Permission denied")
        }
        var isDir: ObjCBool = false
        let destinationIsDirectory = context.fileManager.fileExists(
            atPath: destinationURL.path, isDirectory: &isDir
        ) && isDir.boolValue
        if sources.count > 1 && !destinationIsDirectory {
            return .fail("mv: target \(destination) is not a directory")
        }
        for source in sources {
            guard let sourceURL = context.url(for: source) else {
                return .fail("mv: \(source): Permission denied")
            }
            guard context.fileManager.fileExists(atPath: sourceURL.path) else {
                return .fail("mv: \(source): No such file or directory")
            }
            let targetURL = destinationIsDirectory
                ? destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
                : destinationURL
            if context.fileManager.fileExists(atPath: targetURL.path) {
                try? context.fileManager.removeItem(at: targetURL)
            }
            do {
                try context.fileManager.moveItem(at: sourceURL, to: targetURL)
            } catch {
                return .fail("mv: \(source): cannot move")
            }
        }
        return .ok()
    }

    // MARK: - touch, stat, ln, chmod, file, mktemp

    private static func touch(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        guard !parsed.operands.isEmpty else {
            return .fail("touch: missing file operand")
        }
        for target in parsed.operands {
            guard let url = context.url(for: target) else {
                return .fail("touch: \(target): Permission denied")
            }
            if context.fileManager.fileExists(atPath: url.path) {
                try? context.fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                continue
            }
            do {
                try context.fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard context.fileManager.createFile(atPath: url.path, contents: Data()) else {
                    return .fail("touch: \(target): cannot create file")
                }
            } catch {
                return .fail("touch: \(target): No such file or directory")
            }
        }
        return .ok()
    }

    private static func stat(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        guard !parsed.operands.isEmpty else {
            return .fail("stat: missing operand")
        }
        var blocks: [String] = []
        for target in parsed.operands {
            guard let url = context.url(for: target),
                  context.fileManager.fileExists(atPath: url.path) else {
                return .fail("stat: \(target): No such file or directory")
            }
            let attributes = (try? context.fileManager.attributesOfItem(atPath: url.path)) ?? [:]
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            var isDir: ObjCBool = false
            _ = context.fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let modified = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let formatter = ISO8601DateFormatter()
            blocks.append(
                """
                  File: \(context.environment.displayPath(url))
                  Size: \(size)\tType: \(isDir.boolValue ? "directory" : "regular file")
                Access: (\(String(modeString(permissions: permissions, isDirectory: isDir.boolValue).dropFirst())))\tMode: \(String(permissions, radix: 8))
                Modify: \(formatter.string(from: modified))
                """
            )
        }
        return .ok(blocks.joined(separator: "\n"))
    }

    private static func ln(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let symbolic = parsed.has("s")
        guard parsed.operands.count >= 2 else {
            return .fail("ln: missing destination file operand")
        }
        let source = parsed.operands[0]
        let destination = parsed.operands[1]
        guard let sourceURL = context.url(for: source),
              let destinationURL = context.url(for: destination) else {
            return .fail("ln: \(destination): Permission denied")
        }
        if context.fileManager.fileExists(atPath: destinationURL.path) {
            return .fail("ln: \(destination): File exists")
        }
        do {
            if symbolic {
                try context.fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: sourceURL)
            } else {
                try context.fileManager.linkItem(at: sourceURL, to: destinationURL)
            }
        } catch {
            return .fail("ln: \(source): cannot create link")
        }
        return .ok()
    }

    private static func chmod(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, stopAtFirstOperand: true)
        guard parsed.operands.count >= 2 else {
            return .fail("chmod: missing operand")
        }
        let modeText = parsed.operands[0]
        let targets = Array(parsed.operands.dropFirst())

        // Octal mode (`755`) applies to every target the same way.
        let octal: Int?
        if (modeText.count == 3 || modeText.count == 4), let value = Int(modeText, radix: 8) {
            octal = value & 0o7777
        } else if modeText.hasPrefix("+") || modeText.hasPrefix("-") {
            octal = nil
        } else {
            return .fail("chmod: invalid mode: '\(modeText)'")
        }

        /// Symbolic mode (`+x`, `-w`, `+rx`) applied on top of the current bits.
        func symbolicMask(_ text: String) -> (adding: Bool, mask: Int)? {
            guard let sign = text.first, sign == "+" || sign == "-" else {
                return nil
            }
            var mask = 0
            for char in text.dropFirst() {
                switch char {
                case "x", "X": mask |= 0o111
                case "r": mask |= 0o444
                case "w": mask |= 0o222
                default: break
                }
            }
            return (sign == "+", mask)
        }

        for target in targets {
            guard let url = context.url(for: target),
                  context.fileManager.fileExists(atPath: url.path) else {
                return .fail("chmod: \(target): No such file or directory")
            }
            let attributes = (try? context.fileManager.attributesOfItem(atPath: url.path)) ?? [:]
            let current = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let updated: Int
            if let octal {
                updated = octal
            } else if let change = symbolicMask(modeText) {
                updated = change.adding ? current | change.mask : current & ~change.mask
            } else {
                return .fail("chmod: invalid mode: '\(modeText)'")
            }
            do {
                try context.fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: updated)], ofItemAtPath: url.path
                )
            } catch {
                return .fail("chmod: \(target): Operation not permitted")
            }
        }
        return .ok()
    }

    private static func file(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        guard !parsed.operands.isEmpty else {
            return .fail("file: missing operand")
        }
        var lines: [String] = []
        for target in parsed.operands {
            guard let url = context.url(for: target),
                  context.fileManager.fileExists(atPath: url.path) else {
                lines.append("\(target): cannot open (No such file or directory)")
                continue
            }
            var isDir: ObjCBool = false
            _ = context.fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                lines.append("\(target): directory")
            } else if let data = try? Data(contentsOf: url) {
                let isText = String(data: data, encoding: .utf8) != nil
                let attributes = (try? context.fileManager.attributesOfItem(atPath: url.path)) ?? [:]
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                lines.append("\(target): \(isText ? "UTF-8 text" : "data"), \(size) bytes")
            } else {
                lines.append("\(target): cannot open")
            }
        }
        return .ok(lines.joined(separator: "\n"))
    }

    private static func mktemp(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let name = "tmp.\(UUID().uuidString.prefix(8))"
        guard let url = context.url(for: name) else {
            return .fail("mktemp: cannot create temporary file")
        }
        guard context.fileManager.createFile(atPath: url.path, contents: Data()) else {
            return .fail("mktemp: cannot create temporary file")
        }
        return .ok(context.environment.displayPath(url))
    }

    // MARK: - Path helpers

    private static func basename(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        guard let target = parsed.operands.first else {
            return .fail("basename: missing operand")
        }
        let name = ShellRunContext.baseName(target)
        if parsed.operands.count > 1 {
            let suffix = parsed.operands[1]
            if !suffix.isEmpty, name.hasSuffix(suffix) {
                return .ok(String(name.dropLast(suffix.count)))
            }
        }
        return .ok(name)
    }

    private static func dirname(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        guard let target = parsed.operands.first else {
            return .fail("dirname: missing operand")
        }
        var components = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.count == 1 {
            return .ok(".")
        }
        components.removeLast()
        let joined = components.joined(separator: "/")
        return .ok(joined.isEmpty ? "/" : joined)
    }

    private static func realpath(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        guard !parsed.operands.isEmpty else {
            return .fail("realpath: missing operand")
        }
        var lines: [String] = []
        for target in parsed.operands {
            guard let url = context.url(for: target) else {
                return .fail("realpath: \(target): Permission denied")
            }
            lines.append(context.environment.displayPath(url.resolvingSymlinksInPath()))
        }
        return .ok(lines.joined(separator: "\n"))
    }

    // MARK: - find, tree, du, df

    private struct WalkOptions {
        var name: String? = nil
        var type: Character? = nil
        var maxDepth: Int? = nil
    }

    private static func walk(
        _ root: URL,
        display: String,
        depth: Int,
        options: WalkOptions,
        visit: (URL, String, Int) -> Bool
    ) {
        if let maxDepth = options.maxDepth, depth > maxDepth {
            return
        }
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return
        }
        for name in children.sorted() {
            let child = root.appendingPathComponent(name)
            let childDisplay = display == "/" ? "/\(name)" : "\(display)/\(name)"
            guard visit(child, childDisplay, depth) else {
                continue
            }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                walk(child, display: childDisplay, depth: depth + 1, options: options, visit: visit)
            }
        }
    }

    private static func matches(_ url: URL, display: String, options: WalkOptions, isDirectory: Bool) -> Bool {
        if let name = options.name {
            if !name.contains("*") {
                if url.lastPathComponent != name { return false }
            } else {
                let pattern = name.replacingOccurrences(of: ".", with: "\\.")
                    .replacingOccurrences(of: "*", with: ".*")
                if display.range(of: "^\(pattern)$", options: .regularExpression) == nil { return false }
            }
        }
        if let type = options.type {
            switch type {
            case "f": if isDirectory { return false }
            case "d": if !isDirectory { return false }
            default: break
            }
        }
        return true
    }

    private static func find(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        var start = "."
        var options = WalkOptions()
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            switch arg {
            case "-name":
                if index < args.count {
                    options.name = args[index]
                    index += 1
                }
            case "-type":
                if index < args.count {
                    options.type = args[index].first
                    index += 1
                }
            case "-maxdepth":
                if index < args.count {
                    options.maxDepth = Int(args[index])
                    index += 1
                }
            default:
                if !arg.hasPrefix("-") {
                    start = arg
                }
            }
        }
        guard let root = context.url(for: start) else {
            return .fail("find: \(start): Permission denied")
        }
        guard context.fileManager.fileExists(atPath: root.path) else {
            return .fail("find: \(start): No such file or directory")
        }
        var results: [String] = []
        var isDir: ObjCBool = false
        _ = context.fileManager.fileExists(atPath: root.path, isDirectory: &isDir)
        let rootDisplay = context.environment.displayPath(root)
        if matches(root, display: rootDisplay, options: options, isDirectory: isDir.boolValue) {
            results.append(rootDisplay)
        }
        walk(root, display: rootDisplay, depth: 1, options: options) { url, display, depth in
            var childIsDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &childIsDir)
            if let maxDepth = options.maxDepth, depth > maxDepth {
                return false
            }
            if matches(url, display: display, options: options, isDirectory: childIsDir.boolValue) {
                results.append(display)
            }
            return true
        }
        return .ok(results.joined(separator: "\n"))
    }

    private static func tree(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args, valueFlags: ["L"])
        let start = parsed.operands.first ?? "."
        let maxDepth = parsed.value("L").flatMap { Int($0) } ?? 3
        guard let root = context.url(for: start),
              context.isDirectory(start) else {
            return .fail("tree: \(start): No such directory")
        }
        var lines = [context.environment.displayPath(root)]
        var files = 0
        var directories = 0
        walk(root, display: "", depth: 1, options: WalkOptions(maxDepth: maxDepth)) { url, display, depth in
            guard Int(depth) <= maxDepth else { return false }
            let name = url.lastPathComponent
            lines.append(String(repeating: "  ", count: depth) + name)
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                directories += 1
            } else {
                files += 1
            }
            return true
        }
        lines.append("")
        lines.append("\(directories) directories, \(files) files")
        return .ok(lines.joined(separator: "\n"))
    }

    private static func du(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let parsed = ShellArgs.parse(args)
        let targets = parsed.operands.isEmpty ? ["."] : parsed.operands
        var lines: [String] = []
        for target in targets {
            guard let url = context.url(for: target),
                  context.fileManager.fileExists(atPath: url.path) else {
                return .fail("du: \(target): No such file or directory")
            }
            let total = directorySize(url)
            lines.append("\(total / 1024)\t\(target)")
        }
        return .ok(lines.joined(separator: "\n"))
    }

    private static func directorySize(_ url: URL) -> Int {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return 0
        }
        if !isDir.boolValue {
            let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            return (attributes[.size] as? NSNumber)?.intValue ?? 0
        }
        var total = 0
        let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for name in children {
            total += directorySize(url.appendingPathComponent(name))
        }
        return total
    }

    private static func df(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let values = try? context.environment.root.resourceValues(forKeys: keys)
        let total = (values?.volumeTotalCapacity ?? 0) / 1024
        let available = (values?.volumeAvailableCapacity ?? 0) / 1024
        let used = max(0, total - available)
        return .ok(
            """
            Filesystem     1K-blocks      Used Available Use% Mounted on
            sandbox        \(total)  \(used)  \(available)  \(total == 0 ? 0 : used * 100 / total)% /
            """
        )
    }
}
