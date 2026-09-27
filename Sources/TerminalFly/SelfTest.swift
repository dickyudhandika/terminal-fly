import Foundation
import SwiftTerm

/// Headless end-to-end check of the shell launch path.
///
/// Run with `TerminalFly --selftest`. It spawns the *same* `ShellConfiguration`
/// the panel uses (login shell, same environment) inside a real PTY, sends a
/// command, and asserts the output came back through the terminal emulator. This
/// is what proves Step 2 works: PTY fork + shell + VT parsing, without needing
/// to drive the GUI.
enum SelfTest {
    static func run() -> Int32 {
        let configuration = ShellConfiguration.default()
        print("selftest: shell=\(configuration.executable) args=\(configuration.arguments)")
        print("selftest: cwd=\(configuration.workingDirectory ?? "-")")

        let marker = "TERMINALFLY_SELFTEST_OK"
        let done = DispatchSemaphore(value: 0)
        var captured = ""
        var exitCode: Int32? = nil
        let lock = NSLock()

        let terminal = HeadlessTerminal(
            queue: DispatchQueue(label: "terminalfly.selftest"),
            options: TerminalOptions.default,
            directDelivery: true,
            onLaunchFailure: { error in
                print("selftest: LAUNCH FAILED: \(error)")
                done.signal()
            },
            onEnd: { code in
                lock.lock(); exitCode = code; lock.unlock()
                done.signal()
            }
        )

        terminal.process.startProcess(
            executable: configuration.executable,
            args: configuration.arguments,
            environment: configuration.environment(),
            execName: "-" + (configuration.executable as NSString).lastPathComponent,
            currentDirectory: configuration.workingDirectory
        )

        // Give the shell a moment to source its profile, then run and exit.
        Thread.sleep(forTimeInterval: 1.5)
        terminal.process.send(data: ArraySlice(Array("echo \(marker); exit 0\r".utf8)))

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            lock.lock(); let finished = exitCode != nil; lock.unlock()
            if finished { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if exitCode == nil {
            terminal.process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
        }

        captured = bufferText(terminal.terminal)
        lock.lock(); let code = exitCode; lock.unlock()

        print("selftest: child exit code = \(code.map(String.init) ?? "nil (killed)")")
        print("selftest: --- terminal buffer ---")
        print(captured)
        print("selftest: -----------------------")

        guard captured.contains(marker) else {
            print("selftest: FAIL — marker '\(marker)' not found in terminal buffer")
            return 1
        }
        guard code == 0 else {
            print("selftest: FAIL — expected exit code 0, got \(code.map(String.init) ?? "nil")")
            return 1
        }
        print("selftest: PASS — shell spawned, command echoed, output parsed by SwiftTerm")
        return 0
    }

    /// Reads the visible screen out of the emulator. SwiftTerm has no single
    /// "get everything" accessor on the public surface, so we walk the lines.
    private static func bufferText(_ terminal: Terminal) -> String {
        var out = ""
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            var text = ""
            for col in 0..<terminal.cols {
                text += terminal.getText(col: col, row: row) ?? " "
            }
            out += text.trimmingCharacters(in: .whitespaces) == "" ? "\n" : text + "\n"
            _ = line
        }
        return out
    }
}
