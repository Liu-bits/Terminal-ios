// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Host functions an instance can import (WASI lives here).
///
/// The instance is passed in because host functions need its memory: WASI's
/// `fd_write` reads an iovec out of linear memory.
protocol WasmHost: AnyObject {
    func call(
        module: String,
        field: String,
        arguments: [WasmValue],
        instance: WasmInstance
    ) throws -> [WasmValue]
}

/// An instantiated module: memory, globals, table and the executor.
///
/// Design notes that matter for an App Store build:
/// - Every accessor is bounds-checked; a bad module traps instead of crashing.
/// - Execution has an instruction budget and a call-depth cap, so a downloaded
///   module cannot spin forever or exhaust the stack.
/// - Memory growth is capped, so a module cannot exhaust the container.
final class WasmInstance {

    struct Limits {
        /// Instruction budget per `invoke` call.
        var instructionBudget = 20_000_000
        /// Maximum memory in 64 KiB pages (32 MiB by default).
        var maxMemoryPages = 512
        /// Maximum nesting of wasm calls.
        var maxCallDepth = 512
    }

    let module: WasmModule
    let host: WasmHost?
    let limits: Limits

    private(set) var memory: [UInt8] = []
    private(set) var globals: [WasmValue] = []
    private(set) var table: [Int?] = []
    private var callDepth = 0
    /// Instructions executed since this instance was created.
    private(set) var executedSteps = 0

    init(module: WasmModule, host: WasmHost? = nil, limits: Limits = Limits()) throws {
        self.module = module
        self.host = host
        self.limits = limits

        let pages = Int(module.memoryLimits?.minimum ?? 0)
        let maximum = Int(module.memoryLimits?.maximum ?? UInt32(limits.maxMemoryPages))
        guard pages <= min(maximum, limits.maxMemoryPages) else {
            throw WasmTrap.runtime("module asks for \(pages) pages, over the \(limits.maxMemoryPages)-page cap")
        }
        memory = [UInt8](repeating: 0, count: pages * WasmInstance.pageSize)
        globals = module.globals.map(\.initialValue)
        if let tableLimits = module.tableLimits {
            table = Array(repeating: nil, count: Int(tableLimits.minimum))
        }

        // Data segments.
        for segment in module.dataSegments {
            guard segment.memoryIndex == 0 else {
                throw WasmTrap.unsupported("data segment for memory \(segment.memoryIndex)")
            }
            let start = Int(segment.offset)
            guard start + segment.bytes.count <= memory.count else {
                throw WasmTrap.runtime("data segment does not fit in memory")
            }
            memory.replaceSubrange(start..<(start + segment.bytes.count), with: segment.bytes)
        }
        // Element segments fill the table.
        for segment in module.elementSegments {
            guard segment.tableIndex == 0 else {
                throw WasmTrap.unsupported("element segment for table \(segment.tableIndex)")
            }
            for (offset, functionIndex) in segment.functionIndices.enumerated() {
                let slot = Int(segment.offset) + offset
                guard slot < table.count else {
                    throw WasmTrap.runtime("element segment does not fit in the table")
                }
                table[slot] = Int(functionIndex)
            }
        }
        if let start = module.startFunction {
            _ = try invoke(functionIndex: Int(start), arguments: [])
        }
    }

    static let pageSize = 65_536

    // MARK: - Calling

    /// Calls an exported function by name.
    func invoke(export name: String, arguments: [WasmValue] = []) throws -> [WasmValue] {
        guard let exported = module.export(named: name) else {
            throw WasmTrap.runtime("no exported function named '\(name)' (exports: \(module.exportNames.joined(separator: ", ")))")
        }
        guard exported.kind == 0 else {
            throw WasmTrap.runtime("export '\(name)' is not a function")
        }
        return try invoke(functionIndex: Int(exported.index), arguments: arguments)
    }

    func invoke(functionIndex index: Int, arguments: [WasmValue]) throws -> [WasmValue] {
        guard index >= 0, index < module.functions.count else {
            throw WasmTrap.runtime("function index \(index) is out of range")
        }
        if index < module.importedFunctionCount {
            return try callImport(index: index, arguments: arguments)
        }
        guard callDepth < limits.maxCallDepth else {
            throw WasmTrap.runtime("call stack exhausted (\(limits.maxCallDepth) frames)")
        }
        callDepth += 1
        defer { callDepth -= 1 }
        return try execute(module.functions[index], arguments: arguments)
    }

    private func callImport(index: Int, arguments: [WasmValue]) throws -> [WasmValue] {
        let imported = module.imports.filter { $0.kind == 0 }
        guard index < imported.count else {
            throw WasmTrap.runtime("imported function \(index) is missing")
        }
        let declaration = imported[index]
        guard let host else {
            throw WasmTrap.runtime("module imports \(declaration.module).\(declaration.field) but no host functions are available")
        }
        return try host.call(
            module: declaration.module, field: declaration.field,
            arguments: arguments, instance: self
        )
    }

    /// Reads memory from the host side (WASI needs this).
    func readMemory(at address: Int, count: Int) throws -> [UInt8] {
        guard address >= 0, count >= 0, address + count <= memory.count else {
            throw WasmTrap.runtime("out of bounds memory access at \(address) for \(count) bytes")
        }
        return Array(memory[address..<(address + count)])
    }

    func writeMemory(at address: Int, bytes: [UInt8]) throws {
        guard address >= 0, address + bytes.count <= memory.count else {
            throw WasmTrap.runtime("out of bounds memory access at \(address) for \(bytes.count) bytes")
        }
        memory.replaceSubrange(address..<(address + bytes.count), with: bytes)
    }

