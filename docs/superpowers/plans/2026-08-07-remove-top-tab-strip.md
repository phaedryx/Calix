# Remove Top Tab Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the horizontal top-of-window tab strip (redundant with the Workspace sidebar's own tab list) and relocate its one non-redundant feature — the git-changes panel toggle — to a native titlebar accessory button, while preserving the UI test suite's ability to observe "which group is active" now that the strip (the only prior source of that signal) is gone.

**Architecture:** `TabBarContentView.swift` and its dead pass-through wiring in `MainContentView`/`CalixWindowController` are deleted outright. The Workspace sidebar gains one small new accessibility hook (an "active group" marker element) so XCUITest can still observe active-group state, replacing a mechanism (`.accessibilityValue`) that was already confirmed dead — undiscoverable by XCUITest for these SwiftUI container elements — during planning. A new small SwiftUI view (`GitChangesTitlebarButtonView`) is hosted in an `NSTitlebarAccessoryViewController` added once at window-controller init, with its state (open/closed, visible/hidden) refreshed from the same single `refreshHostingView()` choke point every other reactive UI update in this window already flows through — no new observation mechanism.

**Tech Stack:** Swift 6, AppKit + SwiftUI (macOS), XCTest (`CalixTests` unit target, `CalixUITests` XCUITest target), `xcodebuild test` via CLI, `xcodegen` for project-file generation.

**Spec:** `docs/superpowers/specs/2026-08-07-remove-top-tab-strip-design.md` (amended alongside this plan — its Testing section originally claimed the affected UI tests "require no test-logic changes"; that turned out false once actual usage was traced, see Task 2 below).

## Global Constraints

- Every task must leave the app building (`xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`) and `CalixTests` green before commit. Tasks that touch `CalixUITests` must also leave the affected UI test classes green (see each task's verification step — the full `CalixUITests` target is not run wholesale; it is scoped to the classes touched, and that scoping is deliberate, not an oversight).
- **This project uses `xcodegen`**: run `xcodegen generate` after adding or removing any `.swift` file, before building. `Calix.xcodeproj` is gitignored and regenerated from `project.yml`'s directory-glob `sources:`.
- Do **not** delete or modify `Calix/Views/TabBar/TabClickRecognizer.swift` (`TabClickContainer`/`ClickContainerNSView`) — the Workspace sidebar's own drag-reorder depends on it directly (`SidebarContentView.swift:388,698`), despite living under the same `Views/TabBar/` directory as the file being deleted.
- No replacement UI for: the strip's "+" new-tab button/double-click gesture (Cmd+T / File menu / palette already cover it), horizontal-scroll-over-strip, or sidebar-hidden tab switching (existing Cmd+Shift+]/[ shortcuts remain the fallback). None of these are in scope — see the spec's "Explicitly out of scope" section.
- A custom `.accessibilityValue(...)` string set on a SwiftUI `.accessibilityElement(children: .contain)` container does **not** surface to XCUITest's `NSPredicate` queries in this app — confirmed empirically during planning (a spike marker test passed for `.accessibilityIdentifier`, and `TabReorderUITests.swift`'s own pre-existing comment records an earlier, independent discovery of the same limitation for `.accessibilityValue`). Do not reintroduce a value-based lookup as a fix for anything in this plan; use identifiers (proven reliable) instead.

---

### Task 1: Remove the top tab strip

**Files:**
- Delete: `Calix/Views/TabBar/TabBarContentView.swift`
- Modify: `Calix/Views/MainWindow/MainContentView.swift`
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift:1002-1052` (`buildMainContentView()`)
- Modify: `Calix/Helpers/AccessibilityID.swift`
- Modify: `Calix/Models/Session/Tab.swift:33-39` (stale comment)
- Modify: `Calix/Features/Persistence/RecoveryBarView.swift:48-54` (stale comment)

**Interfaces:**
- Consumes: nothing new.
- Produces: `MainContentView`'s initializer drops `isGitChangesPanelOpen`, `showGitChangesButton`, `onToggleGitChangesPanel` (Task 3 re-adds equivalent state elsewhere, not through this initializer). `AccessibilityID.TabBar` is deleted; `AccessibilityID.Titlebar.gitChangesButton` is added in its place (new home for the one identifier that survives), consumed by Task 3.

This is a removal-and-verify task, not new-logic TDD: there is no new behavior to write a failing test for. Verification is the full build + full `CalixTests` suite staying green. Confirmed during planning via `grep -rln "TabBarContentView\|TabItemButton\|WheelBridgeView\|AccessibilityID\.TabBar" CalixTests/` (zero matches) that no unit test references any deleted symbol. UI-test fallout from this deletion is real but handled entirely in Task 2, not here — see that task for why.

- [ ] **Step 1: Delete the tab strip file**

```bash
rm Calix/Views/TabBar/TabBarContentView.swift
```

- [ ] **Step 2: Remove the strip's row and dead props from `MainContentView.swift`**

In `Calix/Views/MainWindow/MainContentView.swift`, remove these three properties (currently lines 29-34):

```swift
    /// Active tab's git-changes panel state, for the tab bar's toggle
    /// button. The panel itself renders as a `.gitChanges` pane inside
    /// `splitContainerView`, not through this view.
    var isGitChangesPanelOpen: Bool = false
    var showGitChangesButton: Bool = false
    var onToggleGitChangesPanel: (() -> Void)?
```

And remove the strip's `if` block inside `mainContent`'s `VStack` (currently lines 154-170):

```swift
                        if !activeTabs.isEmpty {
                            TabBarContentView(
                                tabs: activeTabs,
                                activeTabID: activeTabID,
                                onTabSelected: onTabSelected,
                                onNewTab: onNewTab,
                                onCloseTab: onCloseTab,
                                onMoveTab: activeGroup != nil
                                    ? { from, to in onMoveTab?(activeGroup!.id, from, to) }
                                    : nil,
                                onTabRenamed: onTabRenamed,
                                activeGroupID: activeGroup?.id,
                                isGitChangesPanelOpen: isGitChangesPanelOpen,
                                showGitChangesButton: showGitChangesButton,
                                onToggleGitChangesPanel: onToggleGitChangesPanel
                            )
                        }

```

The `VStack` that contained it now starts directly with the `if let browserController = activeBrowserController { ... } else { ... }` block that followed.

`activeTabs`/`activeTabID` (computed at the top of `mainContent`, lines 112-114) are still used elsewhere in this same function's closure captures for `onMoveTab` below — re-check after this edit whether `activeTabs`/`activeTabID` are now unused local `let`s; if so, remove them too (Swift will warn, not error, but don't leave dead locals).

- [ ] **Step 3: Remove the dead pass-through in `CalixWindowController.buildMainContentView()`**

In `Calix/Views/MainWindow/CalixWindowController.swift`, remove these lines from the `MainContentView(...)` call (currently lines 1014-1019):

```swift
            isGitChangesPanelOpen: gitChangesController.isChangesPanelVisible,
            showGitChangesButton: {
                if case .terminal = windowSession.activeGroup?.activeTab?.content { return true }
                return false
            }(),
            onToggleGitChangesPanel: { [weak self] in self?.toggleGitChangesPanel() },
