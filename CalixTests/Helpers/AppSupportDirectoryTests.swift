//
//  AppSupportDirectoryTests.swift
//  CalixTests
//
//  Coverage for AppSupportDirectory.migrateLegacyDirectoryIfNeeded: the
//  one-time Calyx -> Calix Application Support directory migration. All
//  cases exercise `from`/`to` against throwaway temp-directory paths --
//  never the real ~/Library/Application Support/Calyx or Calix.
//

import XCTest
@testable import Calix

final class AppSupportDirectoryTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!
    private var legacyPath: String!
    private var currentPath: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        legacyPath = tempDir + "/Calyx"
        currentPath = tempDir + "/Calix"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeDirectory(atPath path: String, markerFileName: String = "marker.txt") throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/" + markerFileName, contents: Data("x".utf8))
    }

    // MARK: - Tests

    func test_migrateLegacyDirectoryIfNeeded_legacyExistsCurrentAbsent_movesAndReturnsTrue() throws {
        try makeDirectory(atPath: legacyPath)

        let result = AppSupportDirectory.migrateLegacyDirectoryIfNeeded(from: legacyPath, to: currentPath)

        XCTAssertTrue(result, "Migration must report true when it actually moved the directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath),
                       "The legacy directory must no longer exist after migration")
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentPath),
                      "The current directory must exist after migration")
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentPath + "/marker.txt"),
                      "The legacy directory's contents must have moved along with it")
    }

    func test_migrateLegacyDirectoryIfNeeded_legacyAbsent_noopReturnsFalse() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPath),
                       "Precondition: legacy directory must not exist")

        let result = AppSupportDirectory.migrateLegacyDirectoryIfNeeded(from: legacyPath, to: currentPath)

        XCTAssertFalse(result, "Migration must report false when there is nothing to migrate")
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentPath),
                       "No directory should be created when the legacy directory is absent")
    }

    func test_migrateLegacyDirectoryIfNeeded_bothExist_noopNeitherDirectoryTouched() throws {
        try makeDirectory(atPath: legacyPath, markerFileName: "legacy-marker.txt")
        try makeDirectory(atPath: currentPath, markerFileName: "current-marker.txt")

        let result = AppSupportDirectory.migrateLegacyDirectoryIfNeeded(from: legacyPath, to: currentPath)

        XCTAssertFalse(result, "Migration must never clobber an existing current directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPath),
                      "The legacy directory must be left untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPath + "/legacy-marker.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentPath),
                      "The current directory must be left untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentPath + "/current-marker.txt"),
                      "The current directory's own content must survive, not be overwritten by the legacy one")
    }

    // MARK: - Default path plumbing

    func test_legacyPath_isSiblingOfPathWithCalyxComponent() {
        // legacyPath must be an independent literal resolving to the same
        // parent directory as `path`, differing only in the final
        // "Calyx" vs "Calix" path component -- not derived from `path`
        // itself (which now contains the mechanically-renamed "Calix"
        // literal).
        let path = AppSupportDirectory.path
        let legacy = AppSupportDirectory.legacyPath

        XCTAssertTrue(path.hasSuffix("/Calix"), "path must resolve to a Calix-suffixed directory")
        XCTAssertTrue(legacy.hasSuffix("/Calyx"), "legacyPath must resolve to a Calyx-suffixed directory")

        let pathParent = (path as NSString).deletingLastPathComponent
        let legacyParent = (legacy as NSString).deletingLastPathComponent
        XCTAssertEqual(pathParent, legacyParent, "path and legacyPath must share the same parent directory")
    }
}
