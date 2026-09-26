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

## Product direction: offline on-device terminal (Terminal-ios)

- Goal: an App Store-compliant, fully offline Linux-like terminal for iOS. No
  downloads, no cloud, no accounts: every tool and package ships inside the app
  bundle and everything runs inside the iOS sandbox.
- `Terminal-ios` is both the repository name and the Xcode target/product name.
  Swift module name is `Terminal_ios` (Xcode replaces the hyphen); use
  `@testable import Terminal_ios` in tests.

### Compliance rules (non-negotiable, App Store Review Guidelines 2.5.2)

- Only code signed in the app bundle may execute. Never download executable code
  of any kind (no native binaries, no scripts, no package payloads from network).
- iOS forbids `fork`/`exec`/`posix_spawn` of unsigned code and forbids JIT in App
  Store builds, so all "processes" run in-process: built-in Swift command
  implementations, embedded interpreters, and a bundled WASM engine (interpreter
  mode, no JIT).
- A C toolchain with MinGW-style UX is allowed only if it compiles to WASM and
  runs in the bundled WASM engine - never native Mach-O. It is post-MVP; do not
  promise native `gcc` behavior.
- `pip`/`apt` are offline UX metaphors over curated catalogs compiled into the
  bundle (pure-Python wheels; prebuilt WASM/script modules). Package code must
  contain no network fetch path - offline by construction, not by flag.
- File access stays inside the app sandbox. No private APIs, no extra
  entitlements.

### Architecture phases

- Phase 0, shell core: UIKit terminal view (ANSI colors), mobile accessory key
  bar (`Ctrl`/`Esc`/`Tab`/`|`/`/`/`~`), built-in shell (`cd`, `ls`, `pwd`, `cat`,
  `echo`, `env`, `export`, `clear`, `history`) with pipes, redirection, and env
  vars - all in Swift, unit-testable in CI with no device and no network.
  Status: **mostly done, two gaps open** - tokenizer/parser/environment/engine
  landed with `Shell*Tests` (19 tests across 4 suites); all nine built-ins
  (`cd`, `ls`, `pwd`, `cat`, `echo`, `env`, `export`, `clear`, `history`) work,
  along with pipes, redirection and env vars. `TerminalViewController` wires the
  engine to a dark scrollback with an input row and an accessory key bar
  (`Tab`/`Esc`/`|`/`/`/`~`/`-`/`Ctrl+C`), Dynamic Type and VoiceOver
  announcements are in. Still open: **ANSI SGR color rendering** (output is
  currently a single green `UILabel`) and the split of the view into
  `TerminalTextView` + `AccessoryKeyBar`.
- Phase 1, Time Machine history (the differentiator): persist every execution to
  local SQLite as a structured snapshot (command + argv, cwd, env, full
  stdout/stderr, exit code, duration). UI offers a snapshot card stream,
  full-text search over commands and outputs, re-enter (restore cwd/env),
  replay-with-edits, copy-output, pin-to-action cards, and text export.
- Phase 2, runtimes + offline catalogs: embedded Python plus the bundled `pip` /
  `apt`-style catalogs described above.
- Phase 3, release hardening: saved workspaces, IPA bundle-size and startup-time
  budgets, App Store metadata and review notes explaining the sandbox /
  developer-tool compliance.

### Engineering constraints for this direction

- UI stays UIKit/Swift; scene life cycle and launch screen rules above still apply.
- Unit tests must run offline in the CI simulator; never require network in tests.
- Track IPA size every release: the offline catalog grows the bundle, so budget it.

## Terminal-ios project structure and needs (target state)

- Theme: dark phosphor-on-black terminal. Monospace text (`Menlo`/`SF Mono`), a
  persistent scrollback, a command input line with a blinking caret, ANSI color
  rendering, and Dynamic Type support; VoiceOver must read new output lines.
