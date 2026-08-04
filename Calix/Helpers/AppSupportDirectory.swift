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
}
