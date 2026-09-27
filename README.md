# Terminal-ios (TimeShell)

An offline iOS terminal app.

## License — read-only, all rights reserved

> **This repository is source-available only. It is NOT open source.**
>
> You may **view and study** the code, but you may **not** modify it, use it
> commercially, or redistribute it (original or modified) in any form.
>
> See [LICENSE](LICENSE) for the full terms.

## What this is

TimeShell is a self-contained terminal for iOS: a shell core, a set of built-in
commands (`ls`, `grep`, `sed`, `awk`, `tar`, and more), a WASM interpreter, and a
Time Machine that records every command you run as a searchable snapshot.

## Building

The build pipeline (unit tests + an unsigned IPA) runs on GitHub Actions on the
`xcode-27` runner. See `.github/workflows/Terminal-ios.yaml`.