- Source tree (all new code is UIKit/Swift, offline only, no third-party packages):
  - `Sources/Terminal-ios/Terminal/` - UI: `TerminalViewController`,
    `TerminalTextView` (rendering + scrollback), `AccessoryKeyBar`
    (`Ctrl`/`Esc`/`Tab`/`|`/`/`/`~`), `HistoryCardCell` snapshot card stream.
  - `Sources/Terminal-ios/Shell/` - pure-logic shell core with no UIKit import:
    tokenizer/quoting, `$VAR` expansion, pipes (`|`), redirection (`>`, `>>`,
    `<`), `&&`/`||`/`;` chaining, plus built-ins (`cd`, `ls`, `pwd`, `cat`,
    `echo`, `env`, `export`, `clear`, `history`). 100% unit-testable in CI.
  - `Sources/Terminal-ios/History/` - Time Machine snapshot store: local SQLite
    (command + argv, cwd, env, full stdout/stderr, exit code, duration),
    full-text search, re-enter (restore cwd/env), replay-with-edits,
    copy-output, pin-to-action cards, plain-text export. No SwiftData, no CloudKit.
  - `Sources/Terminal-ios/Resources/` - offline catalogs compiled into the bundle
    (`python wheels`, `wasm modules`, `script modules`): manifests + payloads,
    content-hashed (`sha256`) and verified at load. No network fetch path anywhere.
  - `Sources/Terminal-iosTests/` - Swift Testing suites mirroring the above:
    `Shell*Tests`, `History*Tests`, `Terminal*Tests` (host-side render model only).
- Needs before Phase 0 starts: a bundled monospace font decision (system font vs
  bundled), the ANSI SGR subset to support, the SQLite access layer (raw
  `sqlite3` vs GRDB-style micro-wrapper - no external SPM dependency), and the
  `fastlane tests` lane passing on the cleaned tree.
- Needs for Phase 2: choose the embedded Python build and the WASM interpreter
  crate/version; both must be App Store-safe (no JIT, no dynamic download).
- Naming: the Xcode target/product, the bundle display name, and the repository
  are all `Terminal-ios`. Bundle identifiers are `com.liu.Terminal-ios[Tests|UITests]`;
  change the `com.liu` prefix if a different team prefix is required.

The tree below is what stays after this reset (scene life cycle, launch screen,
project, CI, tests) - everything else is deleted and rebuilt per the plan above.

```text
Sources/
  Terminal-ios/
    AppDelegate.swift          # minimal entry point (kept, rebranded header)
    SceneDelegate.swift        # scene life cycle, owns the window (load bearing)
    Info.plist                 # scene manifest + $(MARKETING_VERSION)/$(CURRENT_PROJECT_VERSION)
    Scenarios/Common/Base.lproj/LaunchScreen.storyboard
  Terminal-ios.xcodeproj/      # file-system synchronized groups + schemes
  Terminal-iosTests/           # placeholder VC tests (Phase 0 replaces them)
  Terminal-iosUITests/         # placeholder UI test (Phase 0 replaces it)
  .swiftlint.yml
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

`github.com:443` is not reachable directly here, and the global `~/.gitconfig` rewrites
every `https://` remote to the read-only `gitclone.com` mirror (a plain `git push` then
fails with HTTP 502). Push over the local proxy while bypassing the rewrite:

```powershell
$env:GIT_TERMINAL_PROMPT = '0'
$empty = Join-Path $env:TEMP 'empty-gitconfig'; Set-Content -Path $empty -Value '' -NoNewline
$env:GIT_CONFIG_GLOBAL = $empty
git -c credential.helper=manager -c http.proxy=http://127.0.0.1:18081 -c https.proxy=http://127.0.0.1:18081 push origin main
Remove-Item Env:\GIT_CONFIG_GLOBAL; Remove-Item $empty -Force
```

Always verify the result, for example:

```powershell
git -c credential.helper=manager -c http.proxy=http://127.0.0.1:18081 ls-remote origin refs/heads/main
```

The proxy `127.0.0.1:18081` and the cached GitHub credential for `Liu-bits` belong to
this machine; adjust them if the environment changes.

## Build and test

- There is no Xcode toolchain locally (Windows), so changes are compiled by CI.
- Builds run through the `iOS Build` workflow (`.github/workflows/ios-build.yml`,
  `workflow_dispatch`, runner label `xcode-27`) and produce an unsigned `ipa` artifact.
  Keep `snapshot_ref` empty and build the `main` branch.
