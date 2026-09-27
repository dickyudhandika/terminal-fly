#!/usr/bin/env swift
// Dumps on-screen window info (owner, layer, bounds) for TerminalFly.
// Used to verify the panel really sits at the floating window level instead of
// taking a screenshot and eyeballing it.
import AppKit
import CoreGraphics
import Foundation

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("no window list"); exit(1)
}

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "TerminalFly"
var found = 0
for w in raw {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    guard owner.localizedCaseInsensitiveContains(target) else { continue }
    found += 1
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    let name = w[kCGWindowName as String] as? String ?? ""
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
    let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    print("owner=\(owner) name=\"\(name)\" layer=\(layer) alpha=\(alpha) onscreen=\(onScreen) bounds=\(bounds)")
}
if found == 0 { print("NO WINDOWS for \(target)"); exit(2) }
print("--- frontmost app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
