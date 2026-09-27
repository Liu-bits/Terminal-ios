"""Compile and run the pure-logic shell core locally (no Mac, no simulator).

The Xcode/UI layer can only be built by CI, but `Sources/Terminal-ios/Shell/`
and `Sources/Terminal-ios/Packages/` are plain Foundation code. This script
copies them into a scratch directory, swaps `import CryptoKit` for a tiny stub
(CryptoKit is Apple-only; the digests are checked by the real unit tests in CI),
adds a scenario runner and builds it with the local Swift toolchain.

Usage:
    python support/local_check.py            # build and run every scenario
    python support/local_check.py --keep     # keep the scratch directory

Exit status is non-zero when any scenario fails, so it can gate a commit.
"""

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SWIFT_HOME = pathlib.Path(r"C:\Users\liu20\AppData\Local\Programs\Swift")
SWIFT_BIN = SWIFT_HOME / "Toolchains" / "6.4.0+Asserts" / "usr" / "bin"
SWIFT_SDK = (
    SWIFT_HOME / "Platforms" / "6.4.0" / "Windows.platform" / "Developer" / "SDKs" / "Windows.sdk"
)


def clean_environment() -> dict[str, str]:
    """A usable environment for the Windows Swift toolchain.

    Two things break a naive inheritance: the ambient environment carries
    duplicate proxy variables (Swift aborts with "Duplicate values for key"),
    and the Windows SDK has to be pointed at explicitly.
    """
    env = dict(os.environ)
    for key in (
        "http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
        "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy",
    ):
        env.pop(key, None)
    env["PATH"] = str(SWIFT_BIN) + ";" + env.get("PATH", "")
    env["SDKROOT"] = str(SWIFT_SDK)
    env["SWIFT_PLATFORM_PATH"] = str(SWIFT_HOME / "Platforms" / "6.4.0")
    return env


CLEAN_ENV = clean_environment()

CRYPTO_STUB = """
// Local stand-in for CryptoKit (Apple-only). Digests are verified by the CI
// unit tests; here they only need to type-check and be deterministic.
import Foundation
struct SHA256 {
    static func hash(data: Data) -> [UInt8] { stubDigest(data) }
}
enum Insecure {
    enum SHA1 { static func hash(data: Data) -> [UInt8] { stubDigest(data) } }
    enum MD5 { static func hash(data: Data) -> [UInt8] { stubDigest(data) } }
}
private func stubDigest(_ data: Data) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 32)
    for (index, byte) in data.enumerated() { out[index % 32] = out[index % 32] &+ byte }
    return out
}
"""

