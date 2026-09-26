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

print("")
print("checks: \(checks), failures: \(failures)")
exit(failures == 0 ? 0 : 1)
'''


def gather_sources() -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for sub in ("Shell", "Packages"):
        files.extend(sorted((ROOT / "Sources" / "Terminal-ios" / sub).glob("*.swift")))
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
