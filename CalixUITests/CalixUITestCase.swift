// CalixUITestCase.swift
// CalixUITests
//
// Base class for all Calix XCUITests with common helpers.

import XCTest

class CalixUITestCase: XCTestCase {
    var app: XCUIApplication!
    private var sessionTempDir: String?
    /// Per-test-unique `UserDefaults` suite name, read by
    /// `SessionSettings.uiTestSuite` via `CALIX_UITEST_DEFAULTS_SUITE`.
    ///
    /// INCIDENT THAT MADE THIS MANDATORY: before this fix, this base
    /// `setUp()` (the launch path every subclass here uses unless it
    /// overrides `setUp()` with its own launch, e.g.
    /// `SettingsSessionsToggleE2ETests`) launched the app-under-test with
    /// no defaults isolation and no `HOME` override at all. During a
    /// window when the developer's real `com.calix.terminal.e2e` defaults
    /// domain happened to have `persistentSessionsEnabled=1`, every
    /// tab/rename/reorder suite's app instance read that real domain,
    /// found persistence on, and created REAL persistent sessions against
    /// the developer's real `~/.calix` daemon on every launch -- 47 zombie
    /// shells accumulated in one day of running these suites. Setting this
    /// suite name before `app.launch()` mirrors
    /// `SettingsSessionsToggleE2ETests`'s own established isolation (see
    /// that file's header for why a dedicated suite, not just a `HOME`
    /// override, is required: `UserDefaults.standard` is mediated by
    /// `cfprefsd` and keyed by the real macOS account, not by `HOME`).
    private var defaultsSuiteName: String?

