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

    @Test func handleWorkingFileSelected_secondTab_loadsIndependentDiff() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        try runGit(["init", "-q", "-b", "main", scratchDirectory.path], in: scratchDirectory)
        try "one\n".write(
            to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(
            to: scratchDirectory.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: scratchDirectory)
        try runGit(["commit", "-q", "-m", "base"], in: scratchDirectory)

        try "one-changed\n".write(
            to: scratchDirectory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "two-changed\n".write(
            to: scratchDirectory.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)

        let terminalTab = Tab(pwd: scratchDirectory.path)
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
        let statusDeadline = ContinuousClock.now + Duration.seconds(5)
        while true {
            if case .loaded = terminalTab.gitChangesState { break }
            guard ContinuousClock.now < statusDeadline else {
                Issue.record("Timed out waiting for initial git status load, state: \(terminalTab.gitChangesState)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let entry1 = GitFileEntry(
            path: "one.txt", origPath: nil, status: .modified, isStaged: false, renameScore: nil)
        let entry2 = GitFileEntry(
            path: "two.txt", origPath: nil, status: .modified, isStaged: false, renameScore: nil)

        controller.handleWorkingFileSelected(entry1)
        guard let tab1 = group.tabs.last else {
            Issue.record("Expected first diff tab to be created")
            return
        }
        try await waitForDiffState(controller: controller, group: group, tabID: tab1.id)

        // Per-tab repoRoot means only the terminal tab that actually loaded
        // git status carries a resolved repoRoot -- switch back to it before
        // selecting the next file, mirroring how the (Task 9) per-tab panel
        // will keep the changes list scoped to its own originating tab
        // rather than to whatever tab happens to be active.
        group.activeTabID = terminalTab.id
        controller.handleWorkingFileSelected(entry2)
        guard let tab2 = group.tabs.last, tab2.id != tab1.id else {
            Issue.record("Expected second diff tab to be created")
            return
        }
        try await waitForDiffState(controller: controller, group: group, tabID: tab2.id)

        group.activeTabID = tab1.id
        guard case .success(let diff1) = controller.activeDiffState else {
            Issue.record("Expected tab1 diff state .success, got \(String(describing: controller.activeDiffState))")
            return
        }

        group.activeTabID = tab2.id
        guard case .success(let diff2) = controller.activeDiffState else {
            Issue.record("Expected tab2 diff state .success, got \(String(describing: controller.activeDiffState))")
            return
        }

        #expect(diff1.path == "one.txt")
        #expect(diff2.path == "two.txt")
        #expect(!diff1.lines.isEmpty)
        #expect(!diff2.lines.isEmpty)
        #expect(diff1.lines != diff2.lines)
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

        controller.handleWorkingFileSelected(entry1)
        guard let tab1 = group.tabs.last else {
            Issue.record("Expected first diff tab to be created")
            return
        }
        try await waitForDiffState(controller: controller, group: group, tabID: tab1.id)

        group.activeTabID = tab1.id
        guard case .success(let diff1) = controller.activeDiffState, case .unstaged(_, let workDir1) = controller.activeDiffSource else {
            Issue.record("Expected tab1 .success with an unstaged source, got \(String(describing: controller.activeDiffState))")
            return
        }
        #expect(workDir1.hasSuffix(realRepo.lastPathComponent), "tab1 should resolve the real repo (active terminal tab)")
        #expect(!diff1.lines.isEmpty)

        // `repoRoot` now lives on `realRepoTab` itself, not on a
        // window-level cache keyed by workDir -- so re-activating
        // `realRepoTab` (the tab that actually loaded git status) before
        // the next selection resolves unambiguously to its own repo,
        // regardless of `otherTab` sitting earlier in `group.tabs`. This
        // is the structural fix for the old fallback-across-tabs bug: there
        // is no shared cache left for `otherTab` to have poisoned.
        group.activeTabID = realRepoTab.id
        controller.handleWorkingFileSelected(entry2)
        guard let tab2 = group.tabs.last, tab2.id != tab1.id else {
            Issue.record("Expected second diff tab to be created")
            return
        }
        try await waitForDiffState(controller: controller, group: group, tabID: tab2.id)

        group.activeTabID = tab2.id
        guard case .unstaged(_, let workDir2) = controller.activeDiffSource else {
            Issue.record("Expected tab2 to have an unstaged source")
            return
        }
        #expect(
            workDir2 == workDir1,
            "tab2 resolved workDir \(workDir2), not tab1's repo \(workDir1) -- per-tab repoRoot should make this impossible even with otherTab earlier in group.tabs"
        )
        guard case .success(let diff2) = controller.activeDiffState else {
            Issue.record("Expected tab2 .success, got \(String(describing: controller.activeDiffState))")
            return
        }
        #expect(
            !diff2.lines.isEmpty,
            "tab2's diff is empty (blank content, correct title) -- it ran against the wrong repo's workDir"
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
        controller: GitChangesController, group: TabGroup, tabID: UUID,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        group.activeTabID = tabID
        while ContinuousClock.now < deadline {
            if case .loading = controller.activeDiffState {
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            return
        }
        Issue.record("Timed out waiting for diff state on tab \(tabID)")
    }
}
