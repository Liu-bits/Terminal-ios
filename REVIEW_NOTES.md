# App Store Review Notes

Use this text when filling the "Review Notes" field in App Store Connect, and
attach it to any appeal about Guideline 2.5.2.

---

## What this app is

Terminal-ios is a self-contained Linux-like terminal for iOS. It gives the user
a familiar command-line interface (a shell with pipes, redirection, variables
and scripts, plus a set of built-in commands such as `ls`, `grep`, `sed`, `awk`,
`tar`, `less` and an interactive editor) that runs entirely inside the app's
sandbox.

## Compliance with Guideline 2.5.2

The app is **fully self-contained**: every command the user can run is compiled
into the signed binary. There is no mechanism to download, install, or execute
code that changes the app's features.

- **No native code is downloaded or executed.** The app never downloads,
  installs, or runs Mach-O binaries, `.dylib`s, or native CLI tools. It does not
  use `fork`, `exec`, `posix_spawn`, JIT compilation, or `mmap(PROT_EXEC)`.
- **The shell is an interpreter baked into the app.** Commands are implemented
  in Swift and dispatched by an in-process table; a script is interpreted, not
  executed as native code.
- **No remote code importing.** The app does not provide a package manager that
  pulls code from the internet. There is no `apt`, `pip`, or equivalent that can
  install and run foreign executables.
- **Everything runs in the iOS sandbox**, with no private APIs and no extra
  entitlements. File access stays inside the app's container.

## Privacy

The app collects no user data, performs no tracking, and does not transmit any
personal information. See `PrivacyInfo.xcprivacy` for the privacy manifest.

## Precedent

This follows the same model as iSH Shell and a-Shell, which are live on the App
Store: an on-device interpreter for a familiar developer experience, with no
downloading or executing of native code.
