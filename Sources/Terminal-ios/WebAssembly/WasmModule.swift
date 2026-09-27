// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// WebAssembly value types (the MVP set plus the reference types we support).
enum WasmValueType: UInt8, Equatable {
    case i32 = 0x7F
    case i64 = 0x7E
    case f32 = 0x7D
    case f64 = 0x7C
    case funcref = 0x70
    case externref = 0x6F

    var description: String {
        switch self {
        case .i32: return "i32"
        case .i64: return "i64"
        case .f32: return "f32"
        case .f64: return "f64"
        case .funcref: return "funcref"
        case .externref: return "externref"
        }
    }
}

/// A runtime value. Floats keep their bit pattern for NaN-perfect stores.
enum WasmValue: Equatable {
    case i32(Int32)
    case i64(Int64)
    case f32(Float)
    case f64(Double)
    case funcref(Int?)      // function index, or nil for null
    case externref(Int?)    // opaque host reference

    var i32Value: Int32? {
        if case .i32(let value) = self { return value }
        return nil
    }

    var i64Value: Int64? {
        switch self {
        case .i64(let value): return value
        case .i32(let value): return Int64(value)
        default: return nil
        }
    }

    var description: String {
        switch self {
        case .i32(let value): return "\(value)"
        case .i64(let value): return "\(value)"
        case .f32(let value): return "\(value)"
        case .f64(let value): return "\(value)"
        case .funcref(let index): return index.map { "funcref(\($0))" } ?? "funcref(null)"
        case .externref(let index): return index.map { "externref(\($0))" } ?? "externref(null)"
        }
    }
}

/// Function signature.
struct WasmFuncType: Equatable {
    var parameters: [WasmValueType]
    var results: [WasmValueType]
}

/// A block signature: empty, single value type, or an explicit type index.
enum WasmBlockType: Equatable {
    case empty
    case value(WasmValueType)
    case indexed(UInt32)

    /// Resolves to a function type using the module's type section.
    func resolve(_ types: [WasmFuncType]) -> WasmFuncType {
        switch self {
        case .empty: return WasmFuncType(parameters: [], results: [])
        case .value(let type): return WasmFuncType(parameters: [], results: [type])
        case .indexed(let index):
            return index < types.count ? types[Int(index)] : WasmFuncType(parameters: [], results: [])
        }
    }
}

struct WasmLimits: Equatable {
    var minimum: UInt32
    var maximum: UInt32?
}

struct WasmGlobal: Equatable {
    var type: WasmValueType
    var mutable: Bool
    /// Evaluated at instantiation from the init expression.
    var initialValue: WasmValue

    static func == (lhs: WasmGlobal, rhs: WasmGlobal) -> Bool {
        lhs.type == rhs.type && lhs.mutable == rhs.mutable
    }
}

/// One decoded instruction with its position inside the body.
struct WasmInstruction: Equatable {

    enum Code: Equatable {
        case unreachable
        case nop
        case block(WasmBlockType)
        case loop(WasmBlockType)
        case if_(WasmBlockType)
        case else_
        case end
        case br(UInt32)
        case brIf(UInt32)
        case brTable(labels: [UInt32], fallback: UInt32)
        case return_
        case call(UInt32)
        case callIndirect(typeIndex: UInt32, tableIndex: UInt32)
        case drop
        case select
        case localGet(UInt32)
        case localSet(UInt32)
        case localTee(UInt32)
        case globalGet(UInt32)
        case globalSet(UInt32)
        case load(opcode: UInt8, offset: UInt32)
        case store(opcode: UInt8, offset: UInt32)
        case memorySize
        case memoryGrow
        case constI32(Int32)
        case constI64(Int64)
        case constF32(UInt32)
        case constF64(UInt64)
        case refNull(WasmValueType)
        case refFunc(UInt32)
        case refIsNull
        case numeric(UInt8)
        case memoryCopy
        case memoryFill
    }

    var code: Code
    /// Index of this instruction in the decoded body.
    var index: Int
    /// Byte offset in the function body (for diagnostics).
    var offset: Int
    /// For `if_`: the matching `else_` (if any) and `end`.
    var elseIndex: Int?
    var endIndex: Int?
}

/// A function as it exists in the module: type index plus decoded body.
struct WasmFunction {
    var typeIndex: UInt32
    var locals: [WasmValueType]
    var instructions: [WasmInstruction]
    /// Imported functions have no body.
    var isImported: Bool
    /// Index into the index space after imports (set while parsing).
    var index: Int
}

struct WasmImport {
    var module: String
    var field: String
    var kind: UInt8          // 0 func, 1 table, 2 memory, 3 global
    var typeIndex: UInt32
}

