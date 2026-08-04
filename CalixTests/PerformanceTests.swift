//
//  PerformanceTests.swift
//  CalixTests
//
//  Performance benchmarks for core subsystems to catch
//  regressions in hot paths.
//
//  Coverage:
//  - SplitTree equalize with deep tree
//  - FuzzyMatcher scoring across many commands
//  - TabGroup bulk add/remove
//  - SurfaceRegistry lookup for unknown UUIDs
//  - NotificationSanitizer with large dirty strings
//

import XCTest
@testable import Calix

@MainActor
final class PerformanceTests: XCTestCase {

    // ==================== SplitTree ====================

    func test_splitTree_equalize_performance() {
        // Build a tree with many leaves via successive inserts
        var tree = SplitTree(leafID: UUID())
        for _ in 0..<100 {
            let newID = UUID()
            let leafIDs = tree.allLeafIDs()
            guard let lastLeaf = leafIDs.last else { break }
            let (newTree, _) = tree.insert(at: lastLeaf, direction: .horizontal, newID: newID)
            tree = newTree
        }

        measure {
            _ = tree.equalize()
        }
    }

    // ==================== FuzzyMatcher ====================

    func test_fuzzyMatcher_performance_with_many_commands() {
        // Build a large command list and score each via FuzzyMatcher
        let titles = (0..<1000).map { i in "Command Number \(i)" }

        measure {
            for title in titles {
                _ = FuzzyMatcher.score(query: "command 500", candidate: title)
            }
        }
    }

    // ==================== TabGroup ====================

    func test_tabGroup_addRemove_performance() {
        let group = TabGroup()

        measure {
            for _ in 0..<100 {
                let tab = Tab()
                group.addTab(tab)
            }
            let ids = group.tabs.map(\.id)
            for id in ids {
                group.removeTab(id: id)
            }
        }
    }

    // ==================== SurfaceRegistry ====================

    func test_surfaceRegistry_lookup_performance() {
        let registry = SurfaceRegistry()
        let ids = (0..<100).map { _ in UUID() }

        measure {
            for id in ids {
                _ = registry.view(for: id)
            }
        }
    }

    // ==================== NotificationSanitizer ====================

    func test_notificationSanitizer_performance() {
        let dirtyString = String(repeating: "Hello\u{202A}World\u{200B}\n\n\n", count: 100)

        measure {
            for _ in 0..<100 {
                _ = NotificationSanitizer.sanitize(dirtyString)
            }
        }
    }
}