    func growMemory(pages: Int) -> Int32 {
        let current = memory.count / WasmInstance.pageSize
        let maximum = min(Int(module.memoryLimits?.maximum ?? UInt32(limits.maxMemoryPages)), limits.maxMemoryPages)
        guard pages >= 0, current + pages <= maximum else {
            return -1
        }
        memory.append(contentsOf: [UInt8](repeating: 0, count: pages * WasmInstance.pageSize))
        return Int32(current)
    }

    // MARK: - Execution

    private enum ControlKind {
        case block
        case loop
        case if_
        case function
    }

    private struct ControlFrame {
        var kind: ControlKind
        /// Stack height where the frame's results start.
        var stackHeight: Int
        var resultArity: Int
        /// Instruction to jump to on `br` (block/if: the `end`; loop: the body).
        var targetIndex: Int
    }

    private func execute(_ function: WasmFunction, arguments: [WasmValue]) throws -> [WasmValue] {
        let signature = module.types[Int(function.typeIndex)]
        guard arguments.count == signature.parameters.count else {
            throw WasmTrap.runtime("function expected \(signature.parameters.count) arguments, got \(arguments.count)")
        }
        var locals = arguments
        locals.append(contentsOf: function.locals.map { Self.defaultValue(for: $0) })

        let instructions = function.instructions
        var stack: [WasmValue] = []
        var control: [ControlFrame] = [
            ControlFrame(
                kind: .function,
                stackHeight: 0,
                resultArity: signature.results.count,
                targetIndex: instructions.count
            )
        ]
        var pc = 0
        var budget = limits.instructionBudget

        while pc < instructions.count {
            budget -= 1
            executedSteps += 1
            if budget <= 0 {
                throw WasmTrap.budget("instruction budget exhausted after \(limits.instructionBudget) steps (runaway loop?)")
            }
            let instruction = instructions[pc]
            switch instruction.code {
            case .unreachable:
                throw WasmTrap.runtime("unreachable instruction executed")

            case .nop:
                pc += 1

            case .block(let blockType):
                let type = blockType.resolve(module.types)
                control.append(
                    ControlFrame(
                        kind: .block,
                        stackHeight: stack.count,
                        resultArity: type.results.count,
                        targetIndex: instruction.endIndex ?? instructions.count
                    )
                )
                pc += 1

            case .loop(let blockType):
                let type = blockType.resolve(module.types)
                control.append(
                    ControlFrame(
                        kind: .loop,
                        stackHeight: stack.count,
                        resultArity: type.results.count,
                        targetIndex: pc + 1
                    )
                )
                pc += 1

            case .if_(let blockType):
                let condition = try popI32(&stack)
                let type = blockType.resolve(module.types)
                control.append(
                    ControlFrame(
                        kind: .if_,
                        stackHeight: stack.count,
                        resultArity: type.results.count,
                        targetIndex: instruction.endIndex ?? instructions.count
                    )
                )
                if condition != 0 {
                    pc += 1
                } else if let elseIndex = instruction.elseIndex {
                    pc = elseIndex + 1
                } else {
                    pc = instruction.endIndex ?? instructions.count
                }

            case .else_:
                // Reaching `else` means the then-branch finished: skip to `end`.
                pc = instruction.endIndex ?? instructions.count

            case .end:
                guard let frame = control.last else {
                    throw WasmTrap.malformed("`end` without a block")
                }
                let results = Array(stack.suffix(frame.resultArity))
                stack.removeSubrange(min(frame.stackHeight, stack.count)...)
                stack.append(contentsOf: results)
                control.removeLast()
                if frame.kind == .function {
                    return Array(stack.suffix(frame.resultArity))
                }
                pc += 1

            case .br(let depth):
                pc = try branch(depth: depth, stack: &stack, control: &control, instructions: instructions)

            case .brIf(let depth):
                let condition = try popI32(&stack)
                if condition != 0 {
                    pc = try branch(depth: depth, stack: &stack, control: &control, instructions: instructions)
                } else {
                    pc += 1
                }

            case .brTable(let labels, let fallback):
                let selector = try popI32(&stack)
                let depth = selector >= 0 && Int(selector) < labels.count
                    ? labels[Int(selector)]
                    : fallback
                pc = try branch(depth: depth, stack: &stack, control: &control, instructions: instructions)

            case .return_:
                let frame = control[0]
                return Array(stack.suffix(frame.resultArity))

            case .call(let index):
                let results = try invokeFunction(index: Int(index), stack: &stack)
                stack.append(contentsOf: results)
                pc += 1

            case .callIndirect(let typeIndex, _):
                let tableSlot = try popI32(&stack)
                guard tableSlot >= 0, Int(tableSlot) < table.count, let target = table[Int(tableSlot)] else {
                    throw WasmTrap.runtime("call_indirect: table slot \(tableSlot) is empty")
                }
                let expected = module.types[Int(typeIndex)]
                let actual = module.types[Int(module.functions[target].typeIndex)]
                guard expected == actual else {
                    throw WasmTrap.runtime("call_indirect: signature mismatch")
                }
                let results = try invokeFunction(index: target, stack: &stack)
                stack.append(contentsOf: results)
                pc += 1

            case .drop:
                _ = try pop(&stack)
                pc += 1

            case .select:
                let condition = try popI32(&stack)
                let second = try pop(&stack)
                let first = try pop(&stack)
                stack.append(condition != 0 ? first : second)
                pc += 1

            case .localGet(let index):
                stack.append(try local(at: Int(index), in: locals))
                pc += 1

            case .localSet(let index):
                let value = try pop(&stack)
                try setLocal(at: Int(index), in: &locals, value: value)
                pc += 1

            case .localTee(let index):
                guard let value = stack.last else {
                    throw WasmTrap.runtime("stack underflow")
                }
                try setLocal(at: Int(index), in: &locals, value: value)
                pc += 1

            case .globalGet(let index):
                guard Int(index) < globals.count else {
                    throw WasmTrap.runtime("global \(index) is out of range")
                }
                stack.append(globals[Int(index)])
                pc += 1

            case .globalSet(let index):
                guard Int(index) < globals.count else {
                    throw WasmTrap.runtime("global \(index) is out of range")
                }
                guard module.globals[Int(index)].mutable else {
                    throw WasmTrap.runtime("global \(index) is immutable")
                }
                globals[Int(index)] = try pop(&stack)
                pc += 1

            case .load(let opcode, let offset):
                let base = try popI32(&stack)
                let address = Int(base) + Int(offset)
                stack.append(try load(opcode: opcode, address: address))
                pc += 1

            case .store(let opcode, let offset):
                let value = try pop(&stack)
                let base = try popI32(&stack)
                let address = Int(base) + Int(offset)
                try store(opcode: opcode, address: address, value: value)
                pc += 1

            case .memorySize:
                stack.append(.i32(Int32(memory.count / WasmInstance.pageSize)))
                pc += 1

            case .memoryGrow:
                let pages = try popI32(&stack)
                stack.append(.i32(growMemory(pages: Int(pages))))
                pc += 1

            case .memoryCopy:
                let count = Int(try popI32(&stack))
                let source = Int(try popI32(&stack))
                let destination = Int(try popI32(&stack))
                guard count >= 0, source >= 0, destination >= 0,
                      source + count <= memory.count, destination + count <= memory.count else {
                    throw WasmTrap.runtime("out of bounds memory access in memory.copy")
                }
                let slice = Array(memory[source..<(source + count)])
                memory.replaceSubrange(destination..<(destination + count), with: slice)
                pc += 1

            case .memoryFill:
                let count = Int(try popI32(&stack))
                let value = UInt8(truncatingIfNeeded: try popI32(&stack))
                let destination = Int(try popI32(&stack))
                guard count >= 0, destination >= 0, destination + count <= memory.count else {
                    throw WasmTrap.runtime("out of bounds memory access in memory.fill")
                }
                memory.replaceSubrange(destination..<(destination + count), with: [UInt8](repeating: value, count: count))
                pc += 1

            case .constI32(let value):
                stack.append(.i32(value))
                pc += 1

            case .constI64(let value):
                stack.append(.i64(value))
                pc += 1

            case .constF32(let bits):
                stack.append(.f32(Float(bitPattern: bits)))
                pc += 1

            case .constF64(let bits):
                stack.append(.f64(Double(bitPattern: bits)))
                pc += 1

            case .refNull(let type):
                stack.append(type == .funcref ? .funcref(nil) : .externref(nil))
                pc += 1

            case .refFunc(let index):
                stack.append(.funcref(Int(index)))
                pc += 1

            case .refIsNull:
                let value = try pop(&stack)
                let isNull: Int32
                switch value {
                case .funcref(let index), .externref(let index):
                    isNull = index == nil ? 1 : 0
                default:
                    throw WasmTrap.runtime("ref.is_null on a non-reference value")
                }
                stack.append(.i32(isNull))
                pc += 1

            case .numeric(let opcode):
                try numeric(opcode: opcode, stack: &stack)
                pc += 1
            }
        }
        return []
    }

