// SidebarLayout.swift
// Calix
//
// Actor-free shared constants for sidebar dimensions.

import Foundation

enum SidebarLayout {
    static let minWidth: CGFloat = 200
    static let maxWidth: CGFloat = 500
    static let defaultWidth: CGFloat = 220

    static func clampWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultWidth }
        return max(minWidth, min(maxWidth, width))
    }
}