struct WasmExport {
    var name: String
    var kind: UInt8          // 0 func, 1 table, 2 memory, 3 global
    var index: UInt32
}

struct WasmDataSegment {
    var memoryIndex: UInt32
    var offset: UInt32
    var bytes: [UInt8]
}

struct WasmElementSegment {
    var tableIndex: UInt32
    var offset: UInt32
    var functionIndices: [UInt32]
}

/// A parsed WebAssembly module.
///
/// Only the parts that can actually run are kept: the MVP instruction set, one
/// memory, one table, globals and data segments. Anything unsupported fails at
/// parse time with a message naming the feature, so a downloaded module can
/// never half-load.
struct WasmModule {

    var types: [WasmFuncType] = []
    var imports: [WasmImport] = []
    var functions: [WasmFunction] = []
    var globals: [WasmGlobal] = []
    var exports: [WasmExport] = []
    var dataSegments: [WasmDataSegment] = []
    var elementSegments: [WasmElementSegment] = []
    var memoryLimits: WasmLimits?
    var tableLimits: WasmLimits?
    var startFunction: UInt32?
    var importedFunctionCount: Int = 0
    var importedGlobalValues: [WasmValue] = []

    var exportNames: [String] { exports.map(\.name) }

    func export(named name: String) -> WasmExport? {
        exports.first { $0.name == name }
    }

    var memoryPageCount: Int { Int(memoryLimits?.minimum ?? 0) }

    // MARK: - Parsing

    static let magic: [UInt8] = [0x00, 0x61, 0x73, 0x6D]
    static let version: [UInt8] = [0x01, 0x00, 0x00, 0x00]

