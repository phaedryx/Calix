import Foundation

/// One-time migration of the app's CFPreferences (UserDefaults-backed)
/// domain from the pre-rename bundle ID (`com.calyx.terminal`) to the
/// post-rename bundle ID (`com.calix.terminal`). Without this, a user's
/// existing settings would silently reset to defaults the first time they
/// launch a build carrying the new bundle ID, since `UserDefaults.standard`
/// resolves to a domain keyed by `Bundle.main.bundleIdentifier`.
///
/// Design: copies the *entire* source domain into the destination domain
/// (overwrite, not merge) the first time the destination lacks the
/// `didMigrateKey` marker. Overwrite was chosen because, at the time this
/// shipped, no build carrying the new bundle ID had been publicly released,
/// so there was no risk of clobbering a real post-rename setting change.
/// If a pre-migration build of the renamed app ever ships before this
/// lands, switch to fill-missing semantics (skip keys already present in
/// the destination) instead.
enum PreferencesMigrator {
    /// Marker key written into the NEW domain once migration has run.
    static let didMigrateKey = "didMigratePreferencesFromCalyx"

    /// Copies every key from `sourceBundleID`'s CFPreferences domain into
    /// `destinationBundleID`'s domain, then stamps `didMigrateKey` in the
    /// destination so this never re-runs. No-ops if the marker is already
    /// present in the destination, or if the source domain has no data
    /// (fresh install, never ran the old build).
    ///
    /// Injectable bundle IDs so tests can point both ends at throwaway
    /// domain names instead of the real `com.calyx.terminal` /
    /// `com.calix.terminal`.
    static func migrateIfNeeded(
        from sourceBundleID: String = "com.calyx.terminal",
        to destinationBundleID: String = Bundle.main.bundleIdentifier ?? "com.calix.terminal"
    ) {
        // Idempotency guard checked in the NEW domain first -- cheap,
        // and guarantees this never re-runs even if step 2 below finds
        // nothing to copy.
        let alreadyMigrated = CFPreferencesGetAppBooleanValue(
            didMigrateKey as CFString,
            destinationBundleID as CFString,
            nil
        )
        guard !alreadyMigrated else { return }

        if let oldPrefs = CFPreferencesCopyMultiple(
            nil, // nil keyList == "all keys in this domain"
            sourceBundleID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any], !oldPrefs.isEmpty {
            CFPreferencesSetMultiple(
                oldPrefs as CFDictionary,
                nil,
                destinationBundleID as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }

        CFPreferencesSetAppValue(
            didMigrateKey as CFString,
            kCFBooleanTrue,
            destinationBundleID as CFString
        )
        CFPreferencesAppSynchronize(destinationBundleID as CFString)
    }
}
