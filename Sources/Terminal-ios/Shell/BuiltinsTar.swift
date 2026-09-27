// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// A `tar` archive in ustar form.
///
/// The model is separate from the command so creation, listing and extraction
/// can each be tested on their own, and so `support/validate_archives.py` can
/// cross-check the bytes against Python's `tarfile` module - the same "validate
/// against a real implementation" rule the wasm fixtures follow with Node.
enum TarArchive {

    /// One member.
    struct Entry {
        var name: String
        var mode: Int
        var modificationTime: Int
        var kind: Kind
        var linkTarget: String
        var data: Data

        enum Kind: Character {
            case file = "0"
            case directory = "5"
            case symlink = "2"
        }
    }

    static let blockSize = 512

    enum TarError: Error, CustomStringConvertible {
        case badChecksum(name: String)
        case unsupportedFormat
        case truncated(name: String)

        var description: String {
            switch self {
            case .badChecksum(let name):
                return "tar: \(name): bad header checksum"
            case .unsupportedFormat:
                return "tar: not a ustar archive (GNU and PAX extensions are not supported)"
            case .truncated(let name):
                return "tar: \(name): truncated data"
            }
        }
    }

    // MARK: - Reading

    /// Parses an archive.
    ///
    /// The bytes are copied into an array first: indexing a `Data` slice on this
    /// toolchain was not reliable, and an array keeps every offset honest.
    static func parse(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        var entries: [Entry] = []
        var offset = 0
        while offset + blockSize <= bytes.count {
            let header = Array(bytes[offset..<(offset + blockSize)])
            if header.allSatisfy({ $0 == 0 }) {
                // Two zero blocks end the archive.
                break
            }
            let name = string(header, 0, 100)
            guard let mode = octal(header, 100, 8),
                  let size = octal(header, 124, 12),
                  let mtime = octal(header, 136, 12),
                  let checksum = octal(header, 148, 8) else {
                throw TarError.unsupportedFormat
            }
            guard string(header, 257, 6) == "ustar" else {
                throw TarError.unsupportedFormat
            }
            let prefix = string(header, 345, 155)
            let fullName = prefix.isEmpty ? name : prefix + "/" + name

            // The checksum is taken with the checksum field read as spaces, so
            // verification has to blank it out first.
            var verifying = header
            for index in 148..<156 where index < verifying.count {
                verifying[index] = 0x20
            }
            guard checksum == Self.checksum(verifying) else {
                throw TarError.badChecksum(name: fullName)
            }

            let contentStart = offset + blockSize
            guard size >= 0, contentStart + size <= bytes.count else {
                throw TarError.truncated(name: fullName)
            }
            let typeFlag = header[156]
            let payload: [UInt8] = typeFlag == 0x30
                ? Array(bytes[contentStart..<(contentStart + size)])
                : []
            offset = contentStart + padded(size)

            entries.append(
                Entry(
                    name: fullName,
                    mode: mode,
                    modificationTime: mtime,
                    kind: Entry.Kind(rawValue: Character(UnicodeScalar(typeFlag))) ?? .file,
                    linkTarget: string(header, 157, 100),
                    data: Data(payload)
                )
            )
        }
        return entries
    }

    // MARK: - Writing

    static func serialize(_ entries: [Entry]) -> Data {
        var output = Data()
        for entry in entries {
            output.append(header(for: entry))
            if entry.kind == .file {
                output.append(entry.data)
                output.append(Data(repeating: 0, count: padding(for: entry.data.count)))
            }
        }
        output.append(Data(repeating: 0, count: blockSize * 2))
        return output
    }

    private static func header(for entry: Entry) -> Data {
        let (name, prefix) = splitName(entry.name)
        var block = Data(repeating: 0, count: blockSize)
        write(&block, name, at: 0, length: 100)
        write(&block, octalText(entry.mode, width: 7), at: 100, length: 8)
        write(&block, octalText(0, width: 7), at: 108, length: 8)
        write(&block, octalText(0, width: 7), at: 116, length: 8)
        write(&block, octalText(entry.kind == .file ? entry.data.count : 0, width: 11), at: 124, length: 12)
        write(&block, octalText(entry.modificationTime, width: 11), at: 136, length: 12)
        // The checksum field is spaces while the sum is taken.
        write(&block, String(repeating: " ", count: 8), at: 148, length: 8)
        write(&block, String(entry.kind.rawValue), at: 156, length: 1)
        write(&block, entry.linkTarget, at: 157, length: 100)
        write(&block, "ustar", at: 257, length: 6)
        write(&block, "00", at: 263, length: 2)
        write(&block, "user", at: 265, length: 32)
        write(&block, "user", at: 297, length: 32)
        write(&block, prefix, at: 345, length: 155)
        // The checksum is over the header with the checksum field held as spaces
        // (already written above), which is why the field is filled in only now.
        write(&block, String(format: "%06o", checksum([UInt8](block))) + "\0 ", at: 148, length: 8)
        return block
    }

