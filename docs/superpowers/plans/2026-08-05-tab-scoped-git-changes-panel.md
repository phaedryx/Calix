# Tab-Scoped Git Changes Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace window-level git-changes state + sibling "diff tabs" + the
`diffOriginTabIDs` side-table with per-tab changes/diff panes living inside
each `Tab`'s existing `SplitTree`.

**Architecture:** `Tab` gains `paneContent: [UUID: TabPaneKind]`, a side-map
parallel to the existing `registry: SurfaceRegistry`. A `splitTree` leaf
present in `paneContent` renders as a changes-list or diff pane; a leaf
absent from it falls back to `registry` (today's only case, a terminal
surface). Git-changes state (`gitEntries`, `branchDeltaEntries`,
`gitChangesState`, `repoRoot`) moves from `WindowSession` onto `Tab`. Diff
tabs, `TabContent.diff(source:)`, and `diffOriginTabIDs` are deleted, not
migrated — see spec at `docs/superpowers/specs/2026-08-05-tab-scoped-git-changes-panel-design.md`.

**Tech Stack:** Swift 6, AppKit/SwiftUI (macOS), XCTest + Swift Testing
(`CalixTests` target), `xcodebuild test` via CLI.

## Global Constraints

- Every task must leave the app building (`xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`) and `CalixTests` green before commit.
- No task may leave both the old (window-level / sibling-tab) and new (per-tab / pane) mechanisms half-wired at the same time once a task claims to "cut over" a piece — either it's fully moved, or deferred whole to a later task.
- Follow existing test conventions exactly: `GitChangesController`/model tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `Issue.record`) in `CalixTests/Git/DiffTabLifecycleTests.swift`, matching its existing scratch-git-repo fixture helpers (`makeScratchDirectory`, `runGit`, `waitForDiffState`).
- **Baseline correction:** this plan's line numbers/code were captured from a mid-session working state that included an interim fix (`diffOriginTabIDs`, `agentTabCandidates`, `sendReviewToAgent(_:preferredTabID:)`, `submitDiffReview_targetsOriginTab_notGlobalScan`). That fix was never committed, so it is **absent** from this worktree's actual baseline (a fresh worktree only ever contains committed history) — `sendReviewToAgent(_ payload: String) -> ReviewSendResult` in this worktree still has its ORIGINAL inline cross-group title-scanning logic (no `preferredTabID` parameter, no separate `agentTabCandidates` function, `GitChangesController.swift` has no `diffOriginTabIDs` property). Task 4 and Task 7 build the new tab-scoped design directly from this original code — there is nothing from an interim fix to delete first. Where a task's text says "delete X" and X doesn't exist in this worktree, treat it as "X is not present, skip that removal and implement the target state directly."
- **This project uses `xcodegen`**: `Calix.xcodeproj` is generated from `project.yml` and is gitignored — it does not exist in a fresh checkout/worktree. Run `xcodegen generate` once before the first build in a new worktree, and again any time a `.swift` file is added or removed (this project's `CalixTests`/`Calix` targets use directory-glob `sources:` in `project.yml`, not individually-listed files, so a new file just needs `xcodegen generate` re-run — no manual `project.pbxproj` editing is needed, unlike what an isolated look at the `.pbxproj` format might suggest).

---

### Task 1: `TabPaneKind` + `Tab.paneContent`

**Files:**
- Modify: `Calix/Models/Session/Tab.swift`
- Test: `CalixTests/Git/DiffTabLifecycleTests.swift`

**Interfaces:**
- Produces: `TabPaneKind` enum (`.gitChanges`, `.diff(source: DiffSource)`) and `Tab.paneContent: [UUID: TabPaneKind]`, consumed by every later task.

- [ ] **Step 1: Write the failing test**

Add to `CalixTests/Git/DiffTabLifecycleTests.swift` (near the top-level model tests, e.g. after `diffSourceDedup()`):

```swift
@Test func tabPaneContent_defaultsEmpty_andStoresPaneKinds() {
    let tab = Tab()
    #expect(tab.paneContent.isEmpty)

    let leafID = UUID()
    tab.paneContent[leafID] = .gitChanges
    #expect(tab.paneContent[leafID] == .gitChanges)

    let diffLeafID = UUID()
    let source = DiffSource.unstaged(path: "one.txt", workDir: "/repo")
    tab.paneContent[diffLeafID] = .diff(source: source)
    guard case .diff(let storedSource) = tab.paneContent[diffLeafID] else {
        Issue.record("Expected .diff pane kind")
        return
    }
    #expect(storedSource == source)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests/tabPaneContent_defaultsEmpty_andStoresPaneKinds`
Expected: FAIL — `value of type 'Tab' has no member 'paneContent'` / `Cannot find type 'TabPaneKind'`.

- [ ] **Step 3: Add `TabPaneKind` and `paneContent` to `Tab.swift`**

In `Calix/Models/Session/Tab.swift`, add near `TabContent`:

```swift
enum TabPaneKind: Equatable, Sendable {
    case gitChanges
    case diff(source: DiffSource)
}
```

Add to the `Tab` class body (after `var sessionRefs: [UUID: SessionRef]`):

```swift
    /// Non-terminal content for a `splitTree` leaf. A leaf present here
    /// renders as a changes-list or diff pane; a leaf absent from it is a
    /// terminal surface via `registry` (today's only case).
    var paneContent: [UUID: TabPaneKind] = [:]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests`
Expected: all pass, including the new test.

- [ ] **Step 5: Commit**

```bash
git add Calix/Models/Session/Tab.swift CalixTests/Git/DiffTabLifecycleTests.swift
git commit -m "feat: add TabPaneKind and Tab.paneContent for pane-based git review"
```

---

### Task 2: Move git-changes state from `WindowSession` onto `Tab`

**Files:**
- Modify: `Calix/Models/Session/WindowSession.swift`
- Modify: `Calix/Models/Session/Tab.swift`
- Modify: `Calix/Features/Git/GitChangesController.swift`
- Modify: `Calix/Views/Sidebar/SidebarContentView.swift:238-248` (rebind `GitChangesView` to `activeTab`)
- Test: `CalixTests/Git/DiffTabLifecycleTests.swift`

**Interfaces:**
- Consumes: `Tab` from Task 1.
- Produces: `Tab.gitEntries: [GitFileEntry]`, `Tab.branchDeltaBase: String?`, `Tab.branchDeltaEntries: [BranchDiffEntry]`, `Tab.gitChangesState: GitChangesState`, `Tab.repoRoot: String?` — consumed by Task 4 (openDiffTab) and Task 9 (new UI).

- [ ] **Step 1: Write the failing test**

Add to `DiffTabLifecycleTests.swift`, replacing the assumption in `gitChangesStateTransitions()`-style tests that state lives on `WindowSession`:

```swift
@Test func gitChangesState_livesOnTab_notWindowSession() {
    let tab = Tab()
    #expect(tab.gitChangesState == .notLoaded)
    tab.gitChangesState = .loading
    #expect(tab.gitChangesState == .loading)
}

@Test func twoTabs_haveIndependentGitChangesState() {
    let tabA = Tab(pwd: "/repo-a")
    let tabB = Tab(pwd: "/repo-b")
    let session = WindowSession(initialTab: tabA)
    session.activeGroup!.addTab(tabB)

    tabA.gitChangesState = .loaded
    tabA.gitEntries = [GitFileEntry(path: "a.txt", origPath: nil, status: .modified, isStaged: false, renameScore: nil)]

    #expect(tabB.gitChangesState == .notLoaded)
    #expect(tabB.gitEntries.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests/gitChangesState_livesOnTab_notWindowSession -only-testing:CalixTests/DiffTabLifecycleTests/twoTabs_haveIndependentGitChangesState`
Expected: FAIL — `value of type 'Tab' has no member 'gitChangesState'` etc.

- [ ] **Step 3: Move the fields**

In `Calix/Models/Session/WindowSession.swift`, delete these lines (24-29 currently):
```swift
    var gitChangesState: GitChangesState = .notLoaded
    var gitEntries: [GitFileEntry] = []
    var branchDeltaBase: String?
    var branchDeltaEntries: [BranchDiffEntry] = []
    var repoRoots: [String: String] = [:]
```
Keep `sidebarMode` for now (deleted in Task 8).

In `Calix/Models/Session/Tab.swift`, add to the `Tab` class body (alongside `paneContent`):

```swift
    var gitChangesState: GitChangesState = .notLoaded
    var gitEntries: [GitFileEntry] = []
    var branchDeltaBase: String?
    var branchDeltaEntries: [BranchDiffEntry] = []
    /// The work tree this tab's changes/diff panes belong to. Resolved once
    /// from `pwd` when `refreshStatus()` first succeeds for this tab — no
    /// fallback scan of other tabs, because ambiguity here was exactly the
    /// bug this design removes.
    var repoRoot: String?
```

- [ ] **Step 4: Update `GitChangesController` to read/write `activeTab`**

In `Calix/Features/Git/GitChangesController.swift`:

Delete the `currentRepoRoot: String?` property (line 61) and its doc comment.

Replace `findWorkDir()` (lines 331-354) — it previously had a 4-tier
fallback across tabs/groups; that ambiguity is exactly what this design
removes, so it now only ever resolves the active tab's own `pwd`:

```swift
    private func findWorkDir() -> String? {
        activeTab?.pwd
    }
```

Update `refreshStatus(showsLoadingState:)` (lines 116-178): every write to
`windowSession.gitChangesState`/`gitEntries`/`branchDeltaBase`/
`branchDeltaEntries`/`repoRoots`/`currentRepoRoot` becomes a write to
`activeTab?.<field>` instead (guard `let tab = activeTab else { return }` at
the top of the method, mirroring the existing `guard let workDir = findWorkDir() else { ... }` guard). `windowSession.repoRoots[workDir] = workDir` is deleted outright — `repoRoot` is a single value per tab now, no dictionary needed.

Update `handleWorkingFileSelected`/`handleBranchDeltaFileSelected` (lines 230-250): replace `currentRepoRoot` reads with `activeTab?.repoRoot`.

Update `isSidebarVisible` (lines 83-85) to read `activeTab?.gitChangesState` where it previously read window-level state — actually this property only reads `windowSession.showSidebar`/`sidebarMode`, no change needed here; leave as-is (touched in Task 8).

- [ ] **Step 5: Rebind the sidebar's changes UI to `activeTab`**

In `Calix/Views/Sidebar/SidebarContentView.swift:238-248`, change the `GitChangesView` binding from `windowSession.gitEntries`/`gitChangesState`/`branchDeltaBase`/`branchDeltaEntries` to `windowSession.activeGroup?.activeTab?.gitEntries` etc. (with `?? []`/`.notLoaded` defaults for a nil active tab). This is a temporary rebind — the whole `.changes` sidebar mode is deleted in Task 8 in favor of the new per-tab panel (Task 9); this step only keeps the app buildable and functionally correct in between.

- [ ] **Step 6: Run tests to verify everything passes**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests`
Expected: all pass. Also run the full build: `xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build` — expect `BUILD SUCCEEDED` (this step touches enough call sites that a full build check matters more than usual).

- [ ] **Step 7: Commit**

```bash
git add Calix/Models/Session/WindowSession.swift Calix/Models/Session/Tab.swift Calix/Features/Git/GitChangesController.swift Calix/Views/Sidebar/SidebarContentView.swift CalixTests/Git/DiffTabLifecycleTests.swift
git commit -m "refactor: move git-changes state from WindowSession onto Tab"
```

---

### Task 3: `SplitContainerView` renders pane-content leaves

**Files:**
- Create: `Calix/Views/Git/TabPaneResolution.swift`
- Create: `Calix/Views/Git/GitChangesPaneView.swift`
- Create: `Calix/Views/Git/DiffPaneView.swift`
- Modify: `Calix/Views/Split/SplitContainerView.swift`
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift:586,1000,1113-1134`
- Test: `CalixTests/Git/TabPaneResolutionTests.swift` (new file — see note on project registration below)

**Interfaces:**
- Consumes: `Tab.paneContent` from Task 1.
- Produces: `resolvePaneContent(leafID:in:) -> ResolvedLeafContent`; `SplitContainerView.updateRegistry(_:tab:)`, `SplitContainerView.refreshPaneContent()` — the latter consumed by Task 4's `GitChangesController.refresh` wiring.

**Architecture note (verified by reading the actual code, not assumed):**
`SplitContainerView` currently holds only `registry: SurfaceRegistry` and
`currentTree: SplitTree` — it has no `Tab` reference at all
(`SplitContainerView.swift:27-28`). Rendering a `.gitChanges`/`.diff` pane
needs `tab.paneContent`, `tab.gitEntries`, etc., so `SplitContainerView`
gains a `tab: Tab?` property alongside `registry`.

Also verified: `updateLayout(tree:)` early-returns when `oldTree == tree`
(`SplitContainerView.swift:84`, `guard oldTree != tree else { return }`).
`SplitTree` equality doesn't know about `paneContent` or git state, so
calling `updateLayout` again after e.g. a git-status refresh (no leaf
added/removed) is a guaranteed no-op — a separate `refreshPaneContent()`
method is required to push fresh data into already-rendered panes. This
mirrors the codebase's own documented convention: see the comment on
`CalixWindowController.refreshRecoveryBar()` (`CalixWindowController.swift:1071-1077`)
— *"`NSHostingView` is not relied on to pick up an external `@Observable`
change on its own"* — i.e. this codebase always mutates state then
explicitly reassigns a hosting view's `rootView`, it never depends on
Observation auto-invalidation reaching into a nested `NSHostingView`.

Nothing produces a `paneContent` entry yet (Task 4 does), so this task is
purely additive — it cannot regress existing terminal-only tabs, since
`resolvePaneContent` falls back to `.surface` whenever `paneContent[leafID]`
is nil, which is every leaf that exists today.

**Note on new test file registration:** this project uses `xcodegen`
(`project.yml` → generated, gitignored `Calix.xcodeproj`), with `CalixTests`'
sources declared as a directory glob (`path: CalixTests`) rather than an
individually-listed file list. A new file just needs `xcodegen generate`
re-run from the repo root before building/testing — no manual
`project.pbxproj` editing required.

- [ ] **Step 1: Write the failing test**

Create `CalixTests/Git/TabPaneResolutionTests.swift`:

```swift
// TabPaneResolutionTests.swift
// CalixTests

import Foundation
import Testing
@testable import Calix

@MainActor
struct TabPaneResolutionTests {
    @Test func resolvePaneContent_noPaneEntry_resolvesToSurface() {
        let leafID = UUID()
        let result = resolvePaneContent(leafID: leafID, in: [:])
        guard case .surface(let id) = result else {
            Issue.record("Expected .surface, got \(result)")
            return
        }
        #expect(id == leafID)
    }

    @Test func resolvePaneContent_gitChangesEntry_resolvesToGitChanges() {
        let leafID = UUID()
        guard case .gitChanges = resolvePaneContent(leafID: leafID, in: [leafID: .gitChanges]) else {
            Issue.record("Expected .gitChanges")
            return
        }
    }

    @Test func resolvePaneContent_diffEntry_resolvesToDiff() {
        let leafID = UUID()
        let source = DiffSource.unstaged(path: "one.txt", workDir: "/repo")
        guard case .diff(let resolvedSource) = resolvePaneContent(leafID: leafID, in: [leafID: .diff(source: source)]) else {
            Issue.record("Expected .diff")
            return
        }
        #expect(resolvedSource == source)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/TabPaneResolutionTests`
Expected: FAIL — `Cannot find 'resolvePaneContent' in scope`.

- [ ] **Step 3: Write the resolution function**

Create `Calix/Views/Git/TabPaneResolution.swift`:

```swift
// TabPaneResolution.swift
// Calix
//
// Decides what a SplitTree leaf renders as: a terminal surface (the
// implicit default, absent from a tab's paneContent) or a non-terminal pane
// (git-changes list, diff view) recorded explicitly in it.

import Foundation

enum ResolvedLeafContent: Equatable {
    case surface(UUID)
    case gitChanges
    case diff(DiffSource)
}

func resolvePaneContent(leafID: UUID, in paneContent: [UUID: TabPaneKind]) -> ResolvedLeafContent {
    switch paneContent[leafID] {
    case .none:
        return .surface(leafID)
    case .gitChanges:
        return .gitChanges
    case .diff(let source):
        return .diff(source)
    }
}
```

- [ ] **Step 4: Create the two pane SwiftUI wrapper views**

Create `Calix/Views/Git/GitChangesPaneView.swift` — reads directly off `tab`
(an `@Observable` class) so the enclosing `NSHostingView`'s body re-evaluates
whenever `tab.gitEntries`/`gitChangesState`/etc. change, as long as
`refreshPaneContent()` (Step 6) actually re-triggers a body evaluation by
reassigning `rootView`:

```swift
// GitChangesPaneView.swift
// Calix

import SwiftUI

struct GitChangesPaneView: View {
    let tab: Tab
    var onWorkingFileSelected: ((GitFileEntry) -> Void)?
    var onBranchDeltaFileSelected: ((BranchDiffEntry) -> Void)?
    var onRefresh: (() -> Void)?

    var body: some View {
        GitChangesView(
            gitChangesState: tab.gitChangesState,
            gitEntries: tab.gitEntries,
            branchDeltaBase: tab.branchDeltaBase,
            branchDeltaEntries: tab.branchDeltaEntries,
            onWorkingFileSelected: onWorkingFileSelected,
            onBranchDeltaFileSelected: onBranchDeltaFileSelected,
            onRefresh: onRefresh
        )
    }
}
```

(`GitChangesView`'s real initializer, confirmed by reading
`Calix/Views/Git/GitChangesView.swift:8-16`: `gitChangesState`, `gitEntries`,
`branchDeltaBase`, `branchDeltaEntries` as `let`s, then
`onWorkingFileSelected`/`onBranchDeltaFileSelected`/`onRefresh` as optional
closures — the call above matches that exactly.)

Create `Calix/Views/Git/DiffPaneView.swift` — extracted from the live diff
render path at `MainContentView.swift:184-224` (which uses `DiffToolbarView`
+ `DiffGlassContentView`, confirmed by reading that file; **not**
`DiffContainerView`/`DiffViewRepresentable`, which appear unused outside
Previews/tests), parameterized by `leafID` instead of "the tab's one active
diff":

```swift
// DiffPaneView.swift
// Calix

import SwiftUI

struct DiffPaneView: View {
    let leafID: UUID
    let source: DiffSource
    let controller: GitChangesController
    let reduceTransparency: Bool
    let glassOpacity: Double
    let themeColor: Color
    var onSubmitReview: (() -> Void)?
    var onDiscardReview: (() -> Void)?
    var onSubmitAllReviews: (() -> Void)?
    var onDiscardAllReviews: (() -> Void)?

    var body: some View {
        let reviewStore = controller.reviewStore(for: leafID)
        VStack(spacing: 0) {
            DiffToolbarView(
                source: source,
                reviewStore: reviewStore,
                onSubmitReview: onSubmitReview,
                onDiscardReview: onDiscardReview,
                totalReviewCommentCount: controller.totalReviewCommentCount,
                reviewFileCount: controller.reviewFileCount,
                onSubmitAllReviews: onSubmitAllReviews,
                onDiscardAllReviews: onDiscardAllReviews
            )
            switch controller.diffState(for: leafID) {
            case .none, .loading:
                VStack {
                    Spacer()
                    ProgressView("Loading diff...")
                    Spacer()
                }
            case .success(let diff):
                DiffGlassContentView(
                    diff: diff,
                    reduceTransparency: reduceTransparency,
                    glassOpacity: glassOpacity,
                    reviewStore: reviewStore
                )
                .accessibilityIdentifier(AccessibilityID.Diff.content)
            case .error(let message):
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
        .accessibilityIdentifier(AccessibilityID.Diff.container)
    }
}
```

- [ ] **Step 5: Give `SplitContainerView` a `tab` reference and pane-hosting-view cache**

In `Calix/Views/Split/SplitContainerView.swift`, add alongside the existing
`private var registry: SurfaceRegistry` (line 27) and `scrollWrappers`
(line 29):

```swift
    private var tab: Tab?
    private var paneHostingViews: [UUID: NSHostingView<AnyView>] = [:]
    var onWorkingFileSelected: ((GitFileEntry) -> Void)?
    var onBranchDeltaFileSelected: ((BranchDiffEntry) -> Void)?
    var onRefreshGitChanges: (() -> Void)?
    var onSubmitReview: ((UUID) -> Void)?
    var onDiscardReview: ((UUID) -> Void)?
    var onSubmitAllReviews: (() -> Void)?
    var onDiscardAllReviews: (() -> Void)?
    var gitChangesController: GitChangesController?
    var reduceTransparency: Bool = false
    var glassOpacity: Double = 1.0
    var themeColor: Color = .accentColor
```

Update the initializer (line 53-57) and `updateRegistry` (line 68-78) to take a `tab`:

```swift
    init(registry: SurfaceRegistry, tab: Tab? = nil) {
        self.registry = registry
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
    }
```

```swift
    func updateRegistry(_ registry: SurfaceRegistry, tab: Tab?) {
        guard self.registry !== registry else { return }
        self.registry = registry
        self.tab = tab
        currentTree = SplitTree()
        scrollWrappers.removeAll()
        dividerCache.removeAll()
        dividersUsedThisPass.removeAll()
        paneHostingViews.values.forEach { $0.removeFromSuperview() }
        paneHostingViews.removeAll()
        subviews.forEach { $0.removeFromSuperview() }
        activeLeafID = nil
        needsLayout = true
    }
```

In `CalixWindowController.swift`, update the two call sites that construct a
`SplitContainerView` with no tab (`line 586` and `line 1000`'s fallback) to
rely on the new default `tab: Tab? = nil` param — no change needed there.
Update `rebuildSplitContainer()` (lines 1113-1134):

```swift
    private func rebuildSplitContainer() {
        guard let tab = activeTab else { return }
        if let container = splitContainerView {
            container.updateRegistry(tab.registry, tab: tab)
        } else {
            let container = SplitContainerView(registry: tab.registry, tab: tab)
            container.onTargetRatioChange = { [weak self] firstChildID, secondChildID, targetRatio, direction, splitRect in
                self?.handleDividerDrag(
                    firstChildFirstLeafID: firstChildID,
                    secondChildFirstLeafID: secondChildID,
                    targetRatio: targetRatio,
                    direction: direction,
                    splitRect: splitRect
                )
            }
            container.onActiveLeafChange = { [weak self] leafID in
                self?.activeTab?.splitTree.focusedLeafID = leafID
                self?.requestSave()
            }
            container.gitChangesController = gitChangesController
            container.onWorkingFileSelected = { [weak self] entry in self?.gitChangesController.handleWorkingFileSelected(entry) }
            container.onBranchDeltaFileSelected = { [weak self] entry in self?.gitChangesController.handleBranchDeltaFileSelected(entry) }
            container.onRefreshGitChanges = { [weak self] in self?.gitChangesController.refreshStatus() }
            container.onSubmitReview = { [weak self] leafID in self?.gitChangesController.submitDiffReview(leafID: leafID) }
            container.onDiscardReview = { [weak self] leafID in self?.gitChangesController.discardReview(leafID: leafID) }
            container.onSubmitAllReviews = { [weak self] in self?.gitChangesController.submitAllDiffReviews() }
            container.onDiscardAllReviews = { [weak self] in self?.gitChangesController.discardAllDiffReviews() }
            self.splitContainerView = container
        }
    }
```

- [ ] **Step 6: Render pane leaves and add `refreshPaneContent()`**

In `SplitContainerView.layoutNode`'s `.leaf(let id)` case
(`SplitContainerView.swift:179-194`), add an `else` branch after the
existing `if let surfaceView = registry.view(for: id) { ... }` (which only
fires for real surfaces; a pane leaf's `registry.view(for:)` is `nil`):

```swift
        case .leaf(let id):
            if let surfaceView = registry.view(for: id) {
                // existing SurfaceScrollView construction, unchanged
                ...
            } else if let tab {
                let hostingView: NSHostingView<AnyView>
                if let existing = paneHostingViews[id] {
                    hostingView = existing
                } else {
                    hostingView = NSHostingView(rootView: paneView(for: id, in: tab))
                    paneHostingViews[id] = hostingView
                }
                hostingView.frame = rect
                hostingView.autoresizingMask = []
                if hostingView.superview !== self {
                    addSubview(hostingView)
                }
            }
```

Add the view-construction helper and the explicit refresh entry point
(mirrors `refreshHostingView()`'s "mutate then reassign rootView" pattern,
per the architecture note above):

```swift
    private func paneView(for leafID: UUID, in tab: Tab) -> AnyView {
        switch resolvePaneContent(leafID: leafID, in: tab.paneContent) {
        case .surface:
            return AnyView(EmptyView())
        case .gitChanges:
            return AnyView(GitChangesPaneView(
                tab: tab,
                onWorkingFileSelected: onWorkingFileSelected,
                onBranchDeltaFileSelected: onBranchDeltaFileSelected,
                onRefresh: onRefreshGitChanges
            ))
        case .diff(let source):
            return AnyView(DiffPaneView(
                leafID: leafID,
                source: source,
                controller: gitChangesController ?? GitChangesController(
                    windowSession: WindowSession(), refresh: {}, switchToTab: { _ in }, deactivateCurrentTab: {}, sendToAgent: { _ in .failed }
                ),
                reduceTransparency: reduceTransparency,
                glassOpacity: glassOpacity,
                themeColor: themeColor,
                onSubmitReview: { [weak self] in self?.onSubmitReview?(leafID) },
                onDiscardReview: { [weak self] in self?.onDiscardReview?(leafID) },
                onSubmitAllReviews: onSubmitAllReviews,
                onDiscardAllReviews: onDiscardAllReviews
            ))
        }
    }

    /// Explicit repaint of every currently-rendered pane's data, independent
    /// of `updateLayout(tree:)` -- which early-returns on an unchanged tree
    /// (line 84) and so never fires on a pure data change like a git-status
    /// reload or a new review comment. Called from
    /// `GitChangesController.refresh` (Task 4) alongside the top-level
    /// `refreshHostingView()`.
    func refreshPaneContent() {
        guard let tab else { return }
        for (leafID, hostingView) in paneHostingViews {
            hostingView.rootView = paneView(for: leafID, in: tab)
        }
    }
```

(The `gitChangesController ?? GitChangesController(...)` fallback above only
guards against a theoretical nil at construction time in a preview/test
context; in the live app `rebuildSplitContainer()` always sets
`gitChangesController` before any pane leaf can exist, since `paneContent`
entries are only ever created by `GitChangesController.openDiffTab`/
`toggleChangesPanel` — Task 4/9 — which run through that same controller
instance.)

Also update `removeOrphanedSurfaces()` (`SplitContainerView.swift:330-352`)
to clean up `paneHostingViews` the same way it cleans `scrollWrappers`: add,
after the existing `for id in scrollWrappers.keys where !treeIDs.contains(id)`
loop, an identical loop over `paneHostingViews.keys`.

- [ ] **Step 7: Run test to verify it passes**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/TabPaneResolutionTests`
Expected: PASS. Also run: `xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build` — expect `BUILD SUCCEEDED`, and manually confirm via the `run` skill that existing terminal tabs/splits still render identically (nothing should visibly change yet, since no leaf has a `paneContent` entry in production code paths until Task 4).

- [ ] **Step 8: Commit**

```bash
git add Calix/Views/Git/TabPaneResolution.swift Calix/Views/Git/GitChangesPaneView.swift Calix/Views/Git/DiffPaneView.swift Calix/Views/Split/SplitContainerView.swift Calix/Views/MainWindow/CalixWindowController.swift CalixTests/Git/TabPaneResolutionTests.swift
git commit -m "feat: SplitContainerView renders git-changes/diff panes from Tab.paneContent"
```

---

### Task 4: `openDiffTab` inserts a leaf instead of a sibling `Tab`

**Files:**
- Modify: `Calix/Features/Git/GitChangesController.swift`
- Test: `CalixTests/Git/DiffTabLifecycleTests.swift`

**Interfaces:**
- Consumes: `Tab.paneContent`/`TabPaneKind` (Task 1), `Tab.repoRoot` (Task 2), `resolvePaneContent`/pane rendering (Task 3).
- Produces: `openDiffTab` inserting into `activeTab.splitTree`; `diffStates`/`reviewStores`/`diffTasks` now keyed by **leaf ID**, not "diff tab ID" — Task 5/6/7 depend on this key-meaning change.

- [ ] **Step 1: Write the failing test**

Replace `handleWorkingFileSelected_secondTab_loadsIndependentDiff` in
`DiffTabLifecycleTests.swift` with an assertion on the tree, not on
`group.tabs`:

```swift
@Test func handleWorkingFileSelected_insertsLeafIntoActiveTabSplitTree() async throws {
    let scratchDirectory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratchDirectory) }
    try runGit(["init", "-q", "-b", "main", scratchDirectory.path], in: scratchDirectory)
    try "one\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
    try runGit(["add", "-A"], in: scratchDirectory)
    try runGit(["commit", "-q", "-m", "base"], in: scratchDirectory)
    try "one-changed\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)

    let terminalTab = Tab(pwd: scratchDirectory.path)
    let session = WindowSession(initialTab: terminalTab)
    let group = session.activeGroup!
    let terminalLeafCountBefore = terminalTab.splitTree.allLeafIDs().count

    let controller = GitChangesController(
        windowSession: session,
        refresh: {},
        switchToTab: { id in group.activeTabID = id },
        deactivateCurrentTab: {},
        sendToAgent: { _, _ in .sent }
    )

    controller.refreshStatus()
    let deadline = ContinuousClock.now + Duration.seconds(5)
    while true {
        if case .loaded = terminalTab.gitChangesState { break }
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for git status load")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    let entry = GitFileEntry(path: "one.txt", origPath: nil, status: .modified, isStaged: false, renameScore: nil)
    controller.handleWorkingFileSelected(entry)

    // No new sibling Tab -- still exactly one Tab in the group.
    #expect(group.tabs.count == 1)
    #expect(group.tabs[0].id == terminalTab.id)

    // A new leaf was inserted into the SAME tab's splitTree.
    #expect(terminalTab.splitTree.allLeafIDs().count == terminalLeafCountBefore + 1)

    guard let diffLeafID = terminalTab.splitTree.allLeafIDs().first(where: { $0 != terminalTab.splitTree.root?.leafID }) ?? terminalTab.splitTree.allLeafIDs().last else {
        Issue.record("Expected a diff leaf")
        return
    }
    guard case .diff(let source) = terminalTab.paneContent[diffLeafID] else {
        Issue.record("Expected paneContent[diffLeafID] == .diff")
        return
    }
    guard case .unstaged(let path, _) = source else {
        Issue.record("Expected .unstaged source")
        return
    }
    #expect(path == "one.txt")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests/handleWorkingFileSelected_insertsLeafIntoActiveTabSplitTree`
Expected: FAIL — `group.tabs.count == 1` fails (currently 2, since `openDiffTab` still appends a sibling tab).

- [ ] **Step 3: Rewrite `openDiffTab`**

In `Calix/Features/Git/GitChangesController.swift`, replace `openDiffTab(source:)` (lines 252-321):

```swift
    private func openDiffTab(source: DiffSource) {
        guard let group = windowSession.activeGroup, let tab = group.activeTab else { return }

        // Dedup: check if this source is already open as a pane in this tab.
        if let existingLeafID = tab.paneContent.first(where: {
            if case .diff(let existingSource) = $0.value { return existingSource == source }
            return false
        })?.key {
            tab.splitTree.focusedLeafID = existingLeafID
            refresh()
            return
        }

        let (newTree, newLeafID) = tab.splitTree.insert(
            at: tab.splitTree.focusedLeafID ?? tab.splitTree.allLeafIDs().first ?? UUID(),
            direction: .horizontal
        )
        tab.splitTree = newTree
        tab.paneContent[newLeafID] = .diff(source: source)

        diffStates[newLeafID] = .loading
        let reviewStore = DiffReviewStore()
        reviewStore.onCommentsChanged = { [weak self] in self?.refresh() }
        reviewStores[newLeafID] = reviewStore
        refresh()

        diffTasks[newLeafID] = Task { [weak self] in
            guard let self else { return }
            do {
                let rawDiff = try await GitService.fileDiff(source: source)
                guard !Task.isCancelled else { return }

                let path: String
                switch source {
                case .unstaged(let p, _), .staged(let p, _), .branchDelta(let p, _, _), .untracked(let p, _):
                    path = p
                }
                let parsed = DiffParser.parse(rawDiff, path: path)
                guard !Task.isCancelled else { return }

                guard tab.paneContent[newLeafID] != nil else { return }
                self.diffStates[newLeafID] = .success(parsed)
                self.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                self.diffStates[newLeafID] = .error(error.localizedDescription)
                self.refresh()
            }
        }
    }
```

Note the "tab still exists" re-verification (previously
`windowSession.groups.flatMap(\.tabs).contains(where:)`) becomes `tab.paneContent[newLeafID] != nil` — simpler, because we already hold a direct reference to `tab` (a class instance) rather than needing to re-find it by ID, and the existence check that actually matters is "has this pane been closed already," not "does the tab still exist."

Update `activeDiffState`/`activeDiffSource`/`activeDiffReviewStore` (lines
87-100) — these no longer make sense as *singular* properties (a tab can
have multiple open diff panes at once). Delete them; Task 3's `DiffPaneView`
reads `diffStates[leafID]`/`reviewStores[leafID]` directly via new
leaf-keyed accessors:

```swift
    func diffState(for leafID: UUID) -> DiffLoadState? { diffStates[leafID] }
    func diffSource(for leafID: UUID) -> DiffSource? {
        guard case .diff(let source) = activeTab?.paneContent[leafID] else { return nil }
        return source
    }
```

(`reviewStore(for:)` at lines 110-112 already takes an ID parameter — no
change needed, its key now means "leaf ID" instead of "diff tab ID", which
Task 3's `DiffPaneView` already passes correctly.)

Rename `discardReview(tabID:)` (lines 403-407) to `discardReview(leafID:)` —
purely a parameter rename, the body (`reviewStores[leafID]?.clearAll()`) is
unchanged, but Task 3's `SplitContainerView` wiring (`onDiscardReview = { [weak self] leafID in self?.gitChangesController.discardReview(leafID: leafID) }`) already assumes this name.

Finally, wire `refreshPaneContent()` into the existing `refresh` closure
passed to `GitChangesController` at construction
(`CalixWindowController.swift`'s `gitChangesController` lazy property,
`refresh: { [weak self] in self?.refreshHostingView() }`):

```swift
        refresh: { [weak self] in
            self?.refreshHostingView()
            self?.splitContainerView?.refreshPaneContent()
        },
```

Without this, a git-status reload or a new review comment would update
`tab.gitEntries`/`diffStates`/`reviewStores` but the already-rendered pane
`NSHostingView`s (Task 3) would keep showing stale content indefinitely,
since `updateLayout(tree:)` no-ops on an unchanged tree.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests`
Expected: this test passes. Other `DiffTabLifecycleTests` tests that assert
on `group.tabs.last` for a diff tab will now fail — fix each to assert on
`tab.splitTree`/`tab.paneContent` instead, following the same pattern as the
test above. (`handleWorkingFileSelected_secondTab_wrongTerminalTabPicksWrongRepoRoot`
and `agentTabCandidates_*` tests are superseded by Task 2's fix and Task 7's
deletion respectively — update/delete them here rather than leaving them
red.)

- [ ] **Step 5: Commit**

```bash
git add Calix/Features/Git/GitChangesController.swift CalixTests/Git/DiffTabLifecycleTests.swift
git commit -m "refactor: openDiffTab inserts a splitTree leaf instead of a sibling Tab"
```

---

### Task 5: Per-pane close

**Files:**
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift`
- Modify: `Calix/Features/Git/GitChangesController.swift`
- Test: `CalixTests/Git/DiffTabLifecycleTests.swift`

**Interfaces:**
- Consumes: leaf-keyed `diffStates`/`reviewStores`/`diffTasks` from Task 4.
- Produces: `GitChangesController.closeDiffPane(_ leafID: UUID) -> Bool` (returns `false` if the user cancelled due to unsent comments), `CalixWindowController.closePane(tab:group:leafID:)`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func closeDiffPane_removesLeafAndCleansUpState() {
    let tab = Tab()
    let leafID = UUID()
    tab.splitTree = SplitTree(leafID: leafID)
    tab.paneContent[leafID] = .diff(source: .unstaged(path: "one.txt", workDir: "/repo"))
    let session = WindowSession(initialTab: tab)

    let controller = GitChangesController(
        windowSession: session, refresh: {}, switchToTab: { _ in }, deactivateCurrentTab: {},
        sendToAgent: { _, _ in .sent }
    )
    controller.reviewStore(for: leafID) // no-op touch to confirm nil before close
    _ = controller.closeDiffPane(leafID)

    #expect(tab.paneContent[leafID] == nil)
    #expect(controller.reviewStore(for: leafID) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests/closeDiffPane_removesLeafAndCleansUpState`
Expected: FAIL — `value of type 'GitChangesController' has no member 'closeDiffPane'`.

- [ ] **Step 3: Rename/rewrite `closeDiffTab` as `closeDiffPane`**

In `GitChangesController.swift`, replace `closeDiffTab(_:)` (lines 323-329):

```swift
    /// Removes a diff/changes pane. Returns `false` (and leaves the pane in
    /// place) if the caller should abort because of unsent review comments
    /// -- callers are responsible for prompting; this method only reports
    /// whether there's something to prompt about.
    func closeDiffPane(_ leafID: UUID) {
        diffTasks[leafID]?.cancel()
        diffTasks.removeValue(forKey: leafID)
        diffStates.removeValue(forKey: leafID)
        reviewStores.removeValue(forKey: leafID)
        if let tab = windowSession.activeGroup?.activeTab {
            tab.paneContent.removeValue(forKey: leafID)
        }
    }
```

(Unsent-comment confirmation stays the caller's job, same as today's
`closeTab` — Task 6 generalizes that check for whole-tab close; per-pane
close in `CalixWindowController` gets its own equivalent single-pane check,
step 4 below.)

- [ ] **Step 4: Add `CalixWindowController.closePane(tab:group:leafID:)`**

Add near `closeSurfaceAndCleanUp` (`CalixWindowController.swift:2217`):

```swift
    private func closePane(tab: Tab, group: TabGroup, leafID: UUID) {
        if let store = gitChangesController.reviewStore(for: leafID), store.hasUnsubmittedComments {
            let alert = NSAlert()
            alert.messageText = "Unsent Review Comments"
            alert.informativeText = "This diff has \(store.comments.count) unsent review comment(s). Closing will discard them."
            alert.addButton(withTitle: "Discard & Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        gitChangesController.closeDiffPane(leafID)
        tab.splitTree = tab.splitTree.remove(leafID).tree
        if tab.id == activeTab?.id {
            splitContainerView?.updateLayout(tree: tab.splitTree)
        }
        refreshHostingView()
        requestSave()
    }
```

Wire this as the action for each pane's close button (added in `DiffPaneView`/`GitChangesView`'s toolbar from Task 3 — a small `onClose: () -> Void` callback threaded through, calling `closePane(tab:group:leafID:)` with the pane's own `leafID`).

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Calix/Features/Git/GitChangesController.swift Calix/Views/MainWindow/CalixWindowController.swift CalixTests/Git/DiffTabLifecycleTests.swift
git commit -m "feat: close an individual git-changes/diff pane without closing the tab"
```

---

### Task 6: Whole-tab close warns across every diff pane

**Files:**
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift:1554-1566`
- Test: `CalixTests/Git/DiffTabLifecycleTests.swift`

**Interfaces:**
- Consumes: `GitChangesController.reviewStore(for:)`, `Tab.paneContent`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func closeTab_warningCoversAllDiffPanesInTab() {
    let tab = Tab()
    let leafA = UUID()
    let leafB = UUID()
    tab.splitTree = SplitTree(leafID: leafA)
    (tab.splitTree, _) = tab.splitTree.insert(at: leafA, direction: .horizontal, newID: leafB)
    tab.paneContent[leafA] = .diff(source: .unstaged(path: "a.txt", workDir: "/repo"))
    tab.paneContent[leafB] = .diff(source: .unstaged(path: "b.txt", workDir: "/repo"))
    let session = WindowSession(initialTab: tab)

    let controller = GitChangesController(
        windowSession: session, refresh: {}, switchToTab: { _ in }, deactivateCurrentTab: {},
        sendToAgent: { _, _ in .sent }
    )
    controller.reviewStore(for: leafA)?.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "x")

    // Simulate what openDiffTab would have created -- reviewStores populated for both leaves.
    let storeA = DiffReviewStore()
    storeA.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "a")
    let storeB = DiffReviewStore()

    let leafIDsWithComments = tab.paneContent.keys.filter { leafID in
        [storeA, storeB][leafID == leafA ? 0 : 1].hasUnsubmittedComments
    }
    #expect(leafIDsWithComments == [leafA])
}
```

(This test exercises the aggregation logic directly rather than driving the
real `NSAlert`, matching how `discardAllDiffReviews`'s confirm-dialog is
untested at the alert level today — only the underlying boolean/count logic
is unit-tested.)

- [ ] **Step 2: Run test to verify it fails**

Run and confirm it fails only insofar as the harness/fixture doesn't compile yet if you're following strict TDD ordering — since this test is mostly exercising plain arithmetic over existing APIs, if it passes immediately skip to step 4 and fold this into a regression test rather than forcing an artificial red state.

- [ ] **Step 3: Generalize `closeTab`'s pre-close check**

In `CalixWindowController.swift:1554-1566`, replace:

```swift
        // Check for unsent review comments
        if let store = gitChangesController.reviewStore(for: tabID), store.hasUnsubmittedComments {
```

with a scan across every diff pane leaf in the tab:

```swift
        // Check for unsent review comments across every diff pane in this tab
        let diffLeavesWithComments = tab.paneContent.keys.filter { leafID in
            gitChangesController.reviewStore(for: leafID)?.hasUnsubmittedComments ?? false
        }
        if !diffLeavesWithComments.isEmpty {
            let totalComments = diffLeavesWithComments.reduce(0) { $0 + (gitChangesController.reviewStore(for: $1)?.comments.count ?? 0) }
            let alert = NSAlert()
            alert.messageText = "Unsent Review Comments"
            alert.informativeText = "This tab has \(totalComments) unsent review comment(s) across \(diffLeavesWithComments.count) file(s). Closing will discard them."
```

(keep the rest of the existing alert/button/response handling unchanged).

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests`
Expected: PASS. Full build: `xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`.

- [ ] **Step 5: Commit**

```bash
git add Calix/Views/MainWindow/CalixWindowController.swift CalixTests/Git/DiffTabLifecycleTests.swift
git commit -m "fix: closing a tab warns about unsent comments across all its diff panes"
```

---

### Task 7: Submit/send-to-agent — delete cross-tab search entirely

**Files:**
- Modify: `Calix/Features/Git/GitChangesController.swift`
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift`
- Test: `CalixTests/Git/DiffTabLifecycleTests.swift`

**Interfaces:**
- Consumes: leaf-keyed `reviewStores` (Task 4), `Tab.splitTree`.
- Produces: `sendToAgent: (String) -> ReviewSendResult` (parameter-free again — no `preferredTabID`, since the closure now only ever needs `self.activeTab`, which `CalixWindowController` already has).

- [ ] **Step 1: Write the failing test**

```swift
@Test func sendReviewToAgent_onlySearchesActiveTabsOwnTerminalLeaves() {
    // This test targets the pure selection logic moved onto GitChangesController
    // in this task -- see Step 3 for the exact function under test.
    let tab = Tab()
    let terminalLeafA = UUID()
    let terminalLeafB = UUID()
    tab.splitTree = SplitTree(leafID: terminalLeafA)
    (tab.splitTree, _) = tab.splitTree.insert(at: terminalLeafA, direction: .vertical, newID: terminalLeafB)
    // Neither leaf is in tab.paneContent -- both resolve as terminal surfaces.
    let terminalLeaves = tab.splitTree.allLeafIDs().filter { tab.paneContent[$0] == nil }
    #expect(Set(terminalLeaves) == Set([terminalLeafA, terminalLeafB]))
}
```

- [ ] **Step 2: Run test**

This exercises existing `SplitTree`/`paneContent` APIs directly, so it
should pass immediately — its purpose is documenting the exact selection
expression Step 3 must use inside `sendReviewToAgent`, not driving new
production code. Run it to confirm: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests/sendReviewToAgent_onlySearchesActiveTabsOwnTerminalLeaves`

- [ ] **Step 3: Delete cross-tab machinery, rewrite `sendReviewToAgent`**

In `CalixWindowController.swift`, find `private func sendReviewToAgent(_ payload: String) -> ReviewSendResult` — its body scans `windowSession.groups.flatMap(\.tabs)` for terminal tabs whose title matches a static `isAIAgentTitle(_:)` helper (checking for "claude"/codex/openCode/"hermes" substrings), picking one automatically if there's exactly one match or showing an `NSAlert`+`NSPopUpButton` picker if there are several. Delete `isAIAgentTitle(_:)` entirely — no longer needed, since a terminal leaf in the same tab is always the target regardless of its title — and replace `sendReviewToAgent`'s whole body with:

```swift
    private func sendReviewToAgent(_ payload: String) -> ReviewSendResult {
        guard let tab = activeTab else { return .failed }
        let terminalLeaves = tab.splitTree.allLeafIDs().filter { tab.paneContent[$0] == nil }

        guard !terminalLeaves.isEmpty else {
            showIPCAlert(title: "No Terminal", message: "This tab has no terminal pane to send the review to.")
            return .failed
        }

        let targetLeafID: UUID
        if terminalLeaves.count == 1 {
            targetLeafID = terminalLeaves[0]
        } else {
            let alert = NSAlert()
            alert.messageText = "Select Terminal Pane"
            alert.informativeText = "This tab has multiple terminal panes -- choose which one to send the review to:"
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            for (i, leafID) in terminalLeaves.enumerated() {
                popup.addItem(withTitle: "Pane #\(i + 1)")
                popup.lastItem?.representedObject = leafID
            }
            alert.accessoryView = popup

            guard alert.runModal() == .alertFirstButtonReturn else { return .cancelled }
            guard let selected = popup.selectedItem?.representedObject as? UUID else { return .failed }
            targetLeafID = selected
        }

        guard let controller = tab.registry.controller(for: targetLeafID) else {
            showIPCAlert(title: "Send Failed", message: "Could not access terminal surface.")
            return .failed
        }

        controller.sendText(payload)
        sendSyntheticReturn(controller: controller, double: true)
        return .sent
    }
```

(No `switchToTab` call at the end — unlike the old cross-tab version, the
target is always the tab the user is already looking at.)

Update the `sendToAgent` closure signature back to parameter-free at both
ends:
- `GitChangesController.swift`: `private let sendToAgent: (String) -> ReviewSendResult`, and its `init` parameter to match.
- `CalixWindowController.swift:132`: `sendToAgent: { [weak self] payload in self?.sendReviewToAgent(payload) ?? .failed }`.

Rewrite `submitDiffReview(leafID:)`/`submitAllDiffReviews()` in `GitChangesController.swift`:

```swift
    func submitDiffReview(leafID: UUID) {
        guard let tab = activeTab, let store = reviewStores[leafID], store.hasUnsubmittedComments else { return }
        guard case .diff(let source) = tab.paneContent[leafID] else { return }
        let filePath: String
        switch source {
        case .unstaged(let p, _), .staged(let p, _), .branchDelta(let p, _, _), .untracked(let p, _):
            filePath = p
        }

        let payload = store.formatForSubmission(filePath: filePath)
        let result = sendToAgent(payload)
        if result == .sent {
            store.clearAll()
            refresh()
        }
    }

    func submitAllDiffReviews() {
        guard let tab = activeTab else { return }
        let tabLeafIDs = Set(tab.splitTree.allLeafIDs())
        let entries: [(source: DiffSource, store: DiffReviewStore)] = reviewStores.compactMap { leafID, store in
            guard tabLeafIDs.contains(leafID), store.hasUnsubmittedComments else { return nil }
            guard case .diff(let source) = tab.paneContent[leafID] else { return nil }
            return (source: source, store: store)
        }
        guard !entries.isEmpty else { return }

        let payload = DiffReviewStore.formatAllForSubmission(entries)
        let result = sendToAgent(payload)
        if result == .sent {
            for entry in entries { entry.store.clearAll() }
            refresh()
        }
    }
```

Note `submitAllDiffReviews`'s `tabLeafIDs` filter — this is the "submit all
means all diff panes in the *current* tab" behavior from the spec; without
it, stale `reviewStores` entries from panes in tabs the user has since
switched away from would leak into "all."

- [ ] **Step 4: Update callers**

Update every caller of `submitDiffReview(tabID:)` to pass a leaf ID instead
(the pane's own ID, already threaded through from `DiffPaneView`'s toolbar
callback in Task 3/5). (No test deletion needed here — this worktree's
`DiffTabLifecycleTests.swift` never had tests for the interim
`diffOriginTabIDs`/`agentTabCandidates` fix in the first place, per the
Global Constraints baseline-correction note.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests`
Expected: PASS. Full build required — this touches `GitChangesController`'s
public method signatures (`submitDiffReview(tabID:)` → `submitDiffReview(leafID:)`),
so every call site must be updated for the build to succeed.

- [ ] **Step 6: Commit**

```bash
git add Calix/Features/Git/GitChangesController.swift Calix/Views/MainWindow/CalixWindowController.swift CalixTests/Git/DiffTabLifecycleTests.swift
git commit -m "refactor: review submission targets the active tab's own terminal leaves, no cross-tab search"
```

---

### Task 8: Delete `TabContent.diff`, old `.changes` sidebar mode, snapshot case

**Files:**
- Modify: `Calix/Models/Session/Tab.swift`
- Modify: `Calix/Models/Session/WindowSession.swift`
- Modify: `Calix/Features/Git/GitModels.swift`
- Modify: `Calix/Views/Sidebar/SidebarContentView.swift:238-248,626,761`
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift:1181,1819,3292`
- Modify: `Calix/Features/Persistence/SessionSnapshot.swift:245-255`
- Test: `CalixTests/Git/DiffTabLifecycleTests.swift`

**Interfaces:**
- Consumes: nothing new — this task only deletes call sites made dead by Task 4 (no code path constructs `TabContent.diff` anymore after Task 4).

- [ ] **Step 1: Confirm no production code still constructs `.diff`**

Run: `grep -rn "\.diff(source:" Calix/ --include=*.swift`
Expected: zero hits outside of `TabPaneKind.diff(source:)` (Task 1) and
`Tab.paneContent[...] = .diff(source:)` (Task 4) — if `TabContent.diff` still
has a live constructor call, stop and fix Task 4 first.

- [ ] **Step 2: Delete `TabContent.diff` and its call sites**

`Calix/Models/Session/Tab.swift`: remove the `case diff(source: DiffSource)` line from `TabContent`.

`Calix/Views/Sidebar/SidebarContentView.swift:626`: remove the `case .diff: "doc.text"` arm from `tabIcon`.

`Calix/Views/Sidebar/SidebarContentView.swift:761`: remove the `TabContent.isDiff` extension (or its `.diff` case, if the extension covers more than just this).

`Calix/Views/MainWindow/CalixWindowController.swift:1181,1819,3292`: remove the three `case .diff: break` (or equivalent no-op) arms — the exhaustive switches over `TabContent` no longer need them once the case is gone (the compiler will flag any switch you miss as non-exhaustive, so this step is self-checking).

`Calix/Features/Persistence/SessionSnapshot.swift:245-255`: simplify `Tab.snapshot(browserURLOverride:)`'s switch to just `.terminal`/`.browser` (delete the `case .diff: return nil` arm).

- [ ] **Step 3: Delete `sidebarMode`/`.changes` and the old changes-mode UI**

`Calix/Features/Git/GitModels.swift`: remove `case changes` from `SidebarMode`.

`Calix/Models/Session/WindowSession.swift`: `sidebarMode`'s type still exists (`.tabs`/`.agents` remain) — no change needed beyond the enum case removal above.

`Calix/Views/Sidebar/SidebarContentView.swift:238-248`: remove the `case .changes:` arm (the `GitChangesView` binding added in Task 2, Step 5) — the left sidebar's `switch sidebarMode` now only handles `.tabs`/`.agents`.

`CalixWindowController.swift`: remove `setSidebarMode(.changes)` call in the `git.showChanges` palette command (line 441-445) — Task 9 replaces this command's body entirely.

- [ ] **Step 4: Run tests, fix any exhaustiveness/reference errors**

Run: `xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: compiler errors point at every remaining `.diff`/`.changes` reference this step's grep in Step 1 missed (e.g. Swift's exhaustive-switch checking will catch any leftover arm referencing the deleted cases) — fix each until `BUILD SUCCEEDED`.

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: delete TabContent.diff and the old window-level Changes sidebar mode"
```

---

### Task 9: New per-tab UI — toggle changes panel

**Files:**
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift` (`setupCommandRegistry`, `git.showChanges` command)
- Modify: `Calix/Views/Git/GitChangesView.swift` (or wherever the per-tab toggle button lives — a small toolbar button in the terminal's chrome)

**Interfaces:**
- Consumes: `resolvePaneContent`/pane rendering (Task 3), `Tab.paneContent` (Task 1).

- [ ] **Step 1: Write the failing test**

```swift
@Test func toggleChangesPanel_insertsAndRemovesGitChangesLeaf() {
    let tab = Tab(pwd: "/repo")
    let session = WindowSession(initialTab: tab)
    let terminalLeafID = tab.splitTree.allLeafIDs()[0]

    let controller = GitChangesController(
        windowSession: session, refresh: {}, switchToTab: { _ in }, deactivateCurrentTab: {},
        sendToAgent: { _ in .sent }
    )

    controller.toggleChangesPanel()
    #expect(tab.splitTree.allLeafIDs().count == 2)
    let changesLeafID = tab.splitTree.allLeafIDs().first { $0 != terminalLeafID }!
    #expect(tab.paneContent[changesLeafID] == .gitChanges)

    controller.toggleChangesPanel()
    #expect(tab.splitTree.allLeafIDs().count == 1)
    #expect(tab.paneContent.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests/toggleChangesPanel_insertsAndRemovesGitChangesLeaf`
Expected: FAIL — `value of type 'GitChangesController' has no member 'toggleChangesPanel'`.

- [ ] **Step 3: Implement `toggleChangesPanel()`**

Add to `GitChangesController.swift`:

```swift
    func toggleChangesPanel() {
        guard let tab = activeTab else { return }
        if let existingLeafID = tab.paneContent.first(where: { $0.value == .gitChanges })?.key {
            tab.splitTree = tab.splitTree.remove(existingLeafID).tree
            tab.paneContent.removeValue(forKey: existingLeafID)
        } else {
            guard let anchorLeafID = tab.splitTree.focusedLeafID ?? tab.splitTree.allLeafIDs().first else { return }
            let (newTree, newLeafID) = tab.splitTree.insert(at: anchorLeafID, direction: .horizontal)
            tab.splitTree = newTree
            tab.paneContent[newLeafID] = .gitChanges
            if currentRepoRootIsUnset(for: tab) {
                refreshStatus()
            }
        }
        refresh()
    }

    private func currentRepoRootIsUnset(for tab: Tab) -> Bool {
        tab.repoRoot == nil
    }
```

- [ ] **Step 4: Wire the palette command and rebuild `activateCurrentTab`/`splitContainerView` layout**

Replace the `git.showChanges` palette command body
(`CalixWindowController.swift:441-445`):

```swift
        commandRegistry.register(PaletteCommand(id: "git.showChanges", title: "Toggle Git Changes Panel", category: "Git") { [weak self] in
            self?.gitChangesController.toggleChangesPanel()
            if let tab = self?.activeTab {
                self?.splitContainerView?.updateLayout(tree: tab.splitTree)
            }
        })
```

Add a toolbar button (in the terminal chrome, near existing per-tab
controls) calling the same `gitChangesController.toggleChangesPanel()` +
layout-refresh pair, for discoverability beyond the command palette.

- [ ] **Step 5: Run tests to verify they pass, manually verify in the running app**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests`
Expected: PASS.

Use the `run` skill (or `xcodebuild` + manual launch) to confirm visually:
toggling the changes panel on a terminal tab in a git repo shows the file
list beside the terminal; clicking a file opens a diff pane below; resizing
dividers works; closing the tab with an unsubmitted comment warns correctly.

- [ ] **Step 6: Commit**

```bash
git add Calix/Features/Git/GitChangesController.swift Calix/Views/MainWindow/CalixWindowController.swift
git commit -m "feat: per-tab toggle for the git-changes panel, replacing the window-level Changes sidebar mode"
```

---

### Task 10: Retarget refresh/monitoring to the active tab

**Files:**
- Modify: `Calix/Features/Git/GitChangesController.swift` (`startMonitoring`/`stopMonitoring`, lines 190-226)
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift` (`activateCurrentTab`)

**Interfaces:**
- Consumes: `Tab.gitChangesState`/`gitEntries` (Task 2).

- [ ] **Step 1: Write the failing test**

```swift
@Test func switchingActiveGroup_toTabWithCachedEntries_keepsThemUntilRefreshCompletes() async throws {
    let scratchDirectory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratchDirectory) }
    try runGit(["init", "-q", "-b", "main", scratchDirectory.path], in: scratchDirectory)
    try "one\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
    try runGit(["add", "-A"], in: scratchDirectory)
    try runGit(["commit", "-q", "-m", "base"], in: scratchDirectory)
    try "one-changed\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)

    let tabA = Tab(pwd: scratchDirectory.path)
    let groupA = TabGroup(name: "A", tabs: [tabA], activeTabID: tabA.id)
    let tabB = Tab(pwd: scratchDirectory.path)
    let groupB = TabGroup(name: "B", tabs: [tabB], activeTabID: tabB.id)
    let session = WindowSession(groups: [groupA, groupB], activeGroupID: groupA.id)

    let controller = GitChangesController(
        windowSession: session, refresh: {}, switchToTab: { _ in }, deactivateCurrentTab: {},
        sendToAgent: { _ in .sent }
    )

    controller.refreshStatus()
    let deadline = ContinuousClock.now + Duration.seconds(5)
    while true {
        if case .loaded = tabA.gitChangesState { break }
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for tabA's git status load")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!tabA.gitEntries.isEmpty)

    // Switch the active group to B, then back to A -- tabA's cached entries
    // must still be there immediately, with no re-fetch required to see them.
    session.activeGroupID = groupB.id
    session.activeGroupID = groupA.id

    #expect(!tabA.gitEntries.isEmpty, "tabA's cached gitEntries should survive a group switch without needing a fresh refreshStatus() call")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests/switchingActiveGroup_toTabWithCachedEntries_keepsThemUntilRefreshCompletes`
Expected: this test exercises only `Tab`'s own storage (`gitEntries` lives on
the `Tab` instance, untouched by switching `activeGroupID`), so it should
already PASS once Task 2 lands — its purpose here is as a regression guard
for Step 3's `activateCurrentTab()` wiring, confirming that wiring doesn't
introduce a step that clears `tab.gitEntries` before the background refresh
completes. If it fails, Task 2's per-tab storage isn't wired correctly —
stop and fix that before proceeding.

- [ ] **Step 3: Wire monitoring to the active tab**

In `GitChangesController.swift`, `startMonitoring`/`stopMonitoring`
(190-226) currently key off `isSidebarVisible`. Retarget: start monitoring
`activeTab?.repoRoot` whenever `activeTab.paneContent` contains a
`.gitChanges` entry (i.e. that tab's changes panel is open), stop when it
doesn't. In `CalixWindowController.activateCurrentTab()`, after the existing
per-`.terminal`/`.browser`/`.diff` dispatch, add: if the newly active tab has
a `.gitChanges` pane open, call `gitChangesController.refreshStatus(showsLoadingState: false)` (fire-and-forget background refresh; `tab.gitEntries` already holds the cached last-good value, so the UI shows it immediately without waiting).

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Calix/Features/Git/GitChangesController.swift Calix/Views/MainWindow/CalixWindowController.swift CalixTests/Git/DiffTabLifecycleTests.swift
git commit -m "feat: retarget git-changes monitoring to the active tab, cache-then-refresh on activation"
```

---

### Task 11: Persistence — strip pane leaves before snapshot

**Files:**
- Modify: `Calix/Features/Persistence/SessionSnapshot.swift`
- Test: new Swift Testing file or addition to an existing persistence test file (search `CalixTests/` for existing `SessionSnapshot`-related tests first and add alongside them; do not create a new file if one already covers `Tab.snapshot()`).

**Interfaces:**
- Consumes: `Tab.paneContent`, `Tab.splitTree`.
- Produces: `Tab.snapshot()`'s persisted `splitTree` has every `paneContent`-keyed leaf removed before encoding.

- [ ] **Step 1: Write the failing test**

```swift
func testSnapshot_stripsGitChangesAndDiffLeaves() {
    let tab = Tab(pwd: "/repo")
    let terminalLeafID = tab.splitTree.allLeafIDs()[0]
    let (treeWithChanges, changesLeafID) = tab.splitTree.insert(at: terminalLeafID, direction: .horizontal)
    tab.splitTree = treeWithChanges
    tab.paneContent[changesLeafID] = .gitChanges

    let snapshot = tab.snapshot()
    XCTAssertNotNil(snapshot)
    XCTAssertEqual(snapshot?.splitTree.allLeafIDs(), [terminalLeafID])
}
```

(Use XCTest to match whatever existing persistence test file this gets added
to — check its import first; don't introduce a third test style if the file
already standardizes on one.)

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — snapshot's `splitTree` currently still contains
`changesLeafID` (nothing strips it yet).

- [ ] **Step 3: Strip pane leaves in `Tab.snapshot()`**

In `SessionSnapshot.swift`, before building `TabSnapshot`, compute a
stripped `SplitTree` with every `paneContent`-keyed leaf removed:

```swift
    func snapshot(browserURLOverride: URL? = nil) -> TabSnapshot? {
        let refs = sessionRefs.isEmpty ? nil : sessionRefs
        var persistedTree = splitTree
        for leafID in paneContent.keys {
            persistedTree = persistedTree.remove(leafID).tree
        }
        switch content {
        case .terminal:
            return TabSnapshot(id: id, title: title, titleOverride: titleOverride, pwd: pwd, splitTree: persistedTree, browserURL: nil, sessionRefs: refs)
        case .browser(let url):
            return TabSnapshot(id: id, title: title, titleOverride: titleOverride, pwd: pwd, splitTree: persistedTree, browserURL: browserURLOverride ?? url, sessionRefs: refs)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS. Also run the full `CalixTests` suite once, since persistence changes are easy to regress silently: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS'`

- [ ] **Step 5: Commit**

```bash
git add Calix/Features/Persistence/SessionSnapshot.swift CalixTests/
git commit -m "fix: strip git-changes/diff panes from persisted splitTree snapshots"
```

---

### Task 12: Final test-suite cleanup pass

**Files:**
- Modify: `CalixTests/Git/DiffTabLifecycleTests.swift`

**Interfaces:**
- None — this task only removes/renames test code made stale by Tasks 1-11; no production code changes.

- [ ] **Step 1: Read through the whole file**

Confirm every remaining test reflects the new model: no test still asserts
"a new sibling `Tab` was appended" for a diff; no test references
`diffOriginTabIDs`, `agentTabCandidates`, or `sendReviewToAgent(_:preferredTabID:)`
(all deleted in Task 7); the file's fixture helpers (`makeScratchDirectory`,
`runGit`, `waitForDiffState`) are still used consistently.

- [ ] **Step 2: Confirm the same-tab multi-terminal picker test from Task 7 is present and not duplicated**

Task 7 Step 1 already added
`sendReviewToAgent_onlySearchesActiveTabsOwnTerminalLeaves`, which covers
this exact scenario (a tab with two terminal leaves, confirming the
candidate set never looks outside the tab). Confirm it's still present and
passing — do not add a second, near-identical test for the same assertion.

- [ ] **Step 3: Run the full suite**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/DiffTabLifecycleTests`
Expected: all pass.

- [ ] **Step 4: Full app build**

Run: `xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add CalixTests/Git/DiffTabLifecycleTests.swift
git commit -m "test: clean up DiffTabLifecycleTests for the tab-scoped pane model"
```
