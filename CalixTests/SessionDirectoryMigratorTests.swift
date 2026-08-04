//
//  SessionDirectoryMigratorTests.swift
//  CalixTests
//
//  Task 2 of the Calyx -> Calix rename plan: a user with real session
//  history under the pre-rename ~/.calyx must not silently lose it now
//  that SessionRootResolver-derived consumers look under ~/.calix.
//  SessionDirectoryMigrator is a pure, injectable-path function (no
//  hardcoded home-directory resolution inside it) that renames the old
//  session root aside to the new one, once, the first time the renamed
//  build launches.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention): SessionDirectoryMigrator does
//  not exist yet. This file fails to compile until the Green phase adds
//  it at Calix/Features/Persistence/SessionDirectoryMigrator.swift.
//
//  Coverage (all four Outcome cases, exclusively against temp
//  directories under this test's own scratch dir -- never against the
//  real $HOME/.calyx or $HOME/.calix):
//  - .migrated: oldRoot populated with sessions.json, sessions.json.bak,
//    .recovery, sessions.recovery.json; newRoot absent. oldRoot is gone
//    afterward and all four files now live under newRoot.
//  - .alreadyAtNewRoot: both dirs exist with different sessions.json
//    contents. A no-op -- oldRoot untouched, newRoot's pre-existing
//    content untouched byte-for-byte, proving this never clobbers a
//    live .calix with stale .calyx data.
//  - .nothingToMigrate: neither dir exists. newRoot still doesn't exist
//    afterward (no accidental directory creation).
//  - .failed: oldRoot populated, but newRoot's parent directory doesn't
//    exist, so the underlying FileManager.moveItem throws ENOENT
//    without creating intermediates. oldRoot and its contents are still
//    present, untouched.

import XCTest
@testable import Calix

final class SessionDirectoryMigratorTests: XCTestCase {

    private var scratchDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionDirectoryMigratorTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratchDir = dir.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let scratchDir {
            try? FileManager.default.removeItem(at: scratchDir)
        }
        scratchDir = nil
        try super.tearDownWithError()
    }

    private func populateSessionFiles(at root: URL, sessionsContent: String = "old") throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try sessionsContent.write(
            to: root.appendingPathComponent("sessions.json"),
            atomically: true,
            encoding: .utf8
        )
        try "backup".write(
            to: root.appendingPathComponent("sessions.json.bak"),
            atomically: true,
            encoding: .utf8
        )
        try "marker".write(
            to: root.appendingPathComponent(".recovery"),
            atomically: true,
            encoding: .utf8
        )
        try "recovery".write(
            to: root.appendingPathComponent("sessions.recovery.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    func test_migrateIfNeeded_oldRootPopulatedNewRootAbsent_migratesAndRemovesOldRoot() throws {
        let oldRoot = scratchDir.appendingPathComponent(".calyx", isDirectory: true)
        let newRoot = scratchDir.appendingPathComponent(".calix", isDirectory: true)
        try populateSessionFiles(at: oldRoot)

        let outcome = SessionDirectoryMigrator.migrateIfNeeded(oldRoot: oldRoot, newRoot: newRoot)

        XCTAssertEqual(outcome, .migrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.path))
        for name in ["sessions.json", "sessions.json.bak", ".recovery", "sessions.recovery.json"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: newRoot.appendingPathComponent(name).path),
                "expected \(name) to exist under newRoot after migration"
            )
        }
        let migratedContent = try String(contentsOf: newRoot.appendingPathComponent("sessions.json"), encoding: .utf8)
        XCTAssertEqual(migratedContent, "old")
    }

    func test_migrateIfNeeded_bothRootsExist_isNoOpAndNeverClobbersNewRoot() throws {
        let oldRoot = scratchDir.appendingPathComponent(".calyx", isDirectory: true)
        let newRoot = scratchDir.appendingPathComponent(".calix", isDirectory: true)
        try populateSessionFiles(at: oldRoot, sessionsContent: "stale-old-content")
        try populateSessionFiles(at: newRoot, sessionsContent: "live-new-content")

        let outcome = SessionDirectoryMigrator.migrateIfNeeded(oldRoot: oldRoot, newRoot: newRoot)

        XCTAssertEqual(outcome, .alreadyAtNewRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path), "oldRoot must remain untouched")
        let oldContent = try String(contentsOf: oldRoot.appendingPathComponent("sessions.json"), encoding: .utf8)
        XCTAssertEqual(oldContent, "stale-old-content")
        let newContent = try String(contentsOf: newRoot.appendingPathComponent("sessions.json"), encoding: .utf8)
        XCTAssertEqual(newContent, "live-new-content", "newRoot's live content must never be clobbered by stale oldRoot data")
    }

    func test_migrateIfNeeded_neitherRootExists_isNoOpAndCreatesNothing() {
        let oldRoot = scratchDir.appendingPathComponent(".calyx", isDirectory: true)
        let newRoot = scratchDir.appendingPathComponent(".calix", isDirectory: true)

        let outcome = SessionDirectoryMigrator.migrateIfNeeded(oldRoot: oldRoot, newRoot: newRoot)

        XCTAssertEqual(outcome, .nothingToMigrate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newRoot.path))
    }

    func test_migrateIfNeeded_newRootParentMissing_failsAndLeavesOldRootUntouched() throws {
        let oldRoot = scratchDir.appendingPathComponent(".calyx", isDirectory: true)
        // newRoot's parent ("missing-parent") does not exist, so
        // FileManager.moveItem throws ENOENT without creating
        // intermediate directories.
        let newRoot = scratchDir
            .appendingPathComponent("missing-parent", isDirectory: true)
            .appendingPathComponent(".calix", isDirectory: true)
        try populateSessionFiles(at: oldRoot)

        let outcome = SessionDirectoryMigrator.migrateIfNeeded(oldRoot: oldRoot, newRoot: newRoot)

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path), "oldRoot must survive a failed migration")
        let survivingContent = try String(contentsOf: oldRoot.appendingPathComponent("sessions.json"), encoding: .utf8)
        XCTAssertEqual(survivingContent, "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: newRoot.path))
    }
}
