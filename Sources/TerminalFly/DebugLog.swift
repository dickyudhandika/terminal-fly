import Foundation

/// Append-only debug log at /tmp/terminalfly.log.
///
/// `NSLog` output does not reliably surface via `log show --predicate` for
/// ad-hoc-signed bundles launched with `open`, which makes headless verification
/// guesswork. A plain file is boring, always works, and is trivial to `tail`.
enum DebugLog {
    private static let url = URL(fileURLWithPath: "/tmp/terminalfly.log")

    static func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