```

(Task 3 re-adds equivalent logic, targeting the new titlebar accessory instead of `MainContentView`'s initializer.)

- [ ] **Step 4: Clean up `AccessibilityID.TabBar`**

In `Calix/Helpers/AccessibilityID.swift`, replace:

```swift
    enum TabBar {
        static let container = "calix.tabBar"
        static let newTabButton = "calix.tabBar.newTabButton"
        static let gitChangesButton = "calix.tabBar.gitChangesButton"
        static func tab(_ id: UUID) -> String { "calix.tabBar.tab.\(id.uuidString)" }
        static func tabCloseButton(_ id: UUID) -> String { "calix.tabBar.tab.\(id.uuidString).closeButton" }
        static func tabNameTextField(_ id: UUID) -> String { "calix.tabBar.tabNameTextField.\(id.uuidString)" }
        static func tabAtIndex(_ index: Int) -> String { "calix.tabBar.tab.index.\(index)" }
    }
```

with:

```swift
    enum Titlebar {
        static let gitChangesButton = "calix.titlebar.gitChangesButton"
    }
```

(`container`/`newTabButton`/`tab(_:)`/`tabCloseButton(_:)`/`tabNameTextField(_:)`/`tabAtIndex(_:)` were exclusively consumed by the now-deleted `TabBarContentView.swift` — confirmed during planning via `grep -rln "tabBar" --include="*.swift" .` that every remaining reference outside the vendored `ghostty/` library lives in files this plan already accounts for. `gitChangesButton` survives under a new, accurately-named home; Task 3 consumes `AccessibilityID.Titlebar.gitChangesButton`.)

- [ ] **Step 5: Update stale comments**

In `Calix/Models/Session/Tab.swift`, the `renameRequestID` doc comment (currently lines 33-39) reads:

```swift
    /// Bumped to request that whichever tab UI (`TabItemButton` or
    /// `TabRowItemView`) is currently displaying this tab enter inline
    /// rename mode, mirroring what a double-click does. Set by the
    /// `prompt_tab_title`/`prompt_surface_title` keybind handler in
    /// `CalixWindowController`, since that fires from AppKit with no
    /// direct handle on the SwiftUI view's local `isEditing` state.
    var renameRequestID: UUID?
```

Change it to:

```swift
    /// Bumped to request that the Workspace sidebar's `TabRowItemView`,
    /// which is currently displaying this tab, enter inline rename mode,
    /// mirroring what a double-click does. Set by the
    /// `prompt_tab_title`/`prompt_surface_title` keybind handler in
    /// `CalixWindowController`, since that fires from AppKit with no
    /// direct handle on the SwiftUI view's local `isEditing` state.
    var renameRequestID: UUID?
```

In `Calix/Features/Persistence/RecoveryBarView.swift`, the comment above `RecoveryBarBackgroundModifier` (currently lines 48-54) reads:

```swift
/// Same glass-chrome treatment as `TabBarContentView`'s own
/// `TabBarBackgroundModifier` (the closest existing precedent: another
/// horizontal bar sitting directly above/adjacent to the tab strip,
/// bottom-edge-separated from what follows it) -- ties this bar's
/// look to the user's theme color + glass opacity instead of a fixed
/// `.thinMaterial`, so it reads as part of the window chrome rather
/// than a foreign overlay.
```

Change it to:

```swift
/// Same glass-chrome treatment as `SidebarContentView`'s own
/// `SidebarBackgroundModifier` (the closest existing precedent: another
/// bar sitting directly adjacent to the tab list, edge-separated from
/// what follows it) -- ties this bar's look to the user's theme color +
/// glass opacity instead of a fixed `.thinMaterial`, so it reads as part
/// of the window chrome rather than a foreign overlay.
```

(`SidebarBackgroundModifier` is confirmed to exist at `Calix/Views/Sidebar/SidebarContentView.swift:282`, applied at line 224 — this is a real rename, not a guess.)

- [ ] **Step 6: Full build**

Run: `xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Full unit test suite**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests`
Expected: `** TEST SUCCEEDED **`.

Do **not** run `CalixUITests` yet — Task 2 below fixes the UI-test fallout from this deletion. Running the UI suite now is expected to fail (`TabReorderUITests` will fail to compile: it still references `calix.tabBar.tab.*`-pattern helpers that querying nothing will make meaningless, and `GroupManagementUITests`/`MenuShortcutsUITests`/`CalixUITestCase` still compile fine but their `countTabBarTabs()`/`currentTabBarTabIdentifiers()` helpers will always return `0`/`[]` since nothing renders a `calix.tabBar.*`-identified element anymore).

- [ ] **Step 8: Commit**

```bash
git add -A -- Calix/Views/TabBar/TabBarContentView.swift Calix/Views/MainWindow/MainContentView.swift Calix/Views/MainWindow/CalixWindowController.swift Calix/Helpers/AccessibilityID.swift Calix/Models/Session/Tab.swift Calix/Features/Persistence/RecoveryBarView.swift
git commit -m "refactor: remove the redundant top tab strip, kept only in the Workspace sidebar"
```

---

### Task 2: Sidebar active-group marker + UI test fallout

**Why this task exists:** `CalixUITestCase.swift`'s `countTabBarTabs()`/`currentTabBarTabIdentifiers()` helpers, and `TabReorderUITests.swift`'s tab-bar-specific drag tests, were believed during the design-spec phase to be comment-only references to the deleted strip. That belief was wrong — traced during planning via `grep -rn "countTabBarTabs()\|currentTabBarTabIdentifiers()" CalixUITests/`, which surfaced real call sites in six files. Two of those files (`GroupManagementUITests.swift`, `MenuShortcutsUITests.swift`) genuinely need to observe "which group is currently active," a signal the strip provided for free (it only ever rendered the active group's tabs) and the sidebar does not expose today (it renders every group's tabs at once). This task adds that missing signal to the sidebar, then fixes every real dependency on the old, strip-based mechanism.

A value-based fix (reusing the sidebar's existing `AccessibilityID.Sidebar.tabAtIndex(groupID:index:)`, set via `.accessibilityValue(...)` at `SidebarContentView.swift:569`) was considered and rejected: `TabReorderUITests.swift`'s own header comment records that XCUITest does not surface a custom `.accessibilityValue` on these SwiftUI container elements in this app, and a throwaway spike test confirmed (during planning) that a plain `.accessibilityIdentifier` on a 1x1 `Color` view **does** surface reliably. The fix below uses only identifiers.

**Files:**
- Modify: `Calix/Views/Sidebar/SidebarContentView.swift` (new marker element; remove the dead `.accessibilityValue` call)
- Modify: `Calix/Helpers/AccessibilityID.swift` (add `Sidebar.activeGroupMarker(_:)`; remove dead `Sidebar.tabAtIndex(_:_:)`)
- Modify: `CalixUITests/CalixUITestCase.swift` (replace `countTabBarTabs()`/`currentTabBarTabIdentifiers()` with `countSidebarTabs()`/`activeGroupIdentifier()`)
- Modify: `CalixUITests/GroupManagementUITests.swift` (`test_switchGroup`)
- Modify: `CalixUITests/MenuShortcutsUITests.swift` (`test_nextGroupViaMenu_switchesGroup`)
- Modify: `CalixUITests/TabManagementUITests.swift`, `CalixUITests/TabRenameUITests.swift`, `CalixUITests/CommandPaletteUITests.swift`, `CalixUITests/TabReorderUITests.swift` (mechanical `countTabBarTabs()` → `countSidebarTabs()` rename)
- Modify: `CalixUITests/TabReorderUITests.swift` (delete the two tab-bar-specific tests and their three now-dead helpers; reword header comment)
- Modify: `CalixUITests/SessionBrowserAttachKillE2ETests.swift`, `CalixUITests/RealQuitRestoreE2ETests.swift`, `CalixUITests/SessionPersistenceE2ETests.swift` (stale "not the horizontal tab bar" comments)
- Modify: `docs/superpowers/specs/2026-08-07-remove-top-tab-strip-design.md` (Testing section correction)

**Interfaces:**
- Consumes: `AccessibilityID.Sidebar.group(_:)` (existing, unchanged), `AccessibilityID.Sidebar.tab(_:)` (existing, unchanged).
- Produces: `AccessibilityID.Sidebar.activeGroupMarker(_ id: UUID) -> String` (new — `"calix.sidebar.activeGroupMarker.<UUID>"`). `CalixUITestCase.countSidebarTabs() -> Int` and `CalixUITestCase.activeGroupIdentifier() -> String?` (new, `internal` so subclasses can call them — same visibility as the helpers they replace), consumed by every UI test file listed above.

- [ ] **Step 1: Add the active-group marker to `SidebarContentView.swift`**

In `Calix/Views/Sidebar/SidebarContentView.swift`, `GroupSectionView.body` currently has this sequence (lines 483-487):

```swift
                .accessibilityLabel(group.name)
                .onAssumeInsideHover($isHoveringHeader)
            }

            // Tabs in this group (only show if not collapsed)