    /// Parses module bytes. Throws `WasmTrap` with a readable reason.
    static func parse(_ bytes: [UInt8]) throws -> WasmModule {
        var reader = WasmReader(bytes: bytes)
        guard bytes.count >= 8 else {
            throw WasmTrap.malformed("module is only \(bytes.count) bytes")
        }
        guard try reader.readBytes(4) == magic else {
            throw WasmTrap.malformed("bad magic number (not a wasm module)")
        }
        let versionBytes = try reader.readBytes(4)
        guard versionBytes == version else {
            throw WasmTrap.malformed("unsupported wasm version \(versionBytes.map { String(format: "%02x", $0) }.joined())")
        }

        var module = WasmModule()
        var definedTypes: [UInt32] = []

        while !reader.isAtEnd {
            let id = try reader.readByte()
            let size = try reader.readVarUInt32()
            let sectionEnd = reader.offset + Int(size)
            guard sectionEnd <= bytes.count else {
                throw WasmTrap.malformed("section \(id) overruns the module")
            }
            switch id {
            case 0:
                // Custom section: skipped, except that we keep nothing from it.
                reader.offset = sectionEnd
            case 1:
                let count = try reader.readVarUInt32()
                for _ in 0..<count {
                    module.types.append(try reader.readFuncType())
                }
            case 2:
                let count = try reader.readVarUInt32()
                for _ in 0..<count {
                    let importModule = try reader.readName()
                    let field = try reader.readName()
                    let kind = try reader.readByte()
                    switch kind {
                    case 0:
                        let typeIndex = try reader.readVarUInt32()
                        module.imports.append(
                            WasmImport(module: importModule, field: field, kind: kind, typeIndex: typeIndex)
                        )
                        module.functions.append(
                            WasmFunction(
                                typeIndex: typeIndex, locals: [], instructions: [],
                                isImported: true, index: module.functions.count
                            )
                        )
                        module.importedFunctionCount += 1
                    case 1:
                        _ = try reader.readByte()            // element type
                        _ = try reader.readLimits()
                        module.imports.append(WasmImport(module: importModule, field: field, kind: kind, typeIndex: 0))
                    case 2:
                        let limits = try reader.readLimits()
                        module.memoryLimits = limits
                        module.imports.append(WasmImport(module: importModule, field: field, kind: kind, typeIndex: 0))
                    case 3:
                        let type = try reader.readValueType()
                        _ = try reader.readByte()            // mutability
                        module.globals.append(WasmGlobal(type: type, mutable: true, initialValue: .i32(0)))
                        module.imports.append(WasmImport(module: importModule, field: field, kind: kind, typeIndex: 0))
                    default:
                        throw WasmTrap.malformed("unknown import kind \(kind)")
                    }
                }
            case 3:
                let count = try reader.readVarUInt32()
                for _ in 0..<count {
                    definedTypes.append(try reader.readVarUInt32())
                }
            case 4:
                let count = try reader.readVarUInt32()
                for _ in 0..<count {
                    _ = try reader.readByte()                // element type
                    module.tableLimits = try reader.readLimits()
                }
            case 5:
                let count = try reader.readVarUInt32()
                for _ in 0..<count {
                    module.memoryLimits = try reader.readLimits()
                }
            case 6:
                let count = try reader.readVarUInt32()
                for _ in 0..<count {
                    let type = try reader.readValueType()
                    let mutable = (try reader.readByte()) == 1
                    let value = try reader.readInitExpression()
                    module.globals.append(WasmGlobal(type: type, mutable: mutable, initialValue: value))
                }
            case 7:
                let count = try reader.readVarUInt32()
                for _ in 0..<count {
                    let name = try reader.readName()
                    let kind = try reader.readByte()
                    let index = try reader.readVarUInt32()
                    module.exports.append(WasmExport(name: name, kind: kind, index: index))
                }
            case 8:
                module.startFunction = try reader.readVarUInt32()
            case 9:
                let count = try reader.readVarUInt32()
                for _ in 0..<count {
                    let flags = try reader.readVarUInt32()
                    if flags == 0 {
                        let offset = try reader.readInitExpression().i32Value ?? 0
                        let entries = try reader.readVarUInt32()
                        var indices: [UInt32] = []
                        for _ in 0..<entries {
                            indices.append(try reader.readVarUInt32())
                        }
                        module.elementSegments.append(
                            WasmElementSegment(tableIndex: 0, offset: UInt32(bitPattern: offset), functionIndices: indices)
                        )
                    } else {
                        throw WasmTrap.unsupported("element segment flags \(flags)")
                    }
                }
            case 10:
                let count = try reader.readVarUInt32()
                var bodyIndex = 0
                for _ in 0..<count {
                    let bodySize = try reader.readVarUInt32()
                    let bodyEnd = reader.offset + Int(bodySize)
                    let localGroups = try reader.readVarUInt32()
                    var locals: [WasmValueType] = []
                    for _ in 0..<localGroups {
                        let localCount = try reader.readVarUInt32()
                        let type = try reader.readValueType()
                        if localCount > 0 {
                            locals.append(contentsOf: Array(repeating: type, count: Int(localCount)))
                        }
                    }
                    let instructions = try WasmInstructionDecoder.decode(&reader, until: bodyEnd)
                    guard bodyIndex < definedTypes.count else {
                        throw WasmTrap.malformed("more function bodies than declared functions")
                    }
                    module.functions.append(
                        WasmFunction(
                            typeIndex: definedTypes[bodyIndex],
                            locals: locals,
                            instructions: instructions,
                            isImported: false,
                            index: module.functions.count
                        )
                    )
                    bodyIndex += 1
                    reader.offset = bodyEnd
                }
            case 11:
                let count = try reader.readVarUInt32()
                for _ in 0..<count {
                    let flags = try reader.readVarUInt32()
                    switch flags {
                    case 0:
                        let offset = try reader.readInitExpression().i32Value ?? 0
                        let length = try reader.readVarUInt32()
                        let bytes = try reader.readBytes(Int(length))
                        module.dataSegments.append(
                            WasmDataSegment(memoryIndex: 0, offset: UInt32(bitPattern: offset), bytes: bytes)
                        )
                    case 1:
                        let length = try reader.readVarUInt32()
                        _ = try reader.readBytes(Int(length))
                    case 2:
                        let memoryIndex = try reader.readVarUInt32()
                        let offset = try reader.readInitExpression().i32Value ?? 0
                        let length = try reader.readVarUInt32()
                        let bytes = try reader.readBytes(Int(length))
                        module.dataSegments.append(
                            WasmDataSegment(memoryIndex: memoryIndex, offset: UInt32(bitPattern: offset), bytes: bytes)
                        )
                    default:
                        throw WasmTrap.unsupported("data segment flags \(flags)")
                    }
                }
            case 12:
                _ = try reader.readVarUInt32()               // data count
            default:
                throw WasmTrap.unsupported("section \(id)")
            }
            if reader.offset != sectionEnd {
                reader.offset = sectionEnd
            }
        }
        return module
    }
}

/// Raised for anything that stops execution: malformed modules, unsupported
/// features and runtime traps. The message is shown to the user.
enum WasmTrap: Error, Equatable {
    case malformed(String)
    case unsupported(String)
    case runtime(String)
    case budget(String)

    var message: String {
        switch self {
        case .malformed(let text): return "malformed module: \(text)"
        case .unsupported(let text): return "unsupported feature: \(text)"
        case .runtime(let text): return "trap: \(text)"
        case .budget(let text): return text
        }
    }
}

