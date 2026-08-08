// CommandShortcut.swift
// Calix
//
// The single source of truth for a command's real keyboard shortcut.
// AppDelegate's NSMenuItem (keyEquivalent/keyEquivalentModifierMask) and
// PaletteCommand's displayed label both read the same constant here,
// instead of each hand-typing a string that merely happens to agree with
// the other.

import AppKit

struct CommandShortcut: Sendable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    var display: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Cmd") }
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Opt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(key.uppercased())
        return parts.joined(separator: "+")
    }
}

extension CommandShortcut {
    static let newTab = CommandShortcut(key: "t", modifiers: [.command])
    static let closeTab = CommandShortcut(key: "w", modifiers: [.command])
    static let nextTab = CommandShortcut(key: "]", modifiers: [.command, .shift])
    static let previousTab = CommandShortcut(key: "[", modifiers: [.command, .shift])
    static let newGroup = CommandShortcut(key: "n", modifiers: [.control, .shift])
    static let closeGroup = CommandShortcut(key: "w", modifiers: [.control, .shift])
    static let nextGroup = CommandShortcut(key: "]", modifiers: [.control, .shift])
    static let previousGroup = CommandShortcut(key: "[", modifiers: [.control, .shift])
    static let toggleSidebar = CommandShortcut(key: "s", modifiers: [.command, .option])
    static let toggleFullScreen = CommandShortcut(key: "f", modifiers: [.command, .control])
    static let newWindow = CommandShortcut(key: "n", modifiers: [.command])
    static let findInTerminal = CommandShortcut(key: "f", modifiers: [.command])
    static let composeInput = CommandShortcut(key: "e", modifiers: [.command, .shift])
    static let jumpToUnreadTab = CommandShortcut(key: "u", modifiers: [.command, .shift])
    static let sessionBrowser = CommandShortcut(key: "b", modifiers: [.command, .shift])
}
