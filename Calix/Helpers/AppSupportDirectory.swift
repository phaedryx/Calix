// AppSupportDirectory.swift
// Calix
//
// Resolves Calix's `~/Library/Application Support/Calix` directory.

import Foundation

enum AppSupportDirectory {
    /// `~/Library/Application Support/Calix`. Falls back to a manually
    /// constructed path in the (practically unreachable on macOS) case
    /// where `FileManager` can't resolve the search path domain.
    static var path: String {
        let fm = FileManager.default
        let appSupport = fm
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("Calix", isDirectory: true).path
    }

    /// `~/Library/Application Support/Calyx` -- the pre-rename directory.
    /// An independent literal construction (NOT derived from `path`), so
    /// this keeps resolving to the old "Calyx" location even though
    /// `path`'s own "Calyx" literal was mechanically renamed to "Calix".
    static var legacyPath: String {
        let fm = FileManager.default
        let appSupport = fm
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("Calyx", isDirectory: true).path
    }

    /// One-time Calyx -> Calix Application Support directory migration.
    /// Moves `legacy` to `current` in place via `FileManager.moveItem`
    /// (`rename(2)` on the same volume -- atomic, near-instantaneous).
    /// No-op (returns `false`) when the legacy directory is absent, or
    /// when a directory already exists at `current` -- an existing
    /// `current` is always live data and must never be clobbered by a
    /// stale legacy one.
    @discardableResult
    static func migrateLegacyDirectoryIfNeeded(from legacy: String? = nil, to current: String? = nil) -> Bool {
        let legacyPath = legacy ?? Self.legacyPath
        let currentPath = current ?? Self.path
        let fm = FileManager.default

        guard !fm.fileExists(atPath: currentPath) else { return false }
        guard fm.fileExists(atPath: legacyPath) else { return false }

        do {
            try fm.moveItem(atPath: legacyPath, toPath: currentPath)
            return true
        } catch {
            return false
        }
    }
}
