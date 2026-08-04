// SurfaceRegistryTests.swift
// CalixTests
//
// Tests for SurfaceRegistry — verifies UUID→SurfaceView mapping logic.
// Since ghostty C FFI types (ghostty_app_t, ghostty_surface_config_s) cannot be
// easily constructed in a unit-test context, these tests exercise the registry's
// bookkeeping behavior in isolation: empty-state invariants, unknown-UUID lookups,
// and idempotent destruction.

import XCTest
@testable import Calix

@MainActor
final class SurfaceRegistryTests: XCTestCase {

    // MARK: - Fixtures

    private var registry: SurfaceRegistry!

    override func setUp() {
        super.setUp()
        registry = SurfaceRegistry()
    }

    override func tearDown() {
        registry = nil
        super.tearDown()
    }

    // MARK: - Empty State

    /// A freshly created registry should have zero entries.
    func test_should_have_zero_count_when_newly_created() {
        XCTAssertEqual(registry.count, 0, "A new SurfaceRegistry must start with count == 0")
    }

    /// A freshly created registry should return an empty array of IDs.
    func test_should_return_empty_allIDs_when_newly_created() {
        XCTAssertTrue(registry.allIDs.isEmpty, "allIDs must be empty for a new registry")
    }

    // MARK: - Unknown UUID Lookups

    /// Looking up a view for a UUID that was never registered should return nil.
    func test_should_return_nil_view_when_uuid_is_unknown() {
        let unknownID = UUID()
        XCTAssertNil(registry.view(for: unknownID), "view(for:) must return nil for an unregistered UUID")
    }

    /// Looking up a controller for a UUID that was never registered should return nil.
    func test_should_return_nil_controller_when_uuid_is_unknown() {
        let unknownID = UUID()
        XCTAssertNil(registry.controller(for: unknownID), "controller(for:) must return nil for an unregistered UUID")
    }

    // MARK: - Idempotent Destruction

    /// Destroying a surface with an unknown UUID should not crash or alter the registry.
    func test_should_not_crash_when_destroying_unknown_uuid() {
        let unknownID = UUID()

        // Precondition: registry is empty.
        XCTAssertEqual(registry.count, 0)

        // This must not trap or throw.
        registry.destroySurface(unknownID)

        // Postcondition: registry remains empty and consistent.
        XCTAssertEqual(registry.count, 0, "count must remain 0 after destroying an unknown UUID")
        XCTAssertTrue(registry.allIDs.isEmpty, "allIDs must remain empty after destroying an unknown UUID")
    }

    /// Calling destroySurface multiple times with the same unknown UUID should be safe.
    func test_should_be_idempotent_when_destroying_same_unknown_uuid_twice() {
        let unknownID = UUID()

        registry.destroySurface(unknownID)
        registry.destroySurface(unknownID)

        XCTAssertEqual(registry.count, 0, "count must remain 0 after repeated destroys of an unknown UUID")
    }
}
