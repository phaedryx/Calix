//
//  CommandShortcutMenuPaletteAgreementTests.swift
//  CalixTests
//
//  Regression guard for the fix that gave the command palette and the
//  menu bar a single `CommandShortcut` source of truth (see
//  CommandShortcut.swift) instead of two hand-typed strings that merely
//  happened to agree. For every palette command that has a menu
//  counterpart, asserts the menu item's real `keyEquivalent` /
//  `keyEquivalentModifierMask` match the palette command's
//  `CommandShortcut` -- so a future literal re-introduced on only one
//  side fails here instead of drifting silently.
//

import XCTest
import AppKit
@testable import Calix

@MainActor
final class CommandShortcutMenuPaletteAgreementTests: XCTestCase {

    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if let submenu = item.submenu {
                return [item] + allItems(in: submenu)
            }
            return [item]
        }
    }

    private func makeController() -> CalixWindowController {
        let window = CalixWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        return CalixWindowController(window: window, windowSession: session, restoring: true)
    }

    /// Every (palette command id, menu item title) pair that shares one
    /// `CommandShortcut` between the two surfaces.
    private static let sharedBindings: [(paletteID: String, menuTitle: String)] = [
        ("tab.new", "New Tab"),
        ("tab.close", "Close Tab"),
        ("tab.next", "Select Next Tab"),
        ("tab.previous", "Select Previous Tab"),
        ("group.new", "New Group"),
        ("group.close", "Close Group"),
        ("group.next", "Next Group"),
        ("group.previous", "Previous Group"),
        ("view.sidebar", "Toggle Sidebar"),
        ("view.fullscreen", "Toggle Full Screen"),
        ("window.new", "New Window"),
        ("edit.find", "Find…"),
        ("edit.compose", "Compose Input"),
        ("tab.jumpToUnread", "Jump to Unread Tab"),
        ("session.attach", "Session Browser"),
    ]

    /// `view.fullscreen`'s menu item is wired to a `toggleFullScreen:`
    /// selector (CalixWindowController's own implementation, kept
    /// distinct from `NSWindow.toggleFullScreen(_:)` so AppKit doesn't
    /// rewrite the item's *title* -- see the comment at that call site).
    /// AppKit still recognizes the selector NAME as its standard
    /// full-screen action: the moment `NSApp.mainMenu` is assigned, it
    /// silently overwrites that one item's live
    /// `keyEquivalentModifierMask` to match System Settings > Keyboard >
    /// Keyboard Shortcuts' "Toggle full screen" binding, regardless of
    /// what the app set (confirmed by probing the mask immediately
    /// before/after that assignment -- unrelated to this fix and
    /// present before it too). `keyEquivalent` itself is untouched, so
    /// only the modifier-mask half of the check is skipped here.
    private static let modifierMaskOverriddenByAppKit: Set<String> = ["view.fullscreen"]

    func test_everySharedBinding_paletteAndMenuAgreeOnRealShortcut() throws {
        let controller = makeController()
        let paletteCommands = Dictionary(uniqueKeysWithValues: controller.commandRegistry.allCommands.map { ($0.id, $0) })

        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()
        let mainMenu = try XCTUnwrap(NSApp.mainMenu, "setupMainMenu must assign NSApp.mainMenu")
        let menuItems = allItems(in: mainMenu)

        for binding in Self.sharedBindings {
            let paletteCommand = try XCTUnwrap(
                paletteCommands[binding.paletteID],
                "expected a registered palette command with id \(binding.paletteID)"
            )
            let shortcut = try XCTUnwrap(
                paletteCommand.shortcut,
                "\(binding.paletteID) is declared as a shared binding but has no CommandShortcut"
            )
            let menuItem = try XCTUnwrap(
                menuItems.first(where: { $0.title == binding.menuTitle }),
                "expected a menu item titled \"\(binding.menuTitle)\""
            )

            XCTAssertEqual(menuItem.keyEquivalent, shortcut.key,
                           "\(binding.paletteID)'s palette shortcut and \"\(binding.menuTitle)\"'s menu key must match")

            guard !Self.modifierMaskOverriddenByAppKit.contains(binding.paletteID) else { continue }
            XCTAssertEqual(menuItem.keyEquivalentModifierMask, shortcut.modifiers,
                           "\(binding.paletteID)'s palette shortcut and \"\(binding.menuTitle)\"'s menu modifiers must match")
        }
    }
}