    /// Resolves a `br`/`br_if`/`br_table` target and rewinds the stack.
    private func branch(
        depth: UInt32,
        stack: inout [WasmValue],
        control: inout [ControlFrame],
        instructions: [WasmInstruction]
    ) throws -> Int {
        let depth = Int(depth)
        guard depth < control.count else {
            throw WasmTrap.runtime("branch depth \(depth) is out of range")
        }
        let frame = control[control.count - 1 - depth]
        let results = Array(stack.suffix(frame.resultArity))
        // A branch in unreachable code can leave fewer values than the frame
        // expected, so clamp instead of trapping.
        stack.removeSubrange(min(frame.stackHeight, stack.count)...)
        stack.append(contentsOf: results)
        // Frames above the target are discarded; the target itself stays for
        // blocks (so its `end` pops it) but a loop restarts instead.
        control.removeLast(depth)
        if frame.kind == .loop {
            return frame.targetIndex
        }
        return frame.targetIndex < instructions.count ? frame.targetIndex : instructions.count
    }

    private func invokeFunction(index: Int, stack: inout [WasmValue]) throws -> [WasmValue] {
        guard index >= 0, index < module.functions.count else {
            throw WasmTrap.runtime("function index \(index) is out of range")
        }
        let signature = module.types[Int(module.functions[index].typeIndex)]
        guard stack.count >= signature.parameters.count else {
            throw WasmTrap.runtime("stack underflow calling function \(index)")
        }
        let arguments = Array(stack.suffix(signature.parameters.count))
        stack.removeLast(signature.parameters.count)
        return try invoke(functionIndex: index, arguments: arguments)
    }

    // MARK: - Locals and stack

