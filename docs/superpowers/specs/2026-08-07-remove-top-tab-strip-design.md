# Remove the top tab strip in favor of the Workspace sidebar

Date: 2026-08-07

## Problem

Calix has two UI surfaces that both render the same `Tab`/`TabGroup` model: a horizontal strip at the top of the window (`TabBarContentView`, showing only the active group's tabs) and the left sidebar's "Workspace" mode (`SidebarContentView`, showing every group and — once expanded — every tab in each). Click-to-switch, close, rename, and drag-to-reorder tabs exist in both places today. This is visually and functionally redundant; the top strip should be removed.

## Scope

### Removed

- `Calix/Views/TabBar/TabBarContentView.swift` in full — the SwiftUI strip, its `TabItemButton` cell, the `WheelBridgeView` horizontal-scroll bridge, and the strip's own "+" new-tab button / double-click-empty-space gesture.
- The strip's row in `MainContentView`'s `VStack` (`MainContentView.swift:154-170`). Terminal/browser content simply starts where the strip used to be; no replacement spacer needed.
- The strip-specific closures wired in `CalixWindowController.buildMainContentView()` (`CalixWindowController.swift:1002-1052`) collapse to just the sidebar's existing copies (`onTabSelected`, `onNewTab`, `onCloseTab`, `onMoveTab`, `onTabRenamed` — the sidebar already has its own wiring for all of these; only the strip's duplicate wiring goes away).
- The `arrow.triangle.branch` git-changes button and `+` new-tab button that lived inside the strip (see below for where each goes).

### Explicitly kept

- **`Calix/Views/TabBar/TabClickRecognizer.swift`** (`TabClickContainer`/`ClickContainerNSView`). Initial research assumed this was strip-only; it is not — `SidebarContentView.swift` (lines 388, 698) depends on it directly for its own drag-reorder mouse handling. Deleting it would break the sidebar. This file's location under `Views/TabBar/` is now a misnomer but moving/renaming it is out of scope for this change (pure churn, no behavior difference).
- `Tab.renameRequestID` (`Tab.swift:33-39`) — a shared trigger already consumed by both `TabItemButton` and the sidebar's `TabRowItemView`. No model change needed; the sidebar alone honors it going forward. Its doc comment's mention of `TabItemButton` becomes stale and should be trimmed to reference only `TabRowItemView`.

## Git-changes toggle button → titlebar accessory

New `NSTitlebarAccessoryViewController` (a new pattern for this codebase — no existing usage found), added to `CalixWindow`/`CalixWindowController`, `.layoutAttribute = .right`, hosting a small SwiftUI button reusing the same icon and behavior the strip's button had:

- **Icon**: `arrow.triangle.branch`.
- **Conditional visibility**: hidden entirely when the active tab is a browser tab (mirrors today's `showGitChangesButton`) — a browser tab has no git-changes panel to toggle.
- **Highlighted state**: accent-color icon when the panel is open, `.primary` otherwise (mirrors today's `isGitChangesPanelOpen`).
- Same accessibility identifier (`AccessibilityID.TabBar.gitChangesButton` — kept as-is; renaming it to drop the now-inaccurate `tabBar` prefix is optional polish, not required), same tooltip text, same `onToggleGitChangesPanel` closure.

This must update live as the active tab changes (browser ↔ terminal) and as the panel opens/closes — the same reactive wiring the strip had, just retargeted at the accessory controller's hosting view. `titlebarAppearsTransparent = true` / `titleVisibility = .hidden` / `.fullSizeContentView` (`CalixWindow.swift:26-31`) impose no known conflict with a titlebar accessory view — this is a standard, supported combination.

## Explicitly out of scope / accepted tradeoffs

These were raised and deliberately decided against adding replacement UI for:

- **New-tab affordance**: the strip's clickable "+" button and double-click-empty-space gesture are not replaced. Cmd+T, the File menu, and the command palette (`tab.new`, `CalixWindowController.swift:398`) already create a new tab and remain unchanged.
- **Sidebar-hidden tab switching**: the Workspace sidebar can be hidden entirely (`toggleSidebar()`, `CalixWindowController.swift:1892`). Once the strip is gone, hiding the sidebar leaves no clickable tab list — only the existing keyboard shortcuts (Cmd+Shift+] / Cmd+Shift+[, `tab.next`/`tab.previous`, `CalixWindowController.swift:405-409`) and command palette remain reachable. Accepted as-is; no change to `toggleSidebar()`'s availability.
- **Horizontal mouse-wheel-scroll-over-strip**: dropped with the strip. No replacement needed — the sidebar's tab list is a normal vertically-scrolling list.
- **Collapsed active-group edge case** (pre-existing, not newly introduced): if a user collapses the currently-active group in the Workspace sidebar, they lose visibility into its individual tabs there too (today they'd still have the strip as a fallback; after this change they would not, short of expanding the group again or using keyboard shortcuts). Not addressed here — no auto-expand-active-group behavior is being added. Flagged for awareness, not a requirement.

## Testing

No unit test (`CalixTests`) references `TabBarContentView` or its accessibility identifiers. Three UI test files (`CalixUITestCase.swift:137`, `GroupManagementUITests.swift:49`, `MenuShortcutsUITests.swift:413`) mention `TabBarContentView` only in explanatory comments about tab-list data flow, not as an element lookup — none click or query strip-specific identifiers. These comments should be updated for accuracy but require no test-logic changes.

New coverage needed:
- The titlebar accessory button's conditional visibility (hidden for a browser tab, shown for a terminal tab) and highlighted state (open vs. closed), mirroring whatever test coverage (if any) existed for the strip's version — a targeted search during planning should confirm whether `showGitChangesButton`/`isGitChangesPanelOpen` already have unit coverage at the state-computation level (independent of which view renders them) that carries over unchanged.