    /// ustar's way of storing a path longer than 100 bytes.
    private static func splitName(_ path: String) -> (name: String, prefix: String) {
        if path.utf8.count <= 100 {
            return (path, "")
        }
        var cut: String.Index?
        var index = path.startIndex
        while index < path.endIndex {
            if path[index...].utf8.count <= 100 {
                cut = index
                break
            }
            index = path.index(after: index)
        }
        guard let boundary = cut, boundary > path.startIndex else {
            return (String(path.suffix(100)), "")
        }
        return (String(path[boundary...]), String(path[path.startIndex..<path.index(before: boundary)]))
    }

    // MARK: - Field helpers

    private static func padded(_ size: Int) -> Int {
        (size + blockSize - 1) / blockSize * blockSize
    }

    private static func padding(for size: Int) -> Int {
        padded(size) - size
    }

    private static func checksum(_ block: [UInt8]) -> Int {
        block.reduce(0) { $0 + Int($1) }
    }

    private static func string(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String {
        var result: [UInt8] = []
        var index = 0
        while index < length, offset + index < bytes.count, bytes[offset + index] != 0 {
            result.append(bytes[offset + index])
            index += 1
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func octal(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> Int? {
        let text = string(bytes, offset, length).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? 0 : Int(text, radix: 8)
    }

    private static func octalText(_ value: Int, width: Int) -> String {
        String(format: "%0*o", width, max(0, value))
    }

    private static func write(_ block: inout Data, _ text: String, at offset: Int, length: Int) {
        let bytes = Array(text.utf8.prefix(length))
        for index in 0..<bytes.count {
            block[offset + index] = bytes[index]
        }
    }
}

/// `tar` - `cf`, `tf` and `xf`.
///
/// Deliberately ustar-only: no GNU long names, no PAX headers, no compression
/// inside the archive (`z`/`j` are refused with a message, since `gzip` is its
/// own command).
enum TarBuiltin {

    static let all: [ShellBuiltin] = [
        ShellBuiltin("tar", "tar cf/tf/xf: create, list and extract archives") { args, context in
            run(args, context)
        }
    ]

    private static let usage = """
    tar: create, list and extract ustar archives
    usage:
      tar cf <archive.tar> [path ...]        (-v lists each member)
      tar tf <archive.tar>                   (-v adds sizes)
      tar xf <archive.tar> [-C directory]
    """

    private static func run(_ args: [String], _ context: ShellRunContext) -> ShellResult {
        var flags = ""
        var rest: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg == "-C", index < args.count {
                // -C takes a value; keep the pair together so the scan stays simple.
                rest.append("-C")
                rest.append(args[index])
                index += 1
                continue
            }
            if arg.hasPrefix("-") {
                flags += String(arg.dropFirst())
                continue
            }
            if flags.isEmpty, !arg.isEmpty, arg.allSatisfy({ "cftvxzj".contains($0) }) {
                // `tar cf out.tar dir` without the dash is how people type it.
                flags += arg
                continue
            }
            rest.append(arg)
        }

        guard let operation = flags.first(where: { "ctx".contains($0) }) else {
            return .ok(usage)
        }
        if flags.contains("z") || flags.contains("j") {
            return .fail("tar: -z/-j are not supported; pipe through gzip instead:\n  tar cf - dir | gzip > dir.tar.gz", code: 2)
        }
        guard let archiveName = rest.first else {
            return .fail("tar: no archive given\n\n\(usage)", code: 2)
        }

        switch operation {
        case "c":
            return create(archiveName, paths: Array(rest.dropFirst()), verbose: flags.contains("v"), context)
        case "t":
            return list(archiveName, verbose: flags.contains("v"), context)
        case "x":
            // `-C` and its value were kept adjacent in `rest`.
            let target = rest.enumerated().first { $0.element == "-C" }.map { rest[$0.offset + 1] }
            return extract(archiveName, into: target, verbose: flags.contains("v"), context)
        default:
            return .ok(usage)
        }
    }

    // MARK: - Create

    private static func create(
        _ archiveName: String,
        paths: [String],
        verbose: Bool,
        _ context: ShellRunContext
    ) -> ShellResult {
        let targets = paths.isEmpty ? ["."] : paths
        var entries: [TarArchive.Entry] = []
        for path in targets {
            guard let root = context.url(for: path) else {
                return .fail("tar: \(path): outside the sandbox")
            }
            guard let collected = collect(root, display: display(root, environment: context.environment), context: context) else {
                return .fail("tar: \(path): No such file or directory")
            }
            entries.append(contentsOf: collected)
        }
        guard context.writeData(TarArchive.serialize(entries), to: archiveName) else {
            return .fail("tar: \(archiveName): cannot write")
        }
        let lines = verbose
            ? entries.map { "\($0.kind == .directory ? "d" : "-") \($0.data.count)\t\($0.name)" }
            : []
        return .ok(lines.joined(separator: "\n"))
    }

    /// The name a member gets: relative to the sandbox root, the way `tar` stores
    /// names. Storing `~`-prefixed paths would create a literal `~` directory on
    /// extraction.
    private static func display(_ url: URL, environment: ShellEnvironment) -> String {
        let root = environment.root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == root {
            return "."
        }
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }

    /// Walks one path, directories first so extraction can create them.
    private static func collect(
        _ url: URL,
        display: String,
        context: ShellRunContext
    ) -> [TarArchive.Entry]? {
        var isDirectory: ObjCBool = false
        guard context.fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        let attributes = (try? context.fileManager.attributesOfItem(atPath: url.path)) ?? [:]
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? (isDirectory.boolValue ? 0o755 : 0o644)
        let mtime = Int((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let name = isDirectory.boolValue && !display.hasSuffix("/") ? display + "/" : display
        var entries: [TarArchive.Entry] = []

        if isDirectory.boolValue {
            entries.append(
                TarArchive.Entry(name: name, mode: mode, modificationTime: mtime, kind: .directory, linkTarget: "", data: Data())
            )
            let children = (try? context.fileManager.contentsOfDirectory(atPath: url.path)) ?? []
            for child in children.sorted() {
                let childDisplay = display == "." ? child : display + "/" + child
                if let nested = collect(url.appendingPathComponent(child), display: childDisplay, context: context) {
                    entries.append(contentsOf: nested)
                }
            }
            return entries
        }

        if let type = attributes[.type] as? FileAttributeType, type == .typeSymbolicLink {
            let target = (try? context.fileManager.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            entries.append(
                TarArchive.Entry(name: name, mode: mode, modificationTime: mtime, kind: .symlink, linkTarget: target, data: Data())
            )
            return entries
        }
        let data = context.readData(display) ?? context.readData(url.path) ?? Data()
        entries.append(
            TarArchive.Entry(name: name, mode: mode, modificationTime: mtime, kind: .file, linkTarget: "", data: data)
        )
        return entries
    }

    // MARK: - List

    private static func list(_ archiveName: String, verbose: Bool, _ context: ShellRunContext) -> ShellResult {
        guard let data = context.readData(archiveName) else {
            return .fail("tar: \(archiveName): No such file or directory")
        }
        do {
            let entries = try TarArchive.parse(data)
            let lines = entries.map { entry in
                verbose
                    ? "\(entry.kind == .directory ? "d" : "-") \(entry.data.count)\t\(entry.name)"
                    : entry.name
            }
            return .ok(lines.joined(separator: "\n"))
        } catch let error as TarArchive.TarError {
            return .fail(String(describing: error))
        } catch {
            return .fail("tar: \(error)")
        }
    }

    // MARK: - Extract

    private static func extract(
        _ archiveName: String,
        into directory: String?,
        verbose: Bool,
        _ context: ShellRunContext
    ) -> ShellResult {
        guard let data = context.readData(archiveName) else {
            return .fail("tar: \(archiveName): No such file or directory")
        }
        let base: URL
        if let directory {
            guard let resolved = context.url(for: directory) else {
                return .fail("tar: -C \(directory): outside the sandbox")
            }
            base = resolved
        } else {
            base = context.environment.currentDirectory
        }
        let entries: [TarArchive.Entry]
        do {
            entries = try TarArchive.parse(data)
        } catch let error as TarArchive.TarError {
            return .fail(String(describing: error))
        } catch {
            return .fail("tar: \(error)")
        }

        var written: [String] = []
        for entry in entries {
            // An archive is input, and input must not write where it likes:
            // `..`, absolute paths and symlink escapes all stop here.
            guard let url = resolve(entry.name, inside: base, environment: context.environment) else {
                return .fail("tar: \(entry.name): refuses to extract outside the target directory")
            }
            do {
                switch entry.kind {
                case .directory:
                    try context.fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                    try context.fileManager.setAttributes(
                        [.posixPermissions: NSNumber(value: max(0o700, entry.mode))], ofItemAtPath: url.path
                    )
                case .symlink:
                    if context.fileManager.fileExists(atPath: url.path) {
                        try context.fileManager.removeItem(at: url)
                    }
                    try context.fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: entry.linkTarget)
                case .file:
                    try context.fileManager.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try entry.data.write(to: url)
                    try context.fileManager.setAttributes(
                        [.posixPermissions: NSNumber(value: max(0o600, entry.mode))], ofItemAtPath: url.path
                    )
                }
                written.append(entry.name)
            } catch {
                return .fail("tar: \(entry.name): \(error.localizedDescription)")
            }
        }
        return .ok(verbose ? written.joined(separator: "\n") : "")
    }

    /// Resolves a member name against the target directory, refusing anything
    /// that would step outside it (or outside the sandbox).
    private static func resolve(_ name: String, inside base: URL, environment: ShellEnvironment) -> URL? {
        let trimmed = name.hasPrefix("/") ? String(name.dropFirst()) : name
        let url = base.appendingPathComponent(trimmed)
        let canonical = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        let rootPath = environment.root.standardizedFileURL.path
        guard canonical == basePath || canonical.hasPrefix(basePath + "/") else {
            return nil
        }
        guard canonical == rootPath || canonical.hasPrefix(rootPath + "/") else {
            return nil
        }
        return url
    }
}