    private static func defaultValue(for type: WasmValueType) -> WasmValue {
        switch type {
        case .i32: return .i32(0)
        case .i64: return .i64(0)
        case .f32: return .f32(0)
        case .f64: return .f64(0)
        case .funcref: return .funcref(nil)
        case .externref: return .externref(nil)
        }
    }

    private func local(at index: Int, in locals: [WasmValue]) throws -> WasmValue {
        guard index < locals.count else {
            throw WasmTrap.runtime("local \(index) is out of range")
        }
        return locals[index]
    }

    private func setLocal(at index: Int, in locals: inout [WasmValue], value: WasmValue) throws {
        guard index < locals.count else {
            throw WasmTrap.runtime("local \(index) is out of range")
        }
        locals[index] = value
    }

    private func pop(_ stack: inout [WasmValue]) throws -> WasmValue {
        guard let value = stack.popLast() else {
            throw WasmTrap.runtime("stack underflow")
        }
        return value
    }

    private func popI32(_ stack: inout [WasmValue]) throws -> Int32 {
        let value = try pop(&stack)
        guard let number = value.i32Value else {
            throw WasmTrap.runtime("expected an i32 on the stack, found \(value)")
        }
        return number
    }

    // MARK: - Memory access

    private func load(opcode: UInt8, address: Int) throws -> WasmValue {
        func bytes(_ count: Int) throws -> [UInt8] {
            guard address >= 0, address + count <= memory.count else {
                throw WasmTrap.runtime("out of bounds memory access at \(address)")
            }
            return Array(memory[address..<(address + count)])
        }
        switch opcode {
        case 0x28:
            let raw = try bytes(4)
            return .i32(Int32(bitPattern: WasmInstructionDecoder.readUInt32(raw)))
        case 0x29:
            let raw = try bytes(8)
            var value: UInt64 = 0
            for index in 0..<8 {
                value |= UInt64(raw[index]) << (8 * UInt64(index))
            }
            return .i64(Int64(bitPattern: value))
        case 0x2A:
            let raw = try bytes(4)
            return .f32(Float(bitPattern: WasmInstructionDecoder.readUInt32(raw)))
        case 0x2B:
            let raw = try bytes(8)
            var value: UInt64 = 0
            for index in 0..<8 {
                value |= UInt64(raw[index]) << (8 * UInt64(index))
            }
            return .f64(Double(bitPattern: value))
        case 0x2C:
            let raw = try bytes(1)
            return .i32(Int32(Int8(bitPattern: raw[0])))
        case 0x2D:
            let raw = try bytes(1)
            return .i32(Int32(raw[0]))
        case 0x2E:
            let raw = try bytes(2)
            return .i32(Int32(Int16(bitPattern: UInt16(raw[0]) | UInt16(raw[1]) << 8)))
        case 0x2F:
            let raw = try bytes(2)
            return .i32(Int32(UInt16(raw[0]) | UInt16(raw[1]) << 8))
        case 0x30:
            let raw = try bytes(1)
            return .i64(Int64(Int8(bitPattern: raw[0])))
        case 0x31:
            let raw = try bytes(1)
            return .i64(Int64(raw[0]))
        case 0x32:
            let raw = try bytes(2)
            return .i64(Int64(Int16(bitPattern: UInt16(raw[0]) | UInt16(raw[1]) << 8)))
        case 0x33:
            let raw = try bytes(2)
            return .i64(Int64(UInt16(raw[0]) | UInt16(raw[1]) << 8))
        case 0x34:
            let raw = try bytes(4)
            return .i64(Int64(Int32(bitPattern: WasmInstructionDecoder.readUInt32(raw))))
        case 0x35:
            let raw = try bytes(4)
            return .i64(Int64(WasmInstructionDecoder.readUInt32(raw)))
        default:
            throw WasmTrap.unsupported("load opcode 0x\(String(format: "%02x", opcode))")
        }
    }

