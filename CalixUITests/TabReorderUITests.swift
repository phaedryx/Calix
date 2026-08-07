// TabReorderUITests.swift
// CalixUITests
//
// UI tests for tab drag-reorder in the sidebar (the tab bar this file
// used to also test was removed -- see
// docs/superpowers/specs/2026-08-07-remove-top-tab-strip-design.md).

import XCTest

final class TabReorderUITests: CalixUITestCase {

    // MARK: - Helpers

    // Position-ordered tab lookup.
    //
    // The sidebar's tab rows expose their `calix.sidebar.tab.<UUID>`
    // identifier (via `.accessibilityElement(children: .contain)`) but
    // NOT an `.accessibilityValue` index: XCUITest surfaces a container
    // element's identifier and label, but not its `AXValue`, so a
    // value-based index lookup would return nothing (confirmed
    // separately while adding the sidebar's active-group marker, see
    // `SidebarContentView.swift`). Instead, resolve a tab's ordinal
    // position from the on-screen geometry of the identifier-bearing
    // elements: top-to-bottom (minY).
    private static let uuidPattern =
        "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"

    /// Sidebar tab elements (identifier `calix.sidebar.tab.<UUID>`) sorted
    /// top-to-bottom by frame.
    private func sidebarTabsByPosition() -> [XCUIElement] {
        let predicate = NSPredicate(format: "identifier MATCHES %@",
                                    "calix\\.sidebar\\.tab\\.\(Self.uuidPattern)")
        let query = app.descendants(matching: .any).matching(predicate)
        return (0..<query.count)
            .map { query.element(boundBy: $0) }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func sidebarTab(atIndex index: Int) -> XCUIElement? {
        let tabs = sidebarTabsByPosition()
        return index < tabs.count ? tabs[index] : nil
    }

    /// Reads the identifier of the sidebar tab at a given ordinal position.
    private func sidebarTabIdentifier(atIndex index: Int) -> String? {
        sidebarTab(atIndex: index)?.identifier
    }

    /// Creates `count` additional tabs (beyond the initial one) and waits for them to appear.
    private func createTabs(count: Int) {
        for _ in 0..<count {
            createNewTabViaMenu()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    // MARK: - Sidebar Reorder

    func test_dragSidebarTab_reordersCorrectly() {
        // Arrange: create 3 tabs total
        createTabs(count: 2)
        XCTAssertEqual(countSidebarTabs(), 3, "Should have 3 tabs before toggling sidebar")

        // The sidebar is shown by default (WindowSession.showSidebar
        // defaults to true), so its tab rows are already on screen. Do NOT
        // call toggleSidebarViaMenu() here: that would CLOSE the sidebar and
        // hide the very rows this test drags. Just let it settle.
        Thread.sleep(forTimeInterval: 1.0)

        // Find the sidebar tab at index 0
        guard let firstSidebarTab = sidebarTab(atIndex: 0) else {
            return XCTFail("Sidebar tab at index 0 should exist")
        }
        let originalFirstSidebarID = firstSidebarTab.identifier

        // Find the sidebar tab at index 2
        guard let thirdSidebarTab = sidebarTab(atIndex: 2) else {
            return XCTFail("Sidebar tab at index 2 should exist")
        }

        // Act: drag the first sidebar tab down past the third
        firstSidebarTab.press(forDuration: 0.2, thenDragTo: thirdSidebarTab)

        // Allow the reorder animation to settle
        Thread.sleep(forTimeInterval: 1.0)

        // Assert: the tab that was originally at index 0 should no longer be there
        let newFirstSidebarID = sidebarTabIdentifier(atIndex: 0)
        XCTAssertNotNil(newFirstSidebarID, "A sidebar tab should exist at index 0 after reorder")
        XCTAssertNotEqual(
            newFirstSidebarID, originalFirstSidebarID,
            "After dragging the first sidebar tab past the third, a different tab should now occupy index 0"
        )

        // The original first tab should now be at a later index
        let sidebarTabAt1 = sidebarTabIdentifier(atIndex: 1)
        let sidebarTabAt2 = sidebarTabIdentifier(atIndex: 2)
        let originalSidebarTabMoved = (sidebarTabAt1 == originalFirstSidebarID) || (sidebarTabAt2 == originalFirstSidebarID)
        XCTAssertTrue(
            originalSidebarTabMoved,
            "The original first sidebar tab should have moved to index 1 or 2"
        )
    }
}
