//
//  AppearanceAndLSPToggleWiringTests.swift
//  CalixTests
//
//  smoothScrolling (Appearance pane)/lspAutoInstall/lspRequireConfirmation
//  (LSP pane) were the ORIGINAL correctly-wired pattern -- built with a
//  local NSSwitch, seeded `.state`, and target/action all at construction
//  -- that the once-broken Sessions/Agents toggles (see
//  SettingsWindowControllerSessionsToggleWiringTests' header) should have
//  matched. They never had dedicated tests of their own, though, so
//  routing them through the shared sessionToggleInitialState(for:)/
//  toggleRow(...) mechanism (Settings-row-table consolidation) is pinned
//  here for the first time, same two-half split as the other toggle
//  wiring test files.
//
//  smoothScrolling reads/writes UserDefaults.standard directly (not a
//  *Settings type with its own test-suite seam), and LSPSettings does
//  the same (see LSPSettings.swift) -- both save/restore the real value
//  around each test rather than isolating into a throwaway suite.
//

import XCTest
import AppKit
@testable import Calix

@MainActor
final class AppearanceAndLSPToggleWiringTests: XCTestCase {

    // MARK: - (A) target/action wiring, via the real singleton's built view tree

    private func paneView(_ pane: SettingsPane) throws -> NSView {
        let tabViewController = try XCTUnwrap(
            SettingsWindowController.shared.window?.contentViewController as? NSTabViewController,
            "SettingsWindowController's window must host an NSTabViewController as its content"
        )
        let index = try XCTUnwrap(SettingsPane.allCases.firstIndex(of: pane))
        let tabItem = tabViewController.tabViewItems[index]
        return try XCTUnwrap(tabItem.viewController?.view, "The \(pane) tab item must host a real view controller")
    }

    private func findSwitch(identifier: String, in view: NSView) -> NSSwitch? {
        for subview in view.subviews {
            if let toggleSwitch = subview as? NSSwitch, toggleSwitch.accessibilityIdentifier() == identifier {
                return toggleSwitch
            }
            if let found = findSwitch(identifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    func test_smoothScrollingSwitch_existsWithTargetAndActionWired() throws {
        let toggleSwitch = try XCTUnwrap(
            findSwitch(identifier: AccessibilityID.Settings.smoothScrollingSwitch, in: try paneView(.appearance))
        )
        XCTAssertTrue(toggleSwitch.target === SettingsWindowController.shared)
        XCTAssertEqual(toggleSwitch.action, Selector(("smoothScrollDidChange:")))
    }

    func test_lspAutoInstallSwitch_existsWithTargetAndActionWired() throws {
        let toggleSwitch = try XCTUnwrap(
            findSwitch(identifier: AccessibilityID.Settings.lspAutoInstallSwitch, in: try paneView(.lsp))
        )
        XCTAssertTrue(toggleSwitch.target === SettingsWindowController.shared)
        XCTAssertEqual(toggleSwitch.action, Selector(("lspAutoInstallDidChange:")))
    }

    func test_lspRequireConfirmationSwitch_existsWithTargetAndActionWired() throws {
        let toggleSwitch = try XCTUnwrap(
            findSwitch(identifier: AccessibilityID.Settings.lspRequireConfirmationSwitch, in: try paneView(.lsp))
        )
        XCTAssertTrue(toggleSwitch.target === SettingsWindowController.shared)
        XCTAssertEqual(toggleSwitch.action, Selector(("lspRequireConfirmationDidChange:")))
    }

    // MARK: - (B) initial-state seeding, via the existing singleton-independent seam

    private var originalSmoothScroll: Bool?
    private var originalAutoInstall: Bool = false
    private var originalRequireConfirmation: Bool = false

    override func setUp() {
        super.setUp()
        originalSmoothScroll = UserDefaults.standard.object(forKey: "smoothScrollEnabled") as? Bool
        originalAutoInstall = LSPSettings.autoInstallEnabled
        originalRequireConfirmation = LSPSettings.requireInstallConfirmation
    }

    override func tearDown() {
        if let originalSmoothScroll {
            UserDefaults.standard.set(originalSmoothScroll, forKey: "smoothScrollEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "smoothScrollEnabled")
        }
        LSPSettings.autoInstallEnabled = originalAutoInstall
        LSPSettings.requireInstallConfirmation = originalRequireConfirmation
        super.tearDown()
    }

    func test_sessionToggleInitialState_smoothScrolling_readsUserDefaults() {
        UserDefaults.standard.set(false, forKey: "smoothScrollEnabled")
        XCTAssertFalse(SettingsWindowController.sessionToggleInitialState(for: .smoothScrolling))

        UserDefaults.standard.set(true, forKey: "smoothScrollEnabled")
        XCTAssertTrue(SettingsWindowController.sessionToggleInitialState(for: .smoothScrolling))
    }

    func test_sessionToggleInitialState_lspAutoInstall_readsLSPSettings() {
        LSPSettings.autoInstallEnabled = false
        XCTAssertFalse(SettingsWindowController.sessionToggleInitialState(for: .lspAutoInstall))

        LSPSettings.autoInstallEnabled = true
        XCTAssertTrue(SettingsWindowController.sessionToggleInitialState(for: .lspAutoInstall))
    }

    func test_sessionToggleInitialState_lspRequireConfirmation_readsLSPSettings() {
        LSPSettings.requireInstallConfirmation = false
        XCTAssertFalse(SettingsWindowController.sessionToggleInitialState(for: .lspRequireConfirmation))

        LSPSettings.requireInstallConfirmation = true
        XCTAssertTrue(SettingsWindowController.sessionToggleInitialState(for: .lspRequireConfirmation))
    }
}