```

Insert a new sibling element between the header's closing brace and the tabs section. It must be a **sibling** in the outer `VStack`, not nested inside the header's `.accessibilityElement(children: .contain)` block above — nesting it there would make it invisible to XCUITest, the same "`.contain` swallows children" issue this file's own `TabRowItemView` doc comment (a few lines below) already documents for a different element:

```swift
                .accessibilityLabel(group.name)
                .onAssumeInsideHover($isHoveringHeader)
            }

            // Exposes which group is currently active to XCUITest, now
            // that the top tab strip (the previous source of this signal
            // -- it only ever rendered the active group's tabs) is gone.
            // A 1x1 `Color` view with a plain `.accessibilityIdentifier`
            // is used deliberately instead of a custom
            // `.accessibilityValue` on an existing element: confirmed
            // during planning that XCUITest does not surface a custom
            // accessibilityValue on these SwiftUI container elements in
            // this app (see TabReorderUITests.swift's header comment),
            // while plain identifiers reliably do. See
            // CalixUITestCase.activeGroupIdentifier().
            if isActiveGroup {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.activeGroupMarker(group.id))
            }

            // Tabs in this group (only show if not collapsed)
```

- [ ] **Step 2: Remove the dead value-based lookup**

In the same file, remove the dead `.accessibilityValue` call (currently line 569):

```swift
                        .accessibilityValue(AccessibilityID.Sidebar.tabAtIndex(group.id, index))
```

(Delete the line entirely — nothing reads it, confirmed nothing can per Step 1's rationale.)

- [ ] **Step 3: Update `AccessibilityID.swift`**

In `Calix/Helpers/AccessibilityID.swift`, in the `Sidebar` enum, replace:

```swift
        static func tabAtIndex(_ groupID: UUID, _ index: Int) -> String {
            "calix.sidebar.group.\(groupID.uuidString).tab.index.\(index)"
        }
```

with:

```swift
        static func activeGroupMarker(_ id: UUID) -> String { "calix.sidebar.activeGroupMarker.\(id.uuidString)" }
```

(Confirmed during planning via `grep -rn "tabAtIndex" Calix/ CalixTests/ CalixUITests/` that `Sidebar.tabAtIndex` has no callers besides its own definition and the line just deleted in Step 2.)

- [ ] **Step 4: Build and spot-check the marker before touching any test file**

```bash
xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. This is the RED/GREEN checkpoint for this task's one piece of new production behavior — confirm it builds before rewriting six test files against it.

- [ ] **Step 5: Rewrite `CalixUITestCase.swift`'s helpers**

In `CalixUITests/CalixUITestCase.swift`, replace this block (currently lines 125-152):

```swift
    func countTabBarTabs() -> Int {
        // Match exactly "calix.tabBar.tab.<UUID>" and nothing else (no .closeButton suffix)
        let uuidPattern = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
        let predicate = NSPredicate(format: "identifier MATCHES %@", "calix\\.tabBar\\.tab\\.\(uuidPattern)")
        return app.descendants(matching: .any)
            .matching(predicate)
            .count
    }

    /// The identifiers of every tab currently shown in the horizontal tab
    /// bar (`calix.tabBar.tab.<UUID>`, excluding `.closeButton` children),
    /// i.e. the tabs belonging to whichever group is CURRENTLY ACTIVE
    /// (`MainContentView.mainContent` feeds `TabBarContentView` from
    /// `windowSession.activeGroup?.tabs` alone, so switching the active
    /// group changes exactly this set). Used to prove a group-switching
    /// action actually moved the active group, rather than merely
    /// leaving the group COUNT unchanged (which a no-op switch would also
    /// satisfy).
    func currentTabBarTabIdentifiers() -> Set<String> {
        let uuidPattern = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
        let predicate = NSPredicate(format: "identifier MATCHES %@", "calix\\.tabBar\\.tab\\.\(uuidPattern)")
        return Set(
            app.descendants(matching: .any)
                .matching(predicate)
                .allElementsBoundByIndex
                .map { $0.identifier }
        )
    }
```

with:

```swift
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
```

- [ ] **Step 6: Rewrite `GroupManagementUITests.test_switchGroup`**

In `CalixUITests/GroupManagementUITests.swift`, this test currently (lines 44-101) reads:

```swift
    func test_switchGroup() {
        // Baseline: capture the ORIGINAL (first) group's own tab-bar tab
        // identifier set before any second group exists, so switching
        // back to it later can be proven by observing the SAME set
        // reappear (TabBarContentView is fed exclusively from
        // `windowSession.activeGroup?.tabs`, see
        // `CalixUITestCase.currentTabBarTabIdentifiers()`'s own doc
        // comment) -- not just that the group COUNT is unchanged, which
        // a no-op switch would also satisfy.
        let firstGroupTabIdentifiers = currentTabBarTabIdentifiers()
        XCTAssertEqual(firstGroupTabIdentifiers.count, 1, "Should start with exactly one tab in the first group")

        // Create a second group via command palette
        openCommandPaletteViaMenu()

        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calix.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField))

        searchField.typeText("New Group")
        searchField.typeKey(.enter, modifierFlags: [])

        // Wait for palette to dismiss and group to be created
        let palette = app.descendants(matching: .any)
            .matching(identifier: "calix.commandPalette")
            .firstMatch
        waitForNonExistence(palette)
        Thread.sleep(forTimeInterval: 0.5)

        // Click the first group in the sidebar to switch
        let groups = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", "calix.sidebar.group.", "Button"))
        XCTAssertEqual(groups.count, 2, "Should have two groups")

        // The newly created second group becomes active on creation
        // (WindowSession/CalixWindowController.createNewGroup sets
        // `activeGroupID` explicitly), so the tab bar should now show
        // its OWN (different) tab, not the first group's.
        let secondGroupTabIdentifiers = currentTabBarTabIdentifiers()
        XCTAssertNotEqual(
            secondGroupTabIdentifiers, firstGroupTabIdentifiers,
            "Creating a new group should make it active, so the tab bar should show its own tab, not the first group's"
        )

        groups.element(boundBy: 0).click()
        Thread.sleep(forTimeInterval: 0.3)

        // Verify we can interact with it (the group click should succeed without error)
        XCTAssertTrue(groups.element(boundBy: 0).exists, "First group should still exist after clicking")

        // The ACTIVE group must have actually switched back to the first
        // group: the tab bar's visible tab set should match the baseline
        // captured before the second group ever existed.
        XCTAssertEqual(
            currentTabBarTabIdentifiers(), firstGroupTabIdentifiers,
            "Clicking the first group should switch the active group back to it, so the tab bar shows its tab again"
        )
    }
```

Replace it with:

```swift
    func test_switchGroup() {
        // Baseline: capture the ORIGINAL (first) group's own active-group
        // marker UUID before any second group exists, so switching back
        // to it later can be proven by observing the SAME UUID reappear
        // (see `CalixUITestCase.activeGroupIdentifier()`'s own doc
        // comment) -- not just that the group COUNT is unchanged, which
        // a no-op switch would also satisfy.
        let firstGroupID = activeGroupIdentifier()
        XCTAssertNotNil(firstGroupID, "An active group should exist at launch")
        XCTAssertEqual(countSidebarTabs(), 1, "Should start with exactly one tab in the first group")

        // Create a second group via command palette
        openCommandPaletteViaMenu()

        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calix.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField))

        searchField.typeText("New Group")
        searchField.typeKey(.enter, modifierFlags: [])

        // Wait for palette to dismiss and group to be created
        let palette = app.descendants(matching: .any)
            .matching(identifier: "calix.commandPalette")
            .firstMatch
        waitForNonExistence(palette)
        Thread.sleep(forTimeInterval: 0.5)

        // Click the first group in the sidebar to switch
        let groups = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", "calix.sidebar.group.", "Button"))
        XCTAssertEqual(groups.count, 2, "Should have two groups")

        // The newly created second group becomes active on creation
        // (WindowSession/CalixWindowController.createNewGroup sets
        // `activeGroupID` explicitly), so the active-group marker should
        // now report its OWN (different) UUID, not the first group's.
        let secondGroupID = activeGroupIdentifier()
        XCTAssertNotEqual(
            secondGroupID, firstGroupID,
            "Creating a new group should make it active, so the active-group marker should report the new group, not the first one"
        )

        groups.element(boundBy: 0).click()
        Thread.sleep(forTimeInterval: 0.3)

        // Verify we can interact with it (the group click should succeed without error)
        XCTAssertTrue(groups.element(boundBy: 0).exists, "First group should still exist after clicking")

        // The ACTIVE group must have actually switched back to the first
        // group: the active-group marker should report the baseline UUID
        // captured before the second group ever existed.
        XCTAssertEqual(
            activeGroupIdentifier(), firstGroupID,
            "Clicking the first group should switch the active group back to it, so the active-group marker should report the first group's ID again"
        )
    }
```

- [ ] **Step 7: Rewrite `MenuShortcutsUITests.test_nextGroupViaMenu_switchesGroup`**

In `CalixUITests/MenuShortcutsUITests.swift`, this test currently (lines 407-480) reads:

```swift
    func test_nextGroupViaMenu_switchesGroup() {
        // Baseline: the first group's own tab-bar tab identifier set,
        // captured before a second group exists, so a later switch BACK
        // to it can be proven by observing the SAME set reappear
        // (`CalixUITestCase.currentTabBarTabIdentifiers()`'s own doc
        // comment: `TabBarContentView` is fed exclusively from
        // `windowSession.activeGroup?.tabs`) -- not just that the group
        // COUNT is unchanged, which a no-op switch would also satisfy.
        let firstGroupTabIdentifiers = currentTabBarTabIdentifiers()

        // まず 2 つ目のグループを作成
        openMenuBarItem("Window")
        hoverMenuItem("Group")
        let newGroup = app.menuBars.menuItems["New Group"]
        XCTAssertTrue(newGroup.waitForExistence(timeout: 3), "'New Group' must exist")
        newGroup.click()
        let observedAfterNew = waitForGroupCount(2, timeout: 5)

        XCTAssertEqual(observedAfterNew, 2, "Should have 2 groups after creating a new one")

        // The newly created group becomes active on creation, so the tab
        // bar should now show its own (different) tab.
        let secondGroupTabIdentifiers = currentTabBarTabIdentifiers()
        XCTAssertNotEqual(
            secondGroupTabIdentifiers, firstGroupTabIdentifiers,
            "Creating a new group via the menu should make it active, so the tab bar should show its own tab"
        )

        // Previous Group に切り替え
        openMenuBarItem("Window")
        hoverMenuItem("Group")
        let prevGroup = app.menuBars.menuItems["Previous Group"]
        XCTAssertTrue(
            prevGroup.waitForExistence(timeout: 3),
            "'Previous Group' menu item must exist"
        )
        prevGroup.click()
        // Previous Group はグループ数を変えない (active 切替のみ)。
        // 決定論的な完了シグナルが乏しいため短い settle wait を保持する
        // (メニュー dismiss と active-group rebroadcast を待つ)。
        Thread.sleep(forTimeInterval: 0.3)

        // グループ数は変わらない
        XCTAssertEqual(
            currentGroupCount(), 2,
            "Previous Group should switch active group, not remove one"
        )

        // The ACTIVE group must have actually switched back to the
        // first group: the tab bar's visible tab set should match the
        // baseline captured before the second group ever existed.
        XCTAssertEqual(
            currentTabBarTabIdentifiers(), firstGroupTabIdentifiers,
            "Previous Group should switch the active group back to the first one, so the tab bar shows its tab again"
        )

        // Next Group で戻れることも確認
        openMenuBarItem("Window")
        hoverMenuItem("Group")
        let nextGroup = app.menuBars.menuItems["Next Group"]
        XCTAssertTrue(
            nextGroup.waitForExistence(timeout: 3),
            "'Next Group' menu item must exist"
        )
        nextGroup.click()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(
            currentGroupCount(), 2,
            "Next Group should switch active group, not remove one"
        )

        // The ACTIVE group must have switched forward again, back to the
        // second group's own tab.
        XCTAssertEqual(
            currentTabBarTabIdentifiers(), secondGroupTabIdentifiers,
            "Next Group should switch the active group forward to the second one, so the tab bar shows its tab again"
        )
    }
```

