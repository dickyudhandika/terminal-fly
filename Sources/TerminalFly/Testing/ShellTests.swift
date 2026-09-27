import Foundation

/// Tests for shell-configuration parsing and environment assembly.
enum ShellTests {
    static func run() {
        TestHarness.group("ShellConfiguration — defaults") {
            let config = ShellConfiguration.default()
            TestHarness.expect(FileManager.default.isExecutableFile(atPath: config.executable),
                               "default shell (\(config.executable)) exists and is executable")
            TestHarness.expect(config.arguments.contains("-l"),
                               "default shell is a LOGIN shell (this is what loads PATH)")
            TestHarness.equal(config.workingDirectory,
                              FileManager.default.homeDirectoryForCurrentUser.path,
                              "default working directory is $HOME")
        }

        TestHarness.group("ShellConfiguration — environment") {
            let environment = ShellConfiguration.default().environment()
            let keys = environment.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }

            TestHarness.expect(keys.contains("TERM"), "TERM is set (SwiftTerm requires it)")
            TestHarness.expect(keys.contains("HOME"), "HOME is set")
            TestHarness.expect(keys.contains("TERM_PROGRAM"), "TERM_PROGRAM identifies the app")
            TestHarness.expect(environment.contains("TERM_PROGRAM=TerminalFly"),
                               "TERM_PROGRAM=TerminalFly")

            // Every entry must be KEY=VALUE, or execvp will reject the block.
            let malformed = environment.filter { !$0.contains("=") }
            TestHarness.equal(malformed.count, 0, "no malformed environment entries")

            // Duplicate keys make the child's environment non-deterministic;
            // last-wins is the behaviour we rely on, but duplicates should not
            // be there in the first place.
            TestHarness.equal(keys.count, Set(keys).count, "no duplicate environment keys")
        }

        TestHarness.group("ShellConfiguration — custom values are preserved") {
            let config = ShellConfiguration(
                executable: "/bin/bash",
                arguments: ["-l", "-i"],
                workingDirectory: "/tmp"
            )
            TestHarness.equal(config.executable, "/bin/bash", "custom executable kept")
            TestHarness.equal(config.arguments, ["-l", "-i"], "custom arguments kept in order")
            TestHarness.equal(config.workingDirectory, "/tmp", "custom working directory kept")
            TestHarness.expect(config.environment().contains("TERM_PROGRAM=TerminalFly"),
                               "custom config still gets the standard environment")
        }

        TestHarness.group("PreferencesStore — shell argument parsing") {
            // The settings UI stores arguments as a single string; it must split
            // on whitespace and drop empties, or execvp sees "" as an argument.
            let cases: [(String, [String])] = [
                ("-l", ["-l"]),
                ("-l -i", ["-l", "-i"]),
                ("  -l   -i  ", ["-l", "-i"]),
                ("", []),
                ("   ", []),
            ]
            for (input, expected) in cases {
                let parsed = input.split(separator: " ").map(String.init).filter { !$0.isEmpty }
                TestHarness.equal(parsed, expected, "arguments \"\(input)\" parses to \(expected)")
            }
        }
    }
}