    /// Override in subclasses to add extra launch arguments (e.g. UserDefaults overrides).
    var additionalLaunchArguments: [String] { [] }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)"] + additionalLaunchArguments

        let tempDir = NSTemporaryDirectory() + "CalixUITests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: tempDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        sessionTempDir = tempDir
        app.launchEnvironment["CALIX_UITEST_SESSION_DIR"] = tempDir

        let suiteName = "com.calix.tests.e2e.CalixUITestCase-\(UUID().uuidString)"
        defaultsSuiteName = suiteName
        app.launchEnvironment["CALIX_UITEST_DEFAULTS_SUITE"] = suiteName

        app.launch()
    }

    override func tearDown() {
        app.terminate()
        if let dir = sessionTempDir {
            try? FileManager.default.removeItem(atPath: dir)
        }
        if let suiteName = defaultsSuiteName {
            // Best-effort only, mirroring SettingsSessionsToggleE2ETests's
            // own cleanup and its documented cfprefsd-flush caveat: the
            // app-under-test is a SEPARATE process, and cfprefsd flushes a
            // just-terminated process's writes to its on-disk plist on its
            // own schedule, sometimes after this point. A leftover plist
            // is harmless -- `suiteName` is a fresh UUID every run, so it
            // is never read by anything again, and this never touches the
            // real `com.calix.terminal.e2e` domain.
            Thread.sleep(forTimeInterval: 1.0)
            UserDefaults().removePersistentDomain(forName: suiteName)
            let suitePlistPath = "\(NSHomeDirectory())/Library/Preferences/\(suiteName).plist"
            try? FileManager.default.removeItem(atPath: suitePlistPath)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval = 5) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        wait(for: [expectation], timeout: timeout)
    }

    func menuAction(_ menuName: String, item: String) {
        app.menuBars.menuBarItems[menuName].click()
        app.menuBars.menuItems[item].click()
    }

    func createNewTabViaMenu() {
        menuAction("File", item: "New Tab")
    }

    func closeTabViaMenu() {
        menuAction("File", item: "Close Tab")
    }

    func toggleSidebarViaMenu() {
        menuAction("View", item: "Toggle Sidebar")
    }

    func openCommandPaletteViaMenu() {
        menuAction("View", item: "Command Palette")
    }

    func countElements(matching prefix: String, excludingSuffix: String? = nil) -> Int {
        let predicate: NSPredicate
        if let suffix = excludingSuffix {
            predicate = NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", prefix, suffix)
        } else {
            predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        }
        return app.descendants(matching: .any)
            .matching(predicate)
            .count
    }

    /// Every sidebar tab row currently on screen, across every group
    /// (`calix.sidebar.tab.<UUID>`, excluding `.closeButton` children).
    /// Correct as a tab-bar-equivalent count only when exactly one group
    /// exists -- every current caller with a single group active. A
    /// caller with multiple groups on screen wants `activeGroupIdentifier()`
    /// instead, not this.
    func countSidebarTabs() -> Int {
        let uuidPattern = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
        let predicate = NSPredicate(format: "identifier MATCHES %@", "calix\\.sidebar\\.tab\\.\(uuidPattern)")
        return app.descendants(matching: .any)
            .matching(predicate)
            .count
    }

    /// The UUID of whichever Workspace sidebar group is CURRENTLY ACTIVE,
    /// read from the one-per-active-group marker element
    /// `SidebarContentView.GroupSectionView` renders
    /// (`calix.sidebar.activeGroupMarker.<UUID>`, see that file). `nil`
    /// if no group is active yet (e.g. the app is still launching).
    /// Replaces the pre-strip-removal `currentTabBarTabIdentifiers()`,
    /// which proved an active-group switch by observing the tab-bar's
    /// visible tab SET change; this proves the same switch by observing
    /// the marker's UUID change instead, since the sidebar (unlike the
    /// old strip) renders every group's tabs at once and has no
    /// strip-equivalent "visible only for the active group" tab set.
    func activeGroupIdentifier() -> String? {
        let uuidPattern = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
        let predicate = NSPredicate(format: "identifier MATCHES %@", "calix\\.sidebar\\.activeGroupMarker\\.\(uuidPattern)")
        let marker = app.descendants(matching: .any).matching(predicate).firstMatch
        guard marker.exists else { return nil }
        let prefix = "calix.sidebar.activeGroupMarker."
        guard marker.identifier.hasPrefix(prefix) else { return nil }
        return String(marker.identifier.dropFirst(prefix.count))
    }

    /// Fixed scratch directory the team lead reads screenshots from by
    /// hand after a run -- NOT a general-purpose artifact location, so
    /// don't add unrelated files here. ONE level under `/tmp`,
    /// deliberately -- field-verified (not assumed) that this depth
    /// succeeds where a deeper, nested scratchpad path does not: the
    /// sandboxed runner failed an equivalent nested `mkdir` under the
    /// scratchpad with `NSCocoaErrorDomain Code=513 "Operation not
    /// permitted"`, while a one-level `/tmp/<name>` directory (the same
    /// depth `SessionBrowserAttachKillE2ETests`'s own per-test `homeDir`
    /// already succeeds at creating, see that file's `setUp()`) works.
    static let uiShotDir = "/tmp/cxshots"

    /// Saves a full-screen `XCUIScreen` screenshot (not a single
    /// element's, so window chrome/toolbar icons are visible exactly as
    /// a human eyeballing the result would see them) named `name`, via
    /// BOTH of two independent channels: (a) an `XCTAttachment`/`add(_:)`
    /// on the current test -- always succeeds, lands in the run's
    /// `.xcresult` regardless of sandboxing -- and (b) a raw PNG file
    /// under `uiShotDir`, a plain one-level `/tmp` path a human can open
    /// directly without extracting it from the `.xcresult` bundle first.
    /// (b) is a best-effort supplement, not a substitute for (a): if the
    /// write fails for any reason, this logs the failure and falls back
    /// to the attachment alone rather than failing the test over a
    /// diagnostic-only write.
    func saveScreenshot(name: String) {
        let screenshot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let filePath = "\(Self.uiShotDir)/\(name).png"
        do {
            try FileManager.default.createDirectory(atPath: Self.uiShotDir, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: filePath))
            print("[saveScreenshot] \"\(name)\": attached to test result AND wrote \(filePath)")
        } catch {
            print(
                "[saveScreenshot] \"\(name)\": attached to test result, but failed to " +
                "write \(filePath) (\(error)) -- see the test's XCTAttachment instead."
            )
        }
    }
}
