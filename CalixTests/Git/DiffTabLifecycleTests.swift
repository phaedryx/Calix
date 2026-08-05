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
        let session = WindowSession()
        if case .notLoaded = session.gitChangesState {} else {
            Issue.record("Expected initial state .notLoaded")
        }

        session.gitChangesState = .loading
        if case .loading = session.gitChangesState {} else {
            Issue.record("Expected .loading")
        }

        session.gitChangesState = .loaded
        if case .loaded = session.gitChangesState {} else {
            Issue.record("Expected .loaded")
        }
    }

    @Test func gitChangesStateNotRepository() {
        let session = WindowSession()
        session.gitChangesState = .loading
        session.gitChangesState = .notRepository
        if case .notRepository = session.gitChangesState {} else {
            Issue.record("Expected .notRepository")
        }
    }

    @Test func gitChangesStateError() {
        let session = WindowSession()
        session.gitChangesState = .error("test error")
        if case .error(let msg) = session.gitChangesState {
            #expect(msg == "test error")
        } else {
            Issue.record("Expected .error")
        }
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
            if case .loaded = session.gitChangesState { break }
            guard ContinuousClock.now < statusDeadline else {
                Issue.record("Timed out waiting for initial git status load, state: \(session.gitChangesState)")
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

        // Simulate the user having looked at Changes earlier while `otherTab`
        // was active, which is how `windowSession.repoRoots[otherRepo.path]`
        // would have gotten populated in the real app.
        session.repoRoots[otherRepo.path] = otherRepo.path

        controller.refreshStatus()
        let statusDeadline = ContinuousClock.now + Duration.seconds(5)
        while true {
            if case .loaded = session.gitChangesState { break }
            guard ContinuousClock.now < statusDeadline else {
                Issue.record("Timed out waiting for initial git status load, state: \(session.gitChangesState)")
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

        // Active tab is now the diff tab, not a terminal tab -- this is the
        // moment `findWorkDir()` falls through to "any terminal tab in the
        // same group" and can pick the WRONG one.
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
            "BUG: tab2 resolved workDir \(workDir2), not tab1's repo \(workDir1) -- findWorkDir() fell through to the wrong terminal tab"
        )
        guard case .success(let diff2) = controller.activeDiffState else {
            Issue.record("Expected tab2 .success, got \(String(describing: controller.activeDiffState))")
            return
        }
        #expect(
            !diff2.lines.isEmpty,
            "BUG REPRODUCED: tab2's diff is empty (blank content, correct title) because it ran against the wrong repo's workDir"
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
