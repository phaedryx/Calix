// TabGroupColor.swift
// Calix
//
// 10-color preset enum for tab group color identification.

import AppKit

enum TabGroupColor: String, CaseIterable, Codable, Sendable {
    case orange, mint, teal, cyan, blue, indigo, purple, pink

    var nsColor: NSColor {
        switch self {
        case .orange: return .systemOrange
        case .mint: return .systemMint
        case .teal: return .systemTeal
        case .cyan: return .systemCyan
        case .blue: return .systemBlue
        case .indigo: return .systemIndigo
        case .purple: return .systemPurple
        case .pink: return .systemPink
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = TabGroupColor.decode(rawValue: raw)
    }

    /// Maps a persisted raw value to the current palette. `red`/`yellow`/
    /// `green` existed before those were reserved for the agent-state
    /// signal elsewhere in the UI; a group saved with one of them is
    /// remapped to a distinct replacement instead of every removed color
    /// collapsing onto the same fallback, which would erase the visual
    /// distinction between differently-colored groups on load.
    static func decode(rawValue raw: String?) -> TabGroupColor {
        guard let raw else { return .blue }
        if let color = TabGroupColor(rawValue: raw) { return color }
        switch raw {
        case "red": return .orange
        case "yellow": return .mint
        case "green": return .teal
        default: return .blue
        }
    }

    /// Visually distinct assignment order (avoids consecutive similar colors).
    /// Excludes red, yellow, and green: those are reserved elsewhere in the
    /// UI for agent state (error, waiting, working), so a tab group can't
    /// end up color-coded the same as an unrelated status signal.
    private static let assignmentOrder: [TabGroupColor] = [
        .blue, .purple, .pink, .orange, .indigo, .mint, .cyan, .teal,
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
