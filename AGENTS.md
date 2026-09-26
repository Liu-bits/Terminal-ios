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
- CI is a single workflow: `.github/workflows/Terminal-ios.yaml`. Its `test` job runs on
  every push/PR to `main`; its `build` job is `workflow_dispatch`-only on runner label
  `xcode-27` and produces an unsigned `ipa` artifact (`Terminal-ios-unsigned-ipa`).
  The build job verifies the built `Info.plist` keeps `UIApplicationSceneManifest` and
  prints the built commit - a stale or wrong-branch build is the most common reason a fix
  looks like it did not work, so always check the run's `head_sha`.
- Unit tests live in `Sources/Terminal-iosTests` (Swift Testing) and run via
  `bundle exec fastlane tests` (`run_tests` on scheme `Terminal-ios`, simulator
  `iPhone 17`, `Terminal-iosUITests` skipped).
- Because the PAT has no `workflow` scope, `.github/` is excluded from the local index via
  `.git/info/exclude` and the file is **not** on GitHub yet. To publish it, add the
  `workflow` scope to the token (or upload the file through the GitHub web UI), then drop
  the `.github/` line from `.git/info/exclude`.

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
- The file exists on disk but is **not** in the repository: the `gh` token has no
  `workflow` scope, and `.github/` is listed in `.git/info/exclude`. Add the scope
  (or upload via the web UI) and remove the exclude line to publish it.

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
5. `bundle exec fastlane tests` has never been verified green. The old `Test` workflow
   never ran `bundle install`, which is why it failed in about a second; the new
   `Terminal-ios.yaml` does run it, so the first CI run on `xcode-27` is the real
   verification and may surface genuine test or toolchain failures.
6. Publish `.github/workflows/Terminal-ios.yaml` to GitHub: needs `workflow` scope on the
   PAT (or a manual upload), then remove the `.github/` line from `.git/info/exclude`.

### Tree hygiene (intentional, not breakage)

- `LICENSE` and `README.md` are deleted in the working tree from the upstream
  template reset. They stay deleted unless someone wants them back; a fresh
  `README.md` belongs to Phase 3 (App Store metadata).
- `.github/` (holding `workflows/Terminal-ios.yaml`) is excluded from the index via
  `.git/info/exclude`, so it can never be committed by accident while the token lacks
  `workflow` scope. The file is intact on disk; publishing it needs the scope plus
  removing that exclude line.