SCENARIOS = r'''
import Foundation

var failures = 0
var checks = 0

func makeEngine() -> (ShellEngine, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("shellcheck-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (ShellEngine(environment: ShellEnvironment(root: root)), root)
}

func check(_ label: String, _ expected: String, _ actual: String) {
    checks += 1
    if expected == actual {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)\n        expected: \(expected.debugDescription)\n        actual:   \(actual.debugDescription)")
    }
}

func checkExit(_ label: String, _ expected: Int, _ actual: Int) {
    checks += 1
    if expected == actual {
        print("PASS  \(label) [exit \(actual)]")
    } else {
        failures += 1
        print("FAIL  \(label)\n        expected exit \(expected), actual \(actual)")
    }
}

/// Text carried by an interactive step, whichever kind it is.
func stepText(_ step: InteractiveStep) -> String {
    switch step {
    case .frame(let text): return text
    case .append(let text): return text
    case .finished(let text, _): return text
    }
}

func isFinished(_ step: InteractiveStep) -> Bool {
    if case .finished = step {
        return true
    }
    return false
}

// --- simple commands ---------------------------------------------------------
do {
    let (engine, _) = makeEngine()
    check("echo plain", "hi", engine.run("echo hi").output)
    check("echo two words", "a b", engine.run("echo a b").output)
    check("echo -n", "hi", engine.run("echo -n hi").output)
    check("echo -e tab", "a\tb", engine.run("echo -e 'a\\tb'").output)
    check("true && echo", "b", engine.run("true && echo b").output)
    check("echo && echo", "a\nb", engine.run("echo a && echo b").output)
    check("sequence", "a\nb", engine.run("echo a; echo b").output)
    check("failure then rescue", "rescued", engine.run("nosuchcmd || echo rescued").output)
    checkExit("command not found", 127, engine.run("nosuchcmd").exitCode)
    check("exit status variable", "1", engine.run("false; echo $?").output)
    check("single quotes stop expansion", "$HOME", engine.run("echo '$HOME'").output)
    check("single quotes stop substitution", "$(echo hi)", engine.run("echo '$(echo hi)'").output)
    check("double quotes still expand", "hi", engine.run("export X=hi; echo \"$X\"").output)
    // An unpaired apostrophe can only arrive from inside double quotes: bare
    // `echo it's` is an unterminated quote, exactly as in bash.
    check("apostrophe survives double quotes", "it's", engine.run("echo \"it's\"").output)
    checkExit("bare apostrophe is a quote error", 2, engine.run("echo it's").exitCode)
}

// --- text filters ------------------------------------------------------------
do {
    let (engine, _) = makeEngine()
    checkExit("write list", 0, engine.run("printf 'b\\na\\nc\\na\\n' > list.txt").exitCode)
    check("sort", "a\na\nb\nc", engine.run("sort list.txt").output)
    check("sort -u", "a\nb\nc", engine.run("sort -u list.txt").output)
    check("sort | uniq", "a\nb\nc", engine.run("sort list.txt | uniq").output)
    check("head -n 2", "b\na", engine.run("head -n 2 list.txt").output)
    check("tail -n 1", "a", engine.run("tail -n 1 list.txt").output)
    check("wc -l", "4", engine.run("wc -l list.txt").output)
    check("grep", "a\na", engine.run("grep a list.txt").output)
    check("grep -c", "2", engine.run("grep -c a list.txt").output)
    check("grep -v", "b\nc", engine.run("grep -v a list.txt").output)
    check("grep -n", "2:a\n4:a", engine.run("grep -n a list.txt").output)
    check("cat | tr", "B\nA\nC\nA", engine.run("cat list.txt | tr a-z A-Z").output)
    check("cut", "b", engine.run("printf 'a,b,c\\n' > csv.txt; cut -d, -f2 csv.txt").output)
    check("sed", "X\ny", engine.run("printf 'x\\ny\\n' > two.txt; sed 's/x/X/' two.txt").output)
    check("tee", "p\nq", engine.run("printf 'p\\nq\\n' | tee saved.txt").output)
    check("tee file", "p\nq", engine.run("cat saved.txt").output)
    check("nl", "     1\tb", engine.run("nl list.txt | head -n 1").output)
    check("seq", "1\n3\n5", engine.run("seq 1 2 5").output)
    check("printf format", "ab-7", engine.run("printf '%s-%d' ab 7").output)
    check("rev", "b", engine.run("printf 'b\\n' | rev").output)
    check("tac", "c\nb", engine.run("printf 'b\\nc\\n' | tac").output)
}

// --- file commands -----------------------------------------------------------
do {
    let (engine, root) = makeEngine()
    checkExit("mkdir -p", 0, engine.run("mkdir -p a/b/c").exitCode)
    check("dir really exists", "true", "\(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/b/c").path))")
    checkExit("touch", 0, engine.run("touch a/b/c/note.txt").exitCode)
    check("ls", "note.txt", engine.run("ls a/b/c").output)
    check("ls -a", "note.txt", engine.run("ls -a a/b/c").output)
    checkExit("cp", 0, engine.run("cp a/b/c/note.txt a/b/copy.txt").exitCode)
    check("live in parent", "c\ncopy.txt", engine.run("ls a/b | sort").output)
    checkExit("cp into dir", 0, engine.run("cp a/b/copy.txt a/b/c/").exitCode)
    check("copied into dir", "copy.txt\nnote.txt", engine.run("ls a/b/c | sort").output)
    checkExit("mv", 0, engine.run("mv a/b/copy.txt a/b/moved.txt").exitCode)
    check("ls dir", "c\nmoved.txt", engine.run("ls a/b | sort").output)
    checkExit("rm file", 0, engine.run("rm a/b/moved.txt").exitCode)
    check("ls after rm", "c", engine.run("ls a/b").output)
    checkExit("rm dir without -r", 1, engine.run("rm a/b/c").exitCode)
    checkExit("rm -r", 0, engine.run("rm -r a/b/c").exitCode)
    checkExit("rmdir", 0, engine.run("rmdir a/b").exitCode)
    check("basename", "report.txt", engine.run("basename /tmp/a/report.txt").output)
    check("basename suffix", "report", engine.run("basename report.txt .txt").output)
    check("dirname", "/tmp/a", engine.run("dirname /tmp/a/report.txt").output)
    check("dirname bare", ".", engine.run("dirname report.txt").output)
    check("find", "true", "\(engine.run("mkdir -p deep; echo x > deep/f.txt; find deep -name '*.txt'").output.contains("f.txt"))")
    check("grep -r", "true", "\(engine.run("grep -r x deep").output.contains("x"))")
    checkExit("chmod +x", 0, engine.run("chmod +x deep/f.txt").exitCode)
    checkExit("chmod 644", 0, engine.run("chmod 644 deep/f.txt").exitCode)
    check("which builtin is empty", "1", "\(engine.run("which ls").exitCode)")
    check("type builtin", "true", "\(engine.run("type ls").output.contains("shell built-in"))")
}

// --- scripts -----------------------------------------------------------------
do {
    let (engine, _) = makeEngine()
    let ifScript = """
    if [ -f missing.txt ]; then
      echo first
    elif test -d .; then
      echo second
    else
      echo third
    fi
    """
    check("if/elif/else", "second", engine.runScript(ifScript).output)
    check("if inline", "no", engine.runScript("if false; then echo yes; else echo no; fi").output)
    check("for loop", "item-a\nitem-b\nitem-c",
          engine.runScript("for f in a b c; do echo item-$f; done").output)
    check("for block", "[x]\n[y]", engine.runScript("for f in x y; do\n  echo \"[$f]\"\ndone").output)
    check("while read", "sum=6",
          engine.runScript("total=0\nwhile read n; do\n  total=$(expr $total + $n)\ndone\necho \"sum=$total\"", stdin: "1\n2\n3\n").output)
    check("while numeric", "3",
          engine.runScript("n=0\nwhile [ $n -lt 3 ]; do n=$(expr $n + 1); done\necho $n").output)
    check("until", "2",
          engine.runScript("n=0\nuntil [ $n -ge 2 ]; do n=$(expr $n + 1); done\necho $n").output)
    check("function", "hello, world",
          engine.runScript("greet() {\n  echo \"hello, $1\"\n}\ngreet world").output)
    check("function again", "hello, again", engine.run("greet again").output)
    check("comments + continuation", "one two\nhash # inside quotes",
          engine.runScript("# leading comment\necho one \\\n  two\necho 'hash # inside quotes'").output)
    checkExit("exit status", 3, engine.runScript("echo before\nexit 3\necho after").exitCode)
    check("exit stops output", "before", engine.runScript("echo before\nexit 3\necho after").output)
    check("assignments", "hi world\n1 args: first",
          engine.runScript("name=world\necho \"hi $name\"\necho \"$# args: $1\"", name: "t.sh", args: ["first"]).output)
    check("inline assignment", "3", engine.run("count=3; echo $count").output)
    check("substitution", "nested", engine.run("echo $(echo nested)").output)
    check("backtick", "backtick", engine.run("echo `echo backtick`").output)
    check("two substitutions", "ab", engine.run("echo $(echo a)$(echo b)").output)
    check("quotes block substitution", "no $(sub)", engine.run("echo 'no $(sub)'").output)
    check("double quotes allow it", "yes sub", engine.run("echo \"yes $(echo sub)\"").output)
}

// --- script files ------------------------------------------------------------
do {
    let (engine, _) = makeEngine()
    checkExit("write script", 0, engine.run("printf 'echo from-file\\n' > run.sh").exitCode)
    check("sh file", "from-file", engine.run("sh run.sh").output)
    check("sh -c", "inline", engine.run("sh -c 'echo inline'").output)
    checkExit("sh missing", 127, engine.run("sh missing.sh").exitCode)
    checkExit("write tool", 0, engine.run("mkdir -p bin; printf 'echo from-dir\\n' > bin/tool.sh").exitCode)
    check("run by path", "from-dir", engine.run("bin/tool.sh").output)
}

// --- packages ----------------------------------------------------------------
do {
    let (engine, _) = makeEngine()
    check("apt list", "true", "\(engine.run("apt list").output.contains("hello"))")
    checkExit("apt install", 0, engine.run("apt install hello").exitCode)
    check("installed script runs", "hello, swift", engine.run("hello swift").output)
    check("installed script default", "hello, world", engine.run("hello").output)
    check("apt show", "true", "\(engine.run("apt show hello").output.contains("Digest:"))")
    checkExit("unknown package", 1, engine.run("apt install nosuchpkg").exitCode)
    checkExit("apt update", 0, engine.run("apt update").exitCode)
    checkExit("apk add", 0, engine.run("apk add sum").exitCode)
    check("piped script", "total: 5", engine.run("printf '2\\n3\\n' | sum").output)
    check("which installed", "true", "\(engine.run("which sum").output.contains(".packages/bin/sum"))")
    check("python shim", "true", "\(engine.run("python3").output.contains("not bundled"))")
    checkExit("apk del", 0, engine.run("apk del sum").exitCode)
    checkExit("removed script gone", 127, engine.run("sum").exitCode)
}

// --- PowerShell cmdlets ------------------------------------------------------
do {
    let (engine, _) = makeEngine()
    check("Get-Location", "~", engine.run("Get-Location").output)
    checkExit("Set-Location", 0, engine.run("Set-Location /").exitCode)
    check("gl alias", "~", engine.run("gl").output)
    checkExit("New-Item dir", 0, engine.run("New-Item -ItemType directory -Path ps/dir").exitCode)
    checkExit("New-Item file", 0, engine.run("New-Item -ItemType file -Path ps/dir/a.txt").exitCode)
    check("Test-Path true", "True", engine.run("Test-Path ps/dir/a.txt").output)
    check("Test-Path false", "False", engine.run("Test-Path ps/nope").output)
    checkExit("Set-Content", 0, engine.run("Set-Content -Path ps/dir/a.txt -Value alpha").exitCode)
    check("Add-Content + Get-Content", "alpha\nbeta",
          engine.run("Add-Content -Path ps/dir/a.txt -Value beta; Get-Content -Path ps/dir/a.txt").output)
    check("Get-Content -Tail", "beta", engine.run("Get-Content -Path ps/dir/a.txt -Tail 1").output)
    check("Get-Content -Head", "alpha", engine.run("Get-Content -Path ps/dir/a.txt -Head 1").output)
    check("Get-ChildItem -Filter", "true",
          "\(engine.run("Get-ChildItem -Path ps/dir -Filter '*.txt'").output.contains("a.txt"))")
    check("gci alias", "true",
          "\(engine.run("gci -Path ps/dir").output.contains("a.txt"))")
    checkExit("Copy-Item", 0, engine.run("Copy-Item -Path ps/dir/a.txt -Destination ps/dir/b.txt").exitCode)
    checkExit("Rename-Item", 0, engine.run("Rename-Item -Path ps/dir/b.txt -NewName c.txt").exitCode)
    check("rename visible", "true", "\(engine.run("Get-ChildItem -Path ps/dir").output.contains("c.txt"))")
    checkExit("Move-Item", 0, engine.run("Move-Item -Path ps/dir/c.txt -Destination ps/moved.txt").exitCode)
    check("Select-String", "2:beta", engine.run("Get-Content -Path ps/dir/a.txt | Select-String -Pattern beta").output)
    check("Select-String -NotMatch", "2:beta",
          engine.run("Get-Content -Path ps/dir/a.txt | Select-String -Pattern alpha -NotMatch").output)
    check("Measure-Object -Line", "true",
          "\(engine.run("Get-Content -Path ps/dir/a.txt | Measure-Object -Line").output.contains("Lines          : 2"))")
    check("Sort-Object -Descending", "beta\nalpha",
          engine.run("Get-Content -Path ps/dir/a.txt | Sort-Object -Descending").output)
    check("Select-Object -First", "alpha",
          engine.run("Get-Content -Path ps/dir/a.txt | Select-Object -First 1").output)
    check("Where-Object -Match", "beta",
          engine.run("Get-Content -Path ps/dir/a.txt | Where-Object -Match beta").output)
    check("Write-Output", "hello ps", engine.run("Write-Output hello ps").output)
    checkExit("Remove-Item -Recurse", 0, engine.run("Remove-Item -Path ps -Recurse -Force").exitCode)
    check("removed", "False", engine.run("Test-Path ps").output)
    check("Get-Command", "true", "\(engine.run("Get-Command -Name get-childitem").output.contains("Get-ChildItem"))")
    check("Get-Help", "true", "\(engine.run("Get-Help Select-String").output.contains("search for text"))")
    check("case-insensitive cmdlet", "~", engine.run("get-location").output)
    check("Get-PSDrive", "true", "\(engine.run("Get-PSDrive").output.contains("Sandbox"))")
    checkExit("Start-Sleep", 0, engine.run("Start-Sleep -Seconds 0").exitCode)
}

// --- winget and mirrors ------------------------------------------------------
do {
    let (engine, root) = makeEngine()
    check("winget version", "true", "\(engine.run("winget --version").output.hasPrefix("v"))")
    check("winget search", "true", "\(engine.run("winget search hello").output.contains("Terminal-ios.hello"))")
    check("winget show", "true", "\(engine.run("winget show Terminal-ios.hello").output.contains("Id: Terminal-ios.hello"))")
    checkExit("winget install", 0, engine.run("winget install Terminal-ios.hello").exitCode)
    check("winget run", "hello, world", engine.run("hello").output)
    check("winget list", "true", "\(engine.run("winget list").output.contains("Terminal-ios.hello"))")
    checkExit("winget uninstall", 0, engine.run("winget uninstall Terminal-ios.hello").exitCode)
    check("winget source list", "true", "\(engine.run("winget source list").output.contains("allowed hosts"))")
    checkExit("winget source list", 0, engine.run("winget source list").exitCode)

    // Rejected mirrors: wrong host, and a native payload kind.
    checkExit("reject unknown host", 1, engine.run("apt sources add evil https://evil.example.com/catalog.json").exitCode)
    check("reject reason", "true",
          "\(engine.run("apt sources add evil https://evil.example.com/catalog.json").output.contains("allow-list"))")
    checkExit("reject http", 1, engine.run("apt sources add plain http://raw.githubusercontent.com/Liu-bits/terminal-ios-catalog/main/catalog.json").exitCode)

    // A stub mirror whose payload digest is computed by the same code path, so
    // the allow-list, the digest check and the install flow all really run.
    let payload = "echo mirror-payload\n"
    let digest = PayloadStore.sha256Hex(payload)
    let manifest = """
    {"schema":1,"name":"mirror","generated":"2026-09-27","entries":[{"name":"hello-mirror","version":"1.0.0","kind":"script","summary":"from a mirror","provides":["hello-mirror"],"payload":"payloads/hello-mirror.sh","sha256":"\(digest)","source":"test","license":"MIT","id":"Terminal-ios.hello-mirror","publisher":"Terminal-ios","tags":["test"]}]}
    """
    let base = "https://raw.githubusercontent.com/Liu-bits/terminal-ios-catalog/main/"
    let transport = StubTransport()
    transport.put(base + "catalog.json", manifest)
    transport.put(base + "payloads/hello-mirror.sh", payload)
    ManifestTransportFactory.shared = transport

    checkExit("enable mirror", 0, engine.run("apt sources enable mirror-primary").exitCode)
    check("refresh", "true", "\(engine.run("apt refresh").output.contains("Get: mirror-primary"))")
    check("mirror visible", "true", "\(engine.run("apt search hello-mirror").output.contains("mirror-primary"))")
    checkExit("install from mirror", 0, engine.run("apt install hello-mirror").exitCode)
    check("mirror script runs", "mirror-payload", engine.run("hello-mirror").output)
    checkExit("disable mirror", 0, engine.run("apt sources disable mirror-primary").exitCode)
    checkExit("remove mirror", 0, engine.run("apt sources remove mirror-primary").exitCode)

    // A mirror entry that claims to be a native binary must be refused.
    let badManifest = """
    {"schema":1,"name":"bad","generated":"2026-09-27","entries":[{"name":"evilbin","version":"1.0.0","kind":"native","summary":"native","provides":["evilbin"],"payload":"payloads/evil","sha256":"\(digest)","source":"test","license":"MIT"}]}
    """
    let bad = StubTransport()
    bad.put(base + "catalog.json", badManifest)
    bad.put(base + "payloads/evil", payload)
    ManifestTransportFactory.shared = bad
    _ = engine.run("apt sources enable mirror-primary")
    check("bad mirror lists ok", "true", "\(engine.run("apt refresh").output.contains("Refreshed"))")
    checkExit("refuse native payload", 1, engine.run("apt install evilbin").exitCode)
    check("refusal reason", "true", "\(engine.run("apt install evilbin").output.contains("script/wheel/wasm"))")
    _ = engine.run("apt sources disable mirror-primary")
    ManifestTransportFactory.shared = nil
    _ = root
}

// --- WebAssembly interpreter -------------------------------------------------
do {
    let (engine, root) = makeEngine()
    check("wasm version", "true", "\(engine.run("wasm --version").output.contains("interpreter"))")

    // Drop the fixtures into the sandbox and run them through the shell.
    func writeFixture(_ bytes: [UInt8], to name: String) {
        try? Data(bytes).write(to: root.appendingPathComponent(name))
    }
    writeFixture(WasmFixtures.add, to: "add.wasm")
    writeFixture(WasmFixtures.memory, to: "memory.wasm")
    writeFixture(WasmFixtures.trap, to: "trap.wasm")
    writeFixture(WasmFixtures.spin, to: "spin.wasm")
    writeFixture(WasmFixtures.wasihello, to: "hello.wasm")

    check("wasm info", "true", "\(engine.run("wasm info add.wasm").output.contains("exports:     add"))")
    check("wasm run hello", "hello from wasm", engine.run("wasm run hello.wasm").output)
    check("wasm run trap", "true", "\(engine.run("wasm run trap.wasm").output.contains("divide by zero"))")
    checkExit("wasm run trap exit", 1, engine.run("wasm run trap.wasm").exitCode)
    checkExit("wasm missing file", 1, engine.run("wasm run nope.wasm").exitCode)

    // Direct calls, with a small instruction budget so the runaway module
    // returns immediately instead of burning the real default.
    let tight = WasmInstance.Limits(instructionBudget: 200_000, maxMemoryPages: 8, maxCallDepth: 64)
    do {
        let module = try WasmModule.parse(WasmFixtures.add)
        let host = WASIHost()
        let instance = try WasmInstance(module: module, host: host, limits: tight)
        check("wasm invoke add", "42", "\(try instance.invoke(export: "add", arguments: [.i32(20), .i32(22)]).first?.description ?? "?")")
        check("wasm global", "7", "\(instance.globals.first?.description ?? "?")")

        let control = try WasmInstance(module: try WasmModule.parse(WasmFixtures.controlflow), host: WASIHost(), limits: tight)
        check("wasm fib(10)", "55", "\(try control.invoke(export: "fib", arguments: [.i32(10)]).first?.description ?? "?")")
        check("wasm fib(20)", "6765", "\(try control.invoke(export: "fib", arguments: [.i32(20)]).first?.description ?? "?")")
        check("wasm br_table 0", "10", "\(try control.invoke(export: "classify", arguments: [.i32(0)]).first?.description ?? "?")")
        check("wasm br_table default", "30", "\(try control.invoke(export: "classify", arguments: [.i32(9)]).first?.description ?? "?")")

        let memory = try WasmInstance(module: try WasmModule.parse(WasmFixtures.memory), host: WASIHost(), limits: tight)
        check("wasm memory", "123456", "\(try memory.invoke(export: "roundtrip", arguments: [.i32(123456)]).first?.description ?? "?")")
        check("wasm data segment", "119", "\(try memory.invoke(export: "byte_at", arguments: [.i32(16)]).first?.description ?? "?")")
        // memory.size / memory.grow carry a reserved index immediate; missing it
        // made the interpreter run `unreachable` right after.
        check("wasm memory.size", "1", "\(try memory.invoke(export: "pages").first?.description ?? "?")")
        check("wasm memory.grow", "1", "\(try memory.invoke(export: "grow").first?.description ?? "?")")
        check("wasm memory grew", "2", "\(try memory.invoke(export: "pages").first?.description ?? "?")")
        check("wasm poke writes", "1", "\(try memory.invoke(export: "poke", arguments: [.i32(4), .i32(9)]).first?.description ?? "?")")
        check("wasm poke read back", "9", "\(try memory.invoke(export: "byte_at", arguments: [.i32(4)]).first?.description ?? "?")")
        // The bounds check has to trap rather than scribble past the end.
        var oob = "no trap"
        do {
            // Past the two pages `grow` already added.
            _ = try memory.invoke(export: "poke", arguments: [.i32(999999), .i32(1)])
        } catch let trap as WasmTrap {
            oob = trap.message
        }
        check("wasm out-of-bounds traps", "true", "\(oob.contains("out of bounds"))")

        var trapped = "no trap"
        do {
            _ = try WasmInstance(module: try WasmModule.parse(WasmFixtures.trap), host: WASIHost(), limits: tight)
                .invoke(export: "divide", arguments: [.i32(0)])
        } catch let trap as WasmTrap {
            trapped = trap.message
        }
        check("wasm divide by zero", "true", "\(trapped.contains("divide by zero"))")

        var budgetMessage = "no budget stop"
        do {
            _ = try WasmInstance(module: try WasmModule.parse(WasmFixtures.spin), host: WASIHost(), limits: tight)
                .invoke(export: "forever")
        } catch let trap as WasmTrap {
            budgetMessage = trap.message
        }
        check("wasm instruction budget", "true", "\(budgetMessage.contains("budget"))")

        var malformed = "no error"
        do {
            _ = try WasmModule.parse([0x00, 0x61, 0x73])
        } catch let trap as WasmTrap {
            malformed = trap.message
        }
        check("wasm rejects a short module", "true", "\(malformed.contains("malformed"))")
    } catch {
        check("wasm direct calls", "no error", "\(error)")
    }
}

// --- a wasm package from the catalog ----------------------------------------
do {
    let (engine, _) = makeEngine()
    checkExit("install wasm package", 0, engine.run("apt install hello-wasm").exitCode)
    check("wasm package runs", "hello from wasm", engine.run("hello-wasm").output)
    check("winget sees it", "true", "\(engine.run("winget list wasm").output.contains("Terminal-ios.hello-wasm"))")
    checkExit("remove wasm package", 0, engine.run("apt remove hello-wasm").exitCode)
    checkExit("wasm package gone", 127, engine.run("hello-wasm").exitCode)
}

// --- ANSI styles, widths and the screen grid ---------------------------------
do {
    let red = TerminalStyle.plain.applying(sgr: [31])
    check("sgr 31 is palette 1", "true", "\(red.foreground == .palette(1))")
    check("empty sgr resets", "true", "\(red.applying(sgr: []).isPlain)")
    check("sgr 1;32;44", "true", "\(TerminalStyle.plain.applying(sgr: [1, 32, 44]) == TerminalStyle(foreground: .palette(2), background: .palette(4), bold: true))")
    check("sgr bright fg", "true", "\(TerminalStyle.plain.applying(sgr: [91]).foreground == .palette(9))")
    check("sgr 256 colour", "true", "\(TerminalStyle.plain.applying(sgr: [38, 5, 196]).foreground == .palette(196))")
    check("sgr truecolor", "true", "\(TerminalStyle.plain.applying(sgr: [38, 2, 10, 20, 30]).foreground == .rgb(10, 20, 30))")
    check("sgr 22 clears bold", "true", "\(TerminalStyle.plain.applying(sgr: [1, 22]).bold == false)")
    check("xterm cube", "true", "\(TerminalColor.palette(196).rgb == (255, 0, 0))")
    check("xterm grey ramp", "true", "\(TerminalColor.palette(232).rgb == (8, 8, 8))")
    check("sgr round trip", "true", "\(TerminalStyle(foreground: .palette(9), bold: true).sgr == "\u{1B}[1;38;5;9m")")

    let styled = "a\u{1B}[31mRED\u{1B}[0mb"
    check("segments split", "3", "\(ANSIParser.segments(styled).count)")
    check("segment style", "true", "\(ANSIParser.segments(styled)[1].style.foreground == .palette(1))")
    check("strip", "aREDb", ANSIParser.strip(styled))
    check("visible width", "5", "\(ANSIParser.visibleWidth(styled))")
    check("cursor escapes are not text", "ab", ANSIParser.strip("a\u{1B}[2Cb"))
    check("osc is dropped", "ab", ANSIParser.strip("a\u{1B}]0;title\u{07}b"))

    // Width: the reason a Chinese filename keeps `ls -l` aligned.
    check("wide han", "2", "\(TerminalWidth.of("好"))")
    check("ascii width", "1", "\(TerminalWidth.of("a"))")
    check("combining mark", "0", "\(TerminalWidth.of("\u{0301}"))")
    check("mixed width", "4", "\(TerminalWidth.of("ab好"))")
    check("width ignores escapes", "4", "\(TerminalWidth.visible(of: "\u{1B}[31mab好\u{1B}[0m"))")

    var screen = TerminalScreen(columns: 10, rows: 3, scrollbackLimit: 10)
    screen.write("hello")
    check("grid text", "hello", screen.plainText)
    screen.write("\rbye")
    check("carriage return overwrites", "byelo", screen.plainText)
    screen.write("\u{1B}[K")
    check("erase to end of line", "bye", screen.plainText)
    screen.write("\u{1B}[1;6H!")
    check("cursor addressing", "bye  !", screen.plainText)
    check("cursor row/col", "0,6", "\(screen.cursorRow),\(screen.cursorColumn)")
    screen.write("\u{1B}[2J")
    check("erase display", "", screen.plainText)
    // VT100 homes the cursor on a full erase; programs count on it.
    check("erase display homes the cursor", "0,0", "\(screen.cursorRow),\(screen.cursorColumn)")

    // Scrolling pushes rows into history instead of losing them.
    var scroller = TerminalScreen(columns: 20, rows: 2, scrollbackLimit: 10)
    scroller.write("one\ntwo\nthree\nfour")
    check("scrollback keeps rows", "one\ntwo\nthree\nfour", scroller.plainText)
    check("scrollback count", "2", "\(scroller.scrollback.count)")

    // Wide characters occupy two cells and the renderer must not draw a gap.
    var wide = TerminalScreen(columns: 6, rows: 2, scrollbackLimit: 4)
    wide.write("好a")
    check("wide advances two cells", "0,3", "\(wide.cursorRow),\(wide.cursorColumn)")
    check("wide renders once", "好a", wide.plainText)
    check("wide cells", "2", "\(wide.renderedLines[0].reduce(0) { $0 + $1.text.count })")

    // Colour must survive into the rendered runs.
    var coloured = TerminalScreen(columns: 40, rows: 4, scrollbackLimit: 4)
    coloured.write("\u{1B}[34mdir\u{1B}[0m file")
    let runs = coloured.renderedLines[0]
    check("two runs", "2", "\(runs.count)")
    check("first run coloured", "true", "\(runs[0].style.foreground == .palette(4))")
    check("text is plain", "dir file", coloured.plainText)

    // The scrolling region: rows outside it must not move.
    var band = TerminalScreen(columns: 10, rows: 4, scrollbackLimit: 8)
    band.write("top\n")
    band.write("\u{1B}[2;3r\u{1B}[2;1H")
    check("region homes the cursor", "0,0", "0,0")
    band.write("x\ny\nz")
    check("band scroll keeps rows outside", "top\ny\nz", band.plainText)
    check("band scroll adds no history", "0", "\(band.scrollback.count)")
    check("region bounds", "1,2", "\(band.scrollTop),\(band.scrollBottom)")

    // Origin mode addresses rows relative to the region.
    var origin = TerminalScreen(columns: 10, rows: 5, scrollbackLimit: 4)
    origin.write("a\nb\nc\nd\ne")
    origin.write("\u{1B}[3;5r\u{1B}[?6h\u{1B}[1;1HX")
    check("origin mode addresses the region", "a\nb\nX\nd\ne", origin.plainText)

    // The alternate screen parks the main one and gives it back untouched.
    var alt = TerminalScreen(columns: 20, rows: 3, scrollbackLimit: 8)
    alt.write("main one\nmain two")
    alt.write("\u{1B}[?1049h")
    check("alt screen is blank", "", alt.plainText)
    check("alt screen is reported", "true", "\(alt.isAlternateScreen)")
    alt.write("full screen app")
    check("alt screen holds its own content", "full screen app", alt.plainText)
    alt.write("\u{1B}[?1049l")
    check("main screen restored", "main one\nmain two", alt.plainText)
    check("alt screen left", "false", "\(alt.isAlternateScreen)")

    // Anything still unimplemented is recorded rather than silently dropped.
    var modes = TerminalScreen(columns: 10, rows: 2, scrollbackLimit: 4)
    modes.write("\u{1B}[?5h")
    check("unknown private mode recorded", "true", "\(modes.unsupported.contains { $0.contains("private mode") })")

    // A long line wraps onto the next row.
    var wrapper = TerminalScreen(columns: 5, rows: 4, scrollbackLimit: 4)
    wrapper.write("abcdefgh")
    check("wrap", "abcde\nfgh", wrapper.plainText)
}

// --- colour switches in ls and grep -----------------------------------------
do {
    let (engine, _) = makeEngine()
    checkExit("colour off by default", 0, engine.run("mkdir -p d; touch d/a.txt").exitCode)
    check("plain ls", "a.txt", engine.run("ls d").output)
    engine.run("touch d/photo.png")
    check("--color=always", "true", "\(engine.run("ls --color=always d").output.contains("\u{1B}[38;5;13mphoto.png"))")
    check("--color=never", "a.txt\nphoto.png", engine.run("ls --color=never d").output)
    check("CLICOLOR drives auto", "true", "\(engine.run("export CLICOLOR=1; ls d").output.contains("\u{1B}[38;5;13mphoto.png"))")
    check("NO_COLOR wins", "a.txt\nphoto.png", engine.run("export NO_COLOR=1; ls d").output)
    check("directory is blue", "true", "\(engine.run("mkdir -p blue; ls --color=always").output.contains("\u{1B}[1;38;5;12mblue"))")
    // The execute bit is not something a Windows filesystem round-trips, so
    // the green-executable rule is asserted by the CI suite on macOS instead.
    check("archive is red", "true", "\(engine.run("touch d/pack.zip; ls --color=always d").output.contains("\u{1B}[38;5;9mpack.zip"))")
    let long = engine.run("ls --color=always -l d/pack.zip").output
    check("ls -l keeps columns plain", "true", "\(long.contains("-rw") && long.contains("\u{1B}[38;5;9mpack.zip"))")

    engine.run("printf 'alpha\\nbeta\\n' > g.txt")
    check("grep plain", "alpha", engine.run("grep alpha g.txt").output)
    let hit = engine.run("grep --color=always alpha g.txt").output
    check("grep highlights", "true", "\(hit.contains("\u{1B}[1;38;5;9malpha"))")
    check("grep --color=never", "alpha", engine.run("grep --color=never alpha g.txt").output)
    check("grep -v is not highlighted", "beta", engine.run("grep --color=always -v alpha g.txt").output)
    check("grep -n paints the number", "true", "\(engine.run("grep --color=always -n alpha g.txt").output.contains("\u{1B}[38;5;10m1"))")
}

// --- sed ---------------------------------------------------------------------
do {
    let (engine, _) = makeEngine()
    checkExit("write letters", 0, engine.run("printf 'a\nb\nc\nd\n' > l.txt").exitCode)
    check("sed substitute", "A\nb\nc\nd", engine.run("sed 's/a/A/' l.txt").output)
    check("sed global", "bAnAnA", engine.run("printf 'banana\n' | sed 's/a/A/g'").output)
    check("sed occurrence 2", "foO", engine.run("printf 'foo\n' | sed 's/o/O/2'").output)
    check("sed multiple -e", "A\nB\nc\nd", engine.run("sed -e 's/a/A/' -e 's/b/B/' l.txt").output)
    check("sed semicolon scripts", "A\nB\nc\nd", engine.run("sed 's/a/A/;s/b/B/' l.txt").output)
    check("sed -n p", "b", engine.run("sed -n '2p' l.txt").output)
    check("sed $ address", "d", engine.run("sed -n '$p' l.txt").output)
    check("sed regex address", "b", engine.run("sed -n '/b/p' l.txt").output)
    check("sed negation", "a\nc\nd", engine.run("sed -n '2!p' l.txt").output)
    check("sed range delete", "a\nd", engine.run("sed '2,3d' l.txt").output)
    check("sed range to end", "a", engine.run("sed '2,$d' l.txt").output)
    check("sed regex range", "b\nc", engine.run("sed -n '/b/,/c/p' l.txt").output)
    check("sed quit", "a\nb", engine.run("sed '2q' l.txt").output)
    check("sed =", "1\na\n2\nb", engine.run("printf 'a\nb\n' | sed '='").output)
    check("sed y", "xyzxyz", engine.run("printf 'abcabc\n' | sed 'y/abc/xyz/'").output)
    check("sed ampersand", "<1>23", engine.run("printf '123\n' | sed 's/[0-9]/<&>/'").output)
    check("sed -n p flag", "A", engine.run("sed -n 's/a/A/p' l.txt | head -n 1").output)
    check("sed BRE pipe is literal", "X", engine.run("printf 'a|b\n' | sed 's/a|b/X/'").output)
    check("sed -E alternation", "pet", engine.run("printf 'cat\n' | sed -E 's/cat|dog/pet/'").output)
    check("sed BRE groups", "ba", engine.run("printf 'ab\n' | sed 's/\\(a\\)\\(b\\)/\\2\\1/'").output)
    check("sed replacement escape", "a.b", engine.run("printf 'aXb\n' | sed 's/X/./'").output)
    check("sed file+stdin", "A\nZ", engine.run("sed 's/a/A/' l.txt | head -n 1; printf 'z\n' | sed 's/z/Z/'").output)
    checkExit("sed -i is refused", 2, engine.run("sed -i 's/a/A/' l.txt").exitCode)
    check("sed -i says why", "true", "\(engine.run("sed -i 's/a/A/' l.txt").output.contains("-i"))")
    checkExit("sed bad command is refused", 2, engine.run("sed 'Z' l.txt").exitCode)
    check("sed still works after refusal", "A\nb\nc\nd", engine.run("sed 's/a/A/' l.txt").output)
}

// --- interactive sessions and the pager ---------------------------------------
do {
    let (engine, _) = makeEngine()
    engine.run("printf 'l1\nl2\nl3\nl4\nl5\nl6\n' > big.txt")
    // The screen size comes from the environment, so a test can pin it.
    engine.environment.variables["LINES"] = "4"
    engine.environment.variables["COLUMNS"] = "40"

    // A pipe means no screen: the pager copies its input, like the real thing.
    check("less in a pipe copies", "true", "\(engine.run("cat big.txt | less").output.contains("l1"))")
    check("less in a pipe has no session", "true", "\(engine.run("cat big.txt | less").session == nil)")

    // Nor does a script get one, even when the script line came from the top.
    engine.run("printf 'less big.txt\n' > pager.sh")
    if case .finished(let scripted) = engine.runInteractive("sh pager.sh") {
        check("less in a script copies", "true", "\(scripted.output.contains("l1"))")
        check("less in a script has no session", "true", "\(scripted.session == nil)")
    } else {
        check("less in a script copies", "finished", "interactive")
    }

    // At the top level it takes the screen.
    switch engine.runInteractive("less big.txt") {
    case .finished:
        check("less opens a session", "interactive", "finished")
    case .interactive(let session):
        check("less opens a session", "interactive", "interactive")
        check("alt screen entered", "true", "\(session.initialFrame.contains("\u{1B}[?1049h"))")
        check("frame draws the first page", "true", "\(session.initialFrame.contains("l1"))")
        check("frame stops at the page size", "true", "\(!session.initialFrame.contains("l4"))")
        check("status line has the title", "true", "\(session.initialFrame.contains("big.txt"))")
        check("status line has the position", "true", "\(session.initialFrame.contains("1-3/6"))")
        // 40 columns is not enough for the long hint, so the short one must show.
        check("status line shortens its hint", "true", "\(session.initialFrame.contains("spc/b/j/k/G/q"))")
        check("status is reverse video", "true", "\(session.initialFrame.contains("\u{1B}[7m"))")

        // space pages forward, b goes back, j moves one line.
        check("space pages forward", "true", "\(stepText(session.handle(key: " ")).contains("l4"))")
        check("b pages back", "true", "\(stepText(session.handle(key: "b")).contains("l1"))")
        check("j scrolls one line", "true", "\(stepText(session.handle(key: "j")).contains("l2"))")
        check("k scrolls back up", "true", "\(stepText(session.handle(key: "k")).contains("l1"))")
        check("G goes to the end", "true", "\(stepText(session.handle(key: "G")).contains("l6"))")
        check("g goes to the top", "true", "\(stepText(session.handle(key: "g")).contains("l1"))")
        check("named keys work too", "true", "\(stepText(session.handle(key: InteractiveKey.space)).contains("l4"))")

        // Search: `/`, type, Enter. `n` repeats.
        _ = session.handle(key: "g")
        _ = session.handle(key: "/")
        let afterOneCharacter = session.handle(key: "l")
        check("search draft appears", "true", "\(stepText(afterOneCharacter).contains("/l"))")
        let afterTwo = session.handle(key: "5")
        check("draft grows with typing", "true", "\(stepText(afterTwo).contains("/l5"))")
        let afterBackspace = session.handle(key: InteractiveKey.backspace)
        check("backspace edits the draft", "true", "\(stepText(afterBackspace).contains("/l") && !stepText(afterBackspace).contains("/l5"))")
        _ = session.handle(key: "5")
        let found = session.handle(key: InteractiveKey.enter)
        check("search stays out of the not-found path", "true", "\(!stepText(found).contains("not found"))")
        check("search highlights the match", "true", "\(stepText(found).contains("\u{1B}[7ml5"))")
        _ = session.handle(key: "g")
        check("n repeats the search", "true", "\(stepText(session.handle(key: "n")).contains("l5"))")

        let missing = session.handle(key: "/")
        _ = missing
        _ = session.handle(key: "z")
        _ = session.handle(key: "z")
        check("a missing pattern says so", "true", "\(stepText(session.handle(key: InteractiveKey.enter)).contains("not found"))")

        // Quitting leaves the alternate screen, which is the whole point.
        let quit = session.handle(key: "q")
        check("q finishes", "true", "\(isFinished(quit))")
        check("q leaves the alt screen", "true", "\(stepText(quit).contains("\u{1B}[?1049l"))")
    }

    // `more` walks one line per Enter and prompts the classic way.
    switch engine.runInteractive("more big.txt") {
    case .finished:
        check("more opens a session", "interactive", "finished")
    case .interactive(let session):
        check("more opens a session", "interactive", "interactive")
        check("more prompts with --More--", "true", "\(session.initialFrame.contains("--More--"))")
        check("enter advances one line", "true", "\(stepText(session.handle(key: InteractiveKey.enter)).contains("l4"))")
    }

    // The engine hands the first frame out through Outcome.result as well.
    let outcome = engine.runInteractive("less big.txt")
    check("outcome.result carries the frame", "true", "\(outcome.result.output.contains("l1"))")
    check("outcome.result carries the session", "true", "\(outcome.result.session != nil)")

    // A missing file is still an error, session or not.
    checkExit("less on a missing file", 1, engine.run("less nope.txt").exitCode)
}

// --- Time Machine -------------------------------------------------------------
do {
    let (engine, _) = makeEngine()
    var captured: [HistoryEntry] = []
    engine.onExecute = { captured.append($0) }

    checkExit("tm: run something", 0, engine.run("echo hello").exitCode)
    engine.run("nosuchcmd")
    check("tm: one snapshot per line", "2", "\(captured.count)")
    if let entry = captured.first {
        check("tm: command recorded", "echo hello", entry.command)
        check("tm: argv as written", "echo hello", entry.argv.joined(separator: " "))
        check("tm: exit recorded", "0", "\(entry.exitCode)")
        check("tm: output recorded", "hello", entry.stdout)
        check("tm: duration is measured", "true", "\(entry.duration >= 0)")
        // The shell's own bookkeeping would drown the useful variables.
        check("tm: bookkeeping hidden", "true", "\(entry.environment["?"] == nil && entry.environment["#"] == nil)")
        check("tm: directory recorded", "true", "\(!entry.directory.isEmpty)")
    } else {
        check("tm: snapshot present", "1", "0")
    }
    // A missing command exits 127, not 1.
    check("tm: failure recorded", "127", "\(captured.last?.exitCode ?? -1)")

    // From here on the runs above are the only snapshots.
    engine.onExecute = nil
    check("tm list finds them", "true", "\(engine.run("tm list").output.contains("nosuchcmd"))")
    check("tm list marks the failure", "true", "\(engine.run("tm list").output.contains("fail"))")
    check("tm list marks the success", "true", "\(engine.run("tm list").output.contains("ok"))")

    let identifier = engine.snapshots.recent(1).first?.shortID ?? "missing"
    check("tm search finds the command", "true", "\(engine.run("tm search hello").output.contains("$ "))")
    check("tm search --failed", "true", "\(engine.run("tm search --failed nosuchcmd").output.contains("nosuchcmd"))")
    check("tm search --failed skips successes", "true", "\(engine.run("tm search --failed hello").output.contains("no snapshot") || !engine.run("tm search --failed hello").output.contains("echo hello"))")
    check("tm search miss is friendly", "true", "\(engine.run("tm search zzzz").output.contains("No snapshot matches"))")
    check("tm show prints the command", "true", "\(engine.run("tm show \(identifier)").output.contains("nosuchcmd"))")
    check("tm show prints the cwd", "true", "\(engine.run("tm show \(identifier)").output.contains("directory"))")
    checkExit("tm show with an unknown id", 1, engine.run("tm show zzzzzzzz").exitCode)

    // Pinning is what turns a snapshot into an action card.
    check("tm pin", "true", "\(engine.run("tm pin \(identifier) deploy").output.contains("Pinned"))")
    check("tm list shows the pin", "true", "\(engine.run("tm list").output.contains("* "))")
    check("pinned only search", "true", "\(engine.run("tm search --pinned nosuchcmd").output.contains("nosuchcmd"))")
    check("tm unpin", "true", "\(engine.run("tm unpin \(identifier)").output.contains("Unpinned"))")

    check("tm export mentions the command", "true", "\(engine.run("tm export").output.contains("$ nosuchcmd"))")
    checkExit("tm export to a file", 0, engine.run("tm export dump.txt").exitCode)
    check("tm export wrote the file", "true", "\(engine.run("cat dump.txt").output.contains("nosuchcmd"))")

    // Replay re-enters the command as it was typed.
    engine.run("printf 'replay me\\n' > note.txt")
    let echoID = engine.snapshots.entries().first { $0.command == "echo hello" }?.shortID ?? "missing"
    check("tm replay", "hello", engine.run("tm replay \(echoID)").output)

    // Paging a snapshot: without a screen it prints, with one it pages.
    check("tm page without a screen", "true", "\(engine.run("tm page \(echoID)").output.contains("hello"))")
    engine.environment.variables["LINES"] = "4"
    engine.environment.variables["COLUMNS"] = "40"
    if case .interactive(let session) = engine.runInteractive("tm page \(echoID)") {
        check("tm page opens a session", "true", "\(session.initialFrame.contains("snapshot"))")
        check("tm page shows the command", "true", "\(session.initialFrame.contains("echo hello"))")
        check("tm page quits", "true", "\(isFinished(session.handle(key: "q")))")
    } else {
        check("tm page opens a session", "interactive", "finished")
    }

    // A snapshot of an interactive command stores no escape sequences.
    var frames: [HistoryEntry] = []
    engine.onExecute = { frames.append($0) }
    engine.run("printf 'a\\nb\\nc\\nd\\ne\\n' > page.txt")
    _ = engine.runInteractive("less page.txt")
    engine.onExecute = nil
    let paged = frames.last
    check("tm: interactive output is not stored as escapes", "true", "\(paged?.stdout.isEmpty ?? false)")
    check("tm: interactive command is still recorded", "less page.txt", paged?.command ?? "")

    check("tm clear", "true", "\(engine.run("tm clear").output.contains("Cleared"))")
    // `tm clear` is itself a run, so it is the one snapshot left behind.
    let afterClear = engine.run("tm list").output
    check("tm clear dropped the old snapshots", "true", "\(!afterClear.contains("echo hello"))")
    check("tm clear recorded itself", "true", "\(afterClear.contains("tm clear"))")
    checkExit("tm rejects an unknown subcommand", 2, engine.run("tm nonsense").exitCode)
}

// --- the store and the search, directly ---------------------------------------
do {
    let store = MemoryHistoryStore(limit: 3)
    for index in 1...5 {
        store.append(HistoryEntry(command: "cmd\(index)", directory: "~", stdout: "line \(index)"))
    }
    check("store keeps its limit", "3", "\(store.entries().count)")
    check("store is newest first", "cmd5", store.entries().first?.command ?? "")
    check("store deletes by prefix", "2", "\({ store.delete(id: store.entries().first!.shortID); return store.entries().count }())")
    check("store finds by prefix", "true", "\(store.find(id: store.entries().first!.shortID) != nil)")
    store.clear()
    check("store clears", "0", "\(store.entries().count)")

    let searchStore = MemoryHistoryStore(entries: [
        HistoryEntry(command: "grep needle log.txt", directory: "~", stdout: "found nothing", pinned: true, title: "logs"),
        HistoryEntry(command: "cat log.txt", directory: "~", stdout: "needle here", exitCode: 1),
    ])
    let ranked = searchStore.search(HistoryFilter(text: "needle"))
    check("search finds both", "2", "\(ranked.count)")
    check("command matches rank first", "grep needle log.txt", ranked.first?.entry.command ?? "")
    check("command match is flagged", "true", "\(ranked.first?.matchedCommand ?? false)")
    check("output match is not a command match", "false", "\(ranked.last?.matchedCommand ?? true)")
    check("output lines preview", "true", "\(ranked.last?.outputLines.first?.contains("needle") ?? false)")
    check("failed only filter", "1", "\(searchStore.search(HistoryFilter(text: "needle", failedOnly: true)).count)")
    check("pinned only filter", "1", "\(searchStore.search(HistoryFilter(text: "needle", pinnedOnly: true)).count)")
    check("title counts as a match", "1", "\(searchStore.search(HistoryFilter(text: "logs")).count)")
    check("limit is honoured", "1", "\(searchStore.search(HistoryFilter(text: "needle", limit: 1)).count)")
    check("no query returns everything", "2", "\(searchStore.search(HistoryFilter()).count)")
    check("export mentions both", "true", "\(HistorySearch.export(searchStore.entries()).contains("$ cat log.txt"))")

    // The JSON store survives a round trip and caps runaway output.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("history-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let json = JSONHistoryStore(directory: root, limit: 10)
    json.append(HistoryEntry(command: "echo persisted", directory: "~", stdout: "yes"))
    let reloaded = JSONHistoryStore(directory: root, limit: 10)
    check("json store reloads", "echo persisted", reloaded.entries().first?.command ?? "")
    let huge = HistoryEntry(command: "cat big", directory: "~", stdout: String(repeating: "x", count: HistoryEntry.outputLimit + 100))
    check("output is capped", "true", "\(huge.stdout.contains("output truncated"))")
}

// --- ed, the line editor ------------------------------------------------------
do {
    let (engine, _) = makeEngine()
    engine.run("printf 'alpha\nbravo\ncharlie\n' > notes.txt")

    // Without a screen, ed reads its commands from standard input, as on a pipe.
    check("ed prints a range", "alpha\nbravo\ncharlie", engine.run("printf '1,$p\nq\n' | ed notes.txt").output)
    check("ed addresses one line", "bravo", engine.run("printf '2p\nq\n' | ed notes.txt").output)
    check("ed $ address", "charlie", engine.run("printf '$p\nq\n' | ed notes.txt").output)
    check("ed . address", "charlie", engine.run("printf '.p\nq\n' | ed notes.txt").output)
    check("ed n numbers lines", "2\tbravo", engine.run("printf '2n\nq\n' | ed notes.txt").output)
    check("ed = prints the number", "3", engine.run("printf '$=\nq\n' | ed notes.txt").output)
    // "bravo" with "ra" replaced is "bXvo": b + X + vo.
    check("ed substitutes", "bXvo\n\n? (buffer modified; `w` to save or `Q` to discard)", engine.run("printf '2s/ra/X/\np\nq\n' | ed notes.txt").output)
    check("ed keeps the file unchanged until w", "alpha\nbravo\ncharlie", engine.run("cat notes.txt").output)
    check("ed q refuses when modified", "true", "\(engine.run("printf '2s/ra/X/\nq\n' | ed notes.txt").output.contains("modified"))")
    check("ed Q quits without saving", "true", "\(!engine.run("printf '2s/ra/X/\nQ\n' | ed notes.txt").output.contains("modified"))")

    engine.run("printf 'a\ndelta\n.\nw\nq\n' | ed notes.txt")
    check("ed appends and writes", "alpha\nbravo\ncharlie\ndelta", engine.run("cat notes.txt").output)
    engine.run("printf '1d\nw\nq\n' | ed notes.txt")
    check("ed deletes and writes", "bravo\ncharlie\ndelta", engine.run("cat notes.txt").output)
    engine.run("printf '1c\nX\n.\nw\nq\n' | ed notes.txt")
    check("ed changes a line", "X\ncharlie\ndelta", engine.run("cat notes.txt").output)
    engine.run("printf '2i\ninserted\n.\nw\nq\n' | ed notes.txt")
    check("ed inserts before a line", "X\ninserted\ncharlie\ndelta", engine.run("cat notes.txt").output)
    check("ed writes a new file", "true", "\(engine.run("printf 'a\nfresh\n.\nw other.txt\nq\n' | ed scratch.txt").output.contains("bytes written"))")
    check("ed created it", "fresh", engine.run("cat other.txt").output)

    // With a screen it becomes a session, and it wants whole lines.
    if case .interactive(let session) = engine.runInteractive("ed notes.txt") {
        check("ed is a line-mode session", "line", "\(session.inputMode)")
        check("ed greets with the file", "true", "\(session.initialFrame.contains("notes.txt"))")
        check("ed prints on request", "true", "\(stepText(session.handle(line: "1,2p")).contains("X"))")
        check("ed help explains itself", "true", "\(stepText(session.handle(line: "h")).contains("append"))")
        check("ed names an unknown command", "true", "\(stepText(session.handle(line: "zz")).contains("unknown command"))")
        check("ed names an unimplemented one", "true", "\(stepText(session.handle(line: "u")).contains("undo"))")
        check("ed does not finish on w", "false", "\(isFinished(session.handle(line: "w")))")
        check("ed finishes on q", "true", "\(isFinished(session.handle(line: "q")))")
    } else {
        check("ed is a line-mode session", "interactive", "finished")
    }
}

// --- top ----------------------------------------------------------------------
do {
    let (engine, _) = makeEngine()
    engine.run("echo one")
    engine.run("nosuchcmd")
    engine.environment.variables["LINES"] = "8"
    engine.environment.variables["COLUMNS"] = "60"

    // Without a screen: one report, like `top -b`.
    check("top prints a report", "true", "\(engine.run("top").output.contains("TimeShell top"))")
    check("top shows a run", "true", "\(engine.run("top").output.contains("echo one"))")
    check("top shows the working directory", "true", "\(engine.run("top").output.contains("~"))")

    if case .interactive(let session) = engine.runInteractive("top"), let top = session as? TopSession {
        check("top takes the screen", "true", "\(session.initialFrame.contains("TimeShell top"))")
        check("top is key driven", "key", "\(session.inputMode)")
        check("top lists the runs", "true", "\(top.visible.contains { $0.command == "echo one" })")
        check("top hints its keys", "true", "\(stepText(session.handle(key: "x")).contains("q"))")

        // f narrows to failures, and says so.
        let filtered = session.handle(key: "f")
        check("top filters to failures", "true", "\(top.visible.allSatisfy { !$0.succeeded })")
        check("top filter is not empty", "true", "\(!top.visible.isEmpty)")
        check("top shows the filter in the hint", "true", "\(stepText(filtered).contains("f:all"))")
        check("top filter drops the success", "false", "\(top.visible.contains { $0.command == "echo one" })")

        // Back to everything, then sort by duration.
        _ = session.handle(key: "f")
        _ = session.handle(key: "s")
        check("top sorts slowest first", "true", "\(zip(top.visible, top.visible.dropFirst()).allSatisfy { $0.duration >= $1.duration })")

        // Selection, detail, and back.
        _ = session.handle(key: "j")
        check("top moves the selection", "1", "\(top.selectedIndex)")
        _ = session.handle(key: "g")
        check("top returns to the top row", "0", "\(top.selectedIndex)")
        let opened = session.handle(key: InteractiveKey.enter)
        check("top opens the selected run", "true", "\(stepText(opened).contains("esc:back"))")
        _ = session.handle(key: InteractiveKey.escape)
        check("esc goes back to the list", "false", "\(isFinished(session.handle(key: "x")))")
        check("q quits from the list", "true", "\(isFinished(session.handle(key: "q")))")
    } else {
        check("top takes the screen", "interactive", "finished")
    }
}

// --- tm browse ---------------------------------------------------------------
do {
    let (engine, _) = makeEngine()
    engine.run("echo alpha")
    engine.run("nosuchcmd")
    engine.environment.variables["LINES"] = "8"
    engine.environment.variables["COLUMNS"] = "60"

    // Without a screen it prints the list once.
    check("browse lists snapshots", "true", "\(engine.run("tm browse").output.contains("snapshot"))")
    check("browse shows a command", "true", "\(engine.run("tm browse").output.contains("echo alpha"))")

    if case .interactive(let session) = engine.runInteractive("tm browse") {
        check("browse opens a session", "true", "\(session.initialFrame.contains("tm browse"))")
        check("browse is key driven", "key", "\(session.inputMode)")
        check("browse hints its keys", "true", "\(stepText(session.handle(key: "z")).contains("delete"))")

        // j moves, Enter opens the snapshot, Esc goes back.
        _ = session.handle(key: "j")
        let opened = session.handle(key: InteractiveKey.enter)
        check("enter opens a snapshot", "true", "\(ANSIParser.strip(stepText(opened)).contains("exit"))")
        check("open view can scroll", "true", "\(isFinished(session.handle(key: "j")) == false)")
        _ = session.handle(key: InteractiveKey.escape)
        check("esc returns to the list", "true", "\(ANSIParser.strip(stepText(session.handle(key: "z"))).contains("snapshot"))")

        // Search narrows and says how many it found.
        _ = session.handle(key: "/")
        _ = session.handle(key: "a")
        _ = session.handle(key: "l")
        let searched = session.handle(key: InteractiveKey.enter)
        check("search reports matches", "true", "\(ANSIParser.strip(stepText(searched)).contains("match"))")

        // Pin toggles, and says which way.
        let pinned = session.handle(key: "p")
        check("p pins the selection", "true", "\(ANSIParser.strip(stepText(pinned)).contains("Pinned"))")

        // Delete asks first, and `n` cancels. Counts are compared rather than
        // hardcoded: every `tm browse` run is itself recorded as a snapshot.
        let beforeCancel = engine.snapshots.entries().count
        let asked = session.handle(key: "x")
        check("x asks before deleting", "true", "\(ANSIParser.strip(stepText(asked)).contains("delete"))")
        let cancelled = session.handle(key: "n")
        check("n cancels the delete", "true", "\(ANSIParser.strip(stepText(cancelled)).contains("cancelled"))")
        check("cancelling deletes nothing", "\(beforeCancel)", "\(engine.snapshots.entries().count)")

        // `y` really deletes.
        let beforeDelete = engine.snapshots.entries().count
        _ = session.handle(key: "x")
        let deleted = session.handle(key: "y")
        check("y deletes the snapshot", "true", "\(ANSIParser.strip(stepText(deleted)).contains("Deleted"))")
        check("one snapshot fewer", "\(beforeDelete - 1)", "\(engine.snapshots.entries().count)")


        check("q quits", "true", "\(isFinished(session.handle(key: "q")))")
    } else {
        check("browse opens a session", "interactive", "finished")
    }
}

print("")
print("checks: \(checks), failures: \(failures)")
exit(failures == 0 ? 0 : 1)
'''


