// TabReorderState.swift
// Calyx
//
// Drag state tracking for tab reordering.
// Manages dragged-tab identity, measured tab frames, insertion-slot computation,
// and slot-to-destination-index conversion.

import SwiftUI

// MARK: - ReorderAxis

enum ReorderAxis {
    case horizontal
    case vertical
}

// MARK: - TabReorderState

@MainActor @Observable
final class TabReorderState {

    // MARK: Properties

    var draggedTabID: UUID?
    var draggedTabIndex: Int?
    var insertionSlot: Int?
    var dragOffset: CGFloat = 0
    var tabFrames: [UUID: CGRect] = [:]

    // MARK: Insertion Slot

    /// Determines which slot the drag midpoint falls into by sorting tab frames
    /// along the given axis and counting how many tab midpoints the drag has passed.
    ///
    /// Slot layout for 4 tabs:
    /// ```
    /// [Tab0] | [Tab1] | [Tab2] | [Tab3]
    ///   ^  0  ^  1  ^  2  ^  3  ^  4
    /// ```
    func updateInsertionSlot(dragMidpoint: CGFloat, axis: ReorderAxis) {
        let sortedMidpoints: [CGFloat] = tabFrames.values
            .sorted { midpoint($0, axis: axis) < midpoint($1, axis: axis) }
            .map { midpoint($0, axis: axis) }

        var slot = 0
        for mid in sortedMidpoints {
            if dragMidpoint > mid {
                slot += 1
            } else {
                break
            }
        }
        insertionSlot = slot
    }

    // MARK: Destination Index

    /// Converts the current `insertionSlot` to a destination item index.
    ///
    /// Returns `nil` when no move is needed (slot is adjacent to the dragged tab)
    /// or when `insertionSlot` has not been set.
    ///
    /// The slot is clamped to `[0, tabCount]` before computation.
    func destinationIndex(fromIndex: Int, tabCount: Int) -> Int? {
        guard let rawSlot = insertionSlot else { return nil }

        let slot = min(max(rawSlot, 0), tabCount)

        if slot <= fromIndex {
            if slot == fromIndex { return nil }
            return slot
        } else {
            if slot == fromIndex + 1 { return nil }
            return slot - 1
        }
    }

    // MARK: Reset

    /// Clears all drag state to defaults.
    func reset() {
        draggedTabID = nil
        draggedTabIndex = nil
        insertionSlot = nil
        dragOffset = 0
        tabFrames = [:]
    }

    // MARK: Private

    private func midpoint(_ rect: CGRect, axis: ReorderAxis) -> CGFloat {
        switch axis {
        case .horizontal: rect.midX
        case .vertical: rect.midY
        }
    }
}

// MARK: - TabFramePreferenceKey

struct TabFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - GroupFramePreferenceKey

/// Distinct from `TabFramePreferenceKey` so a group header's frame doesn't
/// merge with the frames its own (or any other group's) tab rows report via
/// that key — preference values bubble up past intermediate
/// `.onPreferenceChange` listeners, so sharing one key type would pollute
/// the group-reorder frame set with every tab row's frame too.
struct GroupFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