Replace it with:

```swift
    func test_nextGroupViaMenu_switchesGroup() {
        // Baseline: the first group's own active-group marker UUID,
        // captured before a second group exists, so a later switch BACK
        // to it can be proven by observing the SAME UUID reappear (see
        // `CalixUITestCase.activeGroupIdentifier()`'s own doc comment) --
        // not just that the group COUNT is unchanged, which a no-op
        // switch would also satisfy.
        let firstGroupID = activeGroupIdentifier()

        // まず 2 つ目のグループを作成
        openMenuBarItem("Window")
        hoverMenuItem("Group")
        let newGroup = app.menuBars.menuItems["New Group"]
        XCTAssertTrue(newGroup.waitForExistence(timeout: 3), "'New Group' must exist")
        newGroup.click()
        let observedAfterNew = waitForGroupCount(2, timeout: 5)

        XCTAssertEqual(observedAfterNew, 2, "Should have 2 groups after creating a new one")

        // The newly created group becomes active on creation, so the
        // active-group marker should now report its own (different) UUID.
        let secondGroupID = activeGroupIdentifier()
        XCTAssertNotEqual(
            secondGroupID, firstGroupID,
            "Creating a new group via the menu should make it active, so the active-group marker should report the new group"
        )

        // Previous Group に切り替え
        openMenuBarItem("Window")
        hoverMenuItem("Group")
        let prevGroup = app.menuBars.menuItems["Previous Group"]
        XCTAssertTrue(
            prevGroup.waitForExistence(timeout: 3),
            "'Previous Group' menu item must exist"
        )
        prevGroup.click()
        // Previous Group はグループ数を変えない (active 切替のみ)。
        // 決定論的な完了シグナルが乏しいため短い settle wait を保持する
        // (メニュー dismiss と active-group rebroadcast を待つ)。
        Thread.sleep(forTimeInterval: 0.3)

        // グループ数は変わらない
        XCTAssertEqual(
            currentGroupCount(), 2,
            "Previous Group should switch active group, not remove one"
        )

        // The ACTIVE group must have actually switched back to the
        // first group: the active-group marker should report the
        // baseline UUID captured before the second group ever existed.
        XCTAssertEqual(
            activeGroupIdentifier(), firstGroupID,
            "Previous Group should switch the active group back to the first one, so the active-group marker should report it again"
        )

        // Next Group で戻れることも確認
        openMenuBarItem("Window")
        hoverMenuItem("Group")
        let nextGroup = app.menuBars.menuItems["Next Group"]
        XCTAssertTrue(
            nextGroup.waitForExistence(timeout: 3),
            "'Next Group' menu item must exist"
        )
        nextGroup.click()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(
            currentGroupCount(), 2,
            "Next Group should switch active group, not remove one"
        )

        // The ACTIVE group must have switched forward again, back to the
        // second group's own marker UUID.
        XCTAssertEqual(
            activeGroupIdentifier(), secondGroupID,
            "Next Group should switch the active group forward to the second one, so the active-group marker should report it again"
        )
    }
```

- [ ] **Step 8: Mechanical rename in the four single-group files**

Run each of these (`countTabBarTabs()` is a plain count that only ever needs "how many tabs does the one group on screen have" in these four files — confirmed during planning that none of them touch tab-bar-specific identifiers):

```bash
sed -i '' 's/countTabBarTabs()/countSidebarTabs()/g' CalixUITests/TabManagementUITests.swift
sed -i '' 's/countTabBarTabs()/countSidebarTabs()/g' CalixUITests/TabRenameUITests.swift
sed -i '' 's/countTabBarTabs()/countSidebarTabs()/g' CalixUITests/CommandPaletteUITests.swift
```

