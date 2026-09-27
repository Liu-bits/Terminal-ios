// Copyright © 2026 Liu-bits. All rights reserved.

import Foundation

/// In-memory shell environment: working directory plus variables.
struct ShellEnvironment {
    /// Sandbox root the shell may never escape (default: app documents).
    var root: URL
    /// Current directory, always inside `root`.
    var currentDirectory: URL
    /// Shell variables used for `$VAR` expansion.
    var variables: [String: String]

    init(
        root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        variables: [String: String] = [:]
    ) {
        self.root = root.standardizedFileURL
        self.currentDirectory = self.root
        self.variables = variables
    }

    /// Whether commands should emit ANSI colour.
    ///
    /// Follows the two conventions tools already implement: `NO_COLOR` (present
    /// at all) wins, `CLICOLOR` switches colour on unless it is exactly `0`.
    /// The app exports `CLICOLOR=1`; nothing else does, so captured output
    /// stays plain by default.
    var colorEnabled: Bool {
        if variables.index(forKey: "NO_COLOR") != nil {
            return false
        }
        guard let value = variables["CLICOLOR"] else {
            return false
        }
        return value != "0"
    }

    /// Expands `$VAR` and `${VAR}` in a word. `$$` stays literal.
    ///
    /// The special single-character forms `$?`, `$#`, `$@` and `$$` are
    /// resolved from the same variable table, which the session keeps filled
    /// (`$?` is the last exit status, `$#`/`$@` the positional parameters).
    func expand(_ word: String) -> String {
        var result = ""
        var index = word.startIndex
        while index < word.endIndex {
            let char = word[index]
            // Single quotes survive tokenizing precisely so that this pass can
            // see them: POSIX says nothing inside them expands, so `$p` and
            // `$(cmd)` must come through as written. A lone `'` (one that came
            // from inside double quotes, e.g. `"it's"`) has no partner and is
            // copied literally.
            if char == "'", let close = word[word.index(after: index)...].firstIndex(of: "'") {
                result += word[word.index(after: index)..<close]
                index = word.index(after: close)
                continue
            }
            guard char == "$" else {
                result.append(char)
                index = word.index(after: index)
                continue
            }
            let next = word.index(after: index)
            guard next < word.endIndex else {
                result.append(char)
                index = next
                continue
            }
            if word[next] == "$" {
                result.append("$$")
                index = word.index(after: next)
                continue
            }
            if word[next] == "?" || word[next] == "#" || word[next] == "@" || word[next] == "*" {
                let name = word[next] == "*" ? "@" : String(word[next])
                result += variables[name] ?? ""
                index = word.index(after: next)
                continue
            }
            if word[next] == "{" {
                guard let close = word[next...].firstIndex(of: "}") else {
                    result.append(char)
                    index = next
                    continue
                }
                let name = String(word[word.index(after: next)..<close])
                result += variables[name] ?? ""
                index = word.index(after: close)
                continue
            }
            var end = next
            while end < word.endIndex, word[end].isLetter || word[end].isNumber || word[end] == "_" {
                end = word.index(after: end)
            }
            if end == next {
                result.append(char)
                index = next
                continue
            }
            let name = String(word[next..<end])
            result += variables[name] ?? ""
            index = end
        }
        return result
    }

    /// Resolves a path against the current directory.
    ///
    /// `~` expands to the sandbox root; a leading `/` is the sandbox root,
    /// not the host filesystem root. Returns `nil` when the path would escape
    /// the sandbox.
    func resolve(_ path: String) -> URL? {
        let expanded: String
        if path == "~" {
            expanded = root.path
        } else if path.hasPrefix("~/") {
            expanded = root.path + "/" + String(path.dropFirst(2))
        } else if path.hasPrefix("/") {
            // Sandbox-absolute: `/` means the root of the shell's world.
            expanded = root.path + path
        } else {
            expanded = currentDirectory.path + "/" + path
        }
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL
        let rootPath = root.path
        if candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") {
            return candidate
        }
        return nil
    }

    /// Changes directory. Returns the new path or `nil` on failure.
    ///
    /// A path that would escape the sandbox clamps to the root instead of
    /// failing, so `cd ..` at the top simply stays put.
    @discardableResult
    mutating func changeDirectory(_ path: String?) -> String? {
        let target: URL
        if let path, !path.isEmpty {
            target = resolve(path) ?? root
        } else {
            target = root
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        currentDirectory = target
        return target.path
    }

    /// Display path with the sandbox root shortened to `~`.
    func displayPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == root.path {
            return "~"
        }
        if path.hasPrefix(root.path + "/") {
            return "~" + path.dropFirst(root.path.count)
        }
        return path
    }
}