    private func store(opcode: UInt8, address: Int, value: WasmValue) throws {
        func write(_ raw: [UInt8]) throws {
            guard address >= 0, address + raw.count <= memory.count else {
                throw WasmTrap.runtime("out of bounds memory access at \(address)")
            }
            memory.replaceSubrange(address..<(address + raw.count), with: raw)
        }
        func le32(_ bits: UInt32) -> [UInt8] {
            [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
        }
        func le64(_ bits: UInt64) -> [UInt8] {
            (0..<8).map { UInt8((bits >> (8 * UInt64($0))) & 0xFF) }
        }
        switch opcode {
        case 0x36:
            guard let number = value.i32Value else { throw WasmTrap.runtime("i32.store needs an i32") }
            try write(le32(UInt32(bitPattern: number)))
        case 0x37:
            guard let number = value.i64Value else { throw WasmTrap.runtime("i64.store needs an i64") }
            try write(le64(UInt64(bitPattern: number)))
        case 0x38:
            guard case .f32(let number) = value else { throw WasmTrap.runtime("f32.store needs an f32") }
            try write(le32(number.bitPattern))
        case 0x39:
            guard case .f64(let number) = value else { throw WasmTrap.runtime("f64.store needs an f64") }
            try write(le64(number.bitPattern))
        case 0x3A:
            guard let number = value.i32Value else { throw WasmTrap.runtime("i32.store8 needs an i32") }
            try write([UInt8(truncatingIfNeeded: number)])
        case 0x3B:
            guard let number = value.i32Value else { throw WasmTrap.runtime("i32.store16 needs an i32") }
            try write([UInt8(truncatingIfNeeded: number), UInt8(truncatingIfNeeded: number >> 8)])
        case 0x3C:
            guard let number = value.i64Value else { throw WasmTrap.runtime("i64.store8 needs an i64") }
            try write([UInt8(truncatingIfNeeded: number)])
        case 0x3D:
            guard let number = value.i64Value else { throw WasmTrap.runtime("i64.store16 needs an i64") }
            try write([UInt8(truncatingIfNeeded: number), UInt8(truncatingIfNeeded: number >> 8)])
        case 0x3E:
            guard let number = value.i64Value else { throw WasmTrap.runtime("i64.store32 needs an i64") }
            try write(le32(UInt32(truncatingIfNeeded: number)))
        default:
            throw WasmTrap.unsupported("store opcode 0x\(String(format: "%02x", opcode))")
        }
    }

    // MARK: - Numeric instructions

    private func numeric(opcode: UInt8, stack: inout [WasmValue]) throws {
        func push(_ value: WasmValue) { stack.append(value) }
        func i32Pair() throws -> (Int32, Int32) {
            let right = try popI32(&stack)
            let left = try popI32(&stack)
            return (left, right)
        }
        func i64Pair() throws -> (Int64, Int64) {
            let right = try pop(&stack)
            let left = try pop(&stack)
            guard let a = left.i64Value, let b = right.i64Value else {
                throw WasmTrap.runtime("expected i64 operands")
            }
            return (a, b)
        }
        func f32Pair() throws -> (Float, Float) {
            let right = try pop(&stack)
            let left = try pop(&stack)
            guard case .f32(let a) = left, case .f32(let b) = right else {
                throw WasmTrap.runtime("expected f32 operands")
            }
            return (a, b)
        }
        func f64Pair() throws -> (Double, Double) {
            let right = try pop(&stack)
            let left = try pop(&stack)
            guard case .f64(let a) = left, case .f64(let b) = right else {
                throw WasmTrap.runtime("expected f64 operands")
            }
            return (a, b)
        }

        switch opcode {
        // --- i32 comparisons
        case 0x45: push(.i32(try popI32(&stack) == 0 ? 1 : 0))
        case 0x46: let (a, b) = try i32Pair(); push(.i32(a == b ? 1 : 0))
        case 0x47: let (a, b) = try i32Pair(); push(.i32(a != b ? 1 : 0))
        case 0x48: let (a, b) = try i32Pair(); push(.i32(a < b ? 1 : 0))
        case 0x49: let (a, b) = try i32Pair(); push(.i32(UInt32(bitPattern: a) < UInt32(bitPattern: b) ? 1 : 0))
        case 0x4A: let (a, b) = try i32Pair(); push(.i32(a > b ? 1 : 0))
        case 0x4B: let (a, b) = try i32Pair(); push(.i32(UInt32(bitPattern: a) > UInt32(bitPattern: b) ? 1 : 0))
        case 0x4C: let (a, b) = try i32Pair(); push(.i32(a <= b ? 1 : 0))
        case 0x4D: let (a, b) = try i32Pair(); push(.i32(UInt32(bitPattern: a) <= UInt32(bitPattern: b) ? 1 : 0))
        case 0x4E: let (a, b) = try i32Pair(); push(.i32(a >= b ? 1 : 0))
        case 0x4F: let (a, b) = try i32Pair(); push(.i32(UInt32(bitPattern: a) >= UInt32(bitPattern: b) ? 1 : 0))

        // --- i64 comparisons
        case 0x50:
            let value = try pop(&stack)
            guard let number = value.i64Value else { throw WasmTrap.runtime("i64.eqz needs an i64") }
            push(.i32(number == 0 ? 1 : 0))
        case 0x51: let (a, b) = try i64Pair(); push(.i32(a == b ? 1 : 0))
        case 0x52: let (a, b) = try i64Pair(); push(.i32(a != b ? 1 : 0))
        case 0x53: let (a, b) = try i64Pair(); push(.i32(a < b ? 1 : 0))
        case 0x54: let (a, b) = try i64Pair(); push(.i32(UInt64(bitPattern: a) < UInt64(bitPattern: b) ? 1 : 0))
        case 0x55: let (a, b) = try i64Pair(); push(.i32(a > b ? 1 : 0))
        case 0x56: let (a, b) = try i64Pair(); push(.i32(UInt64(bitPattern: a) > UInt64(bitPattern: b) ? 1 : 0))
        case 0x57: let (a, b) = try i64Pair(); push(.i32(a <= b ? 1 : 0))
        case 0x58: let (a, b) = try i64Pair(); push(.i32(UInt64(bitPattern: a) <= UInt64(bitPattern: b) ? 1 : 0))
        case 0x59: let (a, b) = try i64Pair(); push(.i32(a >= b ? 1 : 0))
        case 0x5A: let (a, b) = try i64Pair(); push(.i32(UInt64(bitPattern: a) >= UInt64(bitPattern: b) ? 1 : 0))

        // --- f32 / f64 comparisons
        case 0x5B: let (a, b) = try f32Pair(); push(.i32(a == b ? 1 : 0))
        case 0x5C: let (a, b) = try f32Pair(); push(.i32(a != b ? 1 : 0))
        case 0x5D: let (a, b) = try f32Pair(); push(.i32(a < b ? 1 : 0))
        case 0x5E: let (a, b) = try f32Pair(); push(.i32(a > b ? 1 : 0))
        case 0x5F: let (a, b) = try f32Pair(); push(.i32(a <= b ? 1 : 0))
        case 0x60: let (a, b) = try f32Pair(); push(.i32(a >= b ? 1 : 0))
        case 0x61: let (a, b) = try f64Pair(); push(.i32(a == b ? 1 : 0))
        case 0x62: let (a, b) = try f64Pair(); push(.i32(a != b ? 1 : 0))
        case 0x63: let (a, b) = try f64Pair(); push(.i32(a < b ? 1 : 0))
        case 0x64: let (a, b) = try f64Pair(); push(.i32(a > b ? 1 : 0))
        case 0x65: let (a, b) = try f64Pair(); push(.i32(a <= b ? 1 : 0))
        case 0x66: let (a, b) = try f64Pair(); push(.i32(a >= b ? 1 : 0))

        // --- i32 arithmetic
        case 0x67:
            let value = try popI32(&stack)
            push(.i32(Int32(clamping: value == 0 ? 32 : Int(value.leadingZeroBitCount))))
        case 0x68:
            let value = try popI32(&stack)
            push(.i32(Int32(clamping: value == 0 ? 32 : Int(value.trailingZeroBitCount))))
        case 0x69: push(.i32(Int32(try popI32(&stack).nonzeroBitCount)))
        case 0x6A: let (a, b) = try i32Pair(); push(.i32(a &+ b))
        case 0x6B: let (a, b) = try i32Pair(); push(.i32(a &- b))
        case 0x6C: let (a, b) = try i32Pair(); push(.i32(a &* b))
        case 0x6D:
            let (a, b) = try i32Pair()
            guard b != 0 else { throw WasmTrap.runtime("integer divide by zero") }
            guard !(a == Int32.min && b == -1) else { throw WasmTrap.runtime("integer overflow") }
            push(.i32(a / b))
        case 0x6E:
            let (a, b) = try i32Pair()
            guard b != 0 else { throw WasmTrap.runtime("integer divide by zero") }
            push(.i32(Int32(bitPattern: UInt32(bitPattern: a) / UInt32(bitPattern: b))))
        case 0x6F:
            let (a, b) = try i32Pair()
            guard b != 0 else { throw WasmTrap.runtime("integer divide by zero") }
            push(.i32(a % b))
        case 0x70:
            let (a, b) = try i32Pair()
            guard b != 0 else { throw WasmTrap.runtime("integer divide by zero") }
            push(.i32(Int32(bitPattern: UInt32(bitPattern: a) % UInt32(bitPattern: b))))
        case 0x71: let (a, b) = try i32Pair(); push(.i32(a & b))
        case 0x72: let (a, b) = try i32Pair(); push(.i32(a | b))
        case 0x73: let (a, b) = try i32Pair(); push(.i32(a ^ b))
        case 0x74:
            let (a, b) = try i32Pair()
            push(.i32(a << (b & 31)))
        case 0x75:
            let (a, b) = try i32Pair()
            push(.i32(a >> (b & 31)))
        case 0x76:
            let (a, b) = try i32Pair()
            push(.i32(Int32(bitPattern: UInt32(bitPattern: a) >> (b & 31))))
        case 0x77:
            let (a, b) = try i32Pair()
            let shift = b & 31
            let bits = UInt32(bitPattern: a)
            push(.i32(Int32(bitPattern: shift == 0 ? bits : (bits << shift) | (bits >> (32 - shift)))))
        case 0x78:
            let (a, b) = try i32Pair()
            let shift = b & 31
            let bits = UInt32(bitPattern: a)
            push(.i32(Int32(bitPattern: shift == 0 ? bits : (bits >> shift) | (bits << (32 - shift)))))

        // --- i64 arithmetic
        case 0x79:
            let value = try pop(&stack)
            guard let number = value.i64Value else { throw WasmTrap.runtime("i64.clz needs an i64") }
            push(.i64(Int64(number == 0 ? 64 : number.leadingZeroBitCount)))
        case 0x7A:
            let value = try pop(&stack)
            guard let number = value.i64Value else { throw WasmTrap.runtime("i64.ctz needs an i64") }
            push(.i64(Int64(number == 0 ? 64 : number.trailingZeroBitCount)))
        case 0x7B:
            let value = try pop(&stack)
            guard let number = value.i64Value else { throw WasmTrap.runtime("i64.popcnt needs an i64") }
            push(.i64(Int64(number.nonzeroBitCount)))
        case 0x7C: let (a, b) = try i64Pair(); push(.i64(a &+ b))
        case 0x7D: let (a, b) = try i64Pair(); push(.i64(a &- b))
        case 0x7E: let (a, b) = try i64Pair(); push(.i64(a &* b))
        case 0x7F:
            let (a, b) = try i64Pair()
            guard b != 0 else { throw WasmTrap.runtime("integer divide by zero") }
            guard !(a == Int64.min && b == -1) else { throw WasmTrap.runtime("integer overflow") }
            push(.i64(a / b))
        case 0x80:
            let (a, b) = try i64Pair()
            guard b != 0 else { throw WasmTrap.runtime("integer divide by zero") }
            push(.i64(Int64(bitPattern: UInt64(bitPattern: a) / UInt64(bitPattern: b))))
        case 0x81:
            let (a, b) = try i64Pair()
            guard b != 0 else { throw WasmTrap.runtime("integer divide by zero") }
            push(.i64(a % b))
        case 0x82:
            let (a, b) = try i64Pair()
            guard b != 0 else { throw WasmTrap.runtime("integer divide by zero") }
            push(.i64(Int64(bitPattern: UInt64(bitPattern: a) % UInt64(bitPattern: b))))
        case 0x83: let (a, b) = try i64Pair(); push(.i64(a & b))
        case 0x84: let (a, b) = try i64Pair(); push(.i64(a | b))
        case 0x85: let (a, b) = try i64Pair(); push(.i64(a ^ b))
        case 0x86:
            let (a, b) = try i64Pair()
            push(.i64(a << (b & 63)))
        case 0x87:
            let (a, b) = try i64Pair()
            push(.i64(a >> (b & 63)))
        case 0x88:
            let (a, b) = try i64Pair()
            push(.i64(Int64(bitPattern: UInt64(bitPattern: a) >> (b & 63))))
        case 0x89:
            let (a, b) = try i64Pair()
            let shift = b & 63
            let bits = UInt64(bitPattern: a)
            push(.i64(Int64(bitPattern: shift == 0 ? bits : (bits << shift) | (bits >> (64 - shift)))))
        case 0x8A:
            let (a, b) = try i64Pair()
            let shift = b & 63
            let bits = UInt64(bitPattern: a)
            push(.i64(Int64(bitPattern: shift == 0 ? bits : (bits >> shift) | (bits << (64 - shift)))))

        // --- f32 arithmetic
        case 0x8B:
            guard case .f32(let value) = try pop(&stack) else { throw WasmTrap.runtime("f32.abs needs an f32") }
            push(.f32(abs(value)))
        case 0x8C:
            guard case .f32(let value) = try pop(&stack) else { throw WasmTrap.runtime("f32.neg needs an f32") }
            push(.f32(-value))
        case 0x8D:
            guard case .f32(let value) = try pop(&stack) else { throw WasmTrap.runtime("f32.ceil needs an f32") }
            push(.f32(value.rounded(.up)))
        case 0x8E:
            guard case .f32(let value) = try pop(&stack) else { throw WasmTrap.runtime("f32.floor needs an f32") }
            push(.f32(value.rounded(.down)))
        case 0x8F:
            guard case .f32(let value) = try pop(&stack) else { throw WasmTrap.runtime("f32.trunc needs an f32") }
            push(.f32(value.rounded(.towardZero)))
        case 0x90:
            guard case .f32(let value) = try pop(&stack) else { throw WasmTrap.runtime("f32.nearest needs an f32") }
            push(.f32(value.rounded(.toNearestOrEven)))
        case 0x91:
            guard case .f32(let value) = try pop(&stack) else { throw WasmTrap.runtime("f32.sqrt needs an f32") }
            push(.f32(value.squareRoot()))
        case 0x92: let (a, b) = try f32Pair(); push(.f32(a + b))
        case 0x93: let (a, b) = try f32Pair(); push(.f32(a - b))
        case 0x94: let (a, b) = try f32Pair(); push(.f32(a * b))
        case 0x95: let (a, b) = try f32Pair(); push(.f32(a / b))
        case 0x96: let (a, b) = try f32Pair(); push(.f32(a < b ? a : b))
        case 0x97: let (a, b) = try f32Pair(); push(.f32(a > b ? a : b))
        case 0x98:
            let (a, b) = try f32Pair()
            push(.f32(a.sign == .minus ? -abs(b) : abs(b)))

        // --- f64 arithmetic
        case 0x99:
            guard case .f64(let value) = try pop(&stack) else { throw WasmTrap.runtime("f64.abs needs an f64") }
            push(.f64(abs(value)))
        case 0x9A:
            guard case .f64(let value) = try pop(&stack) else { throw WasmTrap.runtime("f64.neg needs an f64") }
            push(.f64(-value))
        case 0x9B:
            guard case .f64(let value) = try pop(&stack) else { throw WasmTrap.runtime("f64.ceil needs an f64") }
            push(.f64(value.rounded(.up)))
        case 0x9C:
            guard case .f64(let value) = try pop(&stack) else { throw WasmTrap.runtime("f64.floor needs an f64") }
            push(.f64(value.rounded(.down)))
        case 0x9D:
            guard case .f64(let value) = try pop(&stack) else { throw WasmTrap.runtime("f64.trunc needs an f64") }
            push(.f64(value.rounded(.towardZero)))
        case 0x9E:
            guard case .f64(let value) = try pop(&stack) else { throw WasmTrap.runtime("f64.nearest needs an f64") }
            push(.f64(value.rounded(.toNearestOrEven)))
        case 0x9F:
            guard case .f64(let value) = try pop(&stack) else { throw WasmTrap.runtime("f64.sqrt needs an f64") }
            push(.f64(value.squareRoot()))
        case 0xA0: let (a, b) = try f64Pair(); push(.f64(a + b))
        case 0xA1: let (a, b) = try f64Pair(); push(.f64(a - b))
        case 0xA2: let (a, b) = try f64Pair(); push(.f64(a * b))
        case 0xA3: let (a, b) = try f64Pair(); push(.f64(a / b))
        case 0xA4: let (a, b) = try f64Pair(); push(.f64(a < b ? a : b))
        case 0xA5: let (a, b) = try f64Pair(); push(.f64(a > b ? a : b))
        case 0xA6:
            let (a, b) = try f64Pair()
            push(.f64(a.sign == .minus ? -abs(b) : abs(b)))

        // --- conversions
        case 0xA7:
            guard let value = try pop(&stack).i64Value else { throw WasmTrap.runtime("i32.wrap_i64 needs an i64") }
            push(.i32(Int32(truncatingIfNeeded: value)))
        case 0xA8, 0xA9:
            guard case .f32(let value) = try pop(&stack) else { throw WasmTrap.runtime("i32.trunc_f32 needs an f32") }
            push(.i32(try truncToI32(Double(value), signed: opcode == 0xA8)))
        case 0xAA, 0xAB:
            guard case .f64(let value) = try pop(&stack) else { throw WasmTrap.runtime("i32.trunc_f64 needs an f64") }
            push(.i32(try truncToI32(value, signed: opcode == 0xAA)))
        case 0xAC:
            guard let value = try pop(&stack).i32Value else { throw WasmTrap.runtime("i64.extend_i32_s needs an i32") }
            push(.i64(Int64(value)))
        case 0xAD:
            guard let value = try pop(&stack).i32Value else { throw WasmTrap.runtime("i64.extend_i32_u needs an i32") }
            push(.i64(Int64(UInt32(bitPattern: value))))
        case 0xAE, 0xAF:
            guard case .f32(let value) = try pop(&stack) else { throw WasmTrap.runtime("i64.trunc_f32 needs an f32") }
            push(.i64(try truncToI64(Double(value), signed: opcode == 0xAE)))
        case 0xB0, 0xB1:
            guard case .f64(let value) = try pop(&stack) else { throw WasmTrap.runtime("i64.trunc_f64 needs an f64") }
            push(.i64(try truncToI64(value, signed: opcode == 0xB0)))
        case 0xB2:
            guard let value = try pop(&stack).i32Value else { throw WasmTrap.runtime("f32.convert_i32_s needs an i32") }
            push(.f32(Float(value)))
        case 0xB3:
            guard let value = try pop(&stack).i32Value else { throw WasmTrap.runtime("f32.convert_i32_u needs an i32") }
            push(.f32(Float(UInt32(bitPattern: value))))
        case 0xB4:
            guard let value = try pop(&stack).i64Value else { throw WasmTrap.runtime("f32.convert_i64_s needs an i64") }
            push(.f32(Float(value)))
        case 0xB5:
            guard let value = try pop(&stack).i64Value else { throw WasmTrap.runtime("f32.convert_i64_u needs an i64") }
            push(.f32(Float(UInt64(bitPattern: value))))
        case 0xB6:
            guard case .f64(let value) = try pop(&stack) else { throw WasmTrap.runtime("f32.demote_f64 needs an f64") }
            push(.f32(Float(value)))
        case 0xB7:
            guard let value = try pop(&stack).i32Value else { throw WasmTrap.runtime("f64.convert_i32_s needs an i32") }
            push(.f64(Double(value)))
        case 0xB8:
            guard let value = try pop(&stack).i32Value else { throw WasmTrap.runtime("f64.convert_i32_u needs an i32") }
            push(.f64(Double(UInt32(bitPattern: value))))
        case 0xB9:
            guard let value = try pop(&stack).i64Value else { throw WasmTrap.runtime("f64.convert_i64_s needs an i64") }
            push(.f64(Double(value)))
        case 0xBA:
            guard let value = try pop(&stack).i64Value else { throw WasmTrap.runtime("f64.convert_i64_u needs an i64") }
            push(.f64(Double(UInt64(bitPattern: value))))
        case 0xBB:
            guard case .f32(let value) = try pop(&stack) else { throw WasmTrap.runtime("f64.promote_f32 needs an f32") }
            push(.f64(Double(value)))
        case 0xBC:
            guard let value = try pop(&stack).i32Value else { throw WasmTrap.runtime("i32.reinterpret_f32 needs an i32") }
            push(.f32(Float(bitPattern: UInt32(bitPattern: value))))
        case 0xBD:
            guard let value = try pop(&stack).i64Value else { throw WasmTrap.runtime("i64.reinterpret_f64 needs an i64") }
            push(.f64(Double(bitPattern: UInt64(bitPattern: value))))
        case 0xBE:
            guard case .f32(let value) = try pop(&stack) else { throw WasmTrap.runtime("f32.reinterpret_i32 needs an f32") }
            push(.i32(Int32(bitPattern: value.bitPattern)))
        case 0xBF:
            guard case .f64(let value) = try pop(&stack) else { throw WasmTrap.runtime("f64.reinterpret_i64 needs an f64") }
            push(.i64(Int64(bitPattern: value.bitPattern)))

        default:
            throw WasmTrap.unsupported("numeric opcode 0x\(String(format: "%02x", opcode))")
        }
    }

    private func truncToI32(_ value: Double, signed: Bool) throws -> Int32 {
        guard !value.isNaN else { throw WasmTrap.runtime("invalid conversion to integer") }
        if signed {
            guard value >= -2_147_483_648, value < 2_147_483_648 else {
                throw WasmTrap.runtime("integer overflow")
            }
            return Int32(value.rounded(.towardZero))
        }
        guard value > -1, value < 4_294_967_296 else {
            throw WasmTrap.runtime("integer overflow")
        }
        return Int32(bitPattern: UInt32(value.rounded(.towardZero)))
    }

    private func truncToI64(_ value: Double, signed: Bool) throws -> Int64 {
        guard !value.isNaN else { throw WasmTrap.runtime("invalid conversion to integer") }
        if signed {
            guard value >= -9_223_372_036_854_775_808, value < 9_223_372_036_854_775_808 else {
                throw WasmTrap.runtime("integer overflow")
            }
            return Int64(value.rounded(.towardZero))
        }
        guard value > -1, value < 18_446_744_073_709_551_616 else {
            throw WasmTrap.runtime("integer overflow")
        }
        return Int64(bitPattern: UInt64(value.rounded(.towardZero)))
    }
}
