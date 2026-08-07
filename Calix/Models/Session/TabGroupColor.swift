// TabGroupColor.swift
// Calix
//
// 8-color preset enum for tab group color identification.

import AppKit

enum TabGroupColor: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, teal, blue, purple, pink

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = TabGroupColor.decode(rawValue: raw)
    }

    /// Maps a persisted raw value to the current palette. `mint`/`cyan`
    /// were dropped for being too visually similar to `teal`, and `indigo`
    /// for being too similar to `purple`; a group saved with one of them
    /// remaps to its closest surviving neighbor instead of falling back to
    /// the generic `.blue` default. Anything else unrecognized still falls
    /// back to `.blue`.
    static func decode(rawValue raw: String?) -> TabGroupColor {
        guard let raw else { return .blue }
        if let color = TabGroupColor(rawValue: raw) { return color }
        switch raw {
        case "mint", "cyan": return .teal
        case "indigo": return .purple
        default: return .blue
        }
    }

    /// Visually distinct assignment order (avoids consecutive similar colors).
    private static let assignmentOrder: [TabGroupColor] = [
        .red, .blue, .yellow, .purple, .green, .orange, .teal, .pink,
    ]

    /// Returns the next color that avoids duplicating existing group colors.
    /// If an unused color exists, returns the first one in assignmentOrder.
    /// If all colors are used, returns the least frequently used color.
    static func nextColor(excluding usedColors: [TabGroupColor]) -> TabGroupColor {
        let usedSet = Set(usedColors)
        if let available = assignmentOrder.first(where: { !usedSet.contains($0) }) {
            return available
        }
        let counts = Dictionary(usedColors.map { ($0, 1) }, uniquingKeysWith: +)
        let minCount = counts.values.min() ?? 0
        return assignmentOrder.first(where: { counts[$0, default: 0] == minCount }) ?? .blue
    }
}
