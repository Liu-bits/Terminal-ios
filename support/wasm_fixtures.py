"""Assemble the WebAssembly fixtures used by the interpreter tests.

Hand-assembling the bytes keeps the test suite honest: the fixtures exercise
exactly the encodings the parser has to decode (LEB128, block types, iovec
structures, data segments), and nothing depends on a C toolchain being present.

The modules are validated with Node's WebAssembly implementation before they are
written, so a typo in the assembler cannot silently become "the interpreter is
wrong". Node's results also act as the expected values in the Swift tests.

Outputs:
  catalog/payloads/hello-wasm.wasm            - a real payload the catalog ships
  Sources/Terminal-iosTests/WasmFixtures.swift - the same modules, base64, for tests

Run from the repository root:  python support/wasm_fixtures.py
"""

import base64
import json
import pathlib
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAYLOAD_DIR = ROOT / "catalog" / "payloads"
TESTS_DIR = ROOT / "Sources" / "Terminal-iosTests"


# --- LEB128 helpers ---------------------------------------------------------

def u32(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def i32(value: int) -> bytes:
    out = bytearray()
    more = True
    while more:
        byte = value & 0x7F
        value >>= 7
        sign = byte & 0x40
        more = not ((value == 0 and not sign) or (value == -1 and sign))
        out.append(byte | (0x80 if more else 0))
    return bytes(out)


def section(identifier: int, payload: bytes) -> bytes:
    return bytes([identifier]) + u32(len(payload)) + payload


def vector(items: list[bytes]) -> bytes:
    return u32(len(items)) + b"".join(items)


def name(text: str) -> bytes:
    raw = text.encode("utf-8")
    return u32(len(raw)) + raw


def functype(params: list[int], results: list[int]) -> bytes:
    return bytes([0x60]) + vector([bytes([p]) for p in params]) + vector([bytes([r]) for r in results])


I32, I64, F32, F64 = 0x7F, 0x7E, 0x7D, 0x7C
MAGIC = b"\x00asm\x01\x00\x00\x00"


def module(
    types: list[bytes],
    imports: list[bytes],
    defined_types: list[int],
    memories: list[bytes],
    globals_: list[bytes],
    exports: list[bytes],
    bodies: list[bytes],
    datas: list[bytes],
    start: int | None = None,
) -> bytes:
    out = bytearray(MAGIC)
    out += section(1, vector(types))
    if imports:
        out += section(2, vector(imports))
    if defined_types:
        out += section(3, vector([u32(t) for t in defined_types]))
    if memories:
        out += section(5, vector(memories))
    if globals_:
        out += section(6, vector(globals_))
    out += section(7, vector(exports))
    if start is not None:
        out += section(8, u32(start))
    # Code and data section lengths need to be known before the vector header
    # (LEB128 is variable width), so encode the section once to measure it.
    code_payload = vector([u32(len(b)) + b for b in bodies])
    out += section(10, code_payload)
    if datas:
        out += section(11, vector(datas))
    return bytes(out)


def body(locals_: list[tuple[int, int]], code: bytes) -> bytes:
    local_decls = vector([u32(count) + bytes([type_]) for count, type_ in locals_])
    payload = local_decls + code + bytes([0x0B])
    return payload


def memory(minimum: int, maximum: int | None = None) -> bytes:
    if maximum is None:
        return bytes([0x00]) + u32(minimum)
    return bytes([0x01]) + u32(minimum) + u32(maximum)


def export(text: str, kind: int, index: int) -> bytes:
    return name(text) + bytes([kind]) + u32(index)


def data_segment(offset: int, payload: bytes) -> bytes:
    return u32(0) + bytes([0x41]) + i32(offset) + bytes([0x0B]) + u32(len(payload)) + payload


# --- Fixtures ---------------------------------------------------------------

def add_module() -> bytes:
    """add(i32, i32) -> i32, plus a global and a mutable global."""
    code = bytes([
        0x20, 0x00,          # local.get 0
        0x20, 0x01,          # local.get 1
        0x6A,                # i32.add
    ])
    return module(
        types=[functype([I32, I32], [I32])],
        imports=[],
        defined_types=[0],
        memories=[],
        globals_=[
            bytes([I32, 0x00, 0x41]) + i32(7) + bytes([0x0B]),     # immutable 7
            bytes([I32, 0x01, 0x41]) + i32(0) + bytes([0x0B]),     # mutable 0
        ],
        exports=[
            export("add", 0, 0),
            export("answer", 3, 0),
            export("counter", 3, 1),
        ],
        bodies=[body([], code)],
        datas=[],
    )


def control_flow_module() -> bytes:
    """fib(n) via a loop, sum_to(n) via br_if, and a br_table classifier."""
    # fib(n): iterative
    #   locals: a=0, b=1, i=0, tmp
    fib = bytes([
        0x41, 0x00,              # i32.const 0        ; a
        0x21, 0x02,              # local.set 2
        0x41, 0x01,              # i32.const 1        ; b
        0x21, 0x03,              # local.set 3
        0x41, 0x00,              # i32.const 0        ; i
        0x21, 0x04,              # local.set 4
        0x02, 0x40,              # block
        0x03, 0x40,              #   loop
        0x20, 0x04,              #   local.get 4
        0x20, 0x00,              #   local.get 0
        0x4E,                    #   i32.ge_s
        0x0D, 0x01,              #   br_if 1
        0x20, 0x02,              #   local.get 2
        0x20, 0x03,              #   local.get 3
        0x6A,                    #   i32.add
        0x21, 0x05,              #   local.set 5 (tmp)
        0x20, 0x03,              #   local.get 3
        0x21, 0x02,              #   local.set 2
        0x20, 0x05,              #   local.get 5
        0x21, 0x03,              #   local.set 3
        0x20, 0x04,              #   local.get 4
        0x41, 0x01,              #   i32.const 1
        0x6A,                    #   i32.add
        0x21, 0x04,              #   local.set 4
        0x0C, 0x00,              #   br 0
        0x0B,                    #   end (loop)
        0x0B,                    # end (block)
        0x20, 0x02,              # local.get 2
    ])
    # classify(x): 0 -> 10, 1 -> 20, anything else -> 30. Every br_table
    # target is a void block, which is what the validator requires (all labels
    # must agree on arity); each case exits with `return`.
    classify = bytes([
        0x02, 0x40,              # block (void)            [$b2]
        0x02, 0x40,              #   block (void)          [$b1]
        0x02, 0x40,              #     block (void)        [$b0]
        0x20, 0x00,              #       local.get 0
        0x0E, 0x02, 0x00, 0x01, 0x02,  # br_table [0,1] default 2
        0x0B,                    #     end $b0
        0x41, 0x0A,              #     i32.const 10
        0x0F,                    #     return
        0x0B,                    #   end $b1
        0x41, 0x14,              #   i32.const 20
        0x0F,                    #   return
        0x0B,                    # end $b2
        0x41, 0x1E,              # i32.const 30
    ])
    return module(
        types=[functype([I32], [I32])],
        imports=[],
        defined_types=[0, 0],
        memories=[],
        globals_=[],
        exports=[export("fib", 0, 0), export("classify", 0, 1)],
        bodies=[
            body([(5, I32)], fib),
            body([], classify),
        ],
        datas=[],
    )


def memory_module() -> bytes:
    """load/store + memory.size/grow + a data segment."""
    code = bytes([
        0x41, 0x00,              # i32.const 0
        0x20, 0x00,              # local.get 0
        0x36, 0x02, 0x00,        # i32.store align=2 offset=0
        0x41, 0x00,              # i32.const 0
        0x28, 0x02, 0x00,        # i32.load align=2 offset=0
    ])
    read_string = bytes([
        0x20, 0x00,              # local.get 0 (offset inside the data)
        0x2D, 0x00, 0x00,        # i32.load8_u offset=0
    ])
    # `poke(addr, value)` stores where asked, which roundtrip cannot: its address
    # is the constant 0, so passing a huge argument just stores a huge value and
    # an out-of-bounds test written against it never traps.
    poke = bytes([
        0x20, 0x00,              # local.get 0   (address)
        0x20, 0x01,              # local.get 1   (value)
        0x36, 0x02, 0x00,        # i32.store align=2 offset=0
        0x41, 0x01,              # i32.const 1
    ])
    # `pages` takes no parameters - JS pads a missing argument with 0, so the
    # old (I32) -> I32 signature passed under Node while a real caller with
    # correct arity checking traps. Declare it as () -> I32.
    return module(
        types=[
            functype([I32], [I32]),
            functype([], [I32]),
            functype([I32, I32], [I32]),        # poke
        ],
        imports=[],
        defined_types=[0, 0, 1, 1, 2],
        memories=[memory(1, 4)],
        globals_=[],
        exports=[
            export("memory", 2, 0),
            export("roundtrip", 0, 0),
            export("byte_at", 0, 1),
            export("pages", 0, 2),
            export("grow", 0, 3),
            export("poke", 0, 4),
        ],
        bodies=[
            body([], code),
            body([], read_string),
            body([], bytes([0x3F, 0x00])),      # memory.size  (index byte included)
            body([], bytes([0x41, 0x01, 0x40, 0x00])),   # i32.const 1; memory.grow
            body([], poke),
        ],
        datas=[data_segment(16, b"wasm-data\n")],
    )


def wasi_hello_module() -> bytes:
    """The payload the catalog ships: writes "hello from wasm\\n" via fd_write."""
    message = b"hello from wasm\n"
    # iovec {ptr:16, len:len(message)} lives at offset 0.
    iovec = struct.pack("<II", 16, len(message))
    code = bytes([
        0x41, 0x01,              # i32.const 1     ; fd = stdout
        0x41, 0x00,              # i32.const 0     ; iovs
        0x41, 0x01,              # i32.const 1     ; iovs_len
        0x41, 0xC0, 0x00,        # i32.const 64    ; nwritten. Single-byte
                                 # 0x40 would sign-extend to -64, so the
                                 # positive LEB128 form needs two bytes.
        0x10, 0x00,              # call fd_write (import 0)
        0x1A,                    # drop
    ])
    return module(
        types=[
            functype([I32, I32, I32, I32], [I32]),   # fd_write
            functype([], []),                        # _start
        ],
        imports=[
            name("wasi_snapshot_preview1") + name("fd_write") + bytes([0x00]) + u32(0),
        ],
        defined_types=[1],
        memories=[memory(1)],
        globals_=[],
        exports=[export("memory", 2, 0), export("_start", 0, 1)],
        bodies=[body([], code)],
        datas=[data_segment(0, iovec), data_segment(16, message)],
    )


def trap_module() -> bytes:
    """divide(by) traps with 'integer divide by zero' when by == 0.

    `_start` divides by zero too, so `wasm run` also lands on the trap.
    """
    divide = bytes([
        0x41, 0xC8, 0x01,        # i32.const 200
        0x20, 0x00,              # local.get 0
        0x6D,                    # i32.div_s
    ])
    start = bytes([
        0x41, 0x00,              # i32.const 0
        0x10, 0x00,              # call divide
        0x1A,                    # drop
    ])
    return module(
        types=[functype([I32], [I32]), functype([], [])],
        imports=[],
        defined_types=[0, 1],
        memories=[],
        globals_=[],
        exports=[export("divide", 0, 0), export("_start", 0, 1)],
        bodies=[body([], divide), body([], start)],
        datas=[],
    )


def spin_module() -> bytes:
    """forever(): an unconditional loop, used to test the instruction budget."""
    code = bytes([
        0x03, 0x40,              # loop
        0x0C, 0x00,              #   br 0
        0x0B,                    # end
    ])
    return module(
        types=[functype([], [])],
        imports=[],
        defined_types=[0],
        memories=[],
        globals_=[],
        exports=[export("forever", 0, 0)],
        bodies=[body([], code)],
        datas=[],
    )


FIXTURES = {
    "add": add_module,
    "controlflow": control_flow_module,
    "memory": memory_module,
    "wasihello": wasi_hello_module,
    "trap": trap_module,
    "spin": spin_module,
}


# --- Validation with Node ---------------------------------------------------

NODE_PROBE = """
const fs = require('fs');
const bytes = fs.readFileSync(process.argv[2]);
const info = { valid: false };
try {
  info.valid = WebAssembly.validate(bytes);
  const wasmModule = new WebAssembly.Module(bytes);
  info.exports = WebAssembly.Module.exports(wasmModule).map(e => e.name);
  info.imports = WebAssembly.Module.imports(wasmModule).map(i => i.module + '.' + i.name);
  let out = '';
  const imports = {};
  if (info.imports.includes('wasi_snapshot_preview1.fd_write')) {
    imports.wasi_snapshot_preview1 = {
      fd_write: (fd, iovs, len, written) => {
        const view = new DataView(instance.exports.memory.buffer);
        let total = 0;
        for (let i = 0; i < len; i++) {
          const ptr = view.getUint32(iovs + i * 8, true);
          const l = view.getUint32(iovs + i * 8 + 4, true);
          const buf = Buffer.from(view.buffer, ptr, l);
          out += buf.toString('utf8');
          total += l;
        }
        view.setUint32(written, total, true);
        return 0;
      },
      fd_close: () => 0,
      fd_seek: () => 0,
      fd_fdstat_get: () => 0,
      environ_sizes_get: () => 0,
      environ_get: () => 0,
      args_sizes_get: () => 0,
      args_get: () => 0,
      clock_time_get: () => 0,
      random_get: () => 0,
      proc_exit: () => 0,
    };
  }
  const instance = new WebAssembly.Instance(wasmModule, imports);
  info.results = {};
  if (instance.exports.add) info.results.add = instance.exports.add(20, 22);
  if (instance.exports.answer) info.results.answer = instance.exports.answer.value;
  if (instance.exports.fib) {
    info.results.fib10 = instance.exports.fib(10);
    info.results.fib20 = instance.exports.fib(20);
  }
  if (instance.exports.classify) {
    info.results.classify0 = instance.exports.classify(0);
    info.results.classify1 = instance.exports.classify(1);
    info.results.classify9 = instance.exports.classify(9);
  }
  if (instance.exports.roundtrip) info.results.roundtrip = instance.exports.roundtrip(123456);
  if (instance.exports.byte_at) info.results.byte0 = instance.exports.byte_at(16);
  if (instance.exports.pages) info.results.pages = instance.exports.pages();
  if (instance.exports.poke) {
    info.results.poke = instance.exports.poke(4, 7);
    try {
      // Run this while memory is still one page: the grow below would make
      // 70000 a perfectly valid address and hide the trap.
      instance.exports.poke(70000, 1);
      info.results.pokeOutOfBounds = "NO TRAP";
    } catch (error) { info.results.pokeOutOfBounds = String(error); }
  }
  if (instance.exports.grow) {
    try { info.results.grow = instance.exports.grow(); }
    catch (error) { info.results.growError = String(error); }
  }
  if (instance.exports.divide) {
    try { info.results.divide = instance.exports.divide(4); } catch (e) { info.results.divideError = String(e.message); }
  }
  if (instance.exports._start) instance.exports._start();
  info.stdout = out;
} catch (error) {
  info.error = String(error.message);
}
console.log(JSON.stringify(info));
"""


def validate_with_node(path: pathlib.Path) -> dict:
    probe = pathlib.Path(ROOT / "support" / ".wasm_probe.cjs")
    probe.write_text(NODE_PROBE, encoding="utf-8")
    try:
        result = subprocess.run(
            ["node", str(probe), str(path)],
            capture_output=True, text=True, encoding="utf-8",
        )
        if result.returncode != 0:
            return {"error": result.stderr.strip()[:400]}
        return json.loads(result.stdout)
    finally:
        probe.unlink(missing_ok=True)


def main() -> int:
    written: dict[str, pathlib.Path] = {}
    for fixture_name, builder in FIXTURES.items():
        payload = builder()
        path = ROOT / "support" / f".{fixture_name}.wasm"
        path.write_bytes(payload)
        written[fixture_name] = path

    failures = 0
    report: dict[str, dict] = {}
    for fixture_name, path in written.items():
        info = validate_with_node(path)
        report[fixture_name] = info
        if info.get("valid") is not True:
            failures += 1
            print(f"INVALID {fixture_name}: {info.get('error')}")
        else:
            print(f"valid   {fixture_name}: {info.get('results')} stdout={info.get('stdout')!r} err={info.get('error')} imports={info.get('imports')}")

    if failures:
        for path in written.values():
            path.unlink(missing_ok=True)
        return 1

    # The WASI hello module becomes a real catalog payload.
    PAYLOAD_DIR.mkdir(parents=True, exist_ok=True)
    hello = written["wasihello"].read_bytes()
    (PAYLOAD_DIR / "hello-wasm.wasm").write_bytes(hello)
    print(f"wrote catalog/payloads/hello-wasm.wasm ({len(hello)} bytes)")

    # The same modules, as base64, for the Swift tests.
    blocks = []
    for fixture_name, path in sorted(written.items()):
        encoded = base64.b64encode(path.read_bytes()).decode()
        expected = json.dumps(report[fixture_name].get("results", {}), sort_keys=True)
        stdout = report[fixture_name].get("stdout", "")
        blocks.append(
            '    /// Node result: ' + expected + (f' stdout={stdout!r}' if stdout else "")
            + '\n    static let ' + fixture_name + ': [UInt8] = decode("' + encoded + '")'
        )
    fixtures_swift = (
        "// Copyright © 2026 Liu-bits. All rights reserved.\n"
        "\n"
        "// Generated by support/wasm_fixtures.py - do not edit by hand.\n"
        "//\n"
        "// Hand-assembled modules covering LEB128 encodings, block types, control\n"
        "// flow, memory, data segments and a WASI import. Each one was validated with\n"
        "// Node's WebAssembly implementation first, and the comment above every\n"
        "// fixture records what Node returned - that is what the tests assert.\n"
        "\n"
        "import Foundation\n"
        "\n"
        "enum WasmFixtures {\n"
        "\n"
        "    private static func decode(_ base64: String) -> [UInt8] {\n"
        "        [UInt8](Data(base64Encoded: base64) ?? Data())\n"
        "    }\n"
        "\n"
        + "\n".join(blocks)
        + "\n}\n"
    )
    TESTS_DIR.mkdir(parents=True, exist_ok=True)
    (TESTS_DIR / "WasmFixtures.swift").write_text(fixtures_swift, encoding="utf-8")
    print(f"wrote Sources/Terminal-iosTests/WasmFixtures.swift ({len(FIXTURES)} fixtures)")

    for path in written.values():
        path.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
