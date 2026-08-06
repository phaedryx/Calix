// DiffTabLifecycleTests.swift
// CalixTests
//
// Tests for diff tab lifecycle: GitChangesState transitions, SidebarMode, DiffSource dedup.

import AppKit
import Foundation
import Testing
@testable import Calix

@MainActor
struct DiffTabLifecycleTests {
    @Test func gitChangesStateTransitions() {
        let tab = Tab()
        if case .notLoaded = tab.gitChangesState {} else {
            Issue.record("Expected initial state .notLoaded")
        }

        tab.gitChangesState = .loading
        if case .loading = tab.gitChangesState {} else {
            Issue.record("Expected .loading")
        }

        tab.gitChangesState = .loaded
        if case .loaded = tab.gitChangesState {} else {
            Issue.record("Expected .loaded")
        }
    }

    @Test func gitChangesStateNotRepository() {
        let tab = Tab()
        tab.gitChangesState = .loading
        tab.gitChangesState = .notRepository
        if case .notRepository = tab.gitChangesState {} else {
            Issue.record("Expected .notRepository")
        }
    }

    @Test func gitChangesStateError() {
        let tab = Tab()
        tab.gitChangesState = .error("test error")
        if case .error(let msg) = tab.gitChangesState {
            #expect(msg == "test error")
        } else {
            Issue.record("Expected .error")
        }
    }

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

    @Test func sidebarModeToggle() {
        let session = WindowSession()
        #expect(session.sidebarMode == .tabs)
        session.sidebarMode = .agents
        #expect(session.sidebarMode == .agents)
        session.sidebarMode = .tabs
        #expect(session.sidebarMode == .tabs)
    }

    @Test func diffSourceDedup() {
        let a = DiffSource.unstaged(path: "foo.swift", workDir: "/repo")
        let b = DiffSource.unstaged(path: "foo.swift", workDir: "/repo")
        #expect(a == b)

        let c = DiffSource.staged(path: "foo.swift", workDir: "/repo")
        #expect(a != c)

        let d = DiffSource.branchDelta(path: "foo.swift", base: "origin/main", workDir: "/repo")
        #expect(a != d)
    }

    @Test func closeDiffPane_removesLeafAndCleansUpState() {
        let tab = Tab()
        let leafID = UUID()
        tab.splitTree = SplitTree(leafID: leafID)
        tab.paneContent[leafID] = .diff(source: .unstaged(path: "one.txt", workDir: "/repo"))
        let session = WindowSession(initialTab: tab)

        let controller = GitChangesController(
            windowSession: session, refresh: {}, switchToTab: { _ in }, deactivateCurrentTab: {},
            sendToAgent: { _ in .sent }
        )
        _ = controller.reviewStore(for: leafID) // no-op touch to confirm nil before close
        controller.closeDiffPane(leafID)

        #expect(tab.paneContent[leafID] == nil)
        #expect(controller.reviewStore(for: leafID) == nil)
    }

    // Task 6: `closeTab`'s pre-close "Unsent Review Comments" check used
    // to call `gitChangesController.reviewStore(for: tabID)` -- a TAB id
    // against the leaf-keyed `reviewStores` dictionary, which is always
    // nil now that diff panes are `paneContent` leaves (Task 4), so the
    // warning silently stopped firing. Drives two REAL diff panes through
    // `handleWorkingFileSelected` (as `openDiffTab` would create them,
    // with genuine `reviewStores` entries) rather than synthetic
    // stand-in stores, so this actually exercises the same
    // `tab.paneContent.keys.filter { gitChangesController.reviewStore(for:) }`
    // predicate `closeTab` runs -- it goes red if that call reverts to
    // being keyed by `tabID` instead of by leaf.
    @Test func closeTab_warningCoversAllDiffPanesInTab() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        try runGit(["init", "-q", "-b", "main", scratchDirectory.path], in: scratchDirectory)
        try "one\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: scratchDirectory.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: scratchDirectory)
        try runGit(["commit", "-q", "-m", "base"], in: scratchDirectory)
        try "one-changed\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "two-changed\n".write(to: scratchDirectory.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)

        let tab = Tab(pwd: scratchDirectory.path)
        let session = WindowSession(initialTab: tab)
        let group = session.activeGroup!

        let controller = GitChangesController(
            windowSession: session, refresh: {}, switchToTab: { id in group.activeTabID = id },
            deactivateCurrentTab: {}, sendToAgent: { _ in .sent }
        )

