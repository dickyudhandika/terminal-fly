import Foundation

/// Assertion helpers. The app has no XCTest harness (Xcode.app is not
/// installed on this machine — see scripts/build.sh), so tests run as an
/// executable: `TerminalFly --test`. Exit code 0 means all assertions passed.
enum TestHarness {
    nonisolated(unsafe) private static var failures: [String] = []
    nonisolated(unsafe) private static var checks = 0
    nonisolated(unsafe) private static var group = ""

    static func group(_ name: String, _ body: () -> Void) {
        group = name
        print("\n== \(name) ==")
        body()
    }

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if condition {
            print("  ok   \(message)")
        } else {
            print("  FAIL \(message)")
            failures.append("[\(group)] \(message)")
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        expect(actual == expected, "\(message) — got \(actual), expected \(expected)")
    }

    static func finish() -> Int32 {
        print("\n----------------------------------------")
        if failures.isEmpty {
            print("PASS: \(checks) checks, 0 failures")
            return 0
        }
        print("FAIL: \(checks) checks, \(failures.count) failures")
        for failure in failures { print("  - \(failure)") }
        return 1
    }
}
