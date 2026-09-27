#!/usr/bin/env swift
// Posts a synthetic ⌃⌥P keypress so we can verify the global hotkey actually
// fires (panel hides) without a human at the keyboard.
//
// Requires Accessibility permission for the process that runs it. If the
// permission is missing, the events are posted but macOS drops them — check the
// exit code and the panel's visibility afterwards.
import AppKit
import Carbon.HIToolbox

let source = CGEventSource(stateID: .hidSystemState)

func post(keyCode: CGKeyCode) {
    let flags: CGEventFlags = [.maskControl, .maskAlternate]
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
        print("could not create events"); exit(1)
    }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    usleep(40_000)
    up.post(tap: .cghidEventTap)
}

let key: CGKeyCode
switch CommandLine.arguments.dropFirst().first ?? "p" {
case "c": key = CGKeyCode(kVK_ANSI_C)
case "up": key = CGKeyCode(kVK_UpArrow)
case "down": key = CGKeyCode(kVK_DownArrow)
default: key = CGKeyCode(kVK_ANSI_P)
}
print("posting ctrl+alt+\(CommandLine.arguments.dropFirst().first ?? "p")")
post(keyCode: key)
usleep(300_000)
print("posted")