        controller.refreshStatus()
        let deadline = ContinuousClock.now + Duration.seconds(5)
        while true {
            if case .loaded = tab.gitChangesState { break }
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for git status load")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let entryOne = GitFileEntry(path: "one.txt", origPath: nil, status: .modified, isStaged: false, renameScore: nil)
        let entryTwo = GitFileEntry(path: "two.txt", origPath: nil, status: .modified, isStaged: false, renameScore: nil)
        let leavesBeforeFirst = Set(tab.splitTree.allLeafIDs())
        controller.handleWorkingFileSelected(entryOne)
        guard let leafOne = tab.splitTree.allLeafIDs().first(where: { !leavesBeforeFirst.contains($0) }) else {
            Issue.record("Expected first diff leaf to be created")
            return
        }
        let leavesBeforeSecond = Set(tab.splitTree.allLeafIDs())
        controller.handleWorkingFileSelected(entryTwo)
        guard let leafTwo = tab.splitTree.allLeafIDs().first(where: { !leavesBeforeSecond.contains($0) }) else {
            Issue.record("Expected second diff leaf to be created")
            return
        }

        // Only leafOne gets a comment -- reviewStores are created
        // synchronously by `openDiffTab` (before the async diff-fetch
        // task), so this is non-nil immediately, no need to wait for
        // `diffState`.
        controller.reviewStore(for: leafOne)?.addComment(
            lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "x")

        // This is the exact predicate `closeTab` runs.
        let diffLeavesWithComments = tab.paneContent.keys.filter { leafID in
            controller.reviewStore(for: leafID)?.hasUnsubmittedComments ?? false
        }
        #expect(diffLeavesWithComments == [leafOne])
        #expect(!diffLeavesWithComments.contains(leafTwo))

        let totalComments = diffLeavesWithComments.reduce(0) { $0 + (controller.reviewStore(for: $1)?.comments.count ?? 0) }
        #expect(totalComments == 1)
    }