- Unit tests live in `Sources/Terminal-iosTests` (Swift Testing) and are run by CI via
  `bundle exec fastlane tests` (`.github/workflows/test.yml`, triggered on push).
- The `Test` workflow is currently red for an unrelated reason: the job installs bundler
  but never runs `bundle install`, so `bundle exec fastlane tests` fails within a second.
  Check which step failed before assuming the code is broken.
- TODO: `iOS Build` does not verify the IPA it produced. Checking the built `Info.plist`
  for `UIApplicationSceneManifest` (and printing the built commit) would catch stale or
  wrong-branch builds before they reach the phone.
- Build versioning: `CFBundleShortVersionString` and `CFBundleVersion` in `Sources/Terminal-ios/Info.plist`
  are configured as `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)` so build numbers can
  be injected during CI build.

## Test device: iPhone 13 on iOS 27.0

The app is manually verified on a physical **iPhone 13 running iOS 27.0** (arm64; the
deployment target is 18.0). There is **no Mac and no Xcode** on this machine, so the phone
only consumes artifacts produced by CI:

- Builds come from the `iOS Build` workflow as an **unsigned `ipa`**; sign and install it
  locally with AltStore/Sideloadly and delete the previously installed app first.
- **Install an IPA built from the commit you want to test.** `workflow_dispatch` builds the
  branch selected in the UI while `snapshot_ref` is empty, so a build of `main` started
  before a fix was merged ships the old code - always check the run's `head_branch` /
  `head_sha` and download the artifact of that exact run. A stale build is the most common
  reason a fix looks like it did not work.
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

## CI workflows (stored outside the repo)

- GitHub Actions workflows are intentionally **not** in this working tree: no
  `.github/` directory exists here. The minimal recipes below are the canonical
  description of the CI.
- The full originals (`ios-build.yml`, `test.yml`, `ios-share.yml`) remain
  retrievable from git history, e.g. `git show HEAD:.github/workflows/test.yml`.
  The working-tree deletions are hidden from git with
  `git update-index --assume-unchanged` so they are never committed or pushed.
  Verify with `git ls-files -v | Select-String '^h'`.
- To restore CI: recreate `.github/workflows/` from the recipes below (or from
  git history), then run `git update-index --no-assume-unchanged` on the three
  workflow files.

### Minimal workflow recipes

All runners use label `xcode-27` with Xcode pinned to 27.0 via
`maxim-lobanov/setup-xcode@v1`. There is no Xcode locally (Windows), so these
are the only compile/test path.

#### test.yml - unit tests on push / PR

```yaml
name: Test

on: [push, pull_request]

jobs:
  job-test:
    name: Run unit tests (Xcode 27)
    runs-on: xcode-27
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode 27
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: '27.0'

      - name: Setup Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'

      - name: Install needed software
        run: |
          gem install xcpretty -N
          gem install bundler -N

      - name: Run unit tests
        run: bundle exec fastlane tests
```

`fastlane tests` runs `run_tests` on scheme `Terminal-ios`, device `iPhone 17`,
skipping `Terminal-iosUITests` (see `fastlane/Fastfile`).

#### ios-build.yml - unsigned IPA via workflow_dispatch

Manually triggered (`workflow_dispatch`, 30-minute timeout). Key inputs:
`build_id` (required), `snapshot_ref` (empty = build this branch),
`ios_path` (default `.`), `scheme` (auto-detected if empty), `use_signing`
(default `false`), `configuration` (default `Debug`). Flutter/Node/JDK/Gradle
setup steps only activate for non-native projects.

Native unsigned path (this repo): find `.xcodeproj`, derive the scheme from it
when empty, then:

```bash
xcodebuild -project <project> -scheme '<scheme>' \
  -configuration '<Debug|Release>' \
  -destination 'generic/platform=iOS' \
  -derivedDataPath '<DerivedData>' \
  COMPILER_INDEX_STORE_ENABLE=NO \
  DEBUG_INFORMATION_FORMAT=dwarf \
  ONLY_ACTIVE_ARCH=YES -quiet \
  SWIFT_ENABLE_COMPILE_CACHE=YES CLANG_ENABLE_COMPILE_CACHE=YES \
  CODE_SIGNING_ALLOWED=NO build
```