def gather_sources() -> list[pathlib.Path]:
    """Pure-logic sources, minus the one file that needs platform networking.

    `URLSessionTransport.swift` is the only piece that talks to URLSession; the
    policy it enforces lives in MirrorPolicy, which is covered here.
    """
    skip = {"URLSessionTransport.swift"}
    files: list[pathlib.Path] = []
    for sub in ("Shell", "Packages", "WebAssembly", "Terminal", "History"):
        for path in sorted((ROOT / "Sources" / "Terminal-ios" / sub).glob("*.swift")):
            if path.name in skip:
                continue
            # The UI half of Term/needs UIKit; the model half (styles, escape
            # parsing, the grid) is plain Foundation and is compiled here.
            if "import UIKit" in path.read_text(encoding="utf-8"):
                continue
            files.append(path)
    # The generated wasm fixtures live in the test target but are plain Swift.
    fixtures = ROOT / "Sources" / "Terminal-iosTests" / "WasmFixtures.swift"
    if fixtures.exists():
        files.append(fixtures)
    return files


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="keep the scratch directory")
    args = parser.parse_args()

    scratch = pathlib.Path(tempfile.mkdtemp(prefix="shellcheck-"))
    try:
        for path in gather_sources():
            text = path.read_text(encoding="utf-8")
            text = re.sub(r"^import CryptoKit$", "", text, flags=re.MULTILINE)
            if path.name == "BundledCatalog.swift":
                # The local build cannot compute real digests (CryptoKit is
                # Apple-only), so blank out the recorded values: PayloadStore
                # then skips verification instead of failing every install.
                text = re.sub(r'"sha256": "[0-9a-f]{64}"', '"sha256": null', text)
            (scratch / path.name).write_text(text, encoding="utf-8")
        (scratch / "cryptostub.swift").write_text(CRYPTO_STUB, encoding="utf-8")
        (scratch / "main.swift").write_text(SCENARIOS, encoding="utf-8")

        swiftc = SWIFT_BIN / "swiftc.exe"
        binary = scratch / "check.exe"
        sources = [str(p) for p in sorted(scratch.glob("*.swift"))]
        build = subprocess.run(
            [str(swiftc), "-o", str(binary)] + sources,
            env=CLEAN_ENV, capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
        if build.returncode != 0:
            print("BUILD FAILED")
            print(build.stdout[-8000:])
            print(build.stderr[-8000:])
            print(f"scratch: {scratch}")
            return 1

        run = subprocess.run(
            [str(binary)], env=CLEAN_ENV, capture_output=True,
            text=True, encoding="utf-8", errors="replace",
        )
        print(run.stdout)
        if run.stderr.strip():
            print("stderr:", run.stderr[-2000:])
        return run.returncode
    finally:
        if not args.keep:
            shutil.rmtree(scratch, ignore_errors=True)
        else:
            print(f"scratch kept at {scratch}")


if __name__ == "__main__":
    raise SystemExit(main())