    // Carried-forward fix (Task 5 review item 1): `closeTab`/
    // `closeActiveGroup`/`closeAllTabsInGroup` used to call
    // `gitChangesController.closeDiffTab(tabID)` -- a call keyed by the
    // closing TAB's id, a leftover from before Task 4 moved diff panes
    // into `paneContent` leaves. This proves the whole-tab close path
    // now visits every diff-pane leaf the closing tab actually holds.
    @Test func closeTab_cleansUpEveryDiffPaneLeafInTheClosingTab() {
        let closingTab = Tab(title: "Closing")
        let diffLeafID = UUID()
        closingTab.splitTree = SplitTree(leafID: diffLeafID)
        closingTab.paneContent[diffLeafID] = .diff(source: .unstaged(path: "one.txt", workDir: "/repo"))

        let otherTab = Tab(title: "Other")
        let group = TabGroup(name: "Default", tabs: [closingTab, otherTab], activeTabID: closingTab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalixWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalixWindowController(window: window, windowSession: session, restoring: true)

        controller.closeTab(nil)

        #expect(!group.tabs.contains(where: { $0.id == closingTab.id }))
        #expect(closingTab.paneContent[diffLeafID] == nil)
    }

    // Review finding on Task 5: closing a tab's only terminal (`exit`
    // in the shell) leaves the tab open showing just its diff pane (see
    // this file's own carried-forward-item-3 decision in the task
    // report -- that's deliberate). But closing THAT diff pane via its
    // own close button used to leave `tab.splitTree` fully empty with
    // no code path removing the tab: no terminal, no pane, no
    // focusable leaf, and no in-place way to revive it (only `Cmd+W`
    // could close it). `closePane` now detects the resulting empty
    // tree and hands off to `closeTab(id:)` (same path `Cmd+W` uses,
    // which already gates on `confirmQuitBeforeCloseIfWouldTerminate()`).
    // This proves the tab is actually gone afterward, not lingering.
    @Test func closePane_lastLeafInTab_closesTheTabInstead() {
        let diffLeafID = UUID()
        let closingTab = Tab(title: "Closing")
        // Simulates the post-`exit` state: the tab's only terminal
        // surface is already gone, so the diff pane is the sole leaf
        // left in splitTree.
        closingTab.splitTree = SplitTree(leafID: diffLeafID)
        closingTab.paneContent[diffLeafID] = .diff(source: .unstaged(path: "one.txt", workDir: "/repo"))

        let otherTab = Tab(title: "Other")
        let group = TabGroup(name: "Default", tabs: [closingTab, otherTab], activeTabID: otherTab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalixWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalixWindowController(window: window, windowSession: session, restoring: true)

        controller._closePaneForTesting(leafID: diffLeafID)

        #expect(!group.tabs.contains(where: { $0.id == closingTab.id }), "the leafless tab should be closed, not left lingering")
        #expect(group.tabs.contains(where: { $0.id == otherTab.id }))
    }

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

    // Regression test for the bug this task actually fixes: since Task 4,
    // diffs are `paneContent[leafID] == .diff(source:)` entries on a
    // `.terminal` tab, not a tab whose whole `content` is `.diff`. Before
    // this task, `submitDiffReview` still read `tab.content`, so this
    // guard always failed and submission was a silent no-op. This proves
    // the file path is read from `paneContent` and the review store is
    // actually cleared on a successful send.
    @Test func submitDiffReview_readsPaneContentAndClearsStoreOnSend() async throws {
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

        var capturedPayload: String?
        let controller = GitChangesController(
            windowSession: session,
            refresh: {},
            switchToTab: { id in group.activeTabID = id },
            deactivateCurrentTab: {},
            sendToAgent: { payload in
                capturedPayload = payload
                return .sent
            }
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

        let leavesBefore = Set(terminalTab.splitTree.allLeafIDs())
        let entry = GitFileEntry(path: "one.txt", origPath: nil, status: .modified, isStaged: false, renameScore: nil)
        controller.handleWorkingFileSelected(entry)
        guard let diffLeafID = terminalTab.splitTree.allLeafIDs().first(where: { !leavesBefore.contains($0) }) else {
            Issue.record("Expected a new diff leaf to be inserted")
            return
        }

        controller.reviewStore(for: diffLeafID)?.addComment(
            lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "looks good")
        #expect(controller.reviewStore(for: diffLeafID)?.hasUnsubmittedComments == true)

        controller.submitDiffReview(leafID: diffLeafID)

        #expect(capturedPayload?.contains("one.txt") == true)
        #expect(capturedPayload?.contains("looks good") == true)
        #expect(controller.reviewStore(for: diffLeafID)?.hasUnsubmittedComments == false)
    }

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
            sendToAgent: { _ in .sent }
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

    @Test func handleWorkingFileSelected_keepsFocusOnTerminalLeaf() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        try runGit(["init", "-q", "-b", "main", scratchDirectory.path], in: scratchDirectory)
        try "one\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: scratchDirectory)
        try runGit(["commit", "-q", "-m", "base"], in: scratchDirectory)
        try "one-changed\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)

        let terminalTab = Tab(pwd: scratchDirectory.path)
        // Simulate a real terminal tab: production always wires a genuine
        // ghostty surface leaf into `splitTree` before any diff pane can be
        // opened (see `CalixWindowController`'s various
        // `tab.splitTree = SplitTree(leafID: surfaceID)` call sites). The
        // other tests in this file use the default empty `SplitTree()`,
        // which masks this bug entirely (an empty tree has no terminal leaf
        // to lose focus from).
        let terminalLeafID = UUID()
        terminalTab.splitTree = SplitTree(leafID: terminalLeafID)

        let session = WindowSession(initialTab: terminalTab)
        let group = session.activeGroup!

        let controller = GitChangesController(
            windowSession: session,
            refresh: {},
            switchToTab: { id in group.activeTabID = id },
            deactivateCurrentTab: {},
            sendToAgent: { _ in .sent }
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

        let leavesBefore = Set(terminalTab.splitTree.allLeafIDs())
        let entry = GitFileEntry(path: "one.txt", origPath: nil, status: .modified, isStaged: false, renameScore: nil)
        controller.handleWorkingFileSelected(entry)

        guard let diffLeafID = terminalTab.splitTree.allLeafIDs().first(where: { !leavesBefore.contains($0) }) else {
            Issue.record("Expected a new diff leaf to be inserted")
            return
        }

        // The diff pane has no ghostty surface -- keyboard focus must stay
        // on the terminal leaf, or the terminal loses first-responder the
        // moment the diff pane is opened (and again every time the tab is
        // revisited, since `focusActiveTabImmediately`/`attemptFocusRestore`
        // both bail when `registry.view(for:)` is nil for the focused leaf).
        #expect(terminalTab.splitTree.focusedLeafID == terminalLeafID)
        #expect(terminalTab.splitTree.focusedLeafID != diffLeafID)

        // Reopening the same file (dedup path) must not move focus either.
        controller.handleWorkingFileSelected(entry)
        #expect(terminalTab.splitTree.allLeafIDs().count == 2, "dedup should not create a second diff leaf")
        #expect(terminalTab.splitTree.focusedLeafID == terminalLeafID)
    }

    @Test func handleWorkingFileSelected_secondTab_wrongTerminalTabPicksWrongRepoRoot() async throws {
        // Repo the user is actually working in.
        let realRepo = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: realRepo) }
        try runGit(["init", "-q", "-b", "main", realRepo.path], in: realRepo)
        try "one\n".write(to: realRepo.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: realRepo.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: realRepo)
        try runGit(["commit", "-q", "-m", "base"], in: realRepo)
        try "one-changed\n".write(to: realRepo.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "two-changed\n".write(to: realRepo.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)

        // An unrelated repo backing some OTHER terminal tab in the same
        // group -- has no "two.txt" at all, so `git diff -- two.txt`
        // there exits cleanly with empty output rather than an error.
        let otherRepo = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: otherRepo) }
        try runGit(["init", "-q", "-b", "main", otherRepo.path], in: otherRepo)
        try "unrelated\n".write(
            to: otherRepo.appendingPathComponent("unrelated.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: otherRepo)
        try runGit(["commit", "-q", "-m", "base"], in: otherRepo)

        // `otherTab` sits BEFORE `realRepoTab` in `group.tabs`, mirroring a
        // window where the user has more than one terminal tab open.
        let otherTab = Tab(pwd: otherRepo.path)
        let realRepoTab = Tab(pwd: realRepo.path)
        let session = WindowSession(initialTab: otherTab)
        let group = session.activeGroup!
        group.addTab(realRepoTab)
        group.activeTabID = realRepoTab.id // user is actively working in the real repo

        let controller = GitChangesController(
            windowSession: session,
            refresh: {},
            switchToTab: { id in group.activeTabID = id },
            deactivateCurrentTab: {},
            sendToAgent: { _ in .sent }
        )

        controller.refreshStatus()
        let statusDeadline = ContinuousClock.now + Duration.seconds(5)
        while true {
            if case .loaded = realRepoTab.gitChangesState { break }
            guard ContinuousClock.now < statusDeadline else {
                Issue.record("Timed out waiting for initial git status load, state: \(realRepoTab.gitChangesState)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let entry1 = GitFileEntry(
            path: "one.txt", origPath: nil, status: .modified, isStaged: false, renameScore: nil)
        let entry2 = GitFileEntry(
            path: "two.txt", origPath: nil, status: .modified, isStaged: false, renameScore: nil)

        // Diffs are now panes inserted into `realRepoTab`'s own
        // `splitTree` -- `group.activeTabID` never changes across either
        // `handleWorkingFileSelected` call, so `otherTab` sitting earlier
        // in `group.tabs` has no opportunity to be consulted at all. What
        // this test still guards: `repoRoot` lives on `realRepoTab`
        // itself (resolved once when its own git status loaded), not on
        // a window-level cache keyed by workDir -- so both diff panes
        // opened from it resolve the same, correct repo.
        let leavesBeforeFirst = Set(realRepoTab.splitTree.allLeafIDs())
        controller.handleWorkingFileSelected(entry1)
        guard let leaf1 = realRepoTab.splitTree.allLeafIDs().first(where: { !leavesBeforeFirst.contains($0) }) else {
            Issue.record("Expected first diff leaf to be created")
            return
        }
        try await waitForDiffState(controller: controller, leafID: leaf1)

        guard case .success(let diff1) = controller.diffState(for: leaf1),
              case .diff(let source1) = realRepoTab.paneContent[leaf1],
              case .unstaged(_, let workDir1) = source1 else {
            Issue.record("Expected leaf1 .success with an unstaged source, got \(String(describing: controller.diffState(for: leaf1)))")
            return
        }
        #expect(workDir1.hasSuffix(realRepo.lastPathComponent), "leaf1 should resolve the real repo (active terminal tab)")
        #expect(!diff1.lines.isEmpty)

        let leavesBeforeSecond = Set(realRepoTab.splitTree.allLeafIDs())
        controller.handleWorkingFileSelected(entry2)
        guard let leaf2 = realRepoTab.splitTree.allLeafIDs().first(where: { !leavesBeforeSecond.contains($0) }) else {
            Issue.record("Expected second diff leaf to be created")
            return
        }
        try await waitForDiffState(controller: controller, leafID: leaf2)

        guard case .diff(let source2) = realRepoTab.paneContent[leaf2],
              case .unstaged(_, let workDir2) = source2 else {
            Issue.record("Expected leaf2 to have an unstaged source")
            return
        }
        #expect(
            workDir2 == workDir1,
            "leaf2 resolved workDir \(workDir2), not leaf1's repo \(workDir1) -- per-tab repoRoot should make this impossible even with otherTab earlier in group.tabs"
        )
        guard case .success(let diff2) = controller.diffState(for: leaf2) else {
            Issue.record("Expected leaf2 .success, got \(String(describing: controller.diffState(for: leaf2)))")
            return
        }
        #expect(
            !diff2.lines.isEmpty,
            "leaf2's diff is empty (blank content, correct title) -- it ran against the wrong repo's workDir"
        )
    }

    // MARK: - Per-Tab Changes Panel Toggle

    @Test func toggleChangesPanel_insertsAndRemovesGitChangesLeaf() {
        let tab = Tab(pwd: "/repo")
        // `Tab.init` defaults to an EMPTY `SplitTree`, so the plan's version
        // of this test (`tab.splitTree.allLeafIDs()[0]`) would trap on an
        // out-of-range index, and `toggleChangesPanel()` would have no
        // anchor leaf to split against. Seed the single terminal leaf every
        // real tab has by the time any panel can be toggled -- same shape as
        // `handleWorkingFileSelected_keepsFocusOnTerminalLeaf` above.
        let terminalLeafID = UUID()
        tab.splitTree = SplitTree(leafID: terminalLeafID)
        let session = WindowSession(initialTab: tab)

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

    @Test func toggleChangesPanel_repeatedToggling_neverDuplicatesTheLeaf() {
        let tab = Tab(pwd: "/repo")
        let terminalLeafID = UUID()
        tab.splitTree = SplitTree(leafID: terminalLeafID)
        let session = WindowSession(initialTab: tab)

        let controller = GitChangesController(
            windowSession: session, refresh: {}, switchToTab: { _ in }, deactivateCurrentTab: {},
            sendToAgent: { _ in .sent }
        )

        for _ in 0..<3 {
            controller.toggleChangesPanel()
            #expect(tab.paneContent.values.filter { $0 == .gitChanges }.count == 1)
            #expect(tab.splitTree.allLeafIDs().count == 2)
            controller.toggleChangesPanel()
            #expect(tab.paneContent.isEmpty)
            #expect(tab.splitTree.allLeafIDs() == [terminalLeafID])
        }
    }

    @Test func toggleChangesPanel_keepsFocusOnTerminalLeaf() {
        let tab = Tab(pwd: "/repo")
        let terminalLeafID = UUID()
        tab.splitTree = SplitTree(leafID: terminalLeafID)
        let session = WindowSession(initialTab: tab)

        let controller = GitChangesController(
            windowSession: session, refresh: {}, switchToTab: { _ in }, deactivateCurrentTab: {},
            sendToAgent: { _ in .sent }
        )

        controller.toggleChangesPanel()
        // Same reasoning as the diff-pane case: a `.gitChanges` leaf has no
        // ghostty surface, so `SplitTree.insert`'s default of focusing the
        // new leaf would make `focusActiveTabImmediately`/
        // `attemptFocusRestore`/`CockpitAppAccess.listPanes`'s `isFocused`
        // all wrong until the user clicks back into the terminal.
        #expect(tab.splitTree.focusedLeafID == terminalLeafID)
    }

    @Test func toggleChangesPanel_onlyTouchesTheActiveTab() {
        let tabA = Tab(pwd: "/repo-a")
        let terminalLeafA = UUID()
        tabA.splitTree = SplitTree(leafID: terminalLeafA)
        let tabB = Tab(pwd: "/repo-b")
        let terminalLeafB = UUID()
        tabB.splitTree = SplitTree(leafID: terminalLeafB)

        let session = WindowSession(initialTab: tabA)
        let group = session.activeGroup!
        group.addTab(tabB)
        group.activeTabID = tabA.id

        let controller = GitChangesController(
            windowSession: session, refresh: {}, switchToTab: { _ in }, deactivateCurrentTab: {},
            sendToAgent: { _ in .sent }
        )

        controller.toggleChangesPanel()
        #expect(tabA.paneContent.values.contains(.gitChanges))
        #expect(tabB.paneContent.isEmpty)
        #expect(controller.isChangesPanelVisible)

        // Panel visibility is a property of the ACTIVE tab's own pane
        // content -- it must not leak across tabs. This is what gates
        // background monitoring and the automatic `refreshStatus()` calls
        // in `CalixWindowController`.
        group.activeTabID = tabB.id
        #expect(!controller.isChangesPanelVisible)

        // ...and toggling now affects tabB only, leaving tabA's panel open.
        controller.toggleChangesPanel()
        #expect(tabB.paneContent.values.contains(.gitChanges))
        #expect(tabA.paneContent.values.contains(.gitChanges))
        #expect(controller.isChangesPanelVisible)

        group.activeTabID = tabA.id
        #expect(controller.isChangesPanelVisible)
    }

    @Test func reviewCounts_scopeToTheActiveTabsOwnDiffPanes() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        try runGit(["init", "-q", "-b", "main", scratchDirectory.path], in: scratchDirectory)
        try "one\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: scratchDirectory)
        try runGit(["commit", "-q", "-m", "base"], in: scratchDirectory)
        try "one-changed\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)

        let tabA = Tab(pwd: scratchDirectory.path)
        tabA.splitTree = SplitTree(leafID: UUID())
        let tabB = Tab(pwd: scratchDirectory.path)
        tabB.splitTree = SplitTree(leafID: UUID())
        let session = WindowSession(initialTab: tabA)
        let group = session.activeGroup!
        group.addTab(tabB)
        group.activeTabID = tabA.id

        let controller = GitChangesController(
            windowSession: session, refresh: {}, switchToTab: { id in group.activeTabID = id },
            deactivateCurrentTab: {}, sendToAgent: { _ in .sent }
        )

        controller.refreshStatus()
        let deadline = ContinuousClock.now + Duration.seconds(5)
        while true {
            if case .loaded = tabA.gitChangesState { break }
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for git status load")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let leavesBefore = Set(tabA.splitTree.allLeafIDs())
        let entry = GitFileEntry(path: "one.txt", origPath: nil, status: .modified, isStaged: false, renameScore: nil)
        controller.handleWorkingFileSelected(entry)
        guard let diffLeafID = tabA.splitTree.allLeafIDs().first(where: { !leavesBefore.contains($0) }) else {
            Issue.record("Expected a new diff leaf in tabA")
            return
        }
        controller.reviewStore(for: diffLeafID)?.addComment(
            lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "needs work")

        #expect(controller.reviewFileCount == 1)
        #expect(controller.totalReviewCommentCount == 1)

        // The counts feed the "Submit All (N in M files)" button label and
        // the `review.submitAll` availability gate, while
        // `submitAllDiffReviews()` only ever submits the ACTIVE tab's own
        // diff panes. From tabB, tabA's comment must be invisible to both.
        group.activeTabID = tabB.id
        #expect(controller.reviewFileCount == 0)
        #expect(controller.totalReviewCommentCount == 0)
    }

    // MARK: - Pane Callback Wiring

    /// Regression guard (Task 9 review finding): the pane callbacks used to
    /// be assigned only in `rebuildSplitContainer()`'s create-a-container
    /// branch, but `setupUI()` runs unconditionally in `init` and parks a
    /// container in `splitContainerView` first -- so that branch never ran
    /// in the app and EVERY callback stayed nil. Clicking a file in the
    /// changes panel did nothing, the refresh and close buttons did nothing,
    /// and diff panes rendered as `EmptyView` (`paneView(for:)` guards on
    /// `gitChangesController`). Asserting after a real `rebuildSplitContainer()`
    /// (driven here through `attachRestoredTab`, an internal entry point that
    /// calls it) is the whole point: an assertion taken straight after `init`
    /// would stay green even if the wiring moved back into the dead branch.
    @Test func rebuildSplitContainer_wiresPaneCallbacksOntoTheExistingContainer() throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        try runGit(["init", "-q", "-b", "main", scratchDirectory.path], in: scratchDirectory)
        try "one\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: scratchDirectory)
        try runGit(["commit", "-q", "-m", "base"], in: scratchDirectory)
        try "one-changed\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)

        let initialTab = makeTerminalTab(pwd: scratchDirectory.path)
        let group = TabGroup(name: "Default", tabs: [initialTab], activeTabID: initialTab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalixWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // `restoring: true` skips `setupTerminalSurface` (which would need a
        // real ghostty app), but `setupUI()` still runs -- exactly the state
        // that made the create-a-container branch unreachable.
        let controller = CalixWindowController(window: window, windowSession: session, restoring: true)

        let restoredTab = makeTerminalTab(pwd: scratchDirectory.path)
        restoredTab.repoRoot = scratchDirectory.path
        controller.attachRestoredTab(restoredTab)

        let container = try #require(controller._splitContainerViewForTesting)
        #expect(container.gitChangesController != nil, "diff panes render as EmptyView without this")
        #expect(container.onWorkingFileSelected != nil)
        #expect(container.onBranchDeltaFileSelected != nil)
        #expect(container.onRefreshGitChanges != nil)
        #expect(container.onSubmitReview != nil)
        #expect(container.onDiscardReview != nil)
        #expect(container.onSubmitAllReviews != nil)
        #expect(container.onDiscardAllReviews != nil)
        #expect(container.onClosePane != nil)
        // Wiring the container must not cost the callbacks that were only
        // ever set in the reuse path.
        #expect(container.onTargetRatioChange != nil)
        #expect(container.onActiveLeafChange != nil)

        // Non-nil isn't enough: fire the closure the panel's file rows call
        // and confirm it reaches `handleWorkingFileSelected` -> `openDiffTab`,
        // which synchronously inserts the diff pane before its async load.
        let leavesBefore = Set(restoredTab.splitTree.allLeafIDs())
        container.onWorkingFileSelected?(
            GitFileEntry(path: "one.txt", origPath: nil, status: .modified, isStaged: false, renameScore: nil)
        )
        guard let diffLeafID = restoredTab.splitTree.allLeafIDs().first(where: { !leavesBefore.contains($0) }) else {
            Issue.record("Clicking a working-tree file inserted no diff leaf -- onWorkingFileSelected is not wired")
            return
        }
        #expect(
            restoredTab.paneContent[diffLeafID] == .diff(source: .unstaged(path: "one.txt", workDir: scratchDirectory.path))
        )
    }

    // MARK: - Task 10: Retarget Monitoring To The Active Tab

    // Real gap this closes: `toggleChangesPanel()` starts a live FSEvents
    // watch on open and stops it on close, but nothing used to stop it when
    // focus merely MOVED to a different tab -- switching away from tabA
    // (panel open) to tabB (no panel) left tabA's repo watched forever, even
    // though `isChangesPanelVisible` (and therefore the monitor's own
    // `onRefresh` guard) now reflects whichever tab is CURRENTLY active, not
    // the one that started the watch. `_monitoredWorkTreeForTesting()` reads
    // the actor's own `repository` field, so this observes the real teardown
    // rather than inferring it from a debounced FSEvents round-trip.
    @Test func switchingAwayFromTabWithOpenChangesPanel_stopsMonitoringItsRepo() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        try runGit(["init", "-q", "-b", "main", scratchDirectory.path], in: scratchDirectory)

        let tabA = makeTerminalTab(pwd: scratchDirectory.path)
        tabA.paneContent[UUID()] = .gitChanges // marks tabA's changes panel as open
        let tabB = makeTerminalTab(pwd: scratchDirectory.path) // panel closed

        let group = TabGroup(name: "Default", tabs: [tabA, tabB], activeTabID: tabA.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalixWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalixWindowController(window: window, windowSession: session, restoring: true)
        let gitChangesController = controller._gitChangesControllerForTesting

        // Kick off tabA's monitor the same way `toggleChangesPanel()` would
        // have when the panel was originally opened (`restoring: true`
        // skips the initial `activateCurrentTab()` a real launch runs).
        gitChangesController.refreshStatus()
        try await waitForMonitoredWorkTree(gitChangesController, toBe: scratchDirectory.path)

        controller.switchToTab(id: tabB.id)

        try await waitForMonitoredWorkTree(gitChangesController, toBe: nil)
    }

    // Companion regression guard for the SAME fix: switching to a tab whose
    // OWN changes panel is open must not be treated as "no panel open" --
    // this failure mode would look identical from a black-box test that
    // only checked `isChangesPanelVisible` (both branches would report
    // `false` -> `true` correctly), so it's worth asserting the monitor
    // actually points at the newly active tab's repo, not merely that it
    // is non-nil.
    @Test func switchingToTabWithOpenChangesPanel_monitorsItsRepo() async throws {
        let scratchDirectoryA = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectoryA) }
        try runGit(["init", "-q", "-b", "main", scratchDirectoryA.path], in: scratchDirectoryA)
        let scratchDirectoryB = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectoryB) }
        try runGit(["init", "-q", "-b", "main", scratchDirectoryB.path], in: scratchDirectoryB)

        let tabA = makeTerminalTab(pwd: scratchDirectoryA.path)
        tabA.paneContent[UUID()] = .gitChanges
        let tabB = makeTerminalTab(pwd: scratchDirectoryB.path)
        tabB.paneContent[UUID()] = .gitChanges

        let group = TabGroup(name: "Default", tabs: [tabA, tabB], activeTabID: tabA.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalixWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalixWindowController(window: window, windowSession: session, restoring: true)
        let gitChangesController = controller._gitChangesControllerForTesting

        gitChangesController.refreshStatus()
        try await waitForMonitoredWorkTree(gitChangesController, toBe: scratchDirectoryA.path)

        controller.switchToTab(id: tabB.id)

        try await waitForMonitoredWorkTree(gitChangesController, toBe: scratchDirectoryB.path)
    }

    // Acceptance criterion from the plan: reactivating a tab whose changes
    // panel is already open must show its CACHED `gitEntries` immediately
    // (`GitChangesView` renders a bare `ProgressView` for `.loading`/
    // `.notLoaded`, so entering that state even briefly hides the list this
    // asserts stays visible the whole time). This is a sampled assertion --
    // green is deterministic once the fix lands (no code path sets `.loading`
    // on this call), red relies on the real `git status` subprocess this
    // spawns taking longer than the ~1ms poll interval to return, which it
    // reliably does.
    @Test func switchingBackToTabWithCachedEntries_neverShowsALoadingFlash() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        try runGit(["init", "-q", "-b", "main", scratchDirectory.path], in: scratchDirectory)
        try "one\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: scratchDirectory)
        try runGit(["commit", "-q", "-m", "base"], in: scratchDirectory)
        try "one-changed\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)

        let tabA = makeTerminalTab(pwd: scratchDirectory.path)
        tabA.paneContent[UUID()] = .gitChanges
        let tabB = makeTerminalTab(pwd: scratchDirectory.path)

        let group = TabGroup(name: "Default", tabs: [tabA, tabB], activeTabID: tabA.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalixWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalixWindowController(window: window, windowSession: session, restoring: true)
        let gitChangesController = controller._gitChangesControllerForTesting

        gitChangesController.refreshStatus()
        let loadDeadline = ContinuousClock.now + Duration.seconds(5)
        while true {
            if case .loaded = tabA.gitChangesState { break }
            guard ContinuousClock.now < loadDeadline else {
                Issue.record("Timed out waiting for tabA's initial git status load")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!tabA.gitEntries.isEmpty)

        controller.switchToTab(id: tabB.id)
        controller.switchToTab(id: tabA.id)

        var sawLoading = false
        let sampleDeadline = ContinuousClock.now + Duration.milliseconds(500)
        while ContinuousClock.now < sampleDeadline {
            if case .loading = tabA.gitChangesState { sawLoading = true; break }
            if case .notLoaded = tabA.gitChangesState { sawLoading = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!sawLoading, "reactivating a tab with cached entries must never pass through .loading/.notLoaded")
        #expect(!tabA.gitEntries.isEmpty, "tabA's cached gitEntries should survive a tab switch without needing a fresh refreshStatus() call")
    }

    // Carried-forward fix (Task 10 review, landed here per the plan): the
    // changes panel's own close button routes through `closePane`, which
    // never stopped the live `GitChangesMonitor` at all -- only
    // `toggleChangesPanel()`'s close branch did. A user who opens the panel
    // then closes it via its X (rather than the toolbar toggle) used to leak
    // the FSEvents watch on the tab's repo indefinitely. Seeds the monitor
    // through `toggleChangesPanel()` itself (the real open path, same as
    // production) rather than a synthetic `paneContent[UUID()] = .gitChanges`
    // seed, so the leaf id closed below is the exact one a real close button
    // would carry.
    //
    // Deliberately NOT `makeTerminalTab` here: that registers a real
    // `SurfaceView` in the tab's registry, and `closePane`'s post-close
    // focus-restore (`window?.makeFirstResponder(focusView)`) then tries to
    // focus a view this test's off-screen `CalixWindow` never actually laid
    // out, which AppKit logs as an invalid-first-responder error. A plain
    // `Tab` with no registry entries makes `registry.view(for:)` nil for
    // the remaining terminal leaf, so that branch is skipped -- irrelevant
    // to what this test is actually proving (monitor lifecycle, not focus).
    @Test func closingChangesPanelPane_viaItsOwnCloseButton_stopsMonitoring() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        try runGit(["init", "-q", "-b", "main", scratchDirectory.path], in: scratchDirectory)

        let tab = Tab(pwd: scratchDirectory.path)
        tab.splitTree = SplitTree(leafID: UUID())
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalixWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalixWindowController(window: window, windowSession: session, restoring: true)
        let gitChangesController = controller._gitChangesControllerForTesting

        gitChangesController.toggleChangesPanel()
        guard let changesLeafID = tab.paneContent.first(where: { $0.value == .gitChanges })?.key else {
            Issue.record("Expected toggleChangesPanel() to insert a .gitChanges leaf")
            return
        }
        try await waitForMonitoredWorkTree(gitChangesController, toBe: scratchDirectory.path)

        controller._closePaneForTesting(leafID: changesLeafID)

        try await waitForMonitoredWorkTree(gitChangesController, toBe: nil)
    }

    // Companion guard for the same fix: closing an UNRELATED diff pane must
    // not stop monitoring out from under a changes panel that's still open
    // on the same tab. A naive fix that always reconciles by re-running
    // `activateCurrentTab()`'s full if/else (rather than only ever stopping)
    // would take the `isChangesPanelVisible == true` branch here and kick
    // off a fresh `refreshStatus()` as a side effect of closing an unrelated
    // pane -- this proves the monitor instead simply keeps running,
    // untouched, pointed at the same repo it already was.
    @Test func closingAnUnrelatedDiffPane_leavesTheChangesPanelsMonitorRunning() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        try runGit(["init", "-q", "-b", "main", scratchDirectory.path], in: scratchDirectory)
        try "one\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: scratchDirectory)
        try runGit(["commit", "-q", "-m", "base"], in: scratchDirectory)
        try "one-changed\n".write(to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)

        let tab = Tab(pwd: scratchDirectory.path)
        tab.splitTree = SplitTree(leafID: UUID())
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalixWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalixWindowController(window: window, windowSession: session, restoring: true)
        let gitChangesController = controller._gitChangesControllerForTesting

        gitChangesController.toggleChangesPanel()
        try await waitForMonitoredWorkTree(gitChangesController, toBe: scratchDirectory.path)
        let deadline = ContinuousClock.now + Duration.seconds(5)
        while true {
            if case .loaded = tab.gitChangesState { break }
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for git status load")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let leavesBefore = Set(tab.splitTree.allLeafIDs())
        let entry = GitFileEntry(path: "one.txt", origPath: nil, status: .modified, isStaged: false, renameScore: nil)
        gitChangesController.handleWorkingFileSelected(entry)
        guard let diffLeafID = tab.splitTree.allLeafIDs().first(where: { !leavesBefore.contains($0) }) else {
            Issue.record("Expected a new diff leaf to be inserted")
            return
        }

        controller._closePaneForTesting(leafID: diffLeafID)

        // Still open, still watching -- unaffected by the unrelated pane's close.
        #expect(gitChangesController.isChangesPanelVisible)
        try await waitForMonitoredWorkTree(gitChangesController, toBe: scratchDirectory.path)

        // Explicit teardown: this test, unlike its sibling above, deliberately
        // leaves the monitor live at the end of its assertions. Tearing it
        // down before the test scope exits (rather than leaving a live
        // FSEventStream to outlive `controller`'s deallocation, racing this
        // test's own `defer` deleting `scratchDirectory` out from under it)
        // avoids destabilizing whichever test happens to run next.
        gitChangesController.shutdown()
    }

    // Free regression guard carried from the plan's own test sketch: `Tab`'s
    // own storage is untouched by switching `activeGroupID` -- this never
    // enters `activateCurrentTab()` at all, so it's evidence Task 2's
    // per-tab storage is wired correctly, not evidence for the cache-then-
    // refresh behavior above (which does go through `activateCurrentTab()`).
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

        session.activeGroupID = groupB.id
        session.activeGroupID = groupA.id

        #expect(!tabA.gitEntries.isEmpty, "tabA's cached gitEntries should survive a group switch without needing a fresh refreshStatus() call")
    }

    // MARK: - Fixture Helpers

    /// A single-leaf terminal tab whose leaf has a registry entry, so
    /// `CalixWindowController`'s layout/focus paths see a real surface.
    private func makeTerminalTab(pwd: String) -> Tab {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        registry._testInsert(view: SurfaceView(frame: .zero), id: leafID)
        return Tab(pwd: pwd, splitTree: SplitTree(leafID: leafID), registry: registry)
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffTabLifecycleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func runGit(_ arguments: [String], in workDirectory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = workDirectory
        process.environment = [
            "GIT_AUTHOR_EMAIL": "calix-tests@example.invalid",
            "GIT_AUTHOR_NAME": "Calix Tests",
            "GIT_COMMITTER_EMAIL": "calix-tests@example.invalid",
            "GIT_COMMITTER_NAME": "Calix Tests",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin",
        ]

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errorData, as: UTF8.self)
            throw NSError(domain: "DiffTabLifecycleTestsFixture", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(stderr)",
            ])
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitForDiffState(
        controller: GitChangesController, leafID: UUID,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if case .loading = controller.diffState(for: leafID) {
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            return
        }
        Issue.record("Timed out waiting for diff state on leaf \(leafID)")
    }

    /// Polls `GitChangesController._monitoredWorkTreeForTesting()` until it
    /// matches `expected` (`nil` meaning "no monitor running"), or fails the
    /// test after `timeout`. Standardizes both sides through `URL` so `/tmp`
    /// vs. its `/private/tmp` symlink resolution can't produce a false
    /// mismatch -- `GitChangesMonitor` standardizes the path it stores the
    /// same way.
    private func waitForMonitoredWorkTree(
        _ controller: GitChangesController, toBe expected: String?,
        timeout: Duration = .seconds(5)
    ) async throws {
        let expectedStandardized = expected.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let deadline = ContinuousClock.now + timeout
        while true {
            let actual = await controller._monitoredWorkTreeForTesting()
            let actualStandardized = actual.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            if actualStandardized == expectedStandardized { return }
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for monitored work tree to be \(String(describing: expected)), last saw \(String(describing: actual))")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
