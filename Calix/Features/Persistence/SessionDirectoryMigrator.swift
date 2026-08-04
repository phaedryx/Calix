// SessionDirectoryMigrator.swift
// Calix
//
// One-time Calyx -> Calix session-root migration. A user with real
// session history under the pre-rename ~/.calyx must not silently lose
// it now that SessionRootResolver-derived consumers (SessionPersistenceActor,
// SessionDaemonClient, SessionCommandSynthesizer) all look under
// ~/.calix instead. This is a pure, stateless, injectable-path function
// -- it never resolves $HOME/NSHomeDirectory() itself -- so the caller
// (AppDelegate.applicationDidFinishLaunching) supplies both paths
// already resolved, and it must run once, synchronously, before
// SessionRootResolver/SessionPersistenceActor.shared are first touched.

import Foundation

enum SessionDirectoryMigrator {
    enum Outcome: Equatable {
        /// oldRoot existed, newRoot did not; oldRoot was renamed to newRoot.
        case migrated
        /// newRoot already existed. A no-op regardless of oldRoot's
        /// state -- an existing newRoot is always live data and must
        /// never be clobbered by a stale oldRoot.
        case alreadyAtNewRoot
        /// Neither directory existed. A no-op; no directory was created.
        case nothingToMigrate
        /// oldRoot existed and newRoot did not, but the move itself
        /// failed (e.g. newRoot's parent directory doesn't exist).
        /// oldRoot is left untouched.
        case failed
    }

    @discardableResult
    static func migrateIfNeeded(
        oldRoot: URL,
        newRoot: URL,
        fileManager: FileManager = .default
    ) -> Outcome {
        if fileManager.fileExists(atPath: newRoot.path) {
            return .alreadyAtNewRoot
        }
        guard fileManager.fileExists(atPath: oldRoot.path) else {
            return .nothingToMigrate
        }
        do {
            try fileManager.moveItem(at: oldRoot, to: newRoot)
            return .migrated
        } catch {
            return .failed
        }
    }
}