(`TabReorderUITests.swift`'s one `countTabBarTabs()` call, at line 122 inside `test_dragSidebarTab_reordersCorrectly`, is handled in Step 9 below alongside that file's other changes — don't `sed` it here, so the deletions in Step 9 apply to a known, unmodified baseline.)

- [ ] **Step 9: Delete the two tab-bar-specific tests in `TabReorderUITests.swift`, fix the third**

In `CalixUITests/TabReorderUITests.swift`, the file currently (210 lines) tests drag-reorder in **both** the tab bar and the sidebar. The tab-bar half tests a UI surface that Task 1 deleted — these aren't broken by the deletion, they test the deleted behavior itself, so they're removed, not fixed.

Replace the file's header (currently lines 1-23):

```swift
// TabReorderUITests.swift
// CalixUITests
//
// UI tests for tab drag-reorder in both the tab bar and sidebar.

import XCTest

final class TabReorderUITests: CalixUITestCase {

    // MARK: - Helpers

    // Position-ordered tab lookup.
    //
    // The tab rows expose their `calix.*.tab.<UUID>` identifier (via
    // `.accessibilityElement(children: .contain)`) but NOT their
    // `.accessibilityValue` index: XCUITest surfaces a container element's
    // identifier and label, but not its `AXValue`, so the previous
    // value-based index lookup returned nothing. Instead, resolve a tab's
    // ordinal position from the on-screen geometry of the identifier-bearing
    // elements: left-to-right (minX) for the horizontal tab bar,
    // top-to-bottom (minY) for the vertical sidebar list.
    private static let uuidPattern =
        "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
```

with:

```swift
// TabReorderUITests.swift
// CalixUITests
//
// UI tests for tab drag-reorder in the sidebar (the tab bar this file
// used to also test was removed -- see
// docs/superpowers/specs/2026-08-07-remove-top-tab-strip-design.md).

import XCTest

final class TabReorderUITests: CalixUITestCase {

    // MARK: - Helpers

    // Position-ordered tab lookup.
    //
    // The sidebar's tab rows expose their `calix.sidebar.tab.<UUID>`
    // identifier (via `.accessibilityElement(children: .contain)`) but
    // NOT an `.accessibilityValue` index: XCUITest surfaces a container
    // element's identifier and label, but not its `AXValue`, so a
    // value-based index lookup would return nothing (confirmed
    // separately while adding the sidebar's active-group marker, see
    // `SidebarContentView.swift`). Instead, resolve a tab's ordinal
    // position from the on-screen geometry of the identifier-bearing
    // elements: top-to-bottom (minY).
    private static let uuidPattern =
        "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
```

Delete the two tab-bar-only helpers (currently lines 25-34 and 47-50, 57-60 — the `tabBarTabsByPosition()`/`tabBarTab(atIndex:)`/`tabBarTabIdentifier(atIndex:)` trio):

```swift
    /// Tab-bar tab elements (identifier `calix.tabBar.tab.<UUID>`, no
    /// `.closeButton` suffix) sorted left-to-right by frame.
    private func tabBarTabsByPosition() -> [XCUIElement] {
        let predicate = NSPredicate(format: "identifier MATCHES %@",
                                    "calix\\.tabBar\\.tab\\.\(Self.uuidPattern)")
        let query = app.descendants(matching: .any).matching(predicate)
        return (0..<query.count)
            .map { query.element(boundBy: $0) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }
```

```swift
    private func tabBarTab(atIndex index: Int) -> XCUIElement? {
        let tabs = tabBarTabsByPosition()
        return index < tabs.count ? tabs[index] : nil
    }
```

```swift
    /// Reads the identifier of the tab-bar tab at a given ordinal position.
    private func tabBarTabIdentifier(atIndex index: Int) -> String? {
        tabBarTab(atIndex: index)?.identifier
    }
```

Delete the two now-meaningless tests, `test_dragTabBarTab_reordersCorrectly()` (under `// MARK: - Tab Bar Reorder`) and `test_tapStillWorksAfterDrag()` (under `// MARK: - Tap After Drag`), in full:

```swift
    // MARK: - Tab Bar Reorder

    func test_dragTabBarTab_reordersCorrectly() {
        // Arrange: create 3 tabs total (1 initial + 2 new)
        createTabs(count: 2)
        XCTAssertEqual(countTabBarTabs(), 3, "Should have 3 tabs before drag")

        // Capture the identifier of the tab currently at index 0
        guard let firstTabElement = tabBarTab(atIndex: 0) else {
            return XCTFail("Tab at index 0 should exist")
        }
        let originalFirstTabID = firstTabElement.identifier

        // Also capture the tab at index 2 to know the drag target position
        guard let thirdTabElement = tabBarTab(atIndex: 2) else {
            return XCTFail("Tab at index 2 should exist")
        }

        // Act: drag the first tab to the right, past the third tab
        firstTabElement.press(forDuration: 0.2, thenDragTo: thirdTabElement)

        // Allow the reorder animation to settle
        Thread.sleep(forTimeInterval: 1.0)

        // Assert: the tab that was originally first should no longer be at index 0
        let newFirstTabID = tabBarTabIdentifier(atIndex: 0)
        XCTAssertNotNil(newFirstTabID, "A tab should exist at index 0 after reorder")
        XCTAssertNotEqual(
            newFirstTabID, originalFirstTabID,
            "After dragging the first tab past the third, a different tab should now occupy index 0"
        )

        // The original first tab should now be at index 1 or 2
        let tabAtIndex1 = tabBarTabIdentifier(atIndex: 1)
        let tabAtIndex2 = tabBarTabIdentifier(atIndex: 2)
        let originalTabMoved = (tabAtIndex1 == originalFirstTabID) || (tabAtIndex2 == originalFirstTabID)
        XCTAssertTrue(
            originalTabMoved,
            "The original first tab should have moved to index 1 or 2"
        )
    }

    // MARK: - Sidebar Reorder
```

(Note the `// MARK: - Sidebar Reorder` line is kept — only the `// MARK: - Tab Bar Reorder` section and its test are deleted.)

```swift
    // MARK: - Tap After Drag

    func test_tapStillWorksAfterDrag() {
        // Arrange: create 2 tabs total
        createTabs(count: 1)
        XCTAssertEqual(countTabBarTabs(), 2, "Should have 2 tabs")

        // Find the tab at index 0
        guard let firstTabElement = tabBarTab(atIndex: 0) else {
            return XCTFail("Tab at index 0 should exist")
        }
        let tabID = firstTabElement.identifier

        // Act: perform a very short press-and-drag (within the 5pt minimumDistance threshold)
        // This should not trigger a reorder; instead the tab should remain tappable.
        // We drag to a nearby coordinate offset (2pt right, 0pt down) which is < minimumDistance.
        let startCoordinate = firstTabElement.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let nearbyCoordinate = startCoordinate.withOffset(CGVector(dx: 2, dy: 0))
        startCoordinate.press(forDuration: 0.1, thenDragTo: nearbyCoordinate)

        Thread.sleep(forTimeInterval: 0.5)

        // Assert: the tab should still be at the same index (no reorder occurred)
        let tabAfterDrag = tabBarTabIdentifier(atIndex: 0)
        XCTAssertEqual(
            tabAfterDrag, tabID,
            "Tab should remain at index 0 after a sub-threshold drag"
        )

        // Verify the tab is still tappable by clicking it
        guard let tabElement = tabBarTab(atIndex: 0) else {
            return XCTFail("Tab at index 0 should still exist")
        }
        XCTAssertTrue(tabElement.isHittable, "Tab should be hittable after a sub-threshold drag")
        tabElement.click()

        Thread.sleep(forTimeInterval: 0.5)

        // The tab should still exist and be at the same position
        let tabAfterClick = tabBarTabIdentifier(atIndex: 0)
        XCTAssertEqual(
            tabAfterClick, tabID,
            "Tab should remain at index 0 after clicking"
        )
    }
}
```

with:

```swift
}
```

(The file now ends after `test_dragSidebarTab_reordersCorrectly()`'s closing brace, with no tap-after-drag coverage — that behavior was tab-bar-specific and had no sidebar equivalent test before this change either.)

Finally, in the surviving `test_dragSidebarTab_reordersCorrectly()`, rename its one `countTabBarTabs()` call to `countSidebarTabs()`:

```swift
        XCTAssertEqual(countTabBarTabs(), 3, "Should have 3 tabs before toggling sidebar")
```

becomes:

```swift
        XCTAssertEqual(countSidebarTabs(), 3, "Should have 3 tabs before toggling sidebar")
```

- [ ] **Step 10: Update the "why sidebar not tab bar" comments in the three E2E files**

These three comments explained a *choice* between two available data sources (sidebar vs. tab bar). Only one source exists now, so the contrast is moot — reword to state the sidebar is used, without contrasting against a removed alternative.

In `CalixUITests/SessionBrowserAttachKillE2ETests.swift`, the `sidebarTabTitles()` doc comment (currently lines 114-139) reads:

```swift
    /// `SidebarContentView.swift`'s own `visibleTitle`) of every tab
    /// currently shown in the SIDEBAR (not the horizontal tab bar --
    /// see below for why), read from each row's own descendant
    /// `StaticText.value` (this codebase's established pattern for
    /// hosted-SwiftUI text: exposed via `value`, not plain `label` --
    /// same as `SessionBrowserRowView`'s row text, per this file's own
    /// header comment).
    ///
    /// Deliberately sidebar, NOT `CalixUITestCase.countTabBarTabs()`'s
    /// tab bar: field-verified across three separate accessibility
    /// snapshots (Xcode's own auto-attached failure diagnostics) that
    /// with the Session Browser panel ALSO open, the tab bar's own row
    /// `Group` elements expose NEITHER their `calix.tabBar.tab.<UUID>`
    /// identifier NOR their `calix.tabBar.tab.index.N` value under any
    /// window-focus arrangement tried (a direct click, a query scoped to
    /// the specific window element, and raising the window via the
    /// standard "Window" menu were all tried and all still showed the
    /// SAME missing attributes in the resulting snapshot) -- only the
    /// row's own nested close-button `Image` carries an identifier. The
    /// SIDEBAR's equivalent rows (`calix.sidebar.tab.<UUID>`), by
    /// contrast, exposed their identifiers cleanly in every one of those
    /// same snapshots regardless of which window was key. Every existing
    /// test using `countTabBarTabs()` elsewhere in this codebase only
    /// ever has ONE window open at a time, so this suite is the first to
    /// hit the tab bar's own limitation here.
```

Change it to:

```swift
    /// `SidebarContentView.swift`'s own `visibleTitle`) of every tab
    /// currently shown in the sidebar, read from each row's own
    /// descendant `StaticText.value` (this codebase's established
    /// pattern for hosted-SwiftUI text: exposed via `value`, not plain
    /// `label` -- same as `SessionBrowserRowView`'s row text, per this
    /// file's own header comment).
    ///
    /// Reads titles via `StaticText.value` rather than
    /// `CalixUITestCase.countSidebarTabs()`'s identifier-based count:
    /// this suite needs each tab's actual title text (to prove which
    /// tab attached where), not just a count or a per-group UUID.
```

In `CalixUITests/RealQuitRestoreE2ETests.swift`, the `sidebarTabTitles()` doc comment (currently around line 161-165) reads:

```swift
    /// Mirrors `SessionBrowserAttachKillE2ETests.sidebarTabTitles()`
    /// exactly (see that file's own doc comment for why the sidebar,
    /// not the horizontal tab bar).
```

Change it to:

```swift
    /// Mirrors `SessionBrowserAttachKillE2ETests.sidebarTabTitles()`
    /// exactly (see that file's own doc comment for why it reads titles
    /// via `StaticText.value` instead of an identifier-based count).
```

In `CalixUITests/SessionPersistenceE2ETests.swift`, the `sidebarTabTitles()` doc comment (currently around line 204-208) reads:

```swift
    /// The visible title of every tab currently shown in the sidebar,
    /// mirroring `SessionBrowserAttachKillE2ETests.sidebarTabTitles()`
    /// exactly (see that file's own doc comment for why the sidebar,
    /// not the horizontal tab bar).
```

Change it to:

```swift
    /// The visible title of every tab currently shown in the sidebar,
    /// mirroring `SessionBrowserAttachKillE2ETests.sidebarTabTitles()`
    /// exactly (see that file's own doc comment for why it reads titles
    /// via `StaticText.value` instead of an identifier-based count).
```

- [ ] **Step 11: Full build**

Run: `xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 12: Full unit test suite**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests`
Expected: `** TEST SUCCEEDED **`. (Nothing in this task touches `CalixTests` — confirmed during planning — this is a regression check, not expected to find anything.)

- [ ] **Step 13: Scoped `CalixUITests` run**

Run the specific classes this task touches, using the `CalixUITests` scheme (not `Calix` — `CalixUITests` is its own scheme, built on a `DebugUITesting` config; confirmed during planning that `xcodebuild test -scheme Calix -only-testing:CalixUITests` fails with "CalixUITests isn't a member of the specified test plan or scheme"):

```bash
xcodebuild test -project Calix.xcodeproj -scheme CalixUITests -destination 'platform=macOS' \
  -only-testing:CalixUITests/GroupManagementUITests \
  -only-testing:CalixUITests/MenuShortcutsUITests \
  -only-testing:CalixUITests/TabManagementUITests \
  -only-testing:CalixUITests/TabRenameUITests \
  -only-testing:CalixUITests/CommandPaletteUITests \
  -only-testing:CalixUITests/TabReorderUITests
```

Expected: `** TEST SUCCEEDED **`. The full `CalixUITests` target is deliberately not run here — it includes long-running E2E suites (session persistence, real quit/restore) unrelated to this change; scoping to the six classes this task actually modifies keeps the loop fast without skipping real coverage. If any of these six fail, do not proceed to Step 14 — fix and re-run this exact scoped command first.

- [ ] **Step 14: Amend the spec's Testing section**

In `docs/superpowers/specs/2026-08-07-remove-top-tab-strip-design.md`, the `## Testing` section currently reads:

```markdown
No unit test (`CalixTests`) references `TabBarContentView` or its accessibility identifiers. Three UI test files (`CalixUITestCase.swift:137`, `GroupManagementUITests.swift:49`, `MenuShortcutsUITests.swift:413`) mention `TabBarContentView` only in explanatory comments about tab-list data flow, not as an element lookup — none click or query strip-specific identifiers. These comments should be updated for accuracy but require no test-logic changes.
```

Change it to:

```markdown
No unit test (`CalixTests`) references `TabBarContentView` or its accessibility identifiers — confirmed via `grep -rln "TabBarContentView\|TabItemButton\|WheelBridgeView\|AccessibilityID\.TabBar" CalixTests/`.

The UI test suite (`CalixUITests`) is a different story: six files have real, functioning dependencies on the strip's accessibility identifiers via `CalixUITestCase.countTabBarTabs()`/`.currentTabBarTabIdentifiers()` and `TabReorderUITests`'s own tab-bar-specific queries — not just explanatory comments, as originally assessed. `GroupManagementUITests` and `MenuShortcutsUITests` each have one test that genuinely needs to observe "which group is currently active," a signal only the strip provided for free; the sidebar needed a small new accessibility hook (a per-active-group marker element) to keep providing it. `TabManagementUITests`, `TabRenameUITests`, and `CommandPaletteUITests` needed only a mechanical rename (they never relied on tab-bar-specific behavior, just a tab count). `TabReorderUITests` had two tests that exercised the tab bar's own drag-reorder directly — deleted outright, since they tested the removed surface itself, not something broken by its removal. See the implementation plan's Task 2 for the full accounting.
```

- [ ] **Step 15: Commit**

```bash
git add Calix/Views/Sidebar/SidebarContentView.swift Calix/Helpers/AccessibilityID.swift \
  CalixUITests/CalixUITestCase.swift CalixUITests/GroupManagementUITests.swift \
  CalixUITests/MenuShortcutsUITests.swift CalixUITests/TabManagementUITests.swift \
  CalixUITests/TabRenameUITests.swift CalixUITests/CommandPaletteUITests.swift \
  CalixUITests/TabReorderUITests.swift CalixUITests/SessionBrowserAttachKillE2ETests.swift \
  CalixUITests/RealQuitRestoreE2ETests.swift CalixUITests/SessionPersistenceE2ETests.swift \
  docs/superpowers/specs/2026-08-07-remove-top-tab-strip-design.md
git commit -m "test: add sidebar active-group marker, fix UI tests broken by tab strip removal"
```

---

### Task 3: Titlebar accessory git-changes toggle button

**Files:**
- Create: `Calix/Views/MainWindow/GitChangesTitlebarButtonView.swift`
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift` (init, `setupUI()` region, `refreshHostingView()`)

**Interfaces:**
- Consumes: `AccessibilityID.Titlebar.gitChangesButton` (Task 1), `gitChangesController.isChangesPanelVisible` (existing), `windowSession.activeGroup?.activeTab?.content` (existing), `toggleGitChangesPanel()` (existing, private on `CalixWindowController`).
- Produces: `GitChangesTitlebarButtonView(isOpen: Bool, isVisible: Bool, onToggle: (() -> Void)?)`, a plain SwiftUI view with no internal state.

- [ ] **Step 1: Create `GitChangesTitlebarButtonView.swift`**

Create `Calix/Views/MainWindow/GitChangesTitlebarButtonView.swift`:

```swift
// GitChangesTitlebarButtonView.swift
// Calix
//
// The git-changes panel toggle, hosted as a titlebar accessory
// (NSTitlebarAccessoryViewController) on the window's right side.
// Replaces the button that used to live inside the now-deleted
// TabBarContentView -- same icon, same visibility/highlight rules,
// relocated because the tab strip it lived in was redundant with the
// Workspace sidebar's own tab list. Deliberately plain (.buttonStyle
// .plain, no GlassButtonModifier): the strip's version used this
// codebase's glass-chrome system, but a native window titlebar isn't
// part of that chrome, so a plain button fits its surroundings better.
// See CalixWindowController's refreshHostingView() for what drives
// isOpen/isVisible.

import SwiftUI

struct GitChangesTitlebarButtonView: View {
    var isOpen: Bool
    var isVisible: Bool
    var onToggle: (() -> Void)?

    var body: some View {
        if isVisible {
            Button(action: { onToggle?() }) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(isOpen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .help(isOpen ? "Hide Git Changes" : "Show Git Changes")
            .accessibilityLabel("Toggle Git Changes Panel")
            .accessibilityAddTraits(isOpen ? [.isSelected] : [])
            .accessibilityIdentifier(AccessibilityID.Titlebar.gitChangesButton)
        }
    }
}
```

- [ ] **Step 2: Add the titlebar accessory setup to `CalixWindowController`**

In `Calix/Views/MainWindow/CalixWindowController.swift`, add a new stored property near the existing `private var hostingView: NSHostingView<MainContentView>?` (currently line 31):

```swift
    private var gitChangesAccessoryHostingView: NSHostingView<GitChangesTitlebarButtonView>?
```

Add a new private method, placed right after `setupUI()`'s closing brace:

```swift
    private func setupGitChangesTitlebarAccessory() {
        guard let window else { return }
        let hosting = NSHostingView(rootView: currentGitChangesButtonView())
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = hosting
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
        self.gitChangesAccessoryHostingView = hosting
    }

    private func currentGitChangesButtonView() -> GitChangesTitlebarButtonView {
        let isVisible: Bool = {
            if case .terminal = windowSession.activeGroup?.activeTab?.content { return true }
            return false
        }()
        return GitChangesTitlebarButtonView(
            isOpen: gitChangesController.isChangesPanelVisible,
            isVisible: isVisible,
            onToggle: { [weak self] in self?.toggleGitChangesPanel() }
        )
    }
```

In `init(window:windowSession:restoring:initialHost:)` (currently lines 373-384), call the new setup method right after `setupUI()`:

```swift
        setupCommandRegistry()
        setupUI()
        setupGitChangesTitlebarAccessory()
        if !restoring { setupTerminalSurface(host: initialHost) }
```

- [ ] **Step 3: Hook the refresh into `refreshHostingView()`**

In the same file, `refreshHostingView()` (currently lines 1054-1056) currently reads:

```swift
    private func refreshHostingView() {
        hostingView?.rootView = buildMainContentView()
    }
```

Change it to also refresh the accessory:

```swift
    private func refreshHostingView() {
        hostingView?.rootView = buildMainContentView()
        gitChangesAccessoryHostingView?.rootView = currentGitChangesButtonView()
    }
```

This is the single choke point `GitChangesController.refresh` (wired at construction to `{ [weak self] in self?.refreshHostingView() }`), `refreshRecoveryBar()`, `refreshApprovalBanner()`, and every tab-switch/mutation path in this file already route through — confirmed during planning that this one change covers every call site (~18 of them) with no further wiring needed.

- [ ] **Step 4: Full build**

Run: `xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Full unit test suite**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Manual verification (required — this button has no dedicated automated test, mirroring the pre-existing lack of coverage for its original tab-strip version)**

Using the `run` skill, or by asking your human partner to check directly (do not attempt full-screen automation/screenshotting — this app's window contains no test-harness-friendly automation surface, and blindly driving the real GUI risks capturing unrelated on-screen content):
1. Launch the app. Confirm a small branch-icon button appears in the top-right of the window's titlebar when the active tab is a terminal, and confirm it's legible against the transparent/glass titlebar background (this is the one visual-polish risk that can't be verified from source alone).
2. Confirm the button disappears when switching to a browser tab, and reappears when switching back to a terminal tab.
3. Click it; confirm the git-changes panel opens and the icon turns accent-colored. Click again; confirm it closes and the icon returns to its default color.
4. Switch tabs, groups, and toggle the sidebar; confirm the button's state always matches the newly-active tab's actual panel state (not a stale value from the previously-active tab).

- [ ] **Step 7: Commit**

```bash
git add Calix/Views/MainWindow/GitChangesTitlebarButtonView.swift Calix/Views/MainWindow/CalixWindowController.swift
git commit -m "feat: relocate git-changes toggle to a titlebar accessory button"
```

---

## Final verification

- [ ] Full build: `xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build` → `** BUILD SUCCEEDED **`.
- [ ] Full unit test suite: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests` → `** TEST SUCCEEDED **`.
- [ ] Scoped UI test suite (Task 2's Step 13 command, re-run once more against the final state): → `** TEST SUCCEEDED **`.
- [ ] Task 3 Step 6's manual pass, actually performed (not skipped) before considering this plan done.
