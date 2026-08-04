import XCTest
@testable import Calix

final class PreferencesMigratorTests: XCTestCase {
    private let oldDomain = "com.calyx.migrator-test.old"
    private let newDomain = "com.calyx.migrator-test.new"

    override func tearDown() {
        for domain in [oldDomain, newDomain] {
            CFPreferencesSetMultiple(
                [:] as CFDictionary,
                CFPreferencesCopyKeyList(
                    domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
                ),
                domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            )
            CFPreferencesAppSynchronize(domain as CFString)
        }
        super.tearDown()
    }

    func testCopiesKeysAndSetsMarkerOnce() {
        CFPreferencesSetValue(
            "someSetting" as CFString, "value1" as CFString,
            oldDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        CFPreferencesAppSynchronize(oldDomain as CFString)

        PreferencesMigrator.migrateIfNeeded(from: oldDomain, to: newDomain)

        let copied = CFPreferencesCopyValue(
            "someSetting" as CFString, newDomain as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? String
        XCTAssertEqual(copied, "value1")

        let marker = CFPreferencesGetAppBooleanValue(
            PreferencesMigrator.didMigrateKey as CFString, newDomain as CFString, nil
        )
        XCTAssertTrue(marker)

        // Second run must be a no-op even if the old domain changes.
        CFPreferencesSetValue(
            "someSetting" as CFString, "value2" as CFString,
            oldDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        CFPreferencesAppSynchronize(oldDomain as CFString)
        PreferencesMigrator.migrateIfNeeded(from: oldDomain, to: newDomain)

        let stillCopied = CFPreferencesCopyValue(
            "someSetting" as CFString, newDomain as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? String
        XCTAssertEqual(stillCopied, "value1", "second run must not re-copy")
    }
}
