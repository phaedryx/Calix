import Foundation
import Testing
@testable import Calix

@MainActor
@Suite("GhosttyAction Search Tests")
struct GhosttyActionSearchTests {

    // Test performSearch sanitization (static helper)
    @Test("sanitizeSearchQuery strips control characters")
    func sanitizeStripControlChars() {
        let result = GhosttySurfaceController.sanitizeSearchQuery("\t\nfoo\0bar")
        #expect(result == "foobar")
    }

    @Test("sanitizeSearchQuery preserves normal text")
    func sanitizePreservesNormal() {
        let result = GhosttySurfaceController.sanitizeSearchQuery("hello world")
        #expect(result == "hello world")
    }

    @Test("sanitizeSearchQuery empty string returns empty")
    func sanitizeEmpty() {
        let result = GhosttySurfaceController.sanitizeSearchQuery("")
        #expect(result == "")
    }

    @Test("sanitizeSearchQuery preserves colons")
    func sanitizePreservesColons() {
        let result = GhosttySurfaceController.sanitizeSearchQuery("foo:bar:baz")
        #expect(result == "foo:bar:baz")
    }

    @Test("sanitizeSearchQuery preserves unicode")
    func sanitizePreservesUnicode() {
        let result = GhosttySurfaceController.sanitizeSearchQuery("日本語テスト")
        #expect(result == "日本語テスト")
    }

    @Test("sanitizeSearchQuery strips mixed control chars")
    func sanitizeMixedControlChars() {
        // \x01 through \x1f are control characters
        let input = String(UnicodeScalar(0x01)) + "a" + String(UnicodeScalar(0x1f)) + "b"
        let result = GhosttySurfaceController.sanitizeSearchQuery(input)
        #expect(result == "ab")
    }

    // Test notification names exist
    @Test("search notification names are defined")
    func searchNotificationNamesDefined() {
        // These should be defined in Notification.Name extension
        _ = Notification.Name.ghosttyStartSearch
        _ = Notification.Name.ghosttyEndSearch
        _ = Notification.Name.ghosttySearchTotal
        _ = Notification.Name.ghosttySearchSelected
    }
}
