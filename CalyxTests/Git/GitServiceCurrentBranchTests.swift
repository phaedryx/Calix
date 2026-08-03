// GitServiceCurrentBranchTests.swift
// CalyxTests
//
// Tests for GitService.currentBranch, used to surface each tab's branch
// name in the sidebar (ported from cmux's per-workspace git metadata).

import Foundation
import Testing
@testable import Calyx

struct GitServiceCurrentBranchTests {
    @Test func test_currentBranch_returnsBranchName() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let repository = scratchDirectory.appendingPathComponent("repository")
        try runGit(["init", "-q", "-b", "main", repository.path], in: scratchDirectory)
        try commit(file: "base.txt", contents: "base\n", message: "base commit", in: repository)

        let branch = try await GitService.currentBranch(workDir: repository.path)
        #expect(branch == "main")
    }

    @Test func test_currentBranch_reflectsCheckoutSwitch() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let repository = scratchDirectory.appendingPathComponent("repository")
        try runGit(["init", "-q", "-b", "main", repository.path], in: scratchDirectory)
        try commit(file: "base.txt", contents: "base\n", message: "base commit", in: repository)
        try runGit(["checkout", "-q", "-b", "feature-x"], in: repository)

        let branch = try await GitService.currentBranch(workDir: repository.path)
        #expect(branch == "feature-x")
    }

    @Test func test_currentBranch_throwsForNonRepository() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        await #expect(throws: (any Error).self) {
            _ = try await GitService.currentBranch(workDir: scratchDirectory.path)
        }
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitServiceCurrentBranchTests-\(UUID().uuidString)")
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
            "GIT_AUTHOR_EMAIL": "calyx-tests@example.invalid",
            "GIT_AUTHOR_NAME": "Calyx Tests",
            "GIT_COMMITTER_EMAIL": "calyx-tests@example.invalid",
            "GIT_COMMITTER_NAME": "Calyx Tests",
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
            throw GitBranchFixtureError(
                arguments: arguments,
                exitCode: process.terminationStatus,
                stderr: String(decoding: errorData, as: UTF8.self)
            )
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
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

private struct GitBranchFixtureError: Error, CustomStringConvertible {
    let arguments: [String]
    let exitCode: Int32
    let stderr: String

    var description: String {
        "git \(arguments.joined(separator: " ")) failed (exit \(exitCode)): \(stderr)"
    }
}
