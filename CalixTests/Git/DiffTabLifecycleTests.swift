// DiffTabLifecycleTests.swift
// CalixTests
//
// Tests for diff tab lifecycle: GitChangesState transitions, SidebarMode, DiffSource dedup.

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
        session.sidebarMode = .changes
        #expect(session.sidebarMode == .changes)
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

    // MARK: - Fixture Helpers

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
}
