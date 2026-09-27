// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// Decodes a function body into instructions.
///
/// Decoding once up front (instead of interpreting bytes on the fly) buys three
/// things: `if`/`else`/`end` pairings are resolved in one pass, the executor can
/// jump by instruction index rather than rescanning, and an unsupported opcode
/// is reported before a single instruction runs.
enum WasmInstructionDecoder {

    static func decode(_ reader: inout WasmReader, until bodyEnd: Int) throws -> [WasmInstruction] {
        var instructions: [WasmInstruction] = []
        var pendingBlocks: [Int] = []       // indices of block/loop/if awaiting `end`

        while reader.offset < bodyEnd {
            let offset = reader.offset
            let opcode = try reader.readByte()
            let index = instructions.count
            let code = try decodeCode(opcode, &reader)
            let instruction = WasmInstruction(code: code, index: index, offset: offset)

            switch code {
            case .block, .loop, .if_:
                pendingBlocks.append(index)
            case .else_:
                guard let opener = pendingBlocks.last else {
                    throw WasmTrap.malformed("`else` without `if`")
                }
                guard case .if_ = instructions[opener].code else {
                    throw WasmTrap.malformed("`else` outside an `if`")
                }
                instructions[opener].elseIndex = index
            case .end:
                if let opener = pendingBlocks.popLast() {
                    instructions[opener].endIndex = index
                    // The `else` branch also needs the end it falls into.
                    if let elseIndex = instructions[opener].elseIndex, elseIndex < instructions.count {
                        instructions[elseIndex].endIndex = index
                    }
                }
            default:
                break
            }
            instructions.append(instruction)
        }
        if !pendingBlocks.isEmpty {
            throw WasmTrap.malformed("unterminated block")
        }
        return instructions
    }

    private static func decodeCode(
        _ opcode: UInt8,
        _ reader: inout WasmReader
    ) throws -> WasmInstruction.Code {
        switch opcode {
        case 0x00: return .unreachable
        case 0x01: return .nop
        case 0x02: return .block(try readBlockType(&reader))
        case 0x03: return .loop(try readBlockType(&reader))
        case 0x04: return .if_(try readBlockType(&reader))
        case 0x05: return .else_
        case 0x0B: return .end
        case 0x0C: return .br(try reader.readVarUInt32())
        case 0x0D: return .brIf(try reader.readVarUInt32())
        case 0x0E:
            let count = try reader.readVarUInt32()
            var labels: [UInt32] = []
            for _ in 0..<count {
                labels.append(try reader.readVarUInt32())
            }
            let fallback = try reader.readVarUInt32()
            return .brTable(labels: labels, fallback: fallback)
        case 0x0F: return .return_
        case 0x10: return .call(try reader.readVarUInt32())
        case 0x11:
            let typeIndex = try reader.readVarUInt32()
            let tableIndex = try reader.readVarUInt32()
            return .callIndirect(typeIndex: typeIndex, tableIndex: tableIndex)
        case 0x1A: return .drop
        case 0x1B: return .select
        case 0x1C:
            let count = try reader.readVarUInt32()
            guard count == 1 else {
                throw WasmTrap.unsupported("typed select with \(count) types")
            }
            _ = try reader.readValueType()
            return .select
        case 0x20: return .localGet(try reader.readVarUInt32())
        case 0x21: return .localSet(try reader.readVarUInt32())
        case 0x22: return .localTee(try reader.readVarUInt32())
        case 0x23: return .globalGet(try reader.readVarUInt32())
        case 0x24: return .globalSet(try reader.readVarUInt32())
        case 0x28...0x35:
            let align = try reader.readVarUInt32()
            let offset = try reader.readVarUInt32()
            return .load(opcode: opcode, offset: offset)
        case 0x36...0x3E:
            let align = try reader.readVarUInt32()
            let offset = try reader.readVarUInt32()
            return .store(opcode: opcode, offset: offset)
        case 0x3F: return .memorySize
        case 0x40: return .memoryGrow
        case 0x41: return .constI32(try reader.readVarInt32())
        case 0x42: return .constI64(try reader.readVarInt64())
        case 0x43:
            let raw = try reader.readBytes(4)
            return .constF32(readUInt32(raw))
        case 0x44:
            let raw = try reader.readBytes(8)
            var bits: UInt64 = 0
            for index in 0..<8 {
                bits |= UInt64(raw[index]) << (8 * UInt64(index))
            }
            return .constF64(bits)
        case 0xD0: return .refNull(try reader.readValueType())
        case 0xD1: return .refIsNull
        case 0xD2: return .refFunc(try reader.readVarUInt32())
        case 0xFC:
            let sub = try reader.readVarUInt32()
            switch sub {
            case 8: _ = try reader.readVarUInt32(); return .memoryFill
            case 9: _ = try reader.readVarUInt32(); return .unreachable    // reserved
            case 10:
                _ = try reader.readVarUInt32()
                _ = try reader.readVarUInt32()
                return .memoryCopy
            default:
                throw WasmTrap.unsupported("0xFC sub-opcode \(sub)")
            }
        default:
            if numericOpcodes.contains(opcode) {
                return .numeric(opcode)
            }
            throw WasmTrap.unsupported("opcode 0x\(String(format: "%02x", opcode))")
        }
    }

    private static func readBlockType(_ reader: inout WasmReader) throws -> WasmBlockType {
        // A block type is either 0x40 (empty), a value type byte, or a signed
        // LEB128 type index.
        let byte = try reader.readByte()
        if byte == 0x40 {
            return .empty
        }
        if let type = WasmValueType(rawValue: byte) {
            return .value(type)
        }
        // Type index: the byte we consumed is the first LEB128 byte, so rebuild
        // the value and continue reading the remaining bytes.
        var result = UInt32(byte & 0x7F)
        var shift: UInt32 = 7
        var current = byte
        while current & 0x80 != 0 {
            current = try reader.readByte()
            result |= UInt32(current & 0x7F) << shift
            shift += 7
        }
        return .indexed(result)
    }

    static func readUInt32(_ raw: [UInt8]) -> UInt32 {
        UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
    }

    /// Numeric and comparison instructions that carry no immediates.
    static let numericOpcodes: Set<UInt8> = [
        0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F,
        0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A,
        0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65,
        0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F, 0x70,
        0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x7B,
        0x7C, 0x7D, 0x7E, 0x7F, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86,
        0x87, 0x88, 0x89, 0x8A, 0x8B,
        0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96,
        0x97, 0x98, 0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F,
        0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6,
        0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB0, 0xB1,
        0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB, 0xBC,
        0xBD, 0xBE, 0xBF
    ]
}
