//
//  TabGroupColorTests.swift
//  CalixTests
//
//  Tests for TabGroupColor.nextColor(excluding:) which assigns
//  the next available color to a new tab group.
//
//  Rewritten to match TabGroupColor's current 8-case palette: `.red`,
//  `.yellow`, and `.green` were removed (reserved elsewhere in the UI
//  for agent-state signals) and `.pink` was added. This file previously
//  asserted the old 10-case palette and assignment order, which no
//  longer compiles/holds against the current TabGroupColor.swift.
//

import XCTest
@testable import Calix

@MainActor
final class TabGroupColorTests: XCTestCase {

    // MARK: - nextColor(excluding:)
    // Assignment order: blue, purple, pink, orange, indigo, mint, cyan, teal

    /// An empty used-colors list should return the first in assignment order (.blue).
    func test_nextColor_emptyList_returnsFirst() {
        let result = TabGroupColor.nextColor(excluding: [])
        XCTAssertEqual(result, .blue, "With no colors in use, the first assignment order entry should be returned")
    }

    /// When only .blue is used, the next color in assignment order is .purple.
    func test_nextColor_oneUsed_skipsIt() {
        let result = TabGroupColor.nextColor(excluding: [.blue])
        XCTAssertEqual(result, .purple, "Should skip .blue and return .purple (2nd in assignment order)")
    }

    /// When .blue and .purple are both used, the next color is .pink.
    func test_nextColor_skipsMultipleUsed() {
        let result = TabGroupColor.nextColor(excluding: [.blue, .purple])
        XCTAssertEqual(result, .pink, "Should skip .blue and .purple, returning .pink")
    }

    /// When every color appears at least once, returns the least frequently
    /// used color (first in assignment order among ties).
    func test_nextColor_allUsed_returnsLeastFrequent() {
        let allOnce: [TabGroupColor] = [
            .blue, .purple, .pink, .orange, .indigo, .mint, .cyan, .teal,
        ]
        // Add a second .teal to make it the most frequent.
        let usedColors = allOnce + [.teal]
        let result = TabGroupColor.nextColor(excluding: usedColors)
        XCTAssertEqual(result, .blue, "Should return .blue as the least frequent (count 1) in assignment order")
    }

    /// Simulates deleting every group but one — only .blue remains.
    /// .purple should be returned since it is unused and first in assignment order.
    func test_nextColor_duplicateScenario() {
        let result = TabGroupColor.nextColor(excluding: [.blue])
        XCTAssertEqual(result, .purple, "Should return .purple since it is unused and first in assignment order")
    }

    /// When all 8 colors are used exactly once (exact tie), returns
    /// the first color in assignment order (.blue).
    func test_nextColor_allUsedEqualFrequency_returnsFirst() {
        let allOnce: [TabGroupColor] = [
            .blue, .purple, .pink, .orange, .indigo, .mint, .cyan, .teal,
        ]
        let result = TabGroupColor.nextColor(excluding: allOnce)
        XCTAssertEqual(result, .blue, "Equal frequency tie should return .blue (first in assignment order)")
    }

    /// Consecutive colors in assignment order should be visually distinct.
    func test_nextColor_consecutiveColorsAreDistinct() {
        var used: [TabGroupColor] = []
        var sequence: [TabGroupColor] = []
        for _ in 0..<8 {
            let next = TabGroupColor.nextColor(excluding: used)
            sequence.append(next)
            used.append(next)
        }
        XCTAssertEqual(sequence, [.blue, .purple, .pink, .orange, .indigo, .mint, .cyan, .teal])
    }
}
