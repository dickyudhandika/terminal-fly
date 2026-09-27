import Foundation
import SwiftTerm

/// Describes how the shell inside the panel is launched.
///
/// The important detail is `-l`. When an app is launched from Finder or from the
/// menu bar it does NOT inherit the PATH that a terminal session would have —
/// `.zshrc` / `.zprofile` never run. Spawning a *login* shell is what makes
/// `node`, `pnpm`, `git` and friends resolve. This is the classic terminal-app
/// gotcha (plan Risk 6).
struct ShellConfiguration {
    var executable: String
    var arguments: [String]
    var workingDirectory: String?

    static func `default`() -> ShellConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let userShell = environment["SHELL"] ?? "/bin/zsh"
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        return ShellConfiguration(
            executable: FileManager.default.isExecutableFile(atPath: userShell) ? userShell : "/bin/zsh",
            // `-l` = login shell (sources profile, fixes PATH). `-i` is implied
            // by the PTY: the shell sees a terminal on stdin, so zsh reads
            // .zshrc interactively on its own.
            arguments: ["-l"],
            workingDirectory: home
        )
    }

    /// Environment for the child process. Starts from SwiftTerm's sane defaults
    /// (`TERM`, `COLORTERM`, `LANG`, ...) and pins `HOME`/`USER` so the login
    /// shell finds the right dotfiles.
    ///
    /// Note: SwiftTerm 1.20's `getEnvironmentVariables` emits `USER` twice (an
    /// upstream bug — the key appears twice in its source list). Duplicate keys
    /// make the child's environment ambiguous, so we de-duplicate here,
    /// last-wins, rather than inherit a non-deterministic block.
    func environment() -> [String] {
        var merged = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        let process = ProcessInfo.processInfo.environment
        if let home = process["HOME"] { merged.append("HOME=\(home)") }
        if let user = process["USER"] { merged.append("USER=\(user)") }
        merged.append("TERM_PROGRAM=TerminalFly")

        var ordered: [String] = []
        var indexByKey: [String: Int] = [:]
        for entry in merged {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[entry.startIndex..<separator])
            if let existing = indexByKey[key] {
                ordered[existing] = entry
            } else {
                indexByKey[key] = ordered.count
                ordered.append(entry)
            }
        }
        return ordered
    }
}