/// Little-endian byte cursor with the LEB128 encodings wasm uses.
struct WasmReader {
    let bytes: [UInt8]
    var offset: Int = 0

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw WasmTrap.malformed("unexpected end of module")
        }
        let byte = bytes[offset]
        offset += 1
        return byte
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else {
            throw WasmTrap.malformed("unexpected end of module")
        }
        let slice = Array(bytes[offset..<(offset + count)])
        offset += count
        return slice
    }

    mutating func readVarUInt32() throws -> UInt32 {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        while true {
            let byte = try readByte()
            result |= UInt32(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift > 28 {
                throw WasmTrap.malformed("LEB128 integer too long")
            }
        }
    }

    mutating func readVarInt32() throws -> Int32 {
        var result: Int32 = 0
        var shift: Int32 = 0
        var byte: UInt8 = 0
        repeat {
            byte = try readByte()
            result |= Int32(byte & 0x7F) << shift
            shift += 7
            if shift > 35 {
                throw WasmTrap.malformed("LEB128 integer too long")
            }
        } while byte & 0x80 != 0
        if shift < 32, byte & 0x40 != 0 {
            result |= ~0 << shift
        }
        return result
    }

    mutating func readVarInt64() throws -> Int64 {
        var result: Int64 = 0
        var shift: Int64 = 0
        var byte: UInt8 = 0
        repeat {
            byte = try readByte()
            result |= Int64(byte & 0x7F) << shift
            shift += 7
            if shift > 70 {
                throw WasmTrap.malformed("LEB128 integer too long")
            }
        } while byte & 0x80 != 0
        if shift < 64, byte & 0x40 != 0 {
            result |= ~0 << shift
        }
        return result
    }

    mutating func readName() throws -> String {
        let length = try readVarUInt32()
        let bytes = try readBytes(Int(length))
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func readValueType() throws -> WasmValueType {
        let byte = try readByte()
        guard let type = WasmValueType(rawValue: byte) else {
            throw WasmTrap.unsupported("value type 0x\(String(format: "%02x", byte))")
        }
        return type
    }

    mutating func readFuncType() throws -> WasmFuncType {
        let form = try readByte()
        guard form == 0x60 else {
            throw WasmTrap.malformed("expected a function type, found 0x\(String(format: "%02x", form))")
        }
        let parameterCount = try readVarUInt32()
        var parameters: [WasmValueType] = []
        for _ in 0..<parameterCount {
            parameters.append(try readValueType())
        }
        let resultCount = try readVarUInt32()
        var results: [WasmValueType] = []
        for _ in 0..<resultCount {
            results.append(try readValueType())
        }
        // Multi-value results need the full stack-polymorphic validator; we run
        // single-result signatures only.
        guard results.count <= 1 else {
            throw WasmTrap.unsupported("multi-value results")
        }
        return WasmFuncType(parameters: parameters, results: results)
    }

    mutating func readLimits() throws -> WasmLimits {
        let flag = try readByte()
        switch flag {
        case 0x00:
            return WasmLimits(minimum: try readVarUInt32(), maximum: nil)
        case 0x01:
            let minimum = try readVarUInt32()
            let maximum = try readVarUInt32()
            return WasmLimits(minimum: minimum, maximum: maximum)
        case 0x03:
            // Shared memory (threads): not supported, but it parses as limits.
            throw WasmTrap.unsupported("shared memory")
        default:
            throw WasmTrap.malformed("unknown limits flag \(flag)")
        }
    }

    /// Reads a constant init expression: `i32.const n`, `i64.const n`,
    /// `f32.const`, `f64.const`, `global.get`, or `ref.null`, then `end`.
    mutating func readInitExpression() throws -> WasmValue {
        let opcode = try readByte()
        let value: WasmValue
        switch opcode {
        case 0x41: value = .i32(try readVarInt32())
        case 0x42: value = .i64(try readVarInt64())
        case 0x43:
            let raw = try readBytes(4)
            value = .f32(Float(bitPattern: UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24))
        case 0x44:
            let raw = try readBytes(8)
            var bits: UInt64 = 0
            for index in 0..<8 {
                bits |= UInt64(raw[index]) << (8 * UInt64(index))
            }
            value = .f64(Double(bitPattern: bits))
        case 0x23:
            _ = try readVarUInt32()
            value = .i32(0)               // imported globals are not supported
        case 0xD0:
            let type = try readValueType()
            value = type == .funcref ? .funcref(nil) : .externref(nil)
        default:
            throw WasmTrap.unsupported("init expression opcode 0x\(String(format: "%02x", opcode))")
        }
        let terminator = try readByte()
        guard terminator == 0x0B else {
            throw WasmTrap.malformed("init expression is not terminated")
        }
        return value
    }
}
