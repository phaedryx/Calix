// GitServiceWorktreeTests.swift
// CalixTests
//
// Integration tests for branch-delta resolution against a real `origin`
// remote, including across linked worktrees -- the "pull a coworker's
// PR into a worktree and see what changed vs. main" scenario the
// Changes tab's branch-delta section exists for.

import Foundation
import Testing
@testable import Calix

struct GitServiceWorktreeTests {
    @Test func test_defaultRemoteBranch_resolvesOriginHEAD_afterClone() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let (_, clone) = try makeOriginAndClone(in: scratchDirectory)

        let base = try await GitService.defaultRemoteBranch(workDir: clone.path)
        #expect(base == "origin/main")
    }

    @Test func test_defaultRemoteBranch_returnsNil_withoutOriginRemote() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let repository = scratchDirectory.appendingPathComponent("repository")
        try runGit(["init", "-q", "-b", "main", repository.path], in: scratchDirectory)
        _ = try commit(file: "base.txt", contents: "base\n", message: "base commit", in: repository)

        let base = try await GitService.defaultRemoteBranch(workDir: repository.path)
        #expect(base == nil)
    }

    @Test func test_linkedWorktree_branchDeltaFilesShowsOwnChangesAgainstOrigin() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let (_, clone) = try makeOriginAndClone(in: scratchDirectory)

        // Pulling a coworker's PR into a worktree: a linked worktree
        // checked out to a branch that's ahead of origin/main. Linked
        // worktrees share the common git dir's refs/remotes, so
        // origin/HEAD resolves the same from inside the worktree.
        let reviewWorktree = scratchDirectory.appendingPathComponent("review-worktree")
        try runGit(["worktree", "add", "-q", "-b", "pr-123", reviewWorktree.path, "origin/main"], in: clone)

        try "feature\n".write(
            to: reviewWorktree.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: reviewWorktree)
        try runGit(["commit", "-q", "-m", "add feature"], in: reviewWorktree)

        let base = try await GitService.defaultRemoteBranch(workDir: reviewWorktree.path)
        #expect(base == "origin/main")

        let entries = try await GitService.branchDeltaFiles(workDir: reviewWorktree.path, base: base!)
        #expect(entries.map(\.path) == ["feature.txt"])
        #expect(entries.first?.status == .added)
    }

    @Test func test_branchDeltaFiles_usesMergeBase_ignoringIndependentOriginProgress() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let (bare, clone) = try makeOriginAndClone(in: scratchDirectory)

        try runGit(["checkout", "-q", "-b", "feature"], in: clone)
        try "feature\n".write(to: clone.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: clone)
        try runGit(["commit", "-q", "-m", "add feature"], in: clone)

        // A second contributor advances origin/main independently,
        // after `feature` diverged -- merge-base (three-dot) semantics
        // must still report only `feature`'s own file, not this too.
        let otherClone = scratchDirectory.appendingPathComponent("other-clone")
        try runGit(["clone", "-q", bare.path, otherClone.path], in: scratchDirectory)
        try "other\n".write(to: otherClone.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: otherClone)
        try runGit(["commit", "-q", "-m", "advance main"], in: otherClone)
        try runGit(["push", "-q", "origin", "main"], in: otherClone)

        try runGit(["fetch", "-q", "origin"], in: clone)

        let entries = try await GitService.branchDeltaFiles(workDir: clone.path, base: "origin/main")
        #expect(entries.map(\.path) == ["feature.txt"])
    }

    // MARK: - Fixture Helpers

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitServiceWorktreeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A bare `origin.git` seeded with one commit on `main`, plus a
    /// non-bare clone of it (so the clone's `refs/remotes/origin/HEAD`
    /// is set, exactly as a real `git clone` sets it).
    private func makeOriginAndClone(in scratchDirectory: URL, cloneName: String = "clone") throws -> (bare: URL, clone: URL) {
        let seed = scratchDirectory.appendingPathComponent("seed")
        try runGit(["init", "-q", "-b", "main", seed.path], in: scratchDirectory)
        _ = try commit(file: "base.txt", contents: "base\n", message: "base commit", in: seed)

        let bare = scratchDirectory.appendingPathComponent("origin.git")
        try runGit(["clone", "-q", "--bare", seed.path, bare.path], in: scratchDirectory)

        let clone = scratchDirectory.appendingPathComponent(cloneName)
        try runGit(["clone", "-q", bare.path, clone.path], in: scratchDirectory)
        return (bare, clone)
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
            throw GitFixtureError(
                arguments: arguments,
                exitCode: process.terminationStatus,
                stderr: String(decoding: errorData, as: UTF8.self)
            )
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(
        file: String,
        contents: String,
        message: String,
        in repository: URL
    ) throws -> String {
        try contents.write(
            to: repository.appendingPathComponent(file),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "--", file], in: repository)
        try runGit(["commit", "-q", "-m", message], in: repository)
        return try runGit(["rev-parse", "HEAD"], in: repository)
    }
}

private struct GitFixtureError: Error, CustomStringConvertible {
    let arguments: [String]
    let exitCode: Int32
    let stderr: String

    var description: String {
        "git \(arguments.joined(separator: " ")) failed (exit \(exitCode)): \(stderr)"
    }
}
