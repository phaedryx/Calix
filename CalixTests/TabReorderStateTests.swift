//
//  TabReorderStateTests.swift
//  CalixTests
//
//  Tests for TabReorderState -- drag state tracking for tab reordering.
//
//  Coverage:
//  - updateInsertionSlot: horizontal axis (finds correct slot from measured frames)
//  - updateInsertionSlot: vertical axis
//  - destinationIndex: slot-to-item conversion moving right
//  - destinationIndex: slot-to-item conversion moving left
//  - destinationIndex: no-op when slot adjacent to source
//  - destinationIndex: clamps to valid range
//  - reset: clears all state
//

import XCTest
@testable import Calix

@MainActor
final class TabReorderStateTests: XCTestCase {

    // MARK: - Helpers

    /// Build a TabReorderState with 4 horizontal tab frames at known positions.
    ///
    /// Layout (each tab is 100pt wide, no gaps):
    ///   Tab0: x=0..100   midX=50
    ///   Tab1: x=100..200 midX=150
    ///   Tab2: x=200..300 midX=250
    ///   Tab3: x=300..400 midX=350
    private func makeHorizontalState() -> (TabReorderState, [UUID]) {
        let state = TabReorderState()
        let ids = (0..<4).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            let x = CGFloat(i) * 100
            state.tabFrames[id] = CGRect(x: x, y: 0, width: 100, height: 30)
        }
        return (state, ids)
    }

    /// Build a TabReorderState with 4 vertical tab frames at known positions.
    ///
    /// Layout (each tab is 40pt tall, no gaps):
    ///   Tab0: y=0..40   midY=20
    ///   Tab1: y=40..80  midY=60
    ///   Tab2: y=80..120 midY=100
    ///   Tab3: y=120..160 midY=140
    private func makeVerticalState() -> (TabReorderState, [UUID]) {
        let state = TabReorderState()
        let ids = (0..<4).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            let y = CGFloat(i) * 40
            state.tabFrames[id] = CGRect(x: 0, y: y, width: 200, height: 40)
        }
        return (state, ids)
    }

    // ==================== 1. updateInsertionSlot -- horizontal ====================

    func test_updateInsertionSlot_findsCorrectSlot_fromMeasuredFrames() {
        // Arrange -- 4 tabs, each 100pt wide, laid out [0,100,200,300]
        let (state, _) = makeHorizontalState()

        // Act & Assert -- drag midpoint before all tabs -> slot 0
        state.updateInsertionSlot(dragMidpoint: 10, axis: .horizontal)
        XCTAssertEqual(state.insertionSlot, 0,
                       "Midpoint 10 is before tab0 midX(50), should be slot 0")

        // Act & Assert -- drag midpoint between tab0 and tab1 -> slot 1
        state.updateInsertionSlot(dragMidpoint: 120, axis: .horizontal)
        XCTAssertEqual(state.insertionSlot, 1,
                       "Midpoint 120 is between tab0 midX(50) and tab1 midX(150), should be slot 1")

        // Act & Assert -- drag midpoint between tab1 and tab2 -> slot 2
        state.updateInsertionSlot(dragMidpoint: 210, axis: .horizontal)
        XCTAssertEqual(state.insertionSlot, 2,
                       "Midpoint 210 is between tab1 midX(150) and tab2 midX(250), should be slot 2")

        // Act & Assert -- drag midpoint between tab2 and tab3 -> slot 3
        state.updateInsertionSlot(dragMidpoint: 310, axis: .horizontal)
        XCTAssertEqual(state.insertionSlot, 3,
                       "Midpoint 310 is between tab2 midX(250) and tab3 midX(350), should be slot 3")

        // Act & Assert -- drag midpoint past all tabs -> slot 4 (= tabCount)
        state.updateInsertionSlot(dragMidpoint: 400, axis: .horizontal)
        XCTAssertEqual(state.insertionSlot, 4,
                       "Midpoint 400 is past tab3 midX(350), should be slot 4 (tabCount)")
    }

    // ==================== 2. updateInsertionSlot -- vertical ====================

    func test_updateInsertionSlot_vertical_findsCorrectSlot() {
        // Arrange -- 4 tabs, each 40pt tall, laid out [0,40,80,120]
        let (state, _) = makeVerticalState()

        // Act & Assert -- drag midpoint before all tabs -> slot 0
        state.updateInsertionSlot(dragMidpoint: 5, axis: .vertical)
        XCTAssertEqual(state.insertionSlot, 0,
                       "Midpoint 5 is before tab0 midY(20), should be slot 0")

        // Act & Assert -- drag midpoint between tab0 and tab1 -> slot 1
        state.updateInsertionSlot(dragMidpoint: 45, axis: .vertical)
        XCTAssertEqual(state.insertionSlot, 1,
                       "Midpoint 45 is between tab0 midY(20) and tab1 midY(60), should be slot 1")

        // Act & Assert -- drag midpoint between tab2 and tab3 -> slot 3
        state.updateInsertionSlot(dragMidpoint: 115, axis: .vertical)
        XCTAssertEqual(state.insertionSlot, 3,
                       "Midpoint 115 is between tab2 midY(100) and tab3 midY(140), should be slot 3")

        // Act & Assert -- drag midpoint past all tabs -> slot 4 (= tabCount)
        state.updateInsertionSlot(dragMidpoint: 160, axis: .vertical)
        XCTAssertEqual(state.insertionSlot, 4,
                       "Midpoint 160 is past tab3 midY(140), should be slot 4 (tabCount)")
    }

    // ==================== 3. destinationIndex -- moving right ====================

    func test_destinationIndex_slotToItemIndex_movingRight() {
        // Arrange -- dragging tab 0 to slot 3
        // [Tab0] | [Tab1] | [Tab2] | [Tab3]
        //   ^  s0  ^  s1  ^  s2  ^  s3  ^  s4
        //
        // insertionSlot=3 > draggedTabIndex(0)+1 -> destination = 3-1 = 2
        let state = TabReorderState()
        state.draggedTabIndex = 0
        state.insertionSlot = 3

        // Act
        let dest = state.destinationIndex(fromIndex: 0, tabCount: 4)

        // Assert
        XCTAssertEqual(dest, 2,
                       "Dragging tab 0 to slot 3 should give destination index 2")
    }

    func test_destinationIndex_movingRight_toEnd() {
        // Arrange -- dragging tab 1 to slot 4 (past the last tab)
        // insertionSlot=4 > draggedTabIndex(1)+1 -> destination = 4-1 = 3
        let state = TabReorderState()
        state.draggedTabIndex = 1
        state.insertionSlot = 4

        // Act
        let dest = state.destinationIndex(fromIndex: 1, tabCount: 4)

        // Assert
        XCTAssertEqual(dest, 3,
                       "Dragging tab 1 to slot 4 should give destination index 3 (last position)")
    }

    // ==================== 4. destinationIndex -- moving left ====================

    func test_destinationIndex_slotToItemIndex_movingLeft() {
        // Arrange -- dragging tab 3 to slot 1
        // insertionSlot=1 <= draggedTabIndex(3) -> destination = 1
        let state = TabReorderState()
        state.draggedTabIndex = 3
        state.insertionSlot = 1

        // Act
        let dest = state.destinationIndex(fromIndex: 3, tabCount: 4)

        // Assert
        XCTAssertEqual(dest, 1,
                       "Dragging tab 3 to slot 1 should give destination index 1")
    }

    func test_destinationIndex_movingLeft_toBeginning() {
        // Arrange -- dragging tab 2 to slot 0 (before all tabs)
        // insertionSlot=0 <= draggedTabIndex(2) -> destination = 0
        let state = TabReorderState()
        state.draggedTabIndex = 2
        state.insertionSlot = 0

        // Act
        let dest = state.destinationIndex(fromIndex: 2, tabCount: 4)

        // Assert
        XCTAssertEqual(dest, 0,
                       "Dragging tab 2 to slot 0 should give destination index 0 (first position)")
    }

    // ==================== 5. destinationIndex -- no-op when adjacent ====================

    func test_destinationIndex_noOp_whenSlotEqualsDraggedIndex() {
        // Arrange -- insertionSlot == draggedTabIndex -> no-op
        let state = TabReorderState()
        state.draggedTabIndex = 2
        state.insertionSlot = 2

        // Act
        let dest = state.destinationIndex(fromIndex: 2, tabCount: 4)

        // Assert
        XCTAssertNil(dest,
                     "Should return nil when insertionSlot == draggedTabIndex (no move needed)")
    }

    func test_destinationIndex_noOp_whenSlotIsDraggedIndexPlusOne() {
        // Arrange -- insertionSlot == draggedTabIndex + 1 -> no-op
        // (dropping right next to current position, same visual spot)
        let state = TabReorderState()
        state.draggedTabIndex = 2
        state.insertionSlot = 3

        // Act
        let dest = state.destinationIndex(fromIndex: 2, tabCount: 4)

        // Assert
        XCTAssertNil(dest,
                     "Should return nil when insertionSlot == draggedTabIndex + 1 (no move needed)")
    }

    // ==================== 6. destinationIndex -- clamps to valid range ====================

    func test_destinationIndex_clampsToValidRange() {
        // Arrange -- insertionSlot beyond tabCount should be clamped
        // With tabCount=4, slot should max out at 4, giving destination = 4-1=3
        let state = TabReorderState()
        state.draggedTabIndex = 0
        state.insertionSlot = 10

        // Act
        let dest = state.destinationIndex(fromIndex: 0, tabCount: 4)

        // Assert -- clamped to tabCount (slot 4) -> destination = 4-1 = 3
        XCTAssertNotNil(dest, "Should return a valid index even when slot exceeds tabCount")
        if let dest = dest {
            XCTAssertLessThan(dest, 4,
                              "Destination index should be within valid range [0, tabCount-1]")
            XCTAssertGreaterThanOrEqual(dest, 0,
                                        "Destination index should not be negative")
        }
    }

    func test_destinationIndex_returnsNil_whenInsertionSlotIsNil() {
        // Arrange -- no insertionSlot set
        let state = TabReorderState()
        state.draggedTabIndex = 1
        // insertionSlot remains nil

        // Act
        let dest = state.destinationIndex(fromIndex: 1, tabCount: 4)

        // Assert
        XCTAssertNil(dest,
                     "Should return nil when insertionSlot has not been computed")
    }

    // ==================== 7. reset -- clears all state ====================

    func test_reset_clearsAllState() {
        // Arrange -- set every property to a non-default value
        let state = TabReorderState()
        state.draggedTabID = UUID()
        state.draggedTabIndex = 2
        state.insertionSlot = 3
        state.dragOffset = 150.0
        state.tabFrames[UUID()] = CGRect(x: 0, y: 0, width: 100, height: 30)

        // Act
        state.reset()

        // Assert
        XCTAssertNil(state.draggedTabID,
                     "draggedTabID should be nil after reset")
        XCTAssertNil(state.draggedTabIndex,
                     "draggedTabIndex should be nil after reset")
        XCTAssertNil(state.insertionSlot,
                     "insertionSlot should be nil after reset")
        XCTAssertEqual(state.dragOffset, 0,
                       "dragOffset should be 0 after reset")
        XCTAssertTrue(state.tabFrames.isEmpty,
                      "tabFrames should be empty after reset")
    }

    func test_reset_isIdempotent() {
        // Arrange -- fresh state, already at defaults
        let state = TabReorderState()

        // Act -- calling reset on clean state should not crash
        state.reset()

        // Assert
        XCTAssertNil(state.draggedTabID)
        XCTAssertNil(state.draggedTabIndex)
        XCTAssertNil(state.insertionSlot)
        XCTAssertEqual(state.dragOffset, 0)
        XCTAssertTrue(state.tabFrames.isEmpty)
    }
}
