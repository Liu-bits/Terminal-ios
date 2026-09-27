// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Raised when a module calls `proc_exit`. The runtime turns it into an exit
/// code instead of a trap.
struct WasmExitSignal: Error {
    var code: Int32
}

/// The WASI subset this shell provides.
///
/// Deliberately small: file descriptors, arguments, environment, a clock and
/// randomness. There is **no** `path_open`/socket/process surface, so a
/// downloaded module cannot read the user's files, open a connection or start a
/// process - the sandbox is the interpreter, not the OS.
final class WASIHost: WasmHost {

    /// Bytes the module wrote to stdout and stderr.
    private(set) var stdout: [UInt8] = []
    private(set) var stderr: [UInt8] = []
    private(set) var exitCode: Int32?

    var arguments: [String]
    var environment: [String: String]
    private var stdinQueue: [UInt8]
    private let started = Date()

    /// Calls the host cannot honour, reported via errno so libc can adapt.
    private enum Errno: Int32 {
        case success = 0
        case badFileDescriptor = 8
        case noEntry = 44
        case notSupported = 58
    }

    init(arguments: [String] = [], environment: [String: String] = [:], stdin: String = "") {
        self.arguments = arguments
        self.environment = environment
        self.stdinQueue = Array(stdin.utf8)
    }

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }

    func call(
        module: String,
        field: String,
        arguments: [WasmValue],
        instance: WasmInstance
    ) throws -> [WasmValue] {
        guard module == "wasi_snapshot_preview1" || module == "wasi_unstable" else {
            throw WasmTrap.unsupported("import \(module).\(field)")
        }
        let args = arguments.compactMap { $0.i32Value.map { Int($0) } }

        switch field {
        case "fd_write":
            return .single(try fdWrite(instance: instance, args: args))
        case "fd_read":
            return .single(try fdRead(instance: instance, args: args))
        case "fd_close", "fd_sync", "fd_datasync":
            return .single(Errno.success.rawValue)
        case "fd_seek":
            // Report the offset unchanged; libc only needs this to succeed.
            if args.count >= 4 {
                try? instance.writeMemory(at: args[3], bytes: [0, 0, 0, 0, 0, 0, 0, 0])
            }
            return .single(Errno.success.rawValue)
        case "fd_fdstat_get":
            // filetype 2 (character device) so libc treats it as a tty.
            if let pointer = args.dropFirst().first {
                try? instance.writeMemory(at: pointer, bytes: [2, 0, 0, 0, 0, 0, 0, 0])
            }
            return .single(Errno.success.rawValue)
        case "fd_prestat_get", "fd_prestat_dir_name", "path_open":
            // No preopened directories and no file access at all.
            return .single(Errno.badFileDescriptor.rawValue)
        case "environ_sizes_get":
            return .single(try sizesGet(instance: instance, args: args, items: environmentEntries.map(\.0)))
        case "environ_get":
            return .single(try entriesGet(instance: instance, args: args, items: environmentEntries))
        case "args_sizes_get":
            return .single(try sizesGet(instance: instance, args: args, items: self.arguments))
        case "args_get":
            return .single(try entriesGet(instance: instance, args: args, items: self.arguments.map { ($0, "") }))
        case "clock_res_get":
            if args.count >= 2 {
                try? instance.writeMemory(at: args[1], bytes: le64(1_000_000))
            }
            return .single(Errno.success.rawValue)
        case "clock_time_get":
            return .single(try clockTimeGet(instance: instance, args: args))
        case "random_get":
            return .single(try randomGet(instance: instance, args: args))
        case "proc_exit":
            let code = Int32(args.first ?? 0)
            exitCode = code
            throw WasmExitSignal(code: code)
        case "sched_yield", "poll_oneoff":
            return .single(Errno.notSupported.rawValue)
        default:
            throw WasmTrap.unsupported("WASI function \(field)")
        }
    }

    // MARK: - Implementations

    private func fdWrite(instance: WasmInstance, args: [Int]) throws -> Int32 {
        guard args.count >= 4 else {
            return Errno.badFileDescriptor.rawValue
        }
        let fileDescriptor = args[0]
        let iovecPointer = args[1]
        let iovecCount = args[2]
        let writtenPointer = args[3]
        guard fileDescriptor == 1 || fileDescriptor == 2 else {
            return Errno.badFileDescriptor.rawValue
        }
        var written = 0
        for index in 0..<iovecCount {
            let entry = iovecPointer + index * 8
            let pointer = Int(try readUInt32(instance: instance, at: entry))
            let length = Int(try readUInt32(instance: instance, at: entry + 4))
            let bytes = try instance.readMemory(at: pointer, count: length)
            if fileDescriptor == 1 {
                stdout.append(contentsOf: bytes)
            } else {
                stderr.append(contentsOf: bytes)
            }
            written += bytes.count
        }
        try instance.writeMemory(at: writtenPointer, bytes: le32(UInt32(truncatingIfNeeded: written)))
        return Errno.success.rawValue
    }

    private func fdRead(instance: WasmInstance, args: [Int]) throws -> Int32 {
        guard args.count >= 4 else {
            return Errno.badFileDescriptor.rawValue
        }
        let iovecPointer = args[1]
        let iovecCount = args[2]
        let readPointer = args[3]
        var total = 0
        for index in 0..<iovecCount {
            if stdinQueue.isEmpty { break }
            let entry = iovecPointer + index * 8
            let pointer = Int(try readUInt32(instance: instance, at: entry))
            let length = Int(try readUInt32(instance: instance, at: entry + 4))
            let take = min(length, stdinQueue.count)
            let chunk = Array(stdinQueue.prefix(take))
            stdinQueue.removeFirst(take)
            try instance.writeMemory(at: pointer, bytes: chunk)
            total += take
        }
        try instance.writeMemory(at: readPointer, bytes: le32(UInt32(truncatingIfNeeded: total)))
        return Errno.success.rawValue
    }

    private var environmentEntries: [(String, String)] {
        environment.sorted { $0.key < $1.key }.map { ("\($0.key)=\($0.value)", "") }
    }

    /// Writes the count and the total byte size of a string list.
    private func sizesGet(instance: WasmInstance, args: [Int], items: [String]) throws -> Int32 {
        guard args.count >= 2 else {
            return Errno.badFileDescriptor.rawValue
        }
        let totalBytes = items.reduce(0) { $0 + $1.utf8.count + 1 }
        try instance.writeMemory(at: args[0], bytes: le32(UInt32(items.count)))
        try instance.writeMemory(at: args[1], bytes: le32(UInt32(totalBytes)))
        return Errno.success.rawValue
    }

    /// Writes a pointer table plus the NUL-terminated strings themselves.
    private func entriesGet(
        instance: WasmInstance,
        args: [Int],
        items: [(String, String)]
    ) throws -> Int32 {
        guard args.count >= 2 else {
            return Errno.badFileDescriptor.rawValue
        }
        let pointerTable = args[0]
        var buffer = args[1]
        for (index, item) in items.enumerated() {
            let text = item.0 + item.1
            try instance.writeMemory(at: pointerTable + index * 4, bytes: le32(UInt32(buffer)))
            let bytes = Array(text.utf8) + [0]
            try instance.writeMemory(at: buffer, bytes: bytes)
            buffer += bytes.count
        }
        return Errno.success.rawValue
    }

    private func clockTimeGet(instance: WasmInstance, args: [Int]) throws -> Int32 {
        guard args.count >= 3 else {
            return Errno.badFileDescriptor.rawValue
        }
        let clockID = args[0]
        let pointer = args[2]
        let nanos: UInt64
        switch clockID {
        case 0:
            nanos = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        default:
            nanos = UInt64(Date().timeIntervalSince(started) * 1_000_000_000)
        }
        try instance.writeMemory(at: pointer, bytes: le64(nanos))
        return Errno.success.rawValue
    }

    private func randomGet(instance: WasmInstance, args: [Int]) throws -> Int32 {
        guard args.count >= 2 else {
            return Errno.badFileDescriptor.rawValue
        }
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<args[1]).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        try instance.writeMemory(at: args[0], bytes: bytes)
        return Errno.success.rawValue
    }

    private func readUInt32(instance: WasmInstance, at address: Int) throws -> UInt32 {
        let raw = try instance.readMemory(at: address, count: 4)
        return WasmInstructionDecoder.readUInt32(raw)
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private func le64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
    }
}

private extension Array where Element == WasmValue {
    /// WASI's single return value is an `errno`.
    static func single(_ errno: Int32) -> [WasmValue] {
        [.i32(errno)]
    }
}
