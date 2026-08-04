// SurfaceViewScrollTests.swift
// CalixTests
//
// Tests for SurfaceView.adjustScrollDeltas static helper.
// Verifies precision multiplier, passthrough, zero/negative/large deltas.

import Testing
@testable import Calix

@MainActor
@Suite("SurfaceView Scroll Delta Adjustment Tests")
struct SurfaceViewScrollTests {

    // MARK: - Precision Scroll (hasPreciseScrollingDeltas = true)

    @Test("Precision scroll multiplies deltas by 2")
    func precisionScrollMultipliesDeltas() {
        let result = SurfaceView.adjustScrollDeltas(
            deltaX: 25,
            deltaY: 50,
            hasPreciseScrollingDeltas: true
        )
        #expect(result.x == 50)
        #expect(result.y == 100)
    }

    // MARK: - Non-Precision Scroll (hasPreciseScrollingDeltas = false)

    @Test("Non-precision scroll passes deltas through unchanged")
    func nonPrecisionScrollPassesThroughDeltas() {
        let result = SurfaceView.adjustScrollDeltas(
            deltaX: 3,
            deltaY: 5,
            hasPreciseScrollingDeltas: false
        )
        #expect(result.x == 3)
        #expect(result.y == 5)
    }

    // MARK: - Zero Deltas

    @Test("Zero deltas remain zero with precision flag true")
    func zeroDeltasPrecision() {
        let result = SurfaceView.adjustScrollDeltas(
            deltaX: 0,
            deltaY: 0,
            hasPreciseScrollingDeltas: true
        )
        #expect(result.x == 0)
        #expect(result.y == 0)
    }

    @Test("Zero deltas remain zero with precision flag false")
    func zeroDeltasNonPrecision() {
        let result = SurfaceView.adjustScrollDeltas(
            deltaX: 0,
            deltaY: 0,
            hasPreciseScrollingDeltas: false
        )
        #expect(result.x == 0)
        #expect(result.y == 0)
    }

    // MARK: - Negative Deltas

    @Test("Negative deltas preserve sign with precision multiplier")
    func negativeDeltasPrecision() {
        let result = SurfaceView.adjustScrollDeltas(
            deltaX: -15,
            deltaY: -30,
            hasPreciseScrollingDeltas: true
        )
        #expect(result.x == -30)
        #expect(result.y == -60)
    }

    @Test("Negative deltas pass through unchanged without precision")
    func negativeDeltasNonPrecision() {
        let result = SurfaceView.adjustScrollDeltas(
            deltaX: -15,
            deltaY: -30,
            hasPreciseScrollingDeltas: false
        )
        #expect(result.x == -15)
        #expect(result.y == -30)
    }

    // MARK: - Large Deltas (Fast Scroll)

    @Test("Large deltas are not capped with precision multiplier")
    func largeDeltasPrecision() {
        let result = SurfaceView.adjustScrollDeltas(
            deltaX: 200,
            deltaY: 200,
            hasPreciseScrollingDeltas: true
        )
        #expect(result.x == 400)
        #expect(result.y == 400)
    }

    @Test("Large deltas pass through unchanged without precision")
    func largeDeltasNonPrecision() {
        let result = SurfaceView.adjustScrollDeltas(
            deltaX: 200,
            deltaY: 200,
            hasPreciseScrollingDeltas: false
        )
        #expect(result.x == 200)
        #expect(result.y == 200)
    }

    // MARK: - Mixed Positive/Negative Deltas

    @Test("Mixed positive X and negative Y with precision multiplier")
    func mixedDeltasPrecision() {
        let result = SurfaceView.adjustScrollDeltas(
            deltaX: 10,
            deltaY: -40,
            hasPreciseScrollingDeltas: true
        )
        #expect(result == SurfaceView.ScrollDelta(x: 20, y: -80))
    }
}