Then locate the `.app` via `xcodebuild -showBuildSettings -json` (fallback:
first `*.app` under `DerivedData/Build/Products/<config>-iphoneos`), copy it to
`build/Payload/`, `zip -rq "<build_id>.ipa" Payload`, and upload
`build/*.ipa` with `actions/upload-artifact@v7` (retention 7 days). Signing
steps (`Install certificate and provisioning profile`, archive + export with a
generated `ExportOptions.plist`, keychain cleanup) only run when
`use_signing: true`. DerivedData is cached per `github.run_id`.

#### ios-share.yml - simulator build shared to the MobAI app

Manually triggered (`workflow_dispatch`, 90-minute timeout). Same
`build_id`/`snapshot_ref`/`ios_path`/`scheme` inputs plus `duration`
(default `30m`). Boots a simulator via `MobAI-App/mobai-ci@v1`
(`$MOBAI_SIM_UDID`), builds Debug unsigned for that simulator:

```bash
xcodebuild <target> -scheme "<scheme>" -configuration Debug \
  -destination "id=$MOBAI_SIM_UDID" \
  -derivedDataPath "$GITHUB_WORKSPACE/DerivedData" \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
```

Then resolves the `.app` the same way as `ios-build.yml` and publishes it with
`mobai-ci share --device ... --app ... --duration ...` (needs the
`MOBAI_API_KEY` secret). This workflow is third-party specific; drop or rewrite
it if MobAI is no longer used.

## Progress snapshot (2026-09-26)

### Overall: Phase 0 ~85%, Phases 1-3 not started

| Phase | Scope | Status |
| ----- | ----- | ------ |
| 0 | Shell core + terminal UI | ~85% - two gaps open (ANSI colors, view split) |
| 1 | Time Machine history (SQLite) | Not started - `Sources/Terminal-ios/History/` does not exist |
| 2 | Embedded runtimes + offline catalogs | Not started - `Sources/Terminal-ios/Resources/` does not exist |
| 3 | Release hardening | Not started |

### What actually exists

```text
Sources/
  Terminal-ios/
    AppDelegate.swift
    SceneDelegate.swift                 # scene life cycle, load bearing
    Info.plist                          # scene manifest + display name Terminal-ios
    Scenarios/Common/Base.lproj/LaunchScreen.storyboard
    Shell/                              # 701 lines, no UIKit
      ShellTokenizer.swift  141
      ShellParser.swift     157
      ShellEnvironment.swift 129
      ShellEngine.swift     274
    Terminal/
      TerminalViewController.swift 199
  Terminal-ios.xcodeproj/            # scheme Terminal-ios, PRODUCT_MODULE_NAME Terminal_ios
  Terminal-iosTests/                 # 235 lines, 19 tests (Swift Testing)
  Terminal-iosUITests/               # placeholder UI test
  .swiftlint.yml
```

### Open items, in the order they should be picked up

1. ANSI SGR color rendering - output is a single green `UILabel`, so `\e[31m`
   and friends are currently dropped. This blocks any real `ls --color` or
   colored program output.
2. Split `TerminalViewController` into `TerminalTextView` (rendering +
   scrollback) and `AccessoryKeyBar`, per the target structure above. The view
   controller is already close to 200 lines and mixes layout with execution.
3. Decide the SQLite access layer (raw `sqlite3` vs a small wrapper - no SPM
   dependency) before Phase 1 starts.
4. Pick the bundled monospace font (system `Menlo`/`SF Mono` vs bundled); the
   ANSI subset to support depends on it.
5. `bundle exec fastlane tests` has never been verified green: the `Test`
   workflow installs bundler but never runs `bundle install`, so the job fails
   in about a second for a reason unrelated to the code.

### Tree hygiene (intentional, not breakage)

- `LICENSE` and `README.md` are deleted in the working tree from the upstream
  template reset. They stay deleted unless someone wants them back; a fresh
  `README.md` belongs to Phase 3 (App Store metadata).
- The three GitHub Actions workflow files are hidden from git with
  `git update-index --assume-unchanged`. They still exist on disk and in history,
  so nothing is lost - restore with `git update-index --no-assume-unchanged`.

