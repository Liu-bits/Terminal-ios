# AGENTS.md

Instructions for AI coding agents working in this repository.

## Project

- Native iOS app written in Swift/UIKit, built with **Xcode 27 / the iOS 27 SDK**.
- Deliberately minimal: the whole UI is a single dark terminal screen, see
  `Sources/Terminal-ios/Terminal/TerminalViewController.swift`.
- The app **must keep the UIKit scene life cycle**: `UIApplicationSceneManifest` in
  `Sources/Terminal-ios/Info.plist` plus `Sources/Terminal-ios/SceneDelegate.swift`.
  Apps built with the iOS 27 SDK that do not adopt scenes fail to launch
  (`_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`). Never remove these.
- The launch screen is required by the iOS 27 launch screen rule and lives in
  `Sources/Terminal-ios/Scenarios/Common/Base.lproj/LaunchScreen.storyboard`.
- Xcode project: `Sources/Terminal-ios.xcodeproj`. It uses file-system synchronized
  groups, so adding or deleting files on disk is enough, no manual project edits needed.

## Product direction: on-device Linux-like terminal (Terminal-ios)

- Goal: an App Store-compliant Linux-like terminal for iOS. Everything runs
  inside the iOS sandbox, with no accounts and no cloud of our own.
- **Updated 2026-09-26 (owner's decision): the app may use the network and may
  download packages - as long as the build still passes App Store review.** The
  exact line between "allowed" and "rejected" is in
  [Network policy](#network-policy-what-may-be-downloaded) below; read it before
  adding any fetch path. The short version: data and *interpreted source* are
  fine, native binaries and JIT are not, and every downloaded payload is
  digest-verified and user-initiated.
- `Terminal-ios` is both the repository name and the Xcode target/product name.
  Swift module name is `Terminal_ios` (Xcode replaces the hyphen); use
  `@testable import Terminal_ios` in tests.

### Compliance rules (non-negotiable)

App Store Review Guidelines 2.5.2 says, in full, that apps "should be
self-contained in their bundles, and may not download, install, or execute code
which introduces or changes features or functionality of the app, including
other apps". The rules below are how this project stays on the right side of it,
and they override any feature request that conflicts with them:

- **Never** download or execute native code: no Mach-O binaries, no `.dylib`,
  no native CLI tools, no JIT and no `mmap(PROT_EXEC)`. iOS cannot
  `fork`/`exec`/`posix_spawn` unsigned code anyway, and 2.5.2 forbids wrapping it.
- **Never** let a downloaded payload replace or extend the app's own logic; it
  may only be *interpreted* by interpreters already signed into the bundle
  (our shell, the bundled Python, the WASM engine in interpreter mode).
- **Always** treat downloaded packages as interpreted source or data:
  shell scripts, pure-Python wheels, WASM modules (interpreter only). Nothing
  that needs `dlopen`, code signing, or executable memory.
- **Always** verify content hashes before use (SHA-256, recorded in the
  manifest), pin the source to a fixed host + path prefix, and require the
  transport to be HTTPS with certificate validation. A payload that fails to
  verify is discarded, never executed.
- **Always** make fetching an explicit, visible user action (`apt update`,
  `pip install`, an install button) - never a silent background download at
  launch, and never at first run.
- No private APIs, no extra entitlements. File access stays inside the app
  sandbox.
- Compliance takes priority over convenience: if a package cannot be expressed
  as interpreted code, it does not ship.

Precedent this project relies on: iSH Shell (a Linux-like terminal with a
package manager) and Pyto / Pythonista (pip installing pure-Python packages on
device) are both live on the App Store. They all draw the same line - interpreted
code, no native code, no JIT - and none of them download Mach-O executables.

### Network policy: what may be downloaded

| Category | Allowed? | Notes |
| --- | --- | --- |
| Documents, images, text, data files | Yes | Ordinary data, no 2.5.2 question. |
| Shell scripts from our own catalog | Yes | Interpreted by our shell; digest-verified. |
| Pure-Python wheels (`py3-none-any`) | Yes | Interpreted by the bundled CPython; no `.so`/`.pyd` members. |
| WASM modules | Yes, carefully | Interpreter mode only; no JIT, no WASI sockets/process spawn. |
| Native binaries, `.dylib`, Mach-O, APK/DEB with native payloads | **No** | Rejected by 2.5.2. |
| Anything that needs `fork`/`exec`, JIT, or `PROT_EXEC` memory | **No** | Also blocked by iOS itself. |
| Remote code that changes app features (our own UI included) | **No** | Keep feature logic in the signed binary. |

Engineering rules that follow from the table:

1. One pinned source by default, mirrors only on request. The bundled catalog is
   always on; mirrors ship **disabled** and are listed in `MirrorPolicy`. They
   can only be enabled by the user (`apt sources enable <id>` / `winget source
   enable`), and nothing is fetched until an explicit `apt refresh`.
2. The mirror allow-list is compiled into the binary: host **and** path prefix
   must match (`MirrorPolicy.allowedHosts`), the scheme must be `https`, and a
   source the user types in is validated before it is stored. Adding a mirror
   means shipping a build, not editing a config file.
3. Three mirrors ship for the same catalog (jsDelivr, GitHub raw, project
   pages) so a blocked host has a fallback, in priority order.
4. Manifest model is shared by both sources: name, version, kind, provides,
   payload, sha256, source, license, plus winget's id/publisher/tags. Remote
   entries **must** carry a 64-hex SHA-256 and a `script`/`wheel`/`wasm` kind -
   `MirrorPolicy.validate` refuses anything else before a byte is downloaded.
5. Downloads are size-capped (2 MB manifests, 32 MB payloads), cached under
   `<sandbox>/.packages/cache`, and every payload is digest-verified again
   before it is written - a mismatch is discarded, never executed.
6. Tests never require the network: `ManifestTransport` is injected
   (`ManifestTransportFactory.shared`), and the tests use `StubTransport`.
   `URLSessionTransport` is the only file that touches URLSession.

### Architecture phases

- Phase 0, shell core: UIKit terminal view, accessory key bar, built-in shell
  with pipes/redirection/env vars, then scripts and the coreutils surface.
  Status: **shell side done, one UI refactor open.** The engine dispatches
  through a built-in table (~120 commands across file/text/system groups) and
  supports `$(...)`, `$?`/`$#`/`$1`, assignments, `if`/`elif`/`else`, `for`,
  `while`/`until`, functions, comments and `sh file.sh`. ANSI SGR colour renders
  through the grid model in `Terminal/` (see below). Open: splitting the view
  into `TerminalTextView` + `AccessoryKeyBar`.
- Phase 1, Time Machine history (the differentiator): persist every execution to
  local SQLite as a structured snapshot (command + argv, cwd, env, full
  stdout/stderr, exit code, duration). UI offers a snapshot card stream,
  full-text search, re-enter, replay-with-edits, copy-output, pin-to-action
  cards, and text export.
- Phase 2, runtimes + catalogs: **catalog and package-manager surface landed**
  (`apt`/`apt-get`/`apk`/`pip` over the bundled `Catalog`, digest-verified
  payloads, install/remove/list/search/show/update/sources). Still to build: the
  bundled WASM engine, the CPython-for-WASM payload (`python3`/`py`/`pip`), the
  MinGW-style toolchain targeting WASM (`gcc`/`cc`/`clang`/`make`), and the
  remote manifest fetcher described above.
- Phase 3, release hardening: saved workspaces, IPA bundle-size and startup-time
  budgets, App Store metadata plus review notes that spell out the
  interpreted-code/no-JIT design and point at the iSH/Pyto precedent.

### Engineering constraints for this direction

- UI stays UIKit/Swift; scene life cycle and launch screen rules above still apply.
- Unit tests must run offline in the CI simulator; never require network in tests.
- Track IPA size every release: catalogs and runtimes grow the bundle, so budget it.
- Every downloaded payload is digest-verified before execution, and the
  verification lives in `PayloadStore` - do not bypass it.

## Terminal-ios project structure and needs (target state)

- Theme: dark phosphor-on-black terminal. Monospace text (`Menlo`/`SF Mono`), a
  persistent scrollback, a command input line with a blinking caret, ANSI color
  rendering, and Dynamic Type support; VoiceOver must read new output lines.
- Source tree (all code is UIKit/Swift, no third-party packages):
  - `Sources/Terminal-ios/Terminal/` - the screen, split in two halves:
    - model half (plain Foundation, compiled by `support/local_check.py`):
      `TerminalStyle` + `ANSIParser` (SGR and escape scanning), `TerminalWidth`
      (East Asian widths), `TerminalScreen` (grid, cursor, scrollback),
      `TerminalOutput` (what the view controller holds)
    - UI half (UIKit, CI only): `TerminalViewController`, and the still-to-do
      `TerminalTextView` (rendering + scrollback), `AccessoryKeyBar`
      (`Ctrl`/`Esc`/`Tab`/`|`/`/`/`~`), `HistoryCardCell` snapshot card stream.
  - `Sources/Terminal-ios/Shell/` - pure-logic shell core, no UIKit import:
    - `ShellTokenizer`, `ShellParser`, `ShellEnvironment` - words, quoting,
      `$VAR`/`$?`/`$#`/`$1`, pipes, redirection, `&&`/`||`/`;`
    - `ShellEngine` - dispatch, pipelines, `$(...)` substitution, assignments,
      function calls, script execution; the only type that owns session state
    - `ShellBuiltin` - `ShellRunContext` (what a command may touch), `ShellArgs`
      flag/operand parser, shared file helpers
    - `BuiltinsFile` / `BuiltinsText` / `BuiltinsSystem` - the command surface
    - `TextSed` - the `sed` program, kept apart from the built-in that drives
      it because splitting a script into commands (ignoring `;` inside an
      `s///` body or a regex address) is the easy part to get wrong
    - `ShellBuiltins` - the merged command table plus `help` text
    - `ShellScriptParser` / `ShellScriptRunner` - `if`/`elif`/`else`, `for`,
      `while`/`until`, functions, comments, continuations, `exit`
    - 100% unit-testable in CI; no device, no network.
  - `Sources/Terminal-ios/Packages/` - the package layer:
    - `Catalog` - manifest model plus `PayloadStore`, which verifies every
      payload's SHA-256 before it is used
    - `SourcePolicy` - `CatalogSource`, the compiled-in mirror allow-list
      (`MirrorPolicy`), and `SourceRegistry` (which sources exist and which are
      enabled)
    - `ManifestFetcher` - `ManifestTransport` protocol, `StubTransport` for
      tests, `ManifestTransportFactory`, and `CatalogFetcher` which applies the
      policy to manifests and payloads
    - `URLSessionTransport.swift` - the only file that uses URLSession; excluded
      from the local check runner
    - `PackageManager` - install/remove/list/search/show/update/refresh/sources
      over every enabled source, in priority order
    - `BundledCatalog.swift` - **generated** by `support/generate_catalog.py`
  - `Sources/Terminal-ios/WebAssembly/` - the interpreter (L2):
    - `WasmModule` - binary parser: sections, types, imports, exports, globals,
      data/element segments, and the LEB128 reader
    - `WasmInstruction` - decodes a function body once, resolving
      `if`/`else`/`end` pairings so the executor jumps by instruction index
    - `WasmInstance` - the stack machine: control flow, memory, tables, the
      numeric instruction set, plus budgets (instructions, memory pages, call
      depth)
    - `WasmWASI` - the WASI subset (`fd_write`/`fd_read`, args, environ, clock,
      random, `proc_exit`) and nothing else
    - `WasmRuntime` - parse + run entry points and `wasm info` summaries
  - `Sources/Terminal-ios/History/` - Time Machine snapshot store: local SQLite
    (command + argv, cwd, env, full stdout/stderr, exit code, duration),
    full-text search, re-enter (restore cwd/env), replay-with-edits,
    copy-output, pin-to-action cards, plain-text export. No SwiftData, no CloudKit.
  - `catalog/` (repo root, outside the Xcode target) - the package source of
    truth: `catalog.json` (manifest, sha256 filled in by the generator) and
    `payloads/*.sh`. Keeping it out of `Sources/` means the Xcode
    file-system-synchronized group never sees raw `.sh`/`.json` files.
  - `Sources/Terminal-iosTests/` - Swift Testing suites: `ShellEngineTests`,
    `ShellParserTests`, `ShellTokenizerTests`, `BuiltinsTests`,
    `ShellScriptTests`, `PackageManagerTests`, `TerminalScreenTests`,
    `WebAssemblyTests`, `PowerShellTests`, `SourcePolicyTests`,
    `TerminalViewControllerTests`.
- Needs for Phase 2 (in progress): the bundled WASM interpreter
  (interpreter-mode only, no JIT), the CPython-for-WASM payload behind
  `python3`/`pip`, and the MinGW-style toolchain that targets WASM.
- Naming: the Xcode target/product, the bundle display name, and the repository
  are all `Terminal-ios`. Bundle identifiers are `com.liu.Terminal-ios[Tests|UITests]`;
  change the `com.liu` prefix if a different team prefix is required.

### Shell quoting rules (load bearing)

- A single-quoted run is **literal**: nothing inside expands, neither `$VAR`
  nor `$(command)`. `ShellTokenizer` keeps the quotes in the word so
  `ShellEnvironment.expand` can see them, and the engine drops them on the
  way out. An unpaired `'` - only reachable from inside double quotes, as in
  `"it's"` - is copied literally instead of swallowing the rest of the word.
- Double quotes allow `$VAR` and `$(...)`, and the tokenizer strips them.
- `$(...)` and backticks expand in `ShellEngine.interpolate` **before**
  parsing, and that pass already tracks both quote kinds. This is why `$p`
  written inside single quotes reaches `sed -n '$p'` intact.
- A bare `'` in the middle of a word is an unterminated quote: the line fails
  with a syntax error, exactly as in bash.

### Command surface (as built)

`help` prints the live table, so the count in this doc is only a sanity check:

- CI runs 11 Swift Testing suites (`ShellTokenizer`, `ShellParser`, `ShellEngine`,
  `Builtins`, `ShellScript`, `PackageManager`, `TerminalScreen`, `WebAssembly`,
  `PowerShell`, `SourcePolicy`, `TerminalViewController`, plus the placeholder UI
  test target). Run `support/local_check.py` before pushing: it catches most of what
  these suites catch, in 40 seconds instead of 12 minutes.

- **files** - `ls` (`-a -l -d`, `--color` with `auto`/`always`/`never`) `cat` (`-n`)
  `mkdir` (`-p`) `rmdir` `rm` (`-r -f`)
  `cp` (`-r -f`) `mv` `touch` `stat` `ln` (`-s`) `basename` `dirname` `realpath`
  `find` (`-name -type -maxdepth`) `tree` (`-L`) `du` `df` `chmod` (octal and
  `+x`-style) `file` `mktemp`
- **text** - `echo` (`-n -e`) `printf` `head` `tail` `wc` (`-l -w -c`)
  `grep` (`-ivnclrE`, `--color` with `auto`/`always`/`never`)
  `sed` (`-n`, `-E`/`-r`, `-e` repeated, addresses `N`, `$` or `/re/`, ranges
  `2,4` / `/a/,/b/` / `3,$`, `!` negation, `s///` with `g`/`p`/`N`/`I`, and
  `p`, `d`, `q`, `=`, `y///`)
  `sort` (`-nruf`) `uniq` (`-cdu`) `cut` (`-d -f -c`)
  `tr` (`-d -s`, ranges) `tee` (`-a`) `nl` `rev` `tac` `seq` `yes` `base64` (`-d`)
  `sha256sum` `sha1sum` `md5sum` `cksum` `diff` `strings`
- **system** - `whoami` `id` `uname` (`-a -m -s -r`) `hostname` `arch` `nproc`
  `date` (+strftime subset) `uptime` `sleep` `tty` `ps` `kill` `free`
  `env` `printenv` `unset` `set` `export` `read` `true` `false` `test` `[`
  `expr` `eval` `sh` `source` `.` `which` `type` `command` `help` `man` `version`
- **packages** - `apt` `apt-get` `apk` `pip` `pip3` `winget`; runtimes declared in the
  catalog: `python3` `python` `py` `gcc` `cc` `clang` `make`
- **wasm** - `wasm run <module.wasm> [args...]`, `wasm info <module.wasm>`,
  `wasm --version` (the bundled interpreter)
- **powershell** - `Get-Location` `Set-Location` `Get-ChildItem` `Get-Item`
  `Get-Content` `Set-Content` `Add-Content` `New-Item` `Remove-Item` `Copy-Item`
  `Move-Item` `Rename-Item` `Test-Path` `Get-PSDrive` `Get-Process` `Get-Command`
  `Get-Help` `Select-String` `Measure-Object` `Sort-Object` `Select-Object`
  `Where-Object` `Write-Output` `Write-Host` `Clear-Host` `Get-Date`
  `Start-Sleep`, with the usual aliases (`gci`, `gc`, `gl`, `sl`, `ni`, `ri`,
  `ci`, `mi`, `rn`, `sc`, `ac`, `gps`, `cls`). Cmdlets are case-insensitive and
  take PowerShell-style parameters (`-Path`, `-Recurse`, `-Filter`, `-Value`);
  `PSArgs` parses those, `ShellArgs` handles POSIX ones.
- **engine commands** - `cd` `pwd` `clear` `history` `exit`

### Offline catalog and package managers

- `catalog/catalog.json` is the only package source compiled into the app; the
  generator writes each payload's SHA-256 back into it, so the manifest is
  self-describing and reviewable. Entries also carry winget metadata (`id`,
  `publisher`, `tags`) so `winget search`/`show`/`list` have proper identifiers.
- `support/generate_catalog.py` embeds the manifest **and** every payload as
  Swift string literals (`BundledCatalog.swift`). Embedding beats bundle
  resources here: the unit tests run without an app bundle, and nothing depends
  on how Xcode treats `.sh`/`.json` files.
- Install flow: resolve entry across sources -> fetch (remote) or read the
  embedded payload (bundled) -> digest check -> materialise under
  `<sandbox>/.packages/prefix` -> write a shim per provided command under
  `<sandbox>/.packages/bin` -> record the name in
  `<sandbox>/.packages/installed.json`. `PackageManager.script(for:)` reads the
  payload back from the prefix, so bundled and mirror packages behave the same
  at run time.
- `apt list` shows `ii`/`un` marks with the source column, `apt show` prints the
  id, source, digest and license, `apt update` re-verifies installed payloads,
  `apt refresh` fetches the enabled mirrors' manifests, `apt sources
  list|enable|disable|add|remove` manages them. `apk` maps `add`/`del`/`info`
  onto the same operations. `winget` adds `search`/`show`/`install`/
  `uninstall`/`list`/`upgrade`/`source ...` on top.
- Entries with `"payload": null` (today `python-runtime`, `mingw-toolchain`) are
  *declared* runtimes: `apt install` reports that the payload is not bundled
  instead of pretending, and the shims say the same. Add `payload` + `sha256`
  when the WASM payloads land.

## Terminal model: escapes, colour, grid (Phase 0 tail)

The UI half is thin on purpose; everything that can be tested without a
simulator lives in `Sources/Terminal-ios/Terminal/` as plain Foundation code,
and `support/local_check.py` compiles it on Windows.

- `TerminalStyle` - one run's attributes (bold/dim/italic/underline/blink/
  reverse/hidden/strikethrough, plus foreground and background as
  `default` / `palette(0...255)` / `rgb`). `applying(sgr:)` folds an SGR
  parameter list in, `sgr` renders the style back out, and the xterm palette
  (0-15 named, 16-231 cube, 232-255 greys) resolves to RGB here.
- `ANSIParser` - one scanner gives three views of the same stream: `segments`
  (styled runs for the UI), `strip` (escape-free text for VoiceOver, width
  maths and tests) and `visibleWidth`. It handles CSI (with private markers and
  intermediates), OSC terminated by BEL or ST, DCS/PM/APC, and `ESC ( B`
  charset selection.
- `TerminalWidth` - East Asian widths, so a Chinese filename does not push
  `ls -l` out of alignment: CJK/Hangul/emoji are 2 columns, combining marks 0.
- `TerminalScreen` - a real grid, not a line buffer: cursor addressing
  (`A B C D E F G d H f`), erasing (`J K X P @`), line editing (`L M S T`),
  save/restore (`s u`), cursor visibility (`?25h/l`), the scrolling region
  (`CSI r`, with origin mode `?6h`), the alternate screen buffer (`?1049`/`?47`),
  wrapping, scrolling with scrollback, and wide cells that render once instead of
  leaving a gap.
  C0 controls are handled: `\r` overwrites, `\t` goes to the next multiple of
  eight, `\b` steps back, and `\n` behaves as CR+LF - the `ONLCR` translation a
  tty would normally do, which this grid has to do itself.
- Colours reach the view as `[[ANSISegment]]`; `TerminalViewController` maps
  them to `UIColor`. Palette 0 and 8 would be invisible on black, so they render
  as greys.
Two rules keep the grid honest:

- Scrollback only records a **full-screen** scroll. A band scroll (`CSI r` plus
  output) rotates rows that are still on screen, so filing them as history would
  duplicate them.
- Anything still unimplemented is recorded in `TerminalScreen.unsupported` with
  the sequence and a reason, instead of being silently dropped: right now that is
  reverse video (`?5h`), focus reporting (`?1004h`) and other modes the app does
  not act on. `less`/`vim` need `?1049` and `CSI r`, and both are implemented -
  what is still missing for them is a way for a command to *read keystrokes*,
  which the synchronous engine does not offer yet.

Colour policy for commands (`ColorPolicy`, shared by `ls` and `grep`):

| Request | Effect |
| ------- | ------ |
| *(none)* / `--color=auto` | colour when `CLICOLOR` is set and non-zero |
| `--color` / `--color=always` | colour regardless of the environment |
| `--color=never` | never |
| `NO_COLOR` set | wins over `CLICOLOR` for `auto` |

The app exports `CLICOLOR=1` (and `TERM=xterm-256color`) in
`TerminalViewController.viewDidLoad`, so the on-screen terminal is coloured
while `> file`, scripts and unit tests stay plain - the same rule as a desktop
shell. `ls` colours by type (directory blue bold, executable green bold, symlink
cyan, archive red, image magenta) and only the *name*, keeping the mode/size/
date columns aligned; `grep` highlights matches (bold red), file prefixes
(magenta) and line numbers (green), and never highlights `-v` output.

## WebAssembly engine (Phase 2 foundation)

The engine is what makes MinGW-style tools and CPython possible at all: it is a
**pure interpreter in Swift**, in-process, with no JIT, no `mmap(PROT_EXEC)` and
no way to call the OS. That is the only shape App Review accepts for "run code
that shipped with the app or arrived as a package".

Coverage and limits, as built:

- A trap worth knowing about, because it produced a wrong trap instead of a
  wrong value: `memory.size` and `memory.grow` each carry a reserved one-byte
  memory index. Not consuming that immediate makes the *next* byte decode as
  `unreachable`, so a `memory.size` body traps with "unreachable instruction
  executed". `WebAssemblyTests.memory` and the local checker's `wasm memory.size`
  scenarios both guard it now, and the fixture grew a `grow` export so the
  `memory.grow` path is covered too.
- Instructions: the MVP integer/float set, comparisons, conversions and
  sign-extension, control flow (`block`/`loop`/`if`/`else`/`br`/`br_if`/
  `br_table`/`return`/`call`/`call_indirect`), locals/globals, loads and stores
  of every width, `memory.size`/`memory.grow`, `memory.copy`/`memory.fill`,
  reference basics (`ref.null`/`ref.func`/`ref.is_null`).
- Not supported (fails loudly at parse or decode time, never silently): SIMD,
  threads/atomics, multi-value results, exception handling, tail calls, passive
  data segments, imported globals and imported memories. The error names the
  feature, e.g. `unsupported feature: multi-value results`.
- Safety budgets per call: 20 M instructions, 512 pages (32 MiB) of memory, 512
  nested calls. A module that loops forever or recurses without bound traps with
  a readable message instead of hanging the UI thread. `WasmInstance.Limits`
  shrinks these for tests.
- WASI is deliberately tiny: `fd_write`, `fd_read`, `fd_close`, `fd_seek`,
  `fd_fdstat_get`, `args_*`, `environ_*`, `clock_*`, `random_get`,
  `proc_exit`. There is **no** `path_open`, no sockets and no process spawning,
  so a downloaded module cannot read the user's files or reach the network;
  file descriptors are limited to stdout/stderr/stdin.
- Payload embedding: binary payloads are stored base64 in
  `BundledCatalog.swift` (`"encoding": "base64"`) and the digest is over the raw
  bytes, so `PayloadStore.bytes(for:)` verifies text and binary payloads the
  same way. `PayloadStore.text(for:)` refuses binary entries instead of
  returning mojibake.
- Fixtures: `support/wasm_fixtures.py` hand-assembles the test modules (LEB128
  encodings, block types, iovec layouts, data segments) and **validates each one
  with Node's WebAssembly implementation before writing it**. The Node results
  are recorded above each fixture in the generated
  `Sources/Terminal-iosTests/WasmFixtures.swift` and are exactly what the Swift
  tests assert. One fixture (`hello-wasm`) is also a real catalog payload, so
  `apt install hello-wasm` exercises the whole path end to end.

The tree below is what stays after this reset (scene life cycle, launch screen,
project, CI, tests) - everything else is deleted and rebuilt per the plan above.

```text
Sources/
  Terminal-ios/
    AppDelegate.swift          # minimal entry point (kept, rebranded header)
    SceneDelegate.swift        # scene life cycle, owns the window (load bearing)
    Info.plist                 # scene manifest + $(MARKETING_VERSION)/$(CURRENT_PROJECT_VERSION)
    Scenarios/Common/Base.lproj/LaunchScreen.storyboard
    Shell/                     # tokenizer, parser, engine, builtins, scripts
    Packages/                  # catalog, package manager, generated payloads
    Terminal/                  # TerminalViewController
  Terminal-ios.xcodeproj/      # file-system synchronized groups + schemes
  Terminal-iosTests/           # Swift Testing suites
  Terminal-iosUITests/         # placeholder UI test (Phase 0 replaces it)
  .swiftlint.yml
catalog/
  catalog.json                 # package manifest (sha256 filled by the generator)
  payloads/*.sh                # script payloads
support/
  generate_catalog.py          # regenerates BundledCatalog.swift
  push_via_api.py              # pushes main when `git push` cannot reach GitHub
```


## Git: always commit to `main`

- **Every git commit must be committed to `main`.** Work on `main`, do not create
  feature branches, and never leave work uncommitted: a task is only finished when its
  changes are committed **and pushed** to `main`.
- If changes ever live on another branch, merge that branch into `main` (prefer
  `--ff-only`) and push `main`.
- Remote: `origin` = <https://github.com/Liu-bits/Terminal-ios.git> (owner `Liu-bits`).
  The repository is **private**. It was renamed from `ios-example` on GitHub, so
  run `git remote set-url origin https://github.com/Liu-bits/Terminal-ios.git`
  on any clone that still points at the old name.
- Never force-push and never rewrite the published history of `main`.
- Commit messages follow conventional commits, e.g. `fix:`, `chore:`, `docs:`.

### Pushing from this machine

`git push` over HTTPS does **not** work from this machine. Observed on 2026-09-26, all
three ways fail:

- direct `https://github.com` : `Failed to connect to github.com:443` (blocked);
- through the local proxy `127.0.0.1:18081` with the default schannel backend: the
  connection stalls right after `schannel: renegotiating SSL/TLS connection`, forever;
- same proxy with `-c http.sslBackend=openssl`: handshake succeeds but the upload dies
  with `send-pack: unexpected disconnect while reading sideband packet`.

The global `~/.gitconfig` additionally rewrites every `https://` remote to the read-only
`gitclone.com` mirror, so a plain `git push` fails with HTTP 502 before it even starts.
Beware: `env -u http_proxy ... <cmd>` is silently swallowed in this sandbox (no output,
exit 0, command never runs) - override with `http_proxy= https_proxy= <cmd>` instead.

**Working method: write the commit through the GitHub Git Data API.** `gh` is
authenticated (`Liu-bits`, token scopes `repo`, `write:org`) and its API path is
reachable, so push a tree without any git transport:

1. `gh api --method POST repos/Liu-bits/Terminal-ios/git/blobs` per file
   (`{"content": base64, "encoding": "base64"}`, taken from `git cat-file blob <sha>`);
2. `.../git/trees` with those blob entries (`mode` `100644` or `100755`);
3. `.../git/commits` with `tree`, `parents`, and explicit `author` / `committer`
   (`name`, `email`, `date`);
4. `gh api --method PATCH repos/Liu-bits/Terminal-ios/git/refs/heads/main -f sha=<commit> -F force=true`.

To keep local and remote identical (so later `git push` is a plain fast-forward), the
commit object must match **byte for byte**. Two traps, both learned the hard way:

- **The message has no trailing newline.** GitHub stores the message verbatim; `git commit`
  always appends `\n`, so a commit made with `git commit` can never match. Build the object
  by hand instead: `printf '%s' '<message with no trailing newline>'` into a file, then
  `git hash-object -w -t commit --stdin` with the `tree` / `parent` / `author` / `committer`
  header lines, and point `main` at the result with `git update-ref`.
- **Dates must be UTC (`+0000`).** GitHub normalises any offset to `Z`, so a local
  `+0800` commit hashes differently. `git commit --amend --reset-author` with
  `GIT_AUTHOR_DATE=...T..:..:..+00:00` also works, but the hand-built object is simpler.

`support/push_via_api.py` does the upload and hard-fails if the tree or the commit hash
disagrees with the local ones, so a mismatch is caught before the ref moves. Commits
`049c6fca`, `c713c15` and `12eb82c` were all created that way and `main`, `origin/main`
and the GitHub ref are the same SHA.

Push with `git push` anyway if the network is fixed; the API route is the fallback, not a
preference. Verify the result with `gh api repos/Liu-bits/Terminal-ios/commits/main`.

## Build and test

- There is no Xcode toolchain locally (Windows), so changes are compiled by CI.
- **But the pure-logic layer can be built and run locally** - do this before pushing,
  it turns a 12-minute CI round trip into a 40-second loop:

  ```bash
  python support/local_check.py          # 267 scenarios, fails loudly on regressions
  ```

  It copies `Shell/`, `Packages/`, `WebAssembly/` and the model half of `Terminal/` into a
  scratch directory (any file containing `import UIKit` is skipped automatically), stubs
  CryptoKit (Apple-only, so the SHA-256 checks in `PayloadStore` are skipped there),
  compiles with the Windows Swift toolchain (6.4.0 under
  `%LOCALAPPDATA%\Programs\Swift`) and runs a scenario list covering built-ins, filters,
  files, scripts, package installs, the WASM interpreter, and the ANSI/grid model. Two
  environment requirements are handled inside the script: the ambient environment carries
  duplicate proxy variables that abort the Swift runtime, and `SDKROOT` has to point at the
  Windows SDK. Anything UIKit (the terminal view, VoiceOver) still needs CI.

  One rule is deliberately **not** local, because it needs a real execute bit: `ls --color`
  painting an executable green is asserted only by the CI suite, on macOS.
- CI is a single workflow, `.github/workflows/Terminal-ios.yaml`, tracked in the repo
  (the `gh` token now carries the `workflow` scope; the old `.github/` exclude rule is
  gone). Its `test` job runs on every push/PR to `main`; its `build` job is
  `workflow_dispatch`-only on runner label `xcode-27` and produces an unsigned `ipa`
  artifact (`Terminal-ios-unsigned-ipa`). The build job verifies the built `Info.plist`
  keeps `UIApplicationSceneManifest` and prints the built commit - a stale or
  wrong-branch build is the most common reason a fix looks like it did not work, so
  always check the run's `head_sha`.
- Unit tests live in `Sources/Terminal-iosTests` (Swift Testing) and run via
  `bundle exec fastlane tests` (`run_tests` on scheme `Terminal-ios`, simulator
  `iPhone 17`, `Terminal-iosUITests` skipped).
- There is deliberately **no `Gemfile.lock`**. The old one pinned `BUNDLED WITH 2.1.4`
  (which crashes on Ruby 3.3) and `fastlane 2.211.0` (whose trainer still calls
  `xcresulttool get --format json`, removed in the Xcode 27 toolchain), so CI resolves
  the gems fresh on every run. The trade-off is unpinned gem versions: if a run breaks
  right after an unrelated fastlane release, suspect that first and consider re-adding a
  lock generated against the `xcode-27` image.
- Because the PAT has no `workflow` scope, `.github/` is excluded from the local index via
  `.git/info/exclude` and the file is **not** on GitHub yet. To publish it, add the
  `workflow` scope to the token (or upload the file through the GitHub web UI), then drop
  the `.github/` line from `.git/info/exclude`.

## Test device: iPhone 13 on iOS 27.0

The app is manually verified on a physical **iPhone 13 running iOS 27.0** (arm64; the
deployment target is 18.0). There is **no Mac and no Xcode** on this machine, so the phone
only consumes artifacts produced by CI:

- Builds come from the `build` job of `Terminal-ios.yaml` (`workflow_dispatch`) as an
  **unsigned `ipa`**; sign and install it locally with AltStore/Sideloadly and delete the
  previously installed app first.
- **Install an IPA built from the commit you want to test.** The build job reports the
  commit it compiled (`Record built commit`) and checks the produced `Info.plist` still
  carries `UIApplicationSceneManifest`; compare that against the commit you expect. A
  stale artifact is the most common reason a fix looks like it did not work.
- Unit and UI tests never run on the phone: they run in CI (`fastlane tests`, simulator
  `iPhone 17`). This machine cannot produce symbolicated device crash logs through Xcode.
- Read crash logs **on the phone**: Settings -> Privacy & Security -> Analytics &
  Improvements -> Analytics Data -> `Terminal-ios-<date>-<id>.ips` (enable "Share iPhone
  Analytics" first if the list stays empty).
- Device history: builds made with the iOS 27 SDK crashed on launch on this phone
  (`_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`) until the app adopted
  the scene life cycle - this is why `UIApplicationSceneManifest` in `Info.plist` and
  `SceneDelegate.swift` are load bearing and must never be removed.
- The Xcode project keeps the upstream author's `DEVELOPMENT_TEAM` (`S6EJ3ZVM4G`); CI
  builds are unsigned, so signing for the phone happens in the sideload tool.

## CI workflow (`.github/workflows/Terminal-ios.yaml`)

- One workflow, named `Terminal-ios`, replaces the old `test.yml` / `ios-build.yml` /
  `ios-share.yml` trio (the MobAI simulator-sharing flow is dropped).
- Triggers: `push` and `pull_request` on `main`, plus `workflow_dispatch` with a
  `configuration` input (`Debug` default, `Release` optional).
- `test` job: checkout, Xcode 27, Ruby 3.3, `gem install bundler` + `bundle install`,
  then `bundle exec fastlane tests`.
- `build` job: `needs: test`, `workflow_dispatch` only, builds an unsigned IPA with
  `CODE_SIGNING_ALLOWED=NO` for `generic/platform=iOS`, stages `build/Payload`,
  zips `Terminal-ios.ipa`, and uploads it as artifact `Terminal-ios-unsigned-ipa`
  (7-day retention).
- Both jobs run on the self-hosted label `xcode-27` with Xcode pinned to 27.0 via
  `maxim-lobanov/setup-xcode@v1`.
- Because `git push` is unusable here, the workflow was published through
  `support/push_via_api.py` once the token gained the `workflow` scope. If the scope is
  ever lost, the contents API still needs it; re-add it with
  `gh auth refresh -h github.com -s workflow` or by editing the PAT under
  GitHub -> Settings -> Developer settings -> Personal access tokens.

## Progress snapshot (2026-09-26, evening)

### Overall: Phase 0 shell + colour done (view split open), Phase 2 surface started, Phases 1/3 not started

| Phase | Scope | Status |
| ----- | ----- | ------ |
| 0 | Shell core + command surface + terminal UI | Shell done (~150 commands incl. cmdlets), ANSI colour + grid model done; only the view split is open |
| 1 | Time Machine history (SQLite) | Not started - `Sources/Terminal-ios/History/` does not exist |
| 2 | Runtimes + package catalogs | Catalog, mirrors, `apt`/`apk`/`pip`/`winget`, digest verification and the **WASM interpreter** landed; CPython and MinGW payloads still to build |
| 3 | Release hardening | Not started |

### What actually exists

```text
Sources/Terminal-ios/
  AppDelegate.swift, SceneDelegate.swift      # scene life cycle, load bearing
  Info.plist                                  # scene manifest + display name Terminal-ios
  Scenarios/Common/Base.lproj/LaunchScreen.storyboard
  Shell/                                      # no UIKit import
    ShellTokenizer.swift, ShellParser.swift, ShellEnvironment.swift
    ShellEngine.swift                         # dispatch, pipelines, $(), assignments
    ShellBuiltin.swift                        # context, flag parser, file helpers
    BuiltinsFile.swift, BuiltinsText.swift, BuiltinsSystem.swift
    ShellBuiltins.swift                       # command table + help text
    ShellScriptParser.swift, ShellScriptRunner.swift
  Packages/
    Catalog.swift                             # manifest + PayloadStore (sha256)
    PackageManager.swift                      # apt/apk/pip backend
    BundledCatalog.swift                      # GENERATED - do not edit
    SourcePolicy.swift, ManifestFetcher.swift    # mirror allow-list + fetch
    URLSessionTransport.swift                    # the only URLSession user
  Terminal/                                      # model half: no UIKit, CI + local_check
    TerminalStyle.swift, ANSIParser.swift, TerminalWidth.swift,
    TerminalScreen.swift, TerminalOutput.swift
    TerminalViewController.swift                 # UI half: UIKit, CI only
  WebAssembly/
    WasmModule.swift, WasmInstruction.swift, WasmInstance.swift,
    WasmWASI.swift, WasmRuntime.swift
Sources/Terminal-iosTests/
  ShellEngineTests, ShellParserTests, ShellTokenizerTests, BuiltinsTests,
  ShellScriptTests, PackageManagerTests, TerminalScreenTests, WebAssemblyTests,
  PowerShellTests, SourcePolicyTests, TerminalViewControllerTests, WasmFixtures
Sources/Terminal-iosUITests/AppUITests.swift
catalog/catalog.json + catalog/payloads/*             # package source of truth
support/generate_catalog.py                          # regenerates BundledCatalog.swift
support/wasm_fixtures.py                             # hand-assembled wasm, Node-validated
support/local_check.py                               # local build + scenario runner
support/push_via_api.py                              # push path when `git push` is blocked
```

### Open items, in the order they should be picked up

1. Split `TerminalViewController` into `TerminalTextView` (rendering +
   scrollback) and `AccessoryKeyBar`; the controller already mixes layout with
   execution. The screen model it draws is done and tested, so this is a straight
   refactor with no behaviour change.
2. Interactive commands: the grid now supports the alternate screen and the
   scrolling region, so `less`/`vim`-style tools are blocked only by the engine
   being synchronous. Adding an input channel (the UI feeds keys into a running
   command) is what unlocks a pager - do it before promising `less`.
3. Phase 2 core: the WASM interpreter landed (see the section above). Next is to
   make it complete enough for real payloads - build a CPython-for-WASM module,
   put it in the catalog, and fix whatever the interpreter turns out to be
   missing (threads and SIMD are out of scope; `dlopen` and `fork` are
   impossible here by design).
4. The remote manifest fetcher, once (3) exists: HTTPS + fixed host/path prefix,
   digest-verified, user-initiated only. Keep the injected-transport seam so the
   unit tests stay offline.
5. Decide the SQLite access layer (raw `sqlite3` vs a small wrapper - no SPM
   dependency) before Phase 1 starts.
6. `while read` loops are capped at 10000 iterations and `yes` prints a bounded
   number of lines; both are deliberate guards against locking the UI thread.
   Revisit if a real workload needs more.
7. Unknown-command UX: a command that resolves to neither a built-in, a shell
   function, an installed package nor a file prints `command not found` with
   exit 127. A `command-not-found` suggestion hook would be a nice touch.

### Tree hygiene (intentional, not breakage)

- `LICENSE` and `README.md` are deleted in the working tree from the upstream
  template reset. They stay deleted unless someone wants them back; a fresh
  `README.md` belongs to Phase 3 (App Store metadata).
- `.github/workflows/Terminal-ios.yaml` is tracked normally now that the token has the
  `workflow` scope. Do not re-add a `.github/` entry to `.git/info/exclude` unless the
  scope is lost again.
- The branch `archive/pre-rename-history` is deliberately kept as an archive: it still
  holds the pre-rename history (`iOSSampleApp` paths) and the three original workflow
  files (`ios-build.yml`, `ios-share.yml`, `test.yml`) that `Terminal-ios.yaml` replaced.
  It is never merged; read from it with `git show archive/pre-rename-history:<path>`.
- `BundledCatalog.swift` is generated. Edit `catalog/catalog.json` and
  `catalog/payloads/*`, then re-run `support/generate_catalog.py`; the script also
  writes the SHA-256 digests back into the manifest. A test fails if the digests
  and the embedded payloads ever drift apart.

### Tree hygiene (intentional, not breakage)

- `LICENSE` and `README.md` are deleted in the working tree from the upstream
  template reset. They stay deleted unless someone wants them back; a fresh
  `README.md` belongs to Phase 3 (App Store metadata).
- `.github/workflows/Terminal-ios.yaml` is tracked normally now that the token has the
  `workflow` scope. Do not re-add a `.github/` entry to `.git/info/exclude` unless the
  scope is lost again.
- The branch `archive/pre-rename-history` is deliberately kept as an archive: it still
  holds the pre-rename history (`iOSSampleApp` paths) and the three original workflow
  files (`ios-build.yml`, `ios-share.yml`, `test.yml`) that `Terminal-ios.yaml` replaced.
  It is never merged; read from it with `git show archive/pre-rename-history:<path>`.

